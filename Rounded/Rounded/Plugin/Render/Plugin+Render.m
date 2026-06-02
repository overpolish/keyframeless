/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import "RoundedMiniCanvasRenderer.h"
#import "RoundedOSCRadiusMath.h"
#import "ShaderTypes.h"
#import <IOSurface/IOSurfaceObjC.h>
#import <KeyframelessKit/KKDataBlob.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation RoundedPlugin (Render)

// Always request the current frame (= default behavior). When a boundary
// popover is open, additionally request that clip fraction's frame so the
// preview can show the actual rendered frame at that time. Step (d) refines
// the fraction→CMTime mapping (host-aware); for now: effectStart +
// frac·effectDuration.
- (BOOL)scheduleInputs:(NSArray<FxImageTileRequest *> *_Nullable *_Nullable)
                           inputImageRequests
       withPluginState:(NSData *)pluginState
                atTime:(CMTime)renderTime
                 error:(NSError **)error {
  KKMotionBlurState mbState = {0};
  if (pluginState.length >= sizeof(KKMotionBlurState))
    [pluginState getBytes:&mbState length:sizeof(mbState)];
  *inputImageRequests = KKBuildSourceRequests(
      renderTime, mbState, RoundedMiniCanvasRequestPath, self.renderCache,
      ^id(CMTime t) {
        return [[FxImageTileRequest alloc]
            initWithSource:kFxImageTileRequestSourceEffectClip
                      time:t
            includeFilters:YES
               parameterID:0];
      });
  return YES;
}

- (BOOL)pluginState:(NSData **)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error {
  RoundedPluginState params;
  if (![self roundedParams:&params atTime:renderTime error:error])
    return NO;

  id<FxParameterRetrievalAPI_v6> paramAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  NSString *mbJSON = KKReadCustomParamString(paramAPI, kKKParamMotionBlurData);
  KKMotionBlurState mbState = [KKMotionBlur snapshotStateFromJSON:mbJSON
                                                        timingAPI:timingAPI
                                                           atTime:renderTime];

  // Per-frame fire-mode gate. In transitions-only / value-changing modes, skip
  // the whole multi-pass on frames where nothing relevant moves across the
  // shutter window (saves the extra source decodes + accumulate, and keeps
  // scheduleInputs from requesting sub-frame sources). Always mode is
  // unconditional.
  if (mbState.enabled && mbState.mode != KKMotionBlurModeAlways) {
    CMTime es = kCMTimeZero, dur = kCMTimeZero;
    [timingAPI startTimeForEffect:&es];
    [timingAPI durationTimeForEffect:&dur];
    double durSec = CMTimeGetSeconds(dur);
    if (durSec > 0) {
      NSArray<NSValue *> *times = [KKMotionBlur sampleTimesForState:mbState
                                                         renderTime:renderTime];
      CMTime tEarliest = renderTime;
      if (times.count)
        [times.lastObject getValue:&tEarliest];
      double fracEnd =
          (CMTimeGetSeconds(renderTime) - CMTimeGetSeconds(es)) / durSec;
      double fracStart =
          (CMTimeGetSeconds(tEarliest) - CMTimeGetSeconds(es)) / durSec;
      NSString *tlJSON =
          KKReadCustomParamString(paramAPI, kKKParamTimelineData);
      KKTimeline *tl =
          tlJSON.length ? [KKTimeline timelineFromJSON:tlJSON] : nil;
      if (![KKMotionBlur frameShouldBlurForMode:mbState.mode
                                       timeline:tl
                                      fracStart:fracStart
                                        fracEnd:fracEnd])
        mbState.enabled = NO;
    }
  }

  // Layout: [KKMotionBlurState | N × RoundedPluginState]. Sample 0 is at
  // renderTime; samples 1..N-1 are evaluated backwards across the shutter
  // window when blur is enabled.
  NSMutableData *data = [NSMutableData data];
  [data appendBytes:&mbState length:sizeof(mbState)];
  [data appendBytes:&params length:sizeof(params)];

  if (mbState.enabled) {
    NSArray<NSValue *> *times = [KKMotionBlur sampleTimesForState:mbState
                                                       renderTime:renderTime];
    for (NSUInteger i = 1; i < times.count; i++) {
      CMTime t = kCMTimeZero;
      [times[i] getValue:&t];
      RoundedPluginState p;
      if (![self roundedParams:&p atTime:t error:error])
        return NO;
      [data appendBytes:&p length:sizeof(p)];
    }
  }

  *pluginState = data;
  return (*pluginState != nil);
}

