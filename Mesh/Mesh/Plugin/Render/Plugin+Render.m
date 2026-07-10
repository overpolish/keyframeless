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

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

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
  double frac = hasTiming
                    ? MAX(0.0, MIN(1.0, (CMTimeGetSeconds(renderTime) -
                                         self.renderCache.effectStartSec) /
                                            durSec))
                    : 0.0;
  frac = KKMaintainTimingRemappedFraction(frac, self.renderCache);
  // Live scrubber: render ticks stop ~1s before the clip end (FCP
  // pre-render buffer - renderTime leads currentTime). Arm the
  // self-terminating poll so it follows currentTime through the tail.
  if (hasTiming) {
    KKPlayheadPoller *poller = self.playheadPoller;
    dispatch_async(dispatch_get_main_queue(), ^{
      [poller ensureRunning];
    });
  }

  memset(outState, 0, sizeof(*outState));

  // Active type + the shared controls (Speed / Seed / Origin apply to every
  // type; elapsed clip seconds drives the animation).
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
  // Common transforms (all types): Scale stored as percent (100 = 1x), Rotation
  // stored in degrees; the shaders want a factor + radians.
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

  // Core film grain (shared by every type, applied in the shader epilogue). The
  // per-type multiplier keeps Grainy stylistic while others stay subtle.
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

  // Build every Type's uniform from its lanes. Shared transforms + grain are
  // in the common block above; each Type's own fields come from its builder.
  // See MeshUniformBuilders.h (one builder per Type, shared with the mini).
  MeshLaneReader read = ^NSArray<NSNumber *> *(NSString *label) {
    return MeshLaneValuesAtFraction(timeline, label, frac);
  };
  MeshBuildAllTypes(read, outState);
  return YES;
}

- (BOOL)pluginState:(NSData **)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error {
  MeshPluginState state;
  if (![self buildState:&state atTime:renderTime error:error])
    return NO;
  *pluginState = [NSData dataWithBytes:&state length:sizeof(state)];
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

  // State built in -pluginState: (params API is invalid here). Fall back to
  // defaults if it's missing/short.
  MeshPluginState state;
  if (pluginState.length >= sizeof(state)) {
    [pluginState getBytes:&state length:sizeof(state)];
  } else {
    memset(&state, 0, sizeof(state));
    state.type = MeshType_Mesh;
    state.mesh = MeshGradientDefault();
    state.dithering = DitheringDefault();
    state.grain = GrainGradientDefault();
    state.warp = WarpDefault();
    state.neuro = NeuroNoiseDefault();
    state.simplex = SimplexNoiseDefault();
    state.metaballs = MetaballsDefault();
    state.godrays = GodRaysDefault();
    state.fluid = FluidDefault();
    state.neon = NeonDefault();
    state.silk = SilkDefault();
    state.strata = StrataDefault();
    state.common = MeshCommonDefault();
  }

  // Dispatch on the active type via the registry (MeshUniformBuilders.h): one
  // row per Type gives the fragment function, the pipeline cache-key suffix and
  // where its uniform lives in `state`.
  const MeshTypeInfo *info = MeshTypeInfoForType(state.type);
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

  // The dither pixel grid + grain / warp reference frames need the dest dims.
  state.common.resolution = (vector_float2){(float)mediaW, (float)mediaH};

  // Match the output encoding to the destination: FCP float buffers are linear;
  // only the 8-bit BGRA path wants gamma.
  int encodeSRGB =
      (destinationImage.ioSurface.pixelFormat == kCVPixelFormatType_32BGRA) ? 1
                                                                            : 0;

  // Point at the active type's uniform block (synchronous encode, so a pointer
  // into the local `state` is valid inside the block).
  const void *uniformBytes = (const char *)&state + info->uniformOffset;
  size_t uniformLen = info->uniformSize;
  const void *commonBytes = (const void *)&state.common;

  // sourceImages is empty for a generator; encodeRenderCommands handles that
  // (empty inputTextures) and still builds the full-screen quad + dest texture.
  return [self
      encodeRenderCommandsForDestinationImage:destinationImage
                                 sourceImages:sourceImages
                                     commands:^(
                                         id<MTLRenderCommandEncoder> encoder,
                                         NSArray<id<MTLTexture>>
                                             *inputTextures) {
                                       [encoder setRenderPipelineState:
                                                    pipelineState];
                                       [encoder
                                           setFragmentBytes:uniformBytes
                                                     length:uniformLen
                                                    atIndex:
                                                        MeshFragmentIndex_Grid];
                                       [encoder
                                           setFragmentBytes:&encodeSRGB
                                                     length:sizeof(encodeSRGB)
                                                    atIndex:
                                                        MeshFragmentIndex_EncodeSRGB];
                                       [encoder
                                           setFragmentBytes:commonBytes
                                                     length:
                                                         sizeof(
                                                             MeshCommonUniforms)
                                                    atIndex:
                                                        MeshFragmentIndex_Common];
                                       [encoder
                                           drawPrimitives:
                                               MTLPrimitiveTypeTriangleStrip
                                              vertexStart:0
                                              vertexCount:4];
                                     }];
}

@end
#pragma clang diagnostic pop
