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

// Builds the mesh grid from the Color lanes at renderTime, and does the timing
// work (render-cache refresh, maintain-timing, playhead poller) the timing
// popover's live preview relies on. Runs where FxParameterRetrievalAPI is valid
// (pluginState:), not at render time.
- (BOOL)buildGrid:(MeshGridUniforms *)outGrid
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

  // Each point's [x, y, spread, r, g, b, a] comes from its "Point N" lane at
  // `frac`; a missing lane falls back to the default so an un-edited instance
  // still renders.
  float pos[KK_MESH_POINT_COUNT][2];
  float spr[KK_MESH_POINT_COUNT];
  float col[KK_MESH_POINT_COUNT][4];
  for (int i = 0; i < KK_MESH_POINT_COUNT; i++) {
    NSArray<NSNumber *> *v =
        MeshLaneValuesAtFraction(timeline, MeshPointLabel(i), frac);
    if (v.count >= 7) {
      pos[i][0] = v[0].floatValue;
      pos[i][1] = v[1].floatValue;
      spr[i] = v[2].floatValue / 100.0f; // stored as percent, shader wants 0..1
      for (int k = 0; k < 4; k++)
        col[i][k] = v[3 + k].floatValue;
    } else {
      pos[i][0] = kMeshDefaultPositions[i][0];
      pos[i][1] = kMeshDefaultPositions[i][1];
      spr[i] = KK_MESH_DEFAULT_SPREAD;
      for (int k = 0; k < 4; k++)
        col[i][k] = kMeshDefaultColorsSRGB[i][k];
    }
  }
  *outGrid = MeshBuildPoints(KK_MESH_POINT_COUNT, pos, spr, col);
  return YES;
}

- (BOOL)pluginState:(NSData **)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error {
  MeshGridUniforms grid;
  if (![self buildGrid:&grid atTime:renderTime error:error])
    return NO;
  *pluginState = [NSData dataWithBytes:&grid length:sizeof(grid)];
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
  // output dimensions (empty slots) to this instance's descriptor. Both mini-
  // viewers read it as `sourceMediaSize`, which the px-scaled X/Y/Spread value
  // fields need to display pixels (values stay stored 0..1). FCP renders this
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

  id<MTLRenderPipelineState> pipelineState =
      [self pipelineStateForPluginID:kPluginID
                    destinationImage:destinationImage
                        vertexShader:@"vertexShader"
                      fragmentShader:@"fragmentShader"
                           blendMode:KKBlendModePremultipliedAlpha];
  if (!pipelineState)
    return NO;

  // Grid built from the Color lanes in -pluginState: (params API is invalid
  // here). Fall back to the default if the state is missing/short.
  MeshGridUniforms grid;
  if (pluginState.length >= sizeof(grid))
    [pluginState getBytes:&grid length:sizeof(grid)];
  else
    grid = MeshDefaultGrid();

  // Match the output encoding to the destination: FCP's float working buffers
  // are linear-light (RGBA16/32Float); only the 8-bit BGRA path wants gamma.
  int encodeSRGB =
      (destinationImage.ioSurface.pixelFormat == kCVPixelFormatType_32BGRA) ? 1
                                                                            : 0;

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
                                           setFragmentBytes:&grid
                                                     length:sizeof(grid)
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