- (BOOL)roundedParams:(RoundedPluginState *)outParams
               atTime:(CMTime)renderTime
                error:(NSError **)error {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (paramGetAPI == nil) {
    if (error != NULL) {
      *error =
          [NSError errorWithDomain:FxPlugErrorDomain
                              code:kFxError_ThirdPartyDeveloperStart + 20
                          userInfo:@{
                            NSLocalizedDescriptionKey :
                                @"Unable to retrieve FxParameterRetrievalAPI_v6"
                          }];
    }
    return NO;
  }
  NSString *timelineJSON =
      KKReadCustomParamString(paramGetAPI, kKKParamTimelineData);
  KKTimeline *timeline =
      timelineJSON.length ? [KKTimeline timelineFromJSON:timelineJSON] : nil;

  // Cache the loop toggle (lives in the UI-state blob) so the main-queue
  // playhead poll can decide whether to wrap at the clip end.
  NSString *uiJSON = KKReadCustomParamString(paramGetAPI, kParamUIState);
  if (uiJSON.length) {
    NSDictionary *ui = [NSJSONSerialization
        JSONObjectWithData:[uiJSON dataUsingEncoding:NSUTF8StringEncoding]
                   options:0
                     error:nil];
    if ([ui isKindOfClass:[NSDictionary class]])
      self.renderCache.loopEnabled = [ui[@"loopEnabled"] boolValue];
  }

  BOOL hasTiming = KKRefreshRenderCache(
      self.apiManager, (KKTimelineInspectorView *)self.inspectorView,
      self.renderCache);
  double durSec = self.renderCache.effectDurSec;
  double frac = hasTiming
                    ? MAX(0.0, MIN(1.0, (CMTimeGetSeconds(renderTime) -
                                         self.renderCache.effectStartSec) /
                                            durSec))
                    : 0.0;
  // Live scrubber: render ticks stop ~1s before the clip end (FCP
  // pre-render buffer - renderTime leads currentTime). Arm the
  // self-terminating poll so it follows currentTime through the tail.
  if (hasTiming) {
    KKPlayheadPoller *poller = self.playheadPoller;
    dispatch_async(dispatch_get_main_queue(), ^{
      [poller ensureRunning];
    });
  }

  NSArray<NSNumber *> *radiusVals = nil;
  NSArray<NSNumber *> *cropVals = nil;
  // `enabled` now means "animatable", not "apply" - a constant (disabled)
  // lane still contributes its single-keypose value. KKTimelineLaneValueAt
  // Fraction returns that constant for a 1-keypose lane regardless of frac.
  for (KKLane *lane in timeline.lanes) {
    if (!radiusVals && [lane.label isEqualToString:@"Radius"])
      radiusVals = KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
    else if (!cropVals && [lane.label isEqualToString:@"Crop"])
      cropVals = KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
  }

  outParams->radius = radiusVals.count > 0 ? radiusVals[0].doubleValue : 20.0;

  outParams->cropW = 1.0;
  outParams->cropH = 1.0;
  outParams->cropX = 0.0;
  outParams->cropY = 0.0;
  if (cropVals.count >= 4) {
    // Crop lane: [width, height, x, y] - normalized; x/y are center offsets.
    outParams->cropW = cropVals[0].doubleValue;
    outParams->cropH = cropVals[1].doubleValue;
    outParams->cropX = cropVals[2].doubleValue;
    outParams->cropY = cropVals[3].doubleValue;
  }
  return YES;
}

- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError *_Nullable *)outError {
  if (!pluginState || !sourceImages[0].ioSurface ||
      !destinationImage.ioSurface ||
      pluginState.length <
          sizeof(KKMotionBlurState) + sizeof(RoundedPluginState)) {
    if (outError != NULL) {
      *outError =
          [NSError errorWithDomain:FxPlugErrorDomain
                              code:kFxError_InvalidParameter
                          userInfo:@{
                            NSLocalizedDescriptionKey :
                                @"Invalid plugin state received from host"
                          }];
    }

    return NO;
  }

  KKMotionBlurState mbState;
  [pluginState getBytes:&mbState length:sizeof(mbState)];

  // Mini-canvas source feed (7a): only on full-frame ticks - a sub-tile
  // (parent Scale > 100%) would publish a squashed sub-region. Runs before
  // the MB/normal branches so it captures every full render regardless of
  // path; the feed self-throttles so this is cheap during playback.
  // While a boundary popover is open, publish ONLY the tile whose mediaTime
  // matches the requested boundary time. FCP does NOT honor request order and
  // serves stale boundary tiles while it re-schedules (proven via mediaTime
  // logs - sourceImages[1] was often the *previous* diamond's frame), so
  // index-based selection flickers between hold frames. If no delivered tile
  // matches this tick, skip the publish and keep the last good frame.
  // Build the list of (slot index, tile) pairs to publish this tick. The
  // boundary channel can request multiple times (onion-skin) - we match
  // each requested time to whichever delivered tile's mediaTime is closest
  // (within ~1 frame). Tiles that don't match anything are skipped (FCP
  // serves stale boundary tiles while it re-schedules - same caveat as the
  // single-time path).
  NSArray<NSNumber *> *reqSecs = self.renderCache.boundaryReqSecs;
  NSMutableArray *pairs = [NSMutableArray array]; // @[ @(slotIdx), tile ]
  if (self.renderCache.boundaryFeedActive && reqSecs.count > 0) {
    if (self.miniCanvasFeed.slotCount != reqSecs.count) {
      self.miniCanvasFeed.slotCount = reqSecs.count;
      [self.miniCanvasFeed publishDescriptor];
    }
    // Greedy assignment: each REQUESTED time claims its closest unclaimed
    // delivered tile. Walking the requests (not the delivered list) avoids
    // the playhead-tile (always sourceImages[0]) poaching a middle slot
    // before the actual mid-clip tile gets a chance to match.
    const double kMaxDt = 0.5;
    NSMutableArray<NSNumber *> *availTileIdx = [NSMutableArray array];
    for (NSUInteger i = 0; i < sourceImages.count; i++)
      [availTileIdx addObject:@(i)];
    for (NSUInteger slot = 0; slot < reqSecs.count; slot++) {
      double want = reqSecs[slot].doubleValue;
      NSInteger bestPos = -1;
      double bestDt = kMaxDt;
      for (NSUInteger p = 0; p < availTileIdx.count; p++) {
        NSUInteger ti = availTileIdx[p].unsignedIntegerValue;
        double mt = CMTimeGetSeconds(sourceImages[ti].mediaTime);
        double dt = fabs(mt - want);
        if (dt < bestDt) {
          bestDt = dt;
          bestPos = (NSInteger)p;
        }
      }
      if (bestPos >= 0) {
        NSUInteger ti = availTileIdx[bestPos].unsignedIntegerValue;
        [pairs addObject:@[ @(slot), sourceImages[ti] ]];
        [availTileIdx removeObjectAtIndex:bestPos];
      }
    }
  } else {
    if (self.miniCanvasFeed.slotCount != 1)
      self.miniCanvasFeed.slotCount = 1;
    [pairs addObject:@[ @0, sourceImages[0] ]];
  }
  for (NSArray *pair in pairs) {
    NSUInteger slotIdx = [pair[0] unsignedIntegerValue];
    FxImageTile *feedTile = pair[1];
    FxRect sTile = feedTile.tilePixelBounds;
    FxRect sImg = feedTile.imagePixelBounds;
    BOOL fullFrame = (sTile.left == sImg.left && sTile.right == sImg.right &&
                      sTile.top == sImg.top && sTile.bottom == sImg.bottom);
    if (!fullFrame)
      continue;
    // FCP's project-library preview re-runs the effect into a 1920×1080
    // browser thumb destination while passing the same source. Both
    // contexts write into the same per-instance feed slot 0 → aspect
    // ping-pongs. Gate on dest *aspect* matching the source within a
    // generous tolerance (FCP often delivers off-by-one bounds for the
    // canonical render).
    FxRect dImg = destinationImage.imagePixelBounds;
    int sW = sImg.right - sImg.left, sH = sImg.top - sImg.bottom;
    int dW = dImg.right - dImg.left, dH = dImg.top - dImg.bottom;
    double sAsp = (sH > 0) ? fabs((double)sW / (double)sH) : 0;
    double dAsp = (dH > 0) ? fabs((double)dW / (double)dH) : 0;
    if (sAsp > 0 && dAsp > 0 && fabs(sAsp - dAsp) > 0.05)
      continue;
    KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
    MTLPixelFormat pf =
        [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
    uint64_t rid = destinationImage.deviceRegistryID;
    id<MTLCommandQueue> q = [cache commandQueueWithRegistryID:rid
                                                  pixelFormat:pf];
    id<MTLDevice> dev = [cache deviceWithRegistryID:rid];
    if (!q || !dev)
      continue;
    id<MTLTexture> srcTex = [feedTile metalTextureForDevice:dev];
    if (!self.miniCanvasFeed) {
      self.miniCanvasFeed = [[KKMiniCanvasFeed alloc]
          initWithDescriptorPath:RoundedMiniCanvasDescriptorPath];
    }
    NSArray<NSNumber *> *fracs = self.renderCache.boundaryReqFracs;
    double tag = (slotIdx < fracs.count) ? fracs[slotIdx].doubleValue : 0.0;
    [self.miniCanvasFeed updateSlot:slotIdx
                  withSourceTexture:srcTex
                                tag:tag
                             device:dev
                       commandQueue:q];
    [cache returnCommandQueueToCache:q];
  }

  id<MTLRenderPipelineState> pipelineState =
      [self pipelineStateForPluginID:kPluginID
                    destinationImage:destinationImage
                        vertexShader:@"vertexShader"
                      fragmentShader:@"fragmentShader"
                           blendMode:KKBlendModePremultipliedAlpha];

  if (!pipelineState)
    return NO;

  // Per-tile constants that don't vary across motion-blur samples.
  simd_float2 imageSize = {(float)(destinationImage.imagePixelBounds.right -
                                   destinationImage.imagePixelBounds.left),
                           (float)(destinationImage.imagePixelBounds.top -
                                   destinationImage.imagePixelBounds.bottom)};
  // Top-left of the dest tile in Y-down image-pixel space, relative to
  // the image origin. Empirically FCP's project-library preview composites
  // tiles with FxRect.bottom as the Y-down top offset within the image
  // (see logged data: strips appear in reverse FxRect-Y order). Subtract
  // imagePixelBounds.left/bottom so the offset is relative to the image
  // origin - handles render contexts where imagePixelBounds isn't at
  // (0,0) (e.g. 480x270 thumbnail render at L720 B405).
  simd_float2 tileOffsetPx = {
      (float)(destinationImage.tilePixelBounds.left -
              destinationImage.imagePixelBounds.left),
      (float)(destinationImage.tilePixelBounds.bottom -
              destinationImage.imagePixelBounds.bottom)};
  void (^encodeDraw)(id<MTLRenderCommandEncoder>, NSArray<id<MTLTexture>> *,
                     RoundedPluginState) =
      ^(id<MTLRenderCommandEncoder> enc, NSArray<id<MTLTexture>> *texs,
        RoundedPluginState s) {
        float fragmentRadius = (float)s.radius;
        simd_float2 cropCenter, cropSize;
        KKCropModelToShader(s.cropW, s.cropH, s.cropX, s.cropY, imageSize,
                            &cropCenter, &cropSize);
        [enc setRenderPipelineState:pipelineState];
        [enc setFragmentTexture:texs[0] atIndex:KKTextureIndex_InputImage];
        [enc setFragmentBytes:&fragmentRadius
                       length:sizeof(fragmentRadius)
                      atIndex:FragmentIndex_Radius];
        [enc setFragmentBytes:&imageSize
                       length:sizeof(imageSize)
                      atIndex:FragmentIndex_ImageSize];
        [enc setFragmentBytes:&tileOffsetPx
                       length:sizeof(tileOffsetPx)
                      atIndex:FragmentIndex_TileOffsetPx];
        [enc setFragmentBytes:&cropCenter
                       length:sizeof(cropCenter)
                      atIndex:FragmentIndex_CropCenter];
        [enc setFragmentBytes:&cropSize
                       length:sizeof(cropSize)
                      atIndex:FragmentIndex_CropSize];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0
                vertexCount:4];
      };

  if (mbState.enabled) {
    __weak typeof(self) weakSelf = self;
    NSData *capturedState = pluginState;
    BOOL applied = [KKMotionBlur
        applyToDestinationImage:destinationImage
                   sourceImages:sourceImages
                          state:mbState
                     renderTime:renderTime
                    renderBlock:^BOOL(int sampleIndex,
                                      id<MTLTexture> sampleDest,
                                      id<MTLCommandBuffer> commandBuffer,
                                      NSArray<id<MTLTexture>> *inputTextures) {
                      __strong typeof(weakSelf) strongSelf = weakSelf;
                      if (!strongSelf || inputTextures.count == 0)
                        return NO;
                      NSUInteger offset =
                          sizeof(KKMotionBlurState) +
                          (NSUInteger)sampleIndex * sizeof(RoundedPluginState);
                      if (offset + sizeof(RoundedPluginState) >
                          capturedState.length)
                        return NO;
                      RoundedPluginState s;
                      [capturedState
                          getBytes:&s
                             range:NSMakeRange(offset,
                                               sizeof(RoundedPluginState))];
                      return [strongSelf
                          encodeFullScreenQuadIntoTexture:sampleDest
                                         destinationImage:destinationImage
                                            commandBuffer:commandBuffer
                                           sourceTextures:inputTextures
                                                 commands:^(
                                                     id<MTLRenderCommandEncoder>
                                                         enc,
                                                     NSArray<id<MTLTexture>>
                                                         *texs) {
                                                   encodeDraw(enc, texs, s);
                                                 }];
                    }];
    if (applied)
      return YES;
    // Fall through on failure so the user sees the un-blurred frame.
  }

  RoundedPluginState state;
  [pluginState getBytes:&state
                  range:NSMakeRange(sizeof(KKMotionBlurState),
                                    sizeof(RoundedPluginState))];

  return [self
      encodeRenderCommandsForDestinationImage:destinationImage
                                 sourceImages:sourceImages
                                     commands:^(
                                         id<MTLRenderCommandEncoder> encoder,
                                         NSArray<id<MTLTexture>>
                                             *inputTextures) {
                                       encodeDraw(encoder, inputTextures,
                                                  state);
                                     }];
}

@end
#pragma clang diagnostic pop
