/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "MeshColorSpace.h"
#import "MeshMiniViewerRenderer.h" // per-instance descriptor path
#import "MeshUniformBuilders.h" // per-Type uniform builders (shared with mini)
#import "Plugin_Private.h"
#import "ShaderTypes.h"
#import <KeyframelessKit/KKMiniViewerFeed.h>
#import <KeyframelessKit/KKMotionBlur.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

// Render-internal state builders (defined in the (Render) category below;
// declared here so the forward call from -buildState: doesn't warn).
@interface MeshPlugin (RenderStateBuilders)
- (BOOL)buildState:(MeshPluginState *)outState
            atTime:(CMTime)renderTime
             error:(NSError **)error;
- (BOOL)buildStates:(MeshPluginState *)outStates
            atTimes:(const CMTime *)times
              count:(NSInteger)count
              error:(NSError **)error;
@end

// The interpolated component values of the lane named `label` at clip fraction
// `frac`, or nil if there's no such lane.
static NSArray<NSNumber *> *
MeshLaneValuesAtFraction(KKTimeline *timeline, NSString *label, double frac) {
  for (KKLane *lane in timeline.lanes) {
    if ([lane.label isEqualToString:label])
      return KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
  }
  return nil;
}

// Build the full plugin state from the timeline at one clip fraction. Pure (no
// timing/cache work) so a caller can refresh the render cache once and evaluate
// many sub-frame fractions cheaply (motion blur samples).
static void MeshEvalStateAtFrac(KKTimeline *timeline, double frac,
                                double durSec, MeshPluginState *outState) {
  memset(outState, 0, sizeof(*outState));

  NSArray<NSNumber *> *typeV =
      MeshLaneValuesAtFraction(timeline, @"Type", frac);
  outState->type =
      typeV.count ? (int)lround(typeV[0].doubleValue) : MeshType_Mesh;
  NSArray<NSNumber *> *speedV =
      MeshLaneValuesAtFraction(timeline, @"Speed", frac);
  float speed =
      speedV.count ? speedV[0].floatValue : KK_MESH_GRAD_DEFAULT_SPEED;
  NSArray<NSNumber *> *seedV =
      MeshLaneValuesAtFraction(timeline, @"Seed", frac);
  float seed = seedV.count ? seedV[0].floatValue : KK_MESH_GRAD_DEFAULT_SEED;
  NSArray<NSNumber *> *originV =
      MeshLaneValuesAtFraction(timeline, @"Origin", frac);
  vector_float2 origin =
      (originV.count >= 2)
          ? (vector_float2){originV[0].floatValue, originV[1].floatValue}
          : (vector_float2){0.5f, 0.5f};
  NSArray<NSNumber *> *scaleV =
      MeshLaneValuesAtFraction(timeline, @"Scale", frac);
  NSArray<NSNumber *> *rotV =
      MeshLaneValuesAtFraction(timeline, @"Rotation", frac);
  vector_float2 scale = (scaleV.count >= 2)
                            ? (vector_float2){scaleV[0].floatValue / 100.0f,
                                              scaleV[1].floatValue / 100.0f}
                            : (vector_float2){1.0f, 1.0f};
  float rotation =
      rotV.count ? rotV[0].floatValue * (float)(M_PI / 180.0) : 0.0f;
  float timeSec = (float)(frac * durSec);

  NSArray<NSNumber *> *grainV =
      MeshLaneValuesAtFraction(timeline, @"Grain", frac);
  NSArray<NSNumber *> *grainSizeV =
      MeshLaneValuesAtFraction(timeline, @"Grain Size", frac);
  MeshCommonUniforms common = MeshCommonDefault();
  common.origin = origin;
  common.scale = scale;
  common.rotation = rotation;
  common.speed = speed;
  common.seed = seed;
  common.time = timeSec;
  common.grain =
      grainV.count ? grainV[0].floatValue / 100.0f : KK_CORE_GRAIN_DEFAULT;
  common.grainSize =
      grainSizeV.count ? grainSizeV[0].floatValue : KK_CORE_GRAINSIZE_DEFAULT;
  common.grainScale = MeshGrainScaleForType(outState->type);
  outState->common = common;

  MeshLaneReader read = ^NSArray<NSNumber *> *(NSString *label) {
    return MeshLaneValuesAtFraction(timeline, label, frac);
  };
  MeshBuildAllTypes(read, outState);
}

