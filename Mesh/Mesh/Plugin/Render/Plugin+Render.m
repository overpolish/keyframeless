/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "MeshColorSpace.h"
#import "MeshMiniViewerRenderer.h" // per-instance descriptor path
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
  float timeSec = (float)(frac * durSec);

  // --- Mesh: a flat list of colour swatches (the shader places the spots) +
  // scalar controls. A missing lane falls back to its default. Sliders are
  // stored as percent, the shader wants 0..1.
  MeshGradientUniforms u;
  memset(&u, 0, sizeof(u));
  int count = 0;
  for (int i = 0; i < KK_MESH_COLOR_COUNT; i++) {
    NSArray<NSNumber *> *v =
        MeshLaneValuesAtFraction(timeline, MeshColorLabel(i), frac);
    if (v.count >= 4) {
      u.colors[count++] = (vector_float4){v[0].floatValue, v[1].floatValue,
                                          v[2].floatValue, v[3].floatValue};
    } else {
      const float *c = kMeshDefaultColorsSRGB[i];
      u.colors[count++] = (vector_float4){c[0], c[1], c[2], c[3]};
    }
  }
  u.colorsCount = count > 0 ? count : 1;
  NSArray<NSNumber *> *distV =
      MeshLaneValuesAtFraction(timeline, @"Distortion", frac);
  NSArray<NSNumber *> *swirlV =
      MeshLaneValuesAtFraction(timeline, @"Swirl", frac);
  NSArray<NSNumber *> *mixV =
      MeshLaneValuesAtFraction(timeline, @"Grain Mixer", frac);
  NSArray<NSNumber *> *grainV =
      MeshLaneValuesAtFraction(timeline, @"Grain", frac);
  u.distortion = distV.count ? distV[0].floatValue / 100.0f
                             : KK_MESH_GRAD_DEFAULT_DISTORTION;
  u.swirl =
      swirlV.count ? swirlV[0].floatValue / 100.0f : KK_MESH_GRAD_DEFAULT_SWIRL;
  u.speed = speed;
  u.seed = seed;
  u.origin = origin;
  u.grainMixer = mixV.count ? mixV[0].floatValue / 100.0f
                            : KK_MESH_GRAD_DEFAULT_GRAINMIXER;
  u.grainOverlay =
      grainV.count ? grainV[0].floatValue / 100.0f : KK_MESH_DEFAULT_GRAIN;
  u.time = timeSec;
  outState->mesh = u;

  // --- Dithering: two colours + a procedural shape through a dither. Choice
  // pills store a 0-based index; the shader wants 1-based shape/type.
  // Resolution is filled at render time (it needs the destination pixel dims).
  DitheringUniforms d = DitheringDefault();
  NSArray<NSNumber *> *backV =
      MeshLaneValuesAtFraction(timeline, @"Background", frac);
  NSArray<NSNumber *> *frontV =
      MeshLaneValuesAtFraction(timeline, @"Foreground", frac);
  NSArray<NSNumber *> *shapeV =
      MeshLaneValuesAtFraction(timeline, @"Shape", frac);
  NSArray<NSNumber *> *ditherV =
      MeshLaneValuesAtFraction(timeline, @"Dither", frac);
  NSArray<NSNumber *> *pxV =
      MeshLaneValuesAtFraction(timeline, @"Pixel Size", frac);
  if (backV.count >= 4)
    d.colorBack = (vector_float4){backV[0].floatValue, backV[1].floatValue,
                                  backV[2].floatValue, backV[3].floatValue};
  if (frontV.count >= 4)
    d.colorFront = (vector_float4){frontV[0].floatValue, frontV[1].floatValue,
                                   frontV[2].floatValue, frontV[3].floatValue};
  if (shapeV.count)
    d.shape = (int)lround(shapeV[0].doubleValue) + 1;
  if (ditherV.count)
    d.type = (int)lround(ditherV[0].doubleValue) + 1;
  if (pxV.count)
    d.pxSize = pxV[0].floatValue;
  d.speed = speed;
  d.seed = seed;
  d.origin = origin;
  d.time = timeSec;
  outState->dithering = d;
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
  }

  // Dispatch on the active type. Each type is a separate fragment function; the
  // pipeline cache keys on plugin ID + pixel format (NOT the shader name), so a
  // distinct ID per type keeps their pipelines from colliding.
  BOOL isDither = (state.type == MeshType_Dithering);
  NSString *pluginID =
      isDither ? [kPluginID stringByAppendingString:@".dithering"] : kPluginID;
  NSString *fragment = isDither ? @"ditheringFragment" : @"fragmentShader";

  id<MTLRenderPipelineState> pipelineState =
      [self pipelineStateForPluginID:pluginID
                    destinationImage:destinationImage
                        vertexShader:@"vertexShader"
                      fragmentShader:fragment
                           blendMode:KKBlendModePremultipliedAlpha];
  if (!pipelineState)
    return NO;

  // Dithering's pixel grid needs the destination pixel dims.
  state.dithering.resolution = (vector_float2){(float)mediaW, (float)mediaH};

  // Match the output encoding to the destination: FCP's float working buffers
  // are linear-light (RGBA16/32Float); only the 8-bit BGRA path wants gamma.
  int encodeSRGB =
      (destinationImage.ioSurface.pixelFormat == kCVPixelFormatType_32BGRA) ? 1
                                                                            : 0;

  // Point at the active type's uniform block (synchronous encode, so a pointer
  // into the local `state` is valid inside the block).
  const void *uniformBytes =
      isDither ? (const void *)&state.dithering : (const void *)&state.mesh;
  size_t uniformLen = isDither ? sizeof(state.dithering) : sizeof(state.mesh);

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
                                           drawPrimitives:
                                               MTLPrimitiveTypeTriangleStrip
                                              vertexStart:0
                                              vertexCount:4];
                                     }];
}

@end
#pragma clang diagnostic pop
