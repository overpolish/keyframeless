/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import "RoundedMiniCanvasRenderer.h"
#import "ShaderTypes.h"
#import <IOSurface/IOSurfaceObjC.h>
#import <KeyframelessKit/KKDataBlob.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation RoundedPlugin (Render)

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
  KKMotionBlurState mbState =
      [KKMotionBlur snapshotStateWithParameterAPI:paramAPI
                                        timingAPI:timingAPI
                                           atTime:renderTime];

  if (mbState.enabled && mbState.transitionsOnly) {
    NSString *tlJSON = KKReadCustomParamString(paramAPI, kKKParamTimelineData);
    KKTimeline *tl = tlJSON.length ? [KKTimeline timelineFromJSON:tlJSON] : nil;
    BOOL anyTransition = NO;
    if (tl.lanes.count) {
      CMTime effectStart = kCMTimeZero, effectDur = kCMTimeZero;
      [timingAPI startTimeForEffect:&effectStart];
      [timingAPI durationTimeForEffect:&effectDur];
      double durSec = CMTimeGetSeconds(effectDur);
      double frac = durSec > 0
                        ? MAX(0.0, MIN(1.0, (CMTimeGetSeconds(renderTime) -
                                             CMTimeGetSeconds(effectStart)) /
                                                durSec))
                        : 0.0;
      for (KKLane *lane in tl.lanes) {
        if (!lane.enabled || lane.keyposes.count < 2)
          continue;
        NSArray<KKKeyPose *> *kps = lane.keyposes;
        for (NSUInteger i = 0; i + 1 < kps.count; i++) {
          if (frac < kps[i + 1].time) {
            KKKeyPose *a = kps[i], *b = kps[i + 1];
            for (NSUInteger j = 0; j < MIN(a.values.count, b.values.count);
                 j++) {
              if (fabs(a.values[j].doubleValue - b.values[j].doubleValue) >
                  1e-6) {
                anyTransition = YES;
                break;
              }
            }
            break;
          }
        }
        if (anyTransition)
          break;
      }
    }
    if (!anyTransition)
      mbState.enabled = NO;
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

  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  CMTime effectStart = kCMTimeZero, effectDuration = kCMTimeZero;
  [timingAPI startTimeForEffect:&effectStart];
  [timingAPI durationTimeForEffect:&effectDuration];
  double durSec = CMTimeGetSeconds(effectDuration);
  double frac = (durSec > 0)
                    ? MAX(0.0, MIN(1.0, (CMTimeGetSeconds(renderTime) -
                                         CMTimeGetSeconds(effectStart)) /
                                            durSec))
                    : 0.0;

  NSArray<NSNumber *> *radiusVals = nil;
  NSArray<NSNumber *> *cropVals = nil;
  // `enabled` now means "animatable", not "apply" — a constant (disabled)
  // lane still contributes its single-keypose value. KKTimelineLaneValueAt
  // Fraction returns that constant for a 1-keypose lane regardless of frac.
  for (KKLane *lane in timeline.lanes) {
    if (!radiusVals && [lane.label isEqualToString:@"Radius"])
      radiusVals = KKTimelineLaneValueAtFraction(lane, frac);
    else if (!cropVals && [lane.label isEqualToString:@"Crop"])
      cropVals = KKTimelineLaneValueAtFraction(lane, frac);
  }

  outParams->radius = radiusVals.count > 0 ? radiusVals[0].doubleValue : 20.0;

  outParams->cropW = 1.0;
  outParams->cropH = 1.0;
  outParams->cropX = 0.0;
  outParams->cropY = 0.0;
  if (cropVals.count >= 4) {
    // Crop lane: [width, height, x, y] — normalized; x/y are center offsets.
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

  // Mini-canvas source feed (7a): only on full-frame ticks — a sub-tile
  // (parent Scale > 100%) would publish a squashed sub-region. Runs before
  // the MB/normal branches so it captures every full render regardless of
  // path; the feed self-throttles so this is cheap during playback.
  {
    FxRect sTile = sourceImages[0].tilePixelBounds;
    FxRect sImg = sourceImages[0].imagePixelBounds;
    BOOL fullFrame = (sTile.left == sImg.left && sTile.right == sImg.right &&
                      sTile.top == sImg.top && sTile.bottom == sImg.bottom);
    if (fullFrame) {
      KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
      MTLPixelFormat pf =
          [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
      uint64_t rid = destinationImage.deviceRegistryID;
      id<MTLCommandQueue> q = [cache commandQueueWithRegistryID:rid
                                                    pixelFormat:pf];
      id<MTLDevice> dev = [cache deviceWithRegistryID:rid];
      if (q && dev) {
        id<MTLTexture> srcTex = [sourceImages[0] metalTextureForDevice:dev];
        if (!self.miniCanvasFeed) {
          KKMiniCanvasFeed *feed = [[KKMiniCanvasFeed alloc]
              initWithDescriptorPath:RoundedMiniCanvasDescriptorPath];
          self.miniCanvasFeed = feed;
          [feed release];
        }
        [self.miniCanvasFeed updateWithSourceTexture:srcTex
                                              device:dev
                                        commandQueue:q];
        [cache returnCommandQueueToCache:q];
      }
    }
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
  // origin — handles render contexts where imagePixelBounds isn't at
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