// Encode one full-screen draw of the active type into `encoder` from `state`
// (its uniform block + shared common block + sRGB flag). Shared by the plain
// render and every motion-blur sample pass.
static void MeshEncodeTypeDraw(id<MTLRenderCommandEncoder> encoder,
                               const MeshPluginState *state,
                               id<MTLRenderPipelineState> pipeline,
                               int encodeSRGB) {
  const MeshTypeInfo *info = MeshTypeInfoForType(state->type);
  const void *uniformBytes = (const char *)state + info->uniformOffset;
  [encoder setRenderPipelineState:pipeline];
  [encoder setFragmentBytes:uniformBytes
                     length:info->uniformSize
                    atIndex:MeshFragmentIndex_Grid];
  [encoder setFragmentBytes:&encodeSRGB
                     length:sizeof(encodeSRGB)
                    atIndex:MeshFragmentIndex_EncodeSRGB];
  [encoder setFragmentBytes:&state->common
                     length:sizeof(MeshCommonUniforms)
                    atIndex:MeshFragmentIndex_Common];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
              vertexStart:0
              vertexCount:4];
}

@implementation MeshPlugin (Render)

// Generator: no input clip, so nothing to schedule. FCP still calls
// -renderDestinationImage: with an empty sourceImages array.
- (BOOL)scheduleInputs:(NSArray<FxImageTileRequest *> *_Nullable *_Nullable)
                           inputImageRequests
       withPluginState:(NSData *)pluginState
                atTime:(CMTime)renderTime
                 error:(NSError **)error {
  *inputImageRequests = @[];
  return YES;
}

// The base implementation derives the output bounds from sourceImages[0], which
// a generator doesn't have. Output at the destination image's own bounds (FCP
// sizes it to the timeline/canvas).
- (BOOL)destinationImageRect:(FxRect *)destinationImageRect
                sourceImages:(NSArray<FxImageTile *> *)sourceImages
            destinationImage:(FxImageTile *)destinationImage
                 pluginState:(NSData *)pluginState
                      atTime:(CMTime)renderTime
                       error:(NSError *_Nullable *)outError {
  *destinationImageRect = destinationImage.imagePixelBounds;
  return YES;
}

// Builds the full plugin state (active type + both types' uniform blocks) from
// the lanes at renderTime, and does the timing work (render-cache refresh,
// maintain-timing, playhead poller) the timing popover's live preview relies
// on. Runs where FxParameterRetrievalAPI is valid (pluginState:), not at render
// time.
- (BOOL)buildState:(MeshPluginState *)outState
            atTime:(CMTime)renderTime
             error:(NSError **)error {
  return [self buildStates:outState atTimes:&renderTime count:1 error:error];
}

// Build N plugin states, one per requested time, refreshing the render cache /
// timing ONCE. Motion-blur sample-accumulate evaluates several sub-frame times
// per frame; times[0] should be the frame's renderTime.
- (BOOL)buildStates:(MeshPluginState *)outStates
            atTimes:(const CMTime *)times
              count:(NSInteger)count
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
    KKRenderCacheApplyUIState(self.renderCache, ui);
  }

  BOOL hasTiming = KKRefreshRenderCache(
      self.apiManager, (KKTimelineInspectorView *)self.inspectorView,
      self.renderCache);
  [self bakeMaintainTimingForCache:self.renderCache
                   timelineParamID:kKKParamTimelineData
                    uiStateParamID:kParamUIState];
  double durSec = self.renderCache.effectDurSec;
  // Live scrubber: render ticks stop ~1s before the clip end (FCP pre-render
  // buffer - renderTime leads currentTime). Arm the self-terminating poll so it
  // follows currentTime through the tail.
  if (hasTiming) {
    KKPlayheadPoller *poller = self.playheadPoller;
    dispatch_async(dispatch_get_main_queue(), ^{
      [poller ensureRunning];
    });
  }

  // Cache refreshed once above; evaluate each requested (sub-frame) time. The
  // per-time work (frac + lane eval + type builders) lives in
  // MeshEvalStateAtFrac.
  for (NSInteger i = 0; i < count; i++) {
    double frac = (hasTiming && durSec > 0.0)
                      ? MAX(0.0, MIN(1.0, (CMTimeGetSeconds(times[i]) -
                                           self.renderCache.effectStartSec) /
                                              durSec))
                      : 0.0;
    frac = KKMaintainTimingRemappedFraction(frac, self.renderCache);
    MeshEvalStateAtFrac(timeline, frac, durSec, &outStates[i]);
  }
  return YES;
}

