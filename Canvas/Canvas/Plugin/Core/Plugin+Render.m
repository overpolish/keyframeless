/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerRender.h"
#import "CanvasMiniViewerRenderer.h"
#import "Constants.h"
#import "Plugin_Private.h"
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKMetalDeviceCache.h>
#import <KeyframelessKit/KKMotionBlur.h>
#import <KeyframelessKit/KKPlugin+MiniViewerFeed.h>
#import <KeyframelessKit/KKShaderTypes.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation CanvasPlugin (Render)

- (BOOL)scheduleInputs:(NSArray<FxImageTileRequest *> *_Nullable *_Nullable)
                           inputImageRequests
       withPluginState:(NSData *)pluginState
                atTime:(CMTime)renderTime
                 error:(NSError **)error {
  // Slot 0 is the playhead frame (the main viewer render). Additional slots
  // are the boundary / filmstrip / onion frames the mini-viewer requested via
  // the reverse-channel path. No motion blur yet, so the state is zeroed.
  KKMotionBlurState mbState = {0};
  NSArray *reqs = KKBuildSourceRequests(
      renderTime, mbState, CanvasMiniViewerRequestPath, self.renderCache,
      ^id(CMTime t) {
        return [[FxImageTileRequest alloc]
            initWithSource:kFxImageTileRequestSourceEffectClip
                      time:t
            includeFilters:YES
               parameterID:0];
      });
  *inputImageRequests = reqs;
  return YES;
}

- (BOOL)sourceTileRect:(FxRect *)sourceTileRect
       sourceImageIndex:(NSUInteger)sourceImageIndex
           sourceImages:(NSArray<FxImageTile *> *)sourceImages
    destinationTileRect:(FxRect)destinationTileRect
       destinationImage:(FxImageTile *)destinationImage
            pluginState:(NSData *)pluginState
                 atTime:(CMTime)renderTime
                  error:(NSError *_Nullable *)outError {
  // Request the FULL source image (not just the dest tile) so the mini-viewer
  // feed publish sees a full-frame tile - its publish gate skips sub-tiles, so
  // without this the preview never receives a frame (the main viewer still
  // works: its encoder maps the dest tile to a source sub-region via UVs).
  *sourceTileRect = sourceImages[sourceImageIndex].imagePixelBounds;
  return YES;
}

- (BOOL)pluginState:(NSData **)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error {
  // Increment 1: render is a literal passthrough, so the state blob carries no
  // per-frame data. We still refresh the render cache + arm the live-scrub
  // poller so the inspector playhead tracks during playback, mirroring the
  // timing-driven plugins.
  id<FxParameterRetrievalAPI_v6> api =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (api) {
    NSString *uiJSON = KKReadCustomParamString(api, kParamUIState);
    if (uiJSON.length) {
      NSDictionary *ui = [NSJSONSerialization
          JSONObjectWithData:[uiJSON dataUsingEncoding:NSUTF8StringEncoding]
                     options:0
                       error:nil];
      KKRenderCacheApplyUIState(self.renderCache, ui);
    }
  }
  BOOL hasTiming = KKRefreshRenderCache(
      self.apiManager, (KKTimelineInspectorView *)self.inspectorView,
      self.renderCache);
  if (hasTiming) {
    KKPlayheadPoller *poller = self.playheadPoller;
    dispatch_async(dispatch_get_main_queue(), ^{
      [poller ensureRunning];
    });
  }

  // Snapshot the layer stack into the state blob so the render reads no params.
  // The param value is base64 of +[KKBezierPath blobFromPaths:]; decode it back
  // to the raw blob here and hand the raw blob to render (pathsFromBlob:).
  NSData *layerBlob = nil;
  if (api) {
    NSString *b64 = KKReadCustomParamString(api, kParamLayerData);
    if (b64.length)
      layerBlob = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
  }
  *pluginState = layerBlob ?: [NSData data];
  return YES;
}

- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError *_Nullable *)outError {
  if (!sourceImages.count || !sourceImages[0].ioSurface ||
      !destinationImage.ioSurface) {
    KKLogError(@"Canvas render bail: src=%lu",
               (unsigned long)sourceImages.count);
    if (outError)
      *outError = [NSError errorWithDomain:FxPlugErrorDomain
                                      code:kFxError_InvalidParameter
                                  userInfo:nil];
    return NO;
  }

  // Mini-viewer source feed: publish the raw source per slot (single-slot =
  // playhead, multi-slot = boundary preview / filmstrip / onion). The inspector
  // renderer blits it straight through (Canvas is passthrough for now).
  [self kkPublishMiniViewerFeedForDestination:destinationImage
                                 sourceImages:sourceImages
                               descriptorPath:CanvasMiniViewerDescriptorPath
                              boundaryReqSecs:self.renderCache.boundaryReqSecs
                             boundaryReqFracs:self.renderCache.boundaryReqFracs
                              multiSlotActive:YES
                            changesOutputSize:NO
                                   defaultTag:CMTimeGetSeconds(renderTime)];

  // Passthrough: sample the source straight into the destination via the kit's
  // shared full-screen-quad infra + the kit-bundle passthrough shaders. Canvas
  // ships no Metal library of its own (increment 1), so the pipeline is built
  // against the KeyframelessKit framework bundle.
  NSString *kitBundleID =
      [NSBundle bundleForClass:[KKPlugin class]].bundleIdentifier;
  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  MTLPixelFormat pf =
      [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
  uint64_t regID = destinationImage.deviceRegistryID;
  id<MTLRenderPipelineState> ps = [cache
      buildAndRegisterPipelineStateForPluginID:@"co.overpolish.keyframeless"
                                               @".Canvas.passthrough"
                                    registryID:regID
                                   pixelFormat:pf
                                      bundleID:kitBundleID
                                  vertexShader:@"KKVertexShader"
                                fragmentShader:@"KKTexturePassthroughFragment"
                                     blendMode:KKBlendModeNone];
  if (!ps) {
    KKLogError(@"Canvas render bail: no passthrough pipeline");
    if (outError)
      *outError = [NSError errorWithDomain:FxPlugErrorDomain
                                      code:kFxError_InvalidParameter
                                  userInfo:nil];
    return NO;
  }

  // Image-layer overlay pipeline: same positioned-quad vertex shader, sampled
  // straight through, composited over the source with premultiplied-alpha "over"
  // (the loader stores premultiplied textures).
  id<MTLRenderPipelineState> imagePS = [cache
      buildAndRegisterPipelineStateForPluginID:@"co.overpolish.keyframeless"
                                               @".Canvas.image"
                                    registryID:regID
                                   pixelFormat:pf
                                      bundleID:kitBundleID
                                  vertexShader:@"KKVertexShader"
                                fragmentShader:@"KKTexturePassthroughFragment"
                                     blendMode:KKBlendModePremultipliedAlpha];

  // Decode the layer stack snapshotted into the state blob (bottom of the array
  // draws in front, so composite back-to-front: last index first).
  NSArray<KKBezierPath *> *layers =
      pluginState.length ? [KKBezierPath pathsFromBlob:pluginState] : nil;
  id<MTLDevice> device = [cache deviceWithRegistryID:regID];
  NSMutableDictionary<NSString *, id<MTLTexture>> *texCache =
      self.imageTextureCache;

  float outputWidth = (float)(destinationImage.tilePixelBounds.right -
                              destinationImage.tilePixelBounds.left);
  float outputHeight = (float)(destinationImage.tilePixelBounds.top -
                               destinationImage.tilePixelBounds.bottom);

  return [self
      encodeRenderCommandsForDestinationImage:destinationImage
                                 sourceImages:sourceImages
                                     commands:^(
                                         id<MTLRenderCommandEncoder> encoder,
                                         NSArray<id<MTLTexture>> *inputs) {
                                       if (!inputs.count)
                                         return;
                                       [encoder setRenderPipelineState:ps];
                                       [encoder
                                            setFragmentTexture:inputs[0]
                                                       atIndex:
                                                   KKTextureIndex_InputImage];
                                       [encoder
                                           drawPrimitives:
                                               MTLPrimitiveTypeTriangleStrip
                                              vertexStart:0
                                              vertexCount:4];

                                       if (!imagePS || !device)
                                         return;
                                       [encoder setRenderPipelineState:imagePS];
                                       CanvasEncodeImageLayers(
                                           layers, encoder, device, texCache,
                                           outputWidth, outputHeight);
                                     }];
}

@end
#pragma clang diagnostic pop
