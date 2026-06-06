/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "MagicMoveMiniViewerRenderer.h"
#import "MagicMoveParamsBuild.h"
#import "OSC.h"
#import "Plugin_Private.h"
#import "ShaderTypes.h"
#import <KeyframelessKit/KeyframelessKit.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation MagicMovePlugin (Render)

// Always request the current frame. When the keypose-value popover is open it
// writes a request file with the desired clip fraction(s); we also request
// the source at each of those times so the boundary preview / filmstrip /
// onion-skin can show the rendered frame there.
- (BOOL)scheduleInputs:(NSArray<FxImageTileRequest *> *_Nullable *_Nullable)
                           inputImageRequests
       withPluginState:(NSData *)pluginState
                atTime:(CMTime)renderTime
                 error:(NSError **)error {
  KKMotionBlurState mbState = {0};
  if (pluginState.length >= sizeof(KKMotionBlurState))
    [pluginState getBytes:&mbState length:sizeof(mbState)];
  NSString *reqPath = MagicMoveMiniViewerRequestPathForUUID(
      KKInstanceUUIDForAPI(self.apiManager));
  *inputImageRequests = KKBuildSourceRequests(
      renderTime, mbState, reqPath, self.renderCache, ^id(CMTime t) {
        return [[FxImageTileRequest alloc]
            initWithSource:kFxImageTileRequestSourceEffectClip
                      time:t
            includeFilters:YES
               parameterID:0];
      });

  return YES;
}

static double KKFracForTime(CMTime t, double effectStartSec, double durSec) {
  if (durSec <= 0)
    return 0.0;
  return MAX(0.0, MIN(1.0, (CMTimeGetSeconds(t) - effectStartSec) / durSec));
}

static BOOL KKMagicMoveIntervalHasRWM(KKInterval *interval) {
  return [interval userBoolForKey:@"rotateWithMotion" default:NO];
}

double KKMagicMoveRotateWithMotionAdjustmentDegrees(KKLane *positionLane,
                                                    double frac,
                                                    double effectDurSec) {
  return KKMotionLeanDegrees(positionLane, frac, effectDurSec,
                             KKMotionLeanConfigDefault(),
                             ^BOOL(KKInterval *outgoing) {
                               return KKMagicMoveIntervalHasRWM(outgoing);
                             });
}

void KKMagicMoveFillParamsFromTimeline(MagicMoveParams *outParams,
                                       KKTimeline *timeline, double frac,
                                       double effectDurSec) {
  KKLane *positionLane = nil;
  NSArray<NSNumber *> *positionVals = nil;
  NSArray<NSNumber *> *rotationVals = nil;
  NSArray<NSNumber *> *scaleVals = nil;
  NSArray<NSNumber *> *opacityVals = nil;
  NSArray<NSNumber *> *anchorVals = nil;
  for (KKLane *lane in timeline.lanes) {
    if ([lane.label isEqualToString:@"Position"]) {
      positionLane = lane;
      positionVals = KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
    } else if ([lane.label isEqualToString:@"Rotation"]) {
      rotationVals = KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
    } else if ([lane.label isEqualToString:@"Scale"]) {
      scaleVals = KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
    } else if ([lane.label isEqualToString:@"Opacity"]) {
      opacityVals = KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
    } else if ([lane.label isEqualToString:@"Anchor"]) {
      anchorVals = KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
    }
  }
  double posX = positionVals.count > 0 ? positionVals[0].doubleValue : 0.5;
  double posY = positionVals.count > 1 ? positionVals[1].doubleValue : 0.5;
  double rotXdeg = rotationVals.count > 0 ? rotationVals[0].doubleValue : 0.0;
  double rotYdeg = rotationVals.count > 1 ? rotationVals[1].doubleValue : 0.0;
  double rotZdeg = rotationVals.count > 2 ? rotationVals[2].doubleValue : 0.0;
  static const double kDegToRad = M_PI / 180.0;

  rotZdeg += KKMagicMoveRotateWithMotionAdjustmentDegrees(positionLane, frac,
                                                          effectDurSec);

  outParams->translate =
      (simd_float2){(float)(posX - 0.5), (float)(posY - 0.5)};
  // Anchor is the pivot rotation/scale swing around: an offset from the clip
  // center in the same normalized object space as Position (0.5,0.5 = center).
  double anchorX = anchorVals.count > 0 ? anchorVals[0].doubleValue : 0.5;
  double anchorY = anchorVals.count > 1 ? anchorVals[1].doubleValue : 0.5;
  outParams->anchorOffset =
      (simd_float2){(float)(anchorX - 0.5), (float)(anchorY - 0.5)};
  outParams->rotation = (float)(rotZdeg * kDegToRad);
  outParams->rotationX = (float)(rotXdeg * kDegToRad);
  outParams->rotationY = (float)(rotYdeg * kDegToRad);
  // Floor at 0: overshoot/undershoot easing can evaluate scale below 0, and a
  // negative scale flips the clip - clamp rather than flip.
  double sclX =
      scaleVals.count > 0 ? fmax(0.0, scaleVals[0].doubleValue) : 100.0;
  double sclY =
      scaleVals.count > 1 ? fmax(0.0, scaleVals[1].doubleValue) : 100.0;
  outParams->scaleX = (float)(sclX / 100.0);
  outParams->scaleY = (float)(sclY / 100.0);
  // Clamp to 0-100%: easing can overshoot past the lane bounds.
  double opac = opacityVals.count > 0
                    ? fmax(0.0, fmin(100.0, opacityVals[0].doubleValue))
                    : 100.0;
  outParams->opacity = (float)(opac / 100.0);
}