- (BOOL)pluginState:(NSData **)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error {
  // Motion blur (Accurate / sample-accumulate): a generator owns every pixel,
  // so instead of requesting extra source frames we re-render the shader at N
  // sub-frame times across the shutter and average them (KKMotionBlur). Layout:
  // [KKMotionBlurState][state@sample0 == renderTime][state@sample1]... Render
  // reads sample `sampleIndex` at sizeof(mbState) + i*sizeof(MeshPluginState).
  id<FxParameterRetrievalAPI_v6> paramAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  NSString *mbJSON = KKReadCustomParamString(paramAPI, kKKParamMotionBlurData);
  KKMotionBlurState mbState = [KKMotionBlur snapshotStateFromJSON:mbJSON
                                                        timingAPI:timingAPI
                                                           atTime:renderTime];

  NSArray<NSValue *> *times =
      mbState.enabled
          ? [KKMotionBlur sampleTimesForState:mbState renderTime:renderTime]
          : @[ [NSValue valueWithBytes:&renderTime objCType:@encode(CMTime)] ];
  NSInteger n = (NSInteger)times.count;
  if (n < 1)
    n = 1;

  CMTime *ct = malloc(sizeof(CMTime) * (size_t)n);
  for (NSInteger i = 0; i < n; i++)
    [times[i] getValue:&ct[i]];
  MeshPluginState *states = malloc(sizeof(MeshPluginState) * (size_t)n);
  BOOL ok = [self buildStates:states atTimes:ct count:n error:error];
  free(ct);
  if (!ok) {
    free(states);
    return NO;
  }

  // Mesh's motion is the shader's own time (Speed), not a keyposed lane, so the
  // timeline-based gates can't see it. Blur only when the pattern actually
  // moves; a frozen generator (Speed ~ 0) skips the N-pass cost.
  if (mbState.enabled && states[0].common.speed <= 1e-3f)
    mbState.enabled = NO;

  NSMutableData *data = [NSMutableData
      dataWithCapacity:sizeof(mbState) + sizeof(MeshPluginState) *
                                             (size_t)(mbState.enabled ? n : 1)];
  [data appendBytes:&mbState length:sizeof(mbState)];
  [data appendBytes:&states[0] length:sizeof(MeshPluginState)];
  if (mbState.enabled)
    for (NSInteger i = 1; i < n; i++)
      [data appendBytes:&states[i] length:sizeof(MeshPluginState)];
  free(states);

  *pluginState = data;
  return (*pluginState != nil);
}

- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError *_Nullable *)outError {
  if (!destinationImage.ioSurface) {
    if (outError != NULL) {
      *outError = [NSError
          errorWithDomain:FxPlugErrorDomain
                     code:kFxError_InvalidParameter
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"No destination IOSurface"
                 }];
    }
    return NO;
  }

  // A generator has no source feed to carry the media size, so publish the
  // output dimensions (empty slots) to this instance's descriptor. The mini-
  // viewer reads it as `sourceMediaSize` for its OSC geometry. FCP renders this
  // same instance at MULTIPLE sizes (main viewer + tiny browser/library
  // preview, same aspect), so publish only the LARGEST size seen - the project
  // resolution is the biggest render; a small preview must not overwrite it
  // (that made the fields flip between 1920 and ~112).
  CGFloat mediaW = destinationImage.imagePixelBounds.right -
                   destinationImage.imagePixelBounds.left;
  CGFloat mediaH = destinationImage.imagePixelBounds.top -
                   destinationImage.imagePixelBounds.bottom;
  if (mediaW > 0 && mediaH > 0) {
    NSString *descPath = MeshMiniViewerDescriptorPathForUUID(
        KKInstanceUUIDForAPI(self.apiManager));
    if (!self.miniViewerFeed ||
        ![self.miniViewerFeedPath isEqualToString:descPath]) {
      self.miniViewerFeed =
          [[KKMiniViewerFeed alloc] initWithDescriptorPath:descPath];
      self.miniViewerFeedPath = descPath;
    }
    CGSize cur = self.miniViewerFeed.mediaSize;
    if (mediaW * mediaH > cur.width * cur.height) {
      self.miniViewerFeed.mediaSize = CGSizeMake(mediaW, mediaH);
      [self.miniViewerFeed publishDescriptor];
    }
  }

  // State(s) built in -pluginState: (params API is invalid here). Layout is
  // [KKMotionBlurState][state@sample0]...; read the header + the base sample.
  // Fall back to defaults if the blob is missing/short.
  KKMotionBlurState mbState;
  MeshPluginState base;
  if (pluginState.length >= sizeof(mbState) + sizeof(base)) {
    [pluginState getBytes:&mbState length:sizeof(mbState)];
    [pluginState getBytes:&base
                    range:NSMakeRange(sizeof(mbState), sizeof(base))];
  } else {
    memset(&mbState, 0, sizeof(mbState)); // disabled
    memset(&base, 0, sizeof(base));
    base.type = MeshType_Mesh;
    base.mesh = MeshGradientDefault();
    base.dithering = DitheringDefault();
    base.grain = GrainGradientDefault();
    base.warp = WarpDefault();
    base.neuro = NeuroNoiseDefault();
    base.simplex = SimplexNoiseDefault();
    base.metaballs = MetaballsDefault();
    base.godrays = GodRaysDefault();
    base.fluid = FluidDefault();
    base.neon = NeonDefault();
    base.silk = SilkDefault();
    base.strata = StrataDefault();
    base.common = MeshCommonDefault();
  }

  // Dispatch on the active type via the registry (MeshUniformBuilders.h). Type
  // is structural (never animated), so one pipeline serves every MB sample.
  const MeshTypeInfo *info = MeshTypeInfoForType(base.type);
  NSString *pluginID =
      info->pluginSuffix[0]
          ? [kPluginID stringByAppendingString:@(info->pluginSuffix)]
          : kPluginID;
  NSString *fragment = @(info->fragment);
  id<MTLRenderPipelineState> pipelineState =
      [self pipelineStateForPluginID:pluginID
                    destinationImage:destinationImage
                        vertexShader:@"vertexShader"
                      fragmentShader:fragment
                           blendMode:KKBlendModePremultipliedAlpha];
  if (!pipelineState)
    return NO;

  // Match the output encoding to the destination: FCP float buffers are linear;
  // only the 8-bit BGRA path wants gamma. The dither/grain/warp frames need
  // dims.
  int encodeSRGB =
      (destinationImage.ioSurface.pixelFormat == kCVPixelFormatType_32BGRA) ? 1
                                                                            : 0;
  vector_float2 resolution = (vector_float2){(float)mediaW, (float)mediaH};

  // Motion blur (Accurate): re-render the type shader at each sub-frame sample
  // into a pooled texture, averaged into dest. Each sample's state (its own
  // shader time) is at sizeof(mbState) + sampleIndex*sizeof(MeshPluginState).
  if (mbState.enabled) {
    __weak typeof(self) weakSelf = self;
    NSData *blob = pluginState;
    BOOL applied = [KKMotionBlur
        applyToDestinationImage:destinationImage
                   sourceImages:sourceImages
                          state:mbState
                     renderTime:renderTime
                    renderBlock:^BOOL(int sampleIndex,
                                      id<MTLTexture> sampleDest,
                                      id<MTLCommandBuffer> commandBuffer,
                                      NSArray<id<MTLTexture>> *inputTextures) {
                      __strong typeof(weakSelf) s = weakSelf;
                      if (!s)
                        return NO;
                      NSUInteger off =
                          sizeof(KKMotionBlurState) +
                          (NSUInteger)sampleIndex * sizeof(MeshPluginState);
                      if (off + sizeof(MeshPluginState) > blob.length)
                        return NO;
                      MeshPluginState sample;
                      [blob getBytes:&sample
                               range:NSMakeRange(off, sizeof(MeshPluginState))];
                      sample.common.resolution = resolution;
                      return [s
                          encodeFullScreenQuadIntoTexture:sampleDest
                                         destinationImage:destinationImage
                                            commandBuffer:commandBuffer
                                           sourceTextures:@[]
                                                 commands:^(
                                                     id<MTLRenderCommandEncoder>
                                                         enc,
                                                     NSArray<id<MTLTexture>>
                                                         *texs) {
                                                   MeshEncodeTypeDraw(
                                                       enc, &sample,
                                                       pipelineState,
                                                       encodeSRGB);
                                                 }];
                    }];
    if (applied)
      return YES;
  }

  // Plain single pass (MB off, gated off as static, or accumulate failed).
  // sourceImages is empty for a generator; encodeRenderCommands handles that.
  base.common.resolution = resolution;
  return [self
      encodeRenderCommandsForDestinationImage:destinationImage
                                 sourceImages:sourceImages
                                     commands:^(
                                         id<MTLRenderCommandEncoder> encoder,
                                         NSArray<id<MTLTexture>>
                                             *inputTextures) {
                                       MeshEncodeTypeDraw(encoder, &base,
                                                          pipelineState,
                                                          encodeSRGB);
                                     }];
}

@end
#pragma clang diagnostic pop
