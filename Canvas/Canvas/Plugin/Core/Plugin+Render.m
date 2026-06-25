/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasFillProperties.h" // CanvasFillEnabledAtFraction (lane gate)
#import "CanvasFillRender.h"     // TEMP solid fill for closed paths
#import "CanvasLayerRender.h"
#import "CanvasLayerTimeline.h" // CanvasSetUIStateSnapshot
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
      // Seed the viewer OSC's UIState snapshot here too (the OSC can't read the
      // param directly). pluginState only fires on a CHANGE, so on a cold FCP
      // launch the snapshot would be empty until the user interacts - leaving the
      // toolbar / grid at defaults. Render runs before the OSC draws, so seeding
      // here restores them immediately.
      CanvasSetUIStateSnapshot(uiJSON);
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

  // Image pipeline: the transform-aware vertex shader (per-layer 4x4 model +
  // perspective + tile shift) + the opacity fragment, composited with
  // premultiplied-alpha "over". Both the source frame AND the layers go through
  // it so they tile identically in FCP's sub-tiled / reverse-Y library preview.
  id<MTLRenderPipelineState> imagePS = [cache
      buildAndRegisterPipelineStateForPluginID:@"co.overpolish.keyframeless"
                                               @".Canvas.image"
                                    registryID:regID
                                   pixelFormat:pf
                                      bundleID:kitBundleID
                                  vertexShader:@"KKTransformVertexShader"
                                fragmentShader:@"KKTextureOpacityFragment"
                                     blendMode:KKBlendModePremultipliedAlpha];
  if (!imagePS) {
    KKLogError(@"Canvas render bail: no image pipeline");
    if (outError)
      *outError = [NSError errorWithDomain:FxPlugErrorDomain
                                      code:kFxError_InvalidParameter
                                  userInfo:nil];
    return NO;
  }
  // Image-tint pipeline: same transform vertex shader, the kit tint fragment
  // (lerp the sampled image toward the fill colour by the amount). Used for a
  // fill-enabled image layer; nil-tolerant (the image just renders plain).
  id<MTLRenderPipelineState> imageTintPS = [cache
      buildAndRegisterPipelineStateForPluginID:@"co.overpolish.keyframeless"
                                               @".Canvas.imageTint"
                                    registryID:regID
                                   pixelFormat:pf
                                      bundleID:kitBundleID
                                  vertexShader:@"KKTransformVertexShader"
                                fragmentShader:@"KKTextureTintFragment"
                                     blendMode:KKBlendModePremultipliedAlpha];
  // Gradient-tint variant: tint the image toward the gradient (UV space).
  id<MTLRenderPipelineState> imageGradTintPS = [cache
      buildAndRegisterPipelineStateForPluginID:@"co.overpolish.keyframeless"
                                               @".Canvas.imageGradTint"
                                    registryID:regID
                                   pixelFormat:pf
                                      bundleID:kitBundleID
                                  vertexShader:@"KKTransformVertexShader"
                                fragmentShader:@"KKTextureGradientTintFragment"
                                     blendMode:KKBlendModePremultipliedAlpha];

  // Stroke pipeline: the SAME transform vertex shader (so vector strokes compose
  // with CanvasComposedModelMatrix exactly like image quads) + the kit's
  // antialiased line fragment, which reads the signed edge distance the
  // tessellator packs into textureCoordinate.y. One pipeline serves normal AND
  // (later) sketch strokes - sketch is a path pre-jitter, not a second pipeline.
  id<MTLRenderPipelineState> strokePS = [cache
      buildAndRegisterPipelineStateForPluginID:@"co.overpolish.keyframeless"
                                               @".Canvas.stroke"
                                    registryID:regID
                                   pixelFormat:pf
                                      bundleID:kitBundleID
                                  vertexShader:@"KKTransformVertexShader"
                                fragmentShader:@"KKLineFragment"
                                     blendMode:KKBlendModePremultipliedAlpha];
  // Gradient-stroke variant: same vertex pipeline, gradient-LUT fragment.
  id<MTLRenderPipelineState> strokeGradientPS = [cache
      buildAndRegisterPipelineStateForPluginID:@"co.overpolish.keyframeless"
                                               @".Canvas.strokeGradient"
                                    registryID:regID
                                   pixelFormat:pf
                                      bundleID:kitBundleID
                                  vertexShader:@"KKTransformVertexShader"
                                fragmentShader:@"KKGradientLineFragment"
                                     blendMode:KKBlendModePremultipliedAlpha];
  // Dashed-stroke variant: a vertex shader that also threads per-vertex arc
  // length, + a fragment that masks the dash pattern by arc (solid OR gradient).
  // Same solid stroke geometry, so dash corners == solid corners.
  id<MTLRenderPipelineState> strokeDashPS = [cache
      buildAndRegisterPipelineStateForPluginID:@"co.overpolish.keyframeless"
                                               @".Canvas.strokeDash"
                                    registryID:regID
                                   pixelFormat:pf
                                      bundleID:kitBundleID
                                  vertexShader:@"KKStrokeDashVertexShader"
                                fragmentShader:@"KKStrokeDashFragment"
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

  // Layers are positioned in FULL-image space; a per-tile shift maps that into
  // the current render tile (the shader divides by the tile viewport). For a
  // full-frame tile the shift is 0; FCP's tiled previews pass a non-zero shift
  // so each tile shows its slice instead of redrawing the whole composite.
  FxRect tileB = destinationImage.tilePixelBounds;
  FxRect imgB = destinationImage.imagePixelBounds;
  float outputWidth = (float)(imgB.right - imgB.left);
  float outputHeight = (float)(imgB.top - imgB.bottom);
  // Publish the true output size for the viewer OSC's path ops (stroke-to-outline
  // bakes px-relative geometry and the OSC only knows zoom-dependent canvas px).
  CanvasSetOutputSize(outputWidth, outputHeight);
  // Render scale: stroke widths are authored in CANONICAL (canvas/100%) px, but
  // a downscaled FCP browser/effect thumbnail renders fewer real pixels per
  // canonical unit. Map the SOURCE image's pixel bounds back to canonical units
  // via its inversePixelTransform (same idiom as Glow / the _Attic): resScale =
  // srcPixelWidth / srcCanonicalWidth (1.0 at full res, < 1 for a thumbnail).
  // Geometry is already correct (it scales with imageWidth); only the absolute
  // stroke width needs this, else thumbnails draw strokes far too thick.
  float strokeScale = 1.0f;
  FxRect sp = sourceImages[0].imagePixelBounds;
  FxMatrix44 *invXf = sourceImages[0].inversePixelTransform;
  if (invXf) {
    FxPoint2D sll = [invXf transform2DPoint:(FxPoint2D){sp.left, sp.bottom}];
    FxPoint2D sur = [invXf transform2DPoint:(FxPoint2D){sp.right, sp.top}];
    float canonW = (float)(sur.x - sll.x);
    float pxW = (float)(sp.right - sp.left);
    if (canonW > 0.0f)
      strokeScale = pxW / canonW;
  }
  float tileShiftX =
      outputWidth * 0.5f - ((tileB.left + tileB.right) * 0.5f - imgB.left);
  // Y measured from the image TOP (the vert/shader Y here runs opposite FCP's
  // Y-up pixel bounds, so a from-bottom reference reversed the tile strip).
  float tileShiftY =
      outputHeight * 0.5f - (imgB.top - (tileB.bottom + tileB.top) * 0.5f);

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
  // Media time since the effect start - drives the marching-ants dash animation
  // (independent of the clip fraction, so it marches even on a constant stroke).
  double marchElapsed =
      fmax(0.0, CMTimeGetSeconds(renderTime) - self.renderCache.effectStartSec);

  // Source passthrough + the layer stack (evaluated at `f`) into one encoder.
  // `withStrokes` keeps the strokes IN this accumulated composite (the
  // motion-blur path, so strokes smear); the non-blur path passes NO and draws
  // strokes in their own pass AFTER the fills (so a fill sits UNDER its stroke).
  void (^composite)(id<MTLRenderCommandEncoder>, NSArray<id<MTLTexture>> *,
                    double, BOOL) = ^(id<MTLRenderCommandEncoder> enc,
                                      NSArray<id<MTLTexture>> *inputs, double f,
                                      BOOL withStrokes) {
    if (!inputs.count || !imagePS || !device)
      return;
    // Source + layers both go through the image pipeline (transform shader +
    // tile shift) so they tile identically in FCP's sub-tiled / reverse-Y
    // library preview. The source is a full-image quad drawn first (over the
    // cleared target = the source), then the layers composite on top.
    [enc setRenderPipelineState:imagePS];
    CanvasEncodeSourceTile(enc, inputs[0], outputWidth, outputHeight,
                           tileShiftX, tileShiftY);
    CanvasEncodeImageLayers(layers, enc, device, texCache, outputWidth,
                            outputHeight, tileShiftX, tileShiftY, f, nil, nil,
                            imagePS, imageTintPS, imageGradTintPS);
    // Vector strokes (pen / shape layers) over the images, same tile transform.
    if (withStrokes && strokePS) {
      [enc setRenderPipelineState:strokePS];
      CanvasEncodeVectorLayers(layers, enc, device, outputWidth, outputHeight,
                               tileShiftX, tileShiftY, f, nil, nil, strokeScale,
                               marchElapsed, strokePS, strokeGradientPS,
                               strokeDashPS);
    }
  };

  // TEMP solid fill for closed filled paths (SVG fills, boolean / outline
  // results), drawn in its own stencil + colour passes on a second command
  // buffer AFTER the composite is committed - the kit's shared encoder has no
  // stencil attachment. Z-order is therefore fill-over-stroke (acceptable for
  // the temp: a path is filled OR stroked here, rarely both). Skipped entirely
  // when nothing is filled.
  FxRect tileBF = destinationImage.tilePixelBounds;
  float tileW = (float)(tileBF.right - tileBF.left);
  float tileH = (float)(tileBF.top - tileBF.bottom);
  void (^runFills)(double) = ^(double f) {
    BOOL anyFill = NO;
    double efill = f < 0.0 ? 0.0 : f;
    for (KKBezierPath *p in layers) {
      if (p.isGroup || p.hidden ||
          !CanvasFillEnabledAtFraction(p, efill, nil, nil))
        continue;
      // A vector shape fills; an image only contributes a fill pass when its
      // Fill Style is a (non-Solid) hachure overlay.
      if (!p.isImage || CanvasFillStyleAtFraction(p, efill, nil, nil).style != 0) {
        anyFill = YES;
        break;
      }
    }
    if (!anyFill || !device)
      return;
    CanvasFillPipelines fillPipes = {0};
    CanvasFillBuildPipelines(device, regID, pf, &fillPipes);
    if (!fillPipes.stencil || !fillPipes.color || !fillPipes.composite)
      return;
    id<MTLTexture> destTex = [destinationImage metalTextureForDevice:device];
    if (!destTex)
      return;
    id<MTLCommandQueue> queue = [cache commandQueueWithRegistryID:regID
                                                      pixelFormat:pf];
    if (!queue)
      return;
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    CanvasEncodeFilledLayers(layers, device, texCache, cb, destTex, &fillPipes,
                             outputWidth, outputHeight, tileW, tileH, tileShiftX,
                             tileShiftY, f, nil, nil);
    [cb commit];
    [cb waitUntilCompleted];
    [cache returnCommandQueueToCache:queue];
  };

  // Strokes drawn in their OWN pass AFTER the fills (non-blur path), so a
  // filled-and-stroked shape shows its stroke ON TOP of its fill. Mirrors the
  // fill pass: own command buffer + an encoder that LOADS the dest, with the
  // SAME viewport + viewport-size buffer the kit composite encoder sets (tile
  // dims), so the KKTransformVertexShader places strokes in the identical space
  // as the images / fills.
  void (^runStrokes)(double) = ^(double f) {
    if (!device || !strokePS)
      return;
    id<MTLTexture> destTex = [destinationImage metalTextureForDevice:device];
    if (!destTex)
      return;
    id<MTLCommandQueue> queue = [cache commandQueueWithRegistryID:regID
                                                      pixelFormat:pf];
    if (!queue)
      return;
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    MTLRenderPassDescriptor *rpd =
        [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = destTex;
    rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc =
        [cb renderCommandEncoderWithDescriptor:rpd];
    [enc setViewport:(MTLViewport){0, 0, tileW, tileH, -1, 1}];
    simd_uint2 vpSize = {(unsigned int)tileW, (unsigned int)tileH};
    [enc setVertexBytes:&vpSize
                 length:sizeof(vpSize)
                atIndex:KKVertexInputIndex_ViewportSize];
    [enc setRenderPipelineState:strokePS];
    CanvasEncodeVectorLayers(layers, enc, device, outputWidth, outputHeight,
                             tileShiftX, tileShiftY, f, nil, nil, strokeScale,
                             marchElapsed, strokePS, strokeGradientPS,
                             strokeDashPS);
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    [cache returnCommandQueueToCache:queue];
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
                                                   // Blur path keeps strokes in
                                                   // the accumulated composite
                                                   // so they smear; fill stays a
                                                   // single post-pass (temp), so
                                                   // it sits over the blurred
                                                   // stroke here.
                                                   composite(enc, texs, f, YES);
                                                 }];
                    }];
    if (applied) {
      runFills(frac); // fills aren't sample-accumulated (temp): drawn once
      return YES;
    }
  }

  // No blur (or the accumulate bailed): single composite at the playhead frac.
  BOOL ok = [self
      encodeRenderCommandsForDestinationImage:destinationImage
                                 sourceImages:sourceImages
                                     commands:^(
                                         id<MTLRenderCommandEncoder> enc,
                                         NSArray<id<MTLTexture>> *inputs) {
                                       // No strokes here: they draw in their own
                                       // pass after the fills, so a fill sits
                                       // under its stroke.
                                       composite(enc, inputs, frac, NO);
                                     }];
  if (ok) {
    runFills(frac);
    runStrokes(frac);
  }
  return ok;
}

@end
#pragma clang diagnostic pop
