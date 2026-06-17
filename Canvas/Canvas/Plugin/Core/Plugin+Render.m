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
  // the reverse-channel path, plus motion-blur sub-frame samples. The MB state
  // is snapshotted into -pluginState: (prefix of the blob); read it back so
  // KKBuildSourceRequests appends the sub-frame source requests.
  KKMotionBlurState mbState = {0};
  if (pluginState.length >= sizeof(KKMotionBlurState))
    [pluginState getBytes:&mbState length:sizeof(mbState)];
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

  // Snapshot the motion-blur settings now (the param API is unavailable at
  // render time). The blob layout is [KKMotionBlurState][layer blob]; render
  // reads the state prefix, then the per-sample clip fractions are recomputed
  // there from sampleTimesForState + the render cache (no paramAPI needed).
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  NSString *mbJSON =
      api ? KKReadCustomParamString(api, kKKParamMotionBlurData) : nil;
  KKMotionBlurState mbState = [KKMotionBlur snapshotStateFromJSON:mbJSON
                                                        timingAPI:timingAPI
                                                           atTime:renderTime];
  NSMutableData *state = [NSMutableData dataWithBytes:&mbState
                                               length:sizeof(mbState)];
  if (layerBlob.length)
    [state appendData:layerBlob];
  *pluginState = state;
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
  // straight through, composited over the source with premultiplied-alpha
  // "over" (the loader stores premultiplied textures).
  id<MTLRenderPipelineState> imagePS = [cache
      buildAndRegisterPipelineStateForPluginID:@"co.overpolish.keyframeless"
                                               @".Canvas.image"
                                    registryID:regID
                                   pixelFormat:pf
                                      bundleID:kitBundleID
                                  vertexShader:@"KKVertexShader"
                                fragmentShader:@"KKTexturePassthroughFragment"
                                     blendMode:KKBlendModePremultipliedAlpha];

  // The state blob is [KKMotionBlurState][layer blob]; split off the MB prefix
  // before decoding the layer stack (bottom of the array draws in front, so
  // composite back-to-front: last index first).
  KKMotionBlurState mbState = {0};
  NSData *layerBlob = nil;
  if (pluginState.length >= sizeof(KKMotionBlurState)) {
    [pluginState getBytes:&mbState length:sizeof(mbState)];
    if (pluginState.length > sizeof(mbState))
      layerBlob = [pluginState
          subdataWithRange:NSMakeRange(sizeof(mbState),
                                       pluginState.length - sizeof(mbState))];
  }
  NSArray<KKBezierPath *> *layers =
      layerBlob.length ? [KKBezierPath pathsFromBlob:layerBlob] : nil;
  id<MTLDevice> device = [cache deviceWithRegistryID:regID];
  NSMutableDictionary<NSString *, id<MTLTexture>> *texCache =
      self.imageTextureCache;

  float outputWidth = (float)(destinationImage.tilePixelBounds.right -
                              destinationImage.tilePixelBounds.left);
  float outputHeight = (float)(destinationImage.tilePixelBounds.top -
                               destinationImage.tilePixelBounds.bottom);

  // Clip-local time a layer's Scale/Position is evaluated at (same remap as
  // every timing read). Negative when the duration isn't known yet, which tells
  // CanvasEncodeImageLayers to draw the static rects.
  double (^fracForTime)(CMTime) = ^double(CMTime t) {
    if (self.renderCache.effectDurSec <= 0.0)
      return -1.0;
    double f = (CMTimeGetSeconds(t) - self.renderCache.effectStartSec) /
               self.renderCache.effectDurSec;
    f = MAX(0.0, MIN(1.0, f));
    return KKMaintainTimingRemappedFraction(f, self.renderCache);
  };
  double frac = fracForTime(renderTime);

  // Source passthrough + the layer stack (evaluated at `f`) into one encoder.
  void (^composite)(id<MTLRenderCommandEncoder>, NSArray<id<MTLTexture>> *,
                    double) = ^(id<MTLRenderCommandEncoder> enc,
                                NSArray<id<MTLTexture>> *inputs, double f) {
    if (!inputs.count)
      return;
    [enc setRenderPipelineState:ps];
    [enc setFragmentTexture:inputs[0] atIndex:KKTextureIndex_InputImage];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip
            vertexStart:0
            vertexCount:4];
    if (!imagePS || !device)
      return;
    [enc setRenderPipelineState:imagePS];
    CanvasEncodeImageLayers(layers, enc, device, texCache, outputWidth,
                            outputHeight, f, nil, nil);
  };

  // Motion blur: accumulate the composite across sub-frame sample times (the
  // shared KKMotionBlur infra averages N passes). Each pass composites the
  // layer stack at that sample's clip fraction over its time-matched source
  // frame, so both the layer animation and the underlying content smear.
  if (mbState.enabled) {
    NSArray<NSValue *> *times = [KKMotionBlur sampleTimesForState:mbState
                                                       renderTime:renderTime];
    NSMutableArray<NSNumber *> *fracs =
        [NSMutableArray arrayWithCapacity:times.count];
    for (NSValue *v in times) {
      CMTime t = kCMTimeZero;
      [v getValue:&t];
      [fracs addObject:@(fracForTime(t))];
    }
    BOOL applied = [KKMotionBlur
        applyToDestinationImage:destinationImage
                   sourceImages:sourceImages
                          state:mbState
                     renderTime:renderTime
                    renderBlock:^BOOL(int sampleIndex,
                                      id<MTLTexture> sampleDest,
                                      id<MTLCommandBuffer> commandBuffer,
                                      NSArray<id<MTLTexture>> *inputTextures) {
                      double f =
                          (sampleIndex >= 0 && sampleIndex < (int)fracs.count)
                              ? fracs[sampleIndex].doubleValue
                              : frac;
                      return [self
                          encodeFullScreenQuadIntoTexture:sampleDest
                                         destinationImage:destinationImage
                                            commandBuffer:commandBuffer
                                           sourceTextures:inputTextures
                                                 commands:^(
                                                     id<MTLRenderCommandEncoder>
                                                         enc,
                                                     NSArray<id<MTLTexture>>
                                                         *texs) {
                                                   composite(enc, texs, f);
                                                 }];
                    }];
    if (applied)
      return YES;
  }

  // No blur (or the accumulate bailed): single composite at the playhead frac.
  return [self
      encodeRenderCommandsForDestinationImage:destinationImage
                                 sourceImages:sourceImages
                                     commands:^(
                                         id<MTLRenderCommandEncoder> enc,
                                         NSArray<id<MTLTexture>> *inputs) {
                                       composite(enc, inputs, frac);
                                     }];
}

@end
#pragma clang diagnostic pop