- (BOOL)magicMoveParams:(MagicMoveParams *)outParams
                 atTime:(CMTime)time
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

  BOOL hasTiming = KKRefreshRenderCache(self.apiManager, self.inspectorView,
                                        self.renderCache);
  if (hasTiming) {
    KKPlayheadPoller *poller = self.playheadPoller;
    dispatch_async(dispatch_get_main_queue(), ^{
      [poller ensureRunning];
    });
  }
  // Even when this tick's KKRefreshRenderCache fails, use the last-known cache
  // values so frac is still correct (the cache survives across ticks once
  // it's been populated once).
  double frac = KKFracForTime(time, self.renderCache.effectStartSec,
                              self.renderCache.effectDurSec);
  KKMagicMoveFillParamsFromTimeline(outParams, timeline, frac,
                                    self.renderCache.effectDurSec);
  return YES;
}

- (BOOL)pluginState:(NSData **)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error {
  // Compute mainParams via the full path (loads API, refreshes timing cache,
  // updates loop toggle, kicks playhead poller). This populates renderCache so
  // boundary-slot evaluation below can reuse it.
  MagicMoveParams params;
  if (![self magicMoveParams:&params atTime:renderTime error:error])
    return NO;

  id<FxParameterRetrievalAPI_v6> paramAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  NSString *mbJSON = KKReadCustomParamString(paramAPI, kKKParamMotionBlurData);
  KKMotionBlurState mbState = [KKMotionBlur snapshotStateFromJSON:mbJSON
                                                        timingAPI:timingAPI
                                                           atTime:renderTime];

  NSMutableData *data = [NSMutableData data];
  [data appendBytes:&mbState length:sizeof(mbState)];
  [data appendBytes:&params length:sizeof(params)];

  if (mbState.enabled) {
    NSArray<NSValue *> *times = [KKMotionBlur sampleTimesForState:mbState
                                                       renderTime:renderTime];
    for (NSUInteger i = 1; i < times.count; i++) {
      CMTime t = kCMTimeZero;
      [times[i] getValue:&t];
      MagicMoveParams p;
      if (![self magicMoveParams:&p atTime:t error:error])
        return NO;
      [data appendBytes:&p length:sizeof(p)];
    }
  }

  *pluginState = data;
  return (*pluginState != nil);
}

- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError *_Nullable *)outError {
  if (!pluginState)
    return NO;
  if (pluginState.length < sizeof(KKMotionBlurState) + sizeof(MagicMoveParams))
    return NO;

  KKMotionBlurState mbState;
  [pluginState getBytes:&mbState length:sizeof(mbState)];

  // Mini-viewer feed: publish raw source per slot (single-slot = playhead,
  // multi-slot = boundary preview / filmstrip / onion). The mini-viewer
  // renderer (same plugin XPC, metallib loaded) applies the real shader
  // source→dest locally per slot, so KK pushes live timeline updates per drag
  // tick without any FxPlug param write (no Flexo write-lock deadlock). Shared
  // glue in KKPlugin (MiniViewerFeed); per-instance descriptor path keyed by
  // the instance UUID so stacked MagicMove clips don't share a /tmp file.
  [self kkPublishMiniViewerFeedForDestination:destinationImage
                                 sourceImages:sourceImages
                               descriptorPath:
                                   MagicMoveMiniViewerDescriptorPathForUUID(
                                       KKInstanceUUIDForAPI(self.apiManager))
                              boundaryReqSecs:self.renderCache.boundaryReqSecs
                             boundaryReqFracs:self.renderCache.boundaryReqFracs
                              multiSlotActive:YES
                                   defaultTag:CMTimeGetSeconds(renderTime)];

  simd_float2 tileOffsetPx = {
      (float)(destinationImage.tilePixelBounds.left -
              destinationImage.imagePixelBounds.left),
      (float)(destinationImage.tilePixelBounds.bottom -
              destinationImage.imagePixelBounds.bottom)};

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
                          (NSUInteger)sampleIndex * sizeof(MagicMoveParams);
                      if (offset + sizeof(MagicMoveParams) >
                          capturedState.length)
                        return NO;
                      MagicMoveParams sampleParams;
                      [capturedState
                          getBytes:&sampleParams
                             range:NSMakeRange(offset,
                                               sizeof(MagicMoveParams))];
                      id<MTLRenderPipelineState> pipeline = [strongSelf
                          pipelineStateForPluginID:kPluginID
                                  destinationImage:destinationImage
                                      vertexShader:@"vertexShader"
                                    fragmentShader:@"fragmentShader"
                                         blendMode:
                                             KKBlendModePremultipliedAlpha];
                      if (!pipeline)
                        return NO;
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
                                                   [enc setRenderPipelineState:
                                                            pipeline];
                                                   [enc
                                                       setFragmentTexture:
                                                           texs[0]
                                                                  atIndex:
                                                                      KKTextureIndex_InputImage];
                                                   [enc
                                                       setFragmentBytes:
                                                           &sampleParams
                                                                 length:
                                                                     sizeof(
                                                                         sampleParams)
                                                                atIndex:
                                                                    FragmentIndex_Params];
                                                   [enc
                                                       setFragmentBytes:
                                                           &tileOffsetPx
                                                                 length:
                                                                     sizeof(
                                                                         tileOffsetPx)
                                                                atIndex:
                                                                    FragmentIndex_TileOffsetPx];
                                                   [enc
                                                       drawPrimitives:
                                                           MTLPrimitiveTypeTriangleStrip
                                                          vertexStart:0
                                                          vertexCount:4];
                                                 }];
                    }];
    if (applied)
      return YES;
  }

  MagicMoveParams params;
  [pluginState getBytes:&params
                  range:NSMakeRange(sizeof(KKMotionBlurState), sizeof(params))];

  id<MTLRenderPipelineState> pipeline =
      [self pipelineStateForPluginID:kPluginID
                    destinationImage:destinationImage
                        vertexShader:@"vertexShader"
                      fragmentShader:@"fragmentShader"
                           blendMode:KKBlendModePremultipliedAlpha];
  if (!pipeline)
    return NO;

  return [self
      encodeRenderCommandsForDestinationImage:destinationImage
                                 sourceImages:sourceImages
                                     commands:^(id<MTLRenderCommandEncoder> enc,
                                                NSArray<id<MTLTexture>> *texs) {
                                       [enc setRenderPipelineState:pipeline];
                                       [enc
                                           setFragmentTexture:texs[0]
                                                      atIndex:
                                                          KKTextureIndex_InputImage];
                                       [enc setFragmentBytes:&params
                                                      length:sizeof(params)
                                                     atIndex:
                                                         FragmentIndex_Params];
                                       [enc
                                           setFragmentBytes:&tileOffsetPx
                                                     length:sizeof(tileOffsetPx)
                                                    atIndex:
                                                        FragmentIndex_TileOffsetPx];
                                       [enc drawPrimitives:
                                                MTLPrimitiveTypeTriangleStrip
                                               vertexStart:0
                                               vertexCount:4];
                                     }];
}

- (BOOL)sourceTileRect:(FxRect *)sourceTileRect
       sourceImageIndex:(NSUInteger)sourceImageIndex
           sourceImages:(NSArray<FxImageTile *> *)sourceImages
    destinationTileRect:(FxRect)destinationTileRect
       destinationImage:(FxImageTile *)destinationImage
            pluginState:(NSData *)pluginState
                 atTime:(CMTime)renderTime
                  error:(NSError *_Nullable *)outError {
  *sourceTileRect = sourceImages[sourceImageIndex].imagePixelBounds;
  return YES;
}

@end
#pragma clang diagnostic pop
