/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasFillProperties.h" // CanvasFillEnabledAtFraction (lane gate)
#import "CanvasFillRender.h"     // TEMP solid fill for closed paths
#import "CanvasLayerRender.h"
#import "CanvasLayerTimeline.h"  // CanvasSetUIStateSnapshot
#import "CanvasLayerTransform.h" // CanvasStrokeEnabledAtFraction (lane gate)
#import "CanvasLayerTree.h"     // CanvasLayerPathWithAncestors
#import "CanvasInspectorView.h" // reloadLayerList (maintain-timing graph refresh)
#import "CanvasMiniViewerRenderer.h"
#import "Constants.h"
#import "Plugin_Private.h"
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKTimingEvaluation.h> // KKLaneDisplayValueAtFraction
#import <KeyframelessKit/KKTimeline.h>       // KKTimelineRetimedForMediaAnchor
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKMetalDeviceCache.h>
#import <KeyframelessKit/KKMotionBlur.h>
#import <KeyframelessKit/KKMotionBlurReconstruct.h>
#import <KeyframelessKit/KKPlugin+MiniViewerFeed.h>
#import <KeyframelessKit/KKShaderTypes.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

// Returns `existing` if it already matches (w,h,format), else allocates a fresh
// private render-target+shader-read texture. Used for the "Fast" motion-blur
// per-layer scratch textures, reused across frames.
static id<MTLTexture> CanvasEnsureScratchTex(id<MTLTexture> existing,
                                             id<MTLDevice> device, NSInteger w,
                                             NSInteger h, MTLPixelFormat fmt) {
  if (existing && (NSInteger)existing.width == w &&
      (NSInteger)existing.height == h && existing.pixelFormat == fmt)
    return existing;
  MTLTextureDescriptor *td =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt
                                                         width:(NSUInteger)w
                                                        height:(NSUInteger)h
                                                     mipmapped:NO];
  td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  td.storageMode = MTLStorageModePrivate;
  return [device newTextureWithDescriptor:td];
}

// Full-content digest of the layer blob for the link-source rebuild gate.
// NSData's -hash only covers the FIRST 80 BYTES, and the blob's head is
// archive header material that never moves when a value deep inside changes -
// gating on it froze the published curves at their first-tick values (the
// stale republish deduped to no file write, so the bus stamp never moved and
// subscribers resolved a dead value forever).
static NSUInteger CanvasLayerBlobDigest(NSData *blob) {
  unsigned long long h = 1469598103934665603ull;
  const unsigned char *b = blob.bytes;
  NSUInteger n = blob.length;
  for (NSUInteger i = 0; i < n; i++) {
    h ^= b[i];
    h *= 1099511628211ull;
  }
  return (NSUInteger)h;
}

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
  NSArray *reqs = KKBuildSourceRequests(
      renderTime,
      CanvasMiniViewerRequestPathForUUID(
          KKInstanceUUIDForAPI(self.apiManager)),
      self.renderCache,
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
  // Persist maintain-timing: when the clip range settles after a trim/grow,
  // retime each layer's animationJSON so the stored keyposes (and the inspector
  // graph) match the media-locked render. Canvas is per-layer, so it overrides
  // -_commitMaintainTimingBakeWithTimelineParamID:uiStateParamID: to walk the
  // layer blob instead of the single kKKParamTimelineData the base retimes.
  [self bakeMaintainTimingForCache:self.renderCache
                   timelineParamID:kParamLayerData
                    uiStateParamID:kParamUIState];
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

  // Advertise this clip as a LAYERED link source (picker: Canvas > Layer >
  // Param; token: `${uuid.layerID.label}`). Each layer's EFFECTIVE timeline
  // (template-seeded when untouched) supplies its referenceable lanes.
  // Sources rebuild only when the layer blob changes; the manifest + curve
  // writes run every timing tick (idempotent) so the clip's absolute span
  // stays fresh.
  NSSet<NSString *> *refSources = nil; // ALL `${refs}` (incl. same-clip)
  if (hasTiming) {
    NSUInteger blobHash = CanvasLayerBlobDigest(layerBlob);
    if (blobHash != self.linkLayerBlobHash || !self.linkLayerSources) {
      self.linkLayerBlobHash = blobHash;
      NSArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:layerBlob];
      NSMutableArray<KKLinkLayerSource *> *sources =
          [NSMutableArray arrayWithCapacity:paths.count];
      NSUInteger idx = 0;
      for (KKBezierPath *p in paths) {
        idx++;
        if (p.layerID.length == 0)
          continue;
        KKLinkLayerSource *src = [[KKLinkLayerSource alloc] init];
        src.layerID = p.layerID;
        // Unnamed layers get an indexed fallback (the layer list shows a bare
        // "Layer") so two unnamed layers stay distinguishable in the picker.
        src.displayName =
            p.name.length
                ? p.name
                : [NSString stringWithFormat:@"Layer %lu", (unsigned long)idx];
        src.lanes =
            CanvasLayerTimelineForPath(p, [CanvasPlugin availableLanes]).lanes;
        [sources addObject:src];
      }
      self.linkLayerSources = sources;
    }
    [self writeLinkManifest];

    // Subscriber side (mirrors Mirage's RenderState wiring): watch the
    // sources this clip's layer expressions reference so a cross-clip source
    // edit forces a re-render. SAME-clip refs are dropped - a layer edit
    // rewrites this clip's own param blob and re-renders it anyway, and this
    // clip republishes its own curves every tick, so watching them would
    // nudge-loop forever.
    NSMutableArray<KKLane *> *allLanes = [NSMutableArray array];
    for (KKLinkLayerSource *src in self.linkLayerSources)
      [allLanes addObjectsFromArray:src.lanes ?: @[]];
    KKTimeline *refScan = [KKTimeline timeline];
    refScan.lanes = allLanes;
    NSSet<NSString *> *linkSources = KKLinkTimelineSourceNames(refScan);
    refSources = [linkSources copy];
    NSString *selfLinkUUID = KKInstanceUUIDForAPI(self.apiManager);
    if (selfLinkUUID.length && linkSources.count) {
      NSString *selfPrefix = [selfLinkUUID stringByAppendingString:@"."];
      NSMutableSet<NSString *> *crossClip = [NSMutableSet set];
      for (NSString *name in linkSources)
        if (![name hasPrefix:selfPrefix])
          [crossClip addObject:name];
      linkSources = crossClip;
    }
    if (linkSources.count > 0 || self.linkWatcher) {
      if (!self.linkWatcher)
        self.linkWatcher =
            [[KKLinkWatcher alloc] initWithAPIManager:self.apiManager
                                         actionTarget:self
                                         nudgeParamID:kKKParamRenderNudgeString];
      KKLinkWatcher *watcher = self.linkWatcher;
      dispatch_async(dispatch_get_main_queue(), ^{
        [watcher setSourceNames:linkSources]; // empty stops it
      });
    }
  }

  // Snapshot the motion-blur settings now (the param API is unavailable at
  // render time). The blob layout is [CanvasLinkTiming][KKMotionBlurState]
  // [layer blob] - transient (produced and consumed within one render
  // request), so the layout can evolve freely. Render reads the prefixes,
  // then the per-sample clip fractions are recomputed there from
  // sampleTimesForState + the render cache (no paramAPI needed).
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  NSString *mbJSON =
      api ? KKReadCustomParamString(api, kKKParamMotionBlurData) : nil;
  KKMotionBlurState mbState = [KKMotionBlur snapshotStateFromJSON:mbJSON
                                                        timingAPI:timingAPI
                                                           atTime:renderTime];
  // The clip's absolute span, for link-expression resolution at encode time
  // (frac -> project seconds; the same linear mapping the bus curves use).
  // Zero duration = timing unavailable -> render evaluates unresolved.
  CanvasLinkTiming linkTiming = {0.0, 0.0, 0ull};
  if (timingAPI) {
    CMTime effStart = kCMTimeZero, dur = kCMTimeZero, effStartTL = kCMTimeZero;
    [timingAPI startTimeForEffect:&effStart];
    [timingAPI durationTimeForEffect:&dur];
    [timingAPI timelineTime:&effStartTL fromInputTime:effStart];
    linkTiming.clipStartTLSec = CMTimeGetSeconds(effStartTL);
    linkTiming.clipDurSec = CMTimeGetSeconds(dur);
  }
  // Fold every referenced source's bus change-stamp into the state (see the
  // CanvasLinkTiming.refFreshness contract). Sorted so the fold is
  // deterministic across the unordered set. Same-clip refs are included but
  // settle: this clip republishes its own curves (idempotently) BEFORE this
  // point in the same call, so their stamps only move when the blob did.
  if (refSources.count) {
    unsigned long long fresh = 0;
    for (NSString *name in [refSources.allObjects
             sortedArrayUsingSelector:@selector(compare:)])
      fresh = fresh * 1099511628211ull ^
              (unsigned long long)[KKLinkBus changeStampForLink:name];
    linkTiming.refFreshness = fresh;
  }
  NSMutableData *state = [NSMutableData dataWithBytes:&linkTiming
                                               length:sizeof(linkTiming)];
  [state appendBytes:&mbState length:sizeof(mbState)];
  if (layerBlob.length)
    [state appendData:layerBlob];
  *pluginState = state;
  return YES;
}

// Link-source opt-in (see KKPlugin -writeLinkManifest): the per-layer sources
// built in -pluginState: above.
- (NSArray<KKLinkLayerSource *> *)linkableLayersForManifest {
  return self.linkLayerSources;
}

// The XPC bundle's CFBundleName is "Canvas XPC Service" - not a picker name.
- (NSString *)linkManifestEffectName {
  return @"Canvas";
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
                               descriptorPath:
                                   CanvasMiniViewerDescriptorPathForUUID(
                                       KKInstanceUUIDForAPI(self.apiManager))
                              boundaryReqSecs:self.renderCache.boundaryReqSecs
                             boundaryReqFracs:self.renderCache.boundaryReqFracs
                              multiSlotActive:YES
                            changesOutputSize:NO
                                   defaultTag:[self.renderCache
                                                  clipFractionAtSeconds:
                                                      CMTimeGetSeconds(
                                                          renderTime)]
                                  renderCache:self.renderCache];

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

  // The state blob is [CanvasLinkTiming][KKMotionBlurState][layer blob];
  // split off the prefixes before decoding the layer stack (bottom of the
  // array draws in front, so composite back-to-front: last index first).
  CanvasLinkTiming linkTiming = {0.0, 0.0};
  KKMotionBlurState mbState = {0};
  NSData *layerBlob = nil;
  const NSUInteger kPrefixLen = sizeof(CanvasLinkTiming) + sizeof(KKMotionBlurState);
  if (pluginState.length >= kPrefixLen) {
    [pluginState getBytes:&linkTiming length:sizeof(linkTiming)];
    [pluginState getBytes:&mbState
                    range:NSMakeRange(sizeof(linkTiming), sizeof(mbState))];
    if (pluginState.length > kPrefixLen)
      layerBlob = [pluginState
          subdataWithRange:NSMakeRange(kPrefixLen,
                                       pluginState.length - kPrefixLen)];
  }
  NSArray<KKBezierPath *> *layers =
      layerBlob.length ? [KKBezierPath pathsFromBlob:layerBlob] : nil;
  // Open the link-expression scope for this encode: every continuous lane
  // read below (CanvasResolvedLaneValue in the property evaluators) resolves
  // linkExpressions against the bus at the clip's absolute time. The cleanup
  // attribute pops the thread-local scope on EVERY exit path of this method
  // (there are many early returns), so a failed encode can't leak an open
  // scope onto this render thread.
  __attribute__((cleanup(CanvasLinkScopeCleanup))) BOOL linkScopeToken = YES;
  (void)linkScopeToken;
  if (linkTiming.clipDurSec > 0.0)
    CanvasLinkScopePush(linkTiming.clipStartTLSec, linkTiming.clipDurSec);
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
  // via its inversePixelTransform: resScale =
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
  // Motion-blur sample: render the layer stack PER LAYER (image -> fill ->
  // stroke, back-to-front, array[0] = topmost drawn last) into one blur SAMPLE
  // texture over its time-matched source, so every accumulated sample carries the
  // SAME correct cross-layer z-order as the non-blur path (fills now smear with
  // the rest instead of the old single post-pass). `sdest` is a tracked scratch
  // texture owned by KKMotionBlur (it commits `scb` and averages the samples), so
  // sequential render passes in that one command buffer serialize correctly - no
  // separate buffers / waits (unlike the untracked FCP dest).
  // Depth-order the drawables ONCE per render (back-to-front) so a layer tilted
  // physically in front draws on top, instead of strict list order. The order is
  // stable across motion-blur sub-frame samples, so it's computed here at the
  // frame `frac` and reused for every sample - NOT rebuilt inside
  // renderSampleOrdered (that re-evaluated every layer's transform N times and
  // stalled the viewer during a rotation drag). Near-coincident layers flip
  // front/back by deck facing (see CanvasOrderDrawablesBackToFront); flat keep
  // stack order.
  NSInteger total = (NSInteger)layers.count;
  NSInteger *idxBuf = malloc(sizeof(NSInteger) * (size_t)MAX(total, 1));
  CanvasLayerDrawKey *keyBuf =
      malloc(sizeof(CanvasLayerDrawKey) * (size_t)MAX(total, 1));
  NSInteger nDraw = 0;
  for (NSInteger i = 0; i < total; i++) {
    KKBezierPath *lp = layers[i];
    if (lp.isGroup || lp.hidden)
      continue;
    idxBuf[nDraw] = i;
    keyBuf[nDraw] = CanvasLayerComposedDrawKey(
        layers, i, frac, outputWidth, outputHeight, tileShiftX, tileShiftY, nil,
        nil);
    nDraw++;
  }
  NSInteger *ordBuf = malloc(sizeof(NSInteger) * (size_t)MAX(nDraw, 1));
  CanvasOrderDrawablesBackToFront(idxBuf, keyBuf, nDraw,
                                  0.02f * fmaxf(outputWidth, outputHeight),
                                  ordBuf);
  NSMutableArray<NSNumber *> *drawOrder =
      [NSMutableArray arrayWithCapacity:(NSUInteger)nDraw];
  for (NSInteger k = 0; k < nDraw; k++)
    [drawOrder addObject:@(ordBuf[k])];
  free(idxBuf);
  free(keyBuf);
  free(ordBuf);

  void (^renderSampleOrdered)(id<MTLTexture>, id<MTLCommandBuffer>,
                              id<MTLTexture>, double, double,
                              NSArray<NSNumber *> *) =
      ^(id<MTLTexture> sdest, id<MTLCommandBuffer> scb, id<MTLTexture> srcTex,
        double f, double mbPrevFrac, NSArray<NSNumber *> *order) {
        if (!device || !sdest || !imagePS)
          return;
        float sw = (float)sdest.width, sh = (float)sdest.height;
        MTLViewport svp = (MTLViewport){0, 0, sw, sh, -1, 1};
        simd_uint2 svpSize = {(unsigned int)sw, (unsigned int)sh};
        id<MTLRenderCommandEncoder> (^sEnc)(id<MTLRenderPipelineState>,
                                            MTLLoadAction) =
            ^(id<MTLRenderPipelineState> ps, MTLLoadAction load) {
              MTLRenderPassDescriptor *rpd =
                  [MTLRenderPassDescriptor renderPassDescriptor];
              rpd.colorAttachments[0].texture = sdest;
              rpd.colorAttachments[0].loadAction = load;
              rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
              if (load == MTLLoadActionClear)
                rpd.colorAttachments[0].clearColor =
                    MTLClearColorMake(0, 0, 0, 0);
              id<MTLRenderCommandEncoder> e =
                  [scb renderCommandEncoderWithDescriptor:rpd];
              [e setViewport:svp];
              [e setVertexBytes:&svpSize
                         length:sizeof(svpSize)
                        atIndex:KKVertexInputIndex_ViewportSize];
              [e setRenderPipelineState:ps];
              return e;
            };
        // Source base: clear the sample + draw its time-matched source frame.
        id<MTLRenderCommandEncoder> base = sEnc(imagePS, MTLLoadActionClear);
        if (srcTex)
          CanvasEncodeSourceTile(base, srcTex, outputWidth, outputHeight,
                                 tileShiftX, tileShiftY);
        [base endEncoding];
        CanvasFillPipelines fillPipes = {0};
        CanvasFillBuildPipelines(device, regID, pf, &fillPipes);
        BOOL canFill =
            fillPipes.stencil && fillPipes.color && fillPipes.composite;
        double ef = f < 0.0 ? 0.0 : f;
        for (NSNumber *idxN in order) {
          NSInteger i = idxN.integerValue;
          KKBezierPath *p = layers[i];
          // Bundle p's ancestor groups in so the per-layer encoders still
          // compose the group transform (they skip group rows but read them for
          // the compose); a bare @[p] drops it and a grouped layer renders
          // untransformed while its OSC/highlight follow the group.
          NSArray<KKBezierPath *> *one =
              CanvasLayerPathWithAncestors(p, layers);
          if (p.isImage) {
            id<MTLRenderCommandEncoder> e = sEnc(imagePS, MTLLoadActionLoad);
            CanvasEncodeImageLayers(one, e, device, texCache, outputWidth,
                                    outputHeight, tileShiftX, tileShiftY, f, nil,
                                    nil, imagePS, imageTintPS, imageGradTintPS);
            [e endEncoding];
          }
          if (canFill && CanvasFillEnabledAtFraction(p, ef, nil, nil) &&
              (!p.isImage ||
               CanvasFillStyleAtFraction(p, ef, nil, nil).style != 0)) {
            CanvasEncodeFilledLayers(one, device, texCache, scb, sdest,
                                     &fillPipes, outputWidth, outputHeight, sw, sh,
                                     tileShiftX, tileShiftY, f, nil, nil);
          }
          if (!p.isImage && CanvasStrokeEnabledAtFraction(p, ef, nil, nil) &&
              strokePS) {
            id<MTLRenderCommandEncoder> e = sEnc(strokePS, MTLLoadActionLoad);
            CanvasEncodeVectorLayers(one, e, device, outputWidth, outputHeight,
                                     tileShiftX, tileShiftY, f, nil, nil,
                                     strokeScale, marchElapsed, mbPrevFrac,
                                     strokePS, strokeGradientPS, strokeDashPS);
            [e endEncoding];
          }
        }
      };

  // Destination tile dims: the non-blur per-layer loop's viewport + the fill
  // MSAA target size. (The blur path reads its sample texture's own dims.)
  FxRect tileBF = destinationImage.tilePixelBounds;
  float tileW = (float)(tileBF.right - tileBF.left);
  float tileH = (float)(tileBF.top - tileBF.bottom);

  // Non-blur path: composite the whole per-layer-ordered stack (source +
  // image/fill/stroke, top-of-list LAST) into a TRACKED per-instance intermediate
  // via renderSampleOrdered - ONE command buffer, whose intra-buffer hazard
  // tracking serialises the passes correctly - then a single blit copies that to
  // FCP's untracked dest tile. This replaces the old per-draw waitUntilCompleted
  // (one command buffer + CPU stall PER image/fill/stroke), which crushed
  // playback on busy / multi-instance setups (dozens of GPU round-trips a frame).
  BOOL (^runLayersOrdered)(double) = ^BOOL(double f) {
    if (!device)
      return NO;
    id<MTLTexture> destTex = [destinationImage metalTextureForDevice:device];
    if (!destTex)
      return NO;
    NSInteger iw = (NSInteger)tileW, ih = (NSInteger)tileH;
    if (iw <= 0 || ih <= 0)
      return NO;
    // Reuse the cached intermediate when its size / format still match.
    id<MTLTexture> interm = self.renderIntermediateTex;
    if (!interm || (NSInteger)interm.width != iw ||
        (NSInteger)interm.height != ih || interm.pixelFormat != pf) {
      MTLTextureDescriptor *td = [MTLTextureDescriptor
          texture2DDescriptorWithPixelFormat:pf
                                       width:(NSUInteger)iw
                                      height:(NSUInteger)ih
                                   mipmapped:NO];
      td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
      td.storageMode = MTLStorageModePrivate;
      interm = [device newTextureWithDescriptor:td];
      self.renderIntermediateTex = interm;
    }
    if (!interm)
      return NO;
    id<MTLCommandQueue> queue = [cache commandQueueWithRegistryID:regID
                                                      pixelFormat:pf];
    if (!queue)
      return NO;
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLTexture> srcTex =
        sourceImages.firstObject
            ? [sourceImages.firstObject metalTextureForDevice:device]
            : nil;
    renderSampleOrdered(interm, cb, srcTex, f, -1.0, drawOrder);
    // Copy the finished composite onto the dest tile. The intermediate is tracked
    // so the blit waits for the render passes; the dest is the lone write here.
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:interm
                sourceSlice:0
                sourceLevel:0
               sourceOrigin:MTLOriginMake(0, 0, 0)
                 sourceSize:MTLSizeMake((NSUInteger)iw, (NSUInteger)ih, 1)
                  toTexture:destTex
           destinationSlice:0
           destinationLevel:0
          destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    [cache returnCommandQueueToCache:queue];
    return YES;
  };

  // "Fast" motion blur: per-layer velocity-buffer reconstruction (McGuire/
  // Guertin via the shared KKMotionBlurReconstruct). For each layer: render it
  // ALONE over transparent (mbColorTex), emit its analytic screen-space velocity
  // (mbVelocityTex) from the composed matrix at the current frac AND the shutter
  // start, reconstruct into mbBlurredTex, then composite that over the dest. Cost
  // is fixed in the tap count - independent of blur length - unlike the N-sample
  // accumulate path below. The source frame is the un-blurred base (footage
  // smear stays on the Accurate path). Returns NO on any setup failure so the
  // caller falls through to accumulate.
  BOOL (^runFastBlur)(void) = ^BOOL {
    if (!device)
      return NO;
    id<MTLTexture> destTex = [destinationImage metalTextureForDevice:device];
    if (!destTex)
      return NO;
    NSInteger iw = (NSInteger)tileW, ih = (NSInteger)tileH;
    if (iw <= 0 || ih <= 0 || drawOrder.count == 0)
      return NO;

    id<MTLRenderPipelineState> velPS = [cache
        buildAndRegisterPipelineStateForPluginID:@"co.overpolish.keyframeless"
                                                 @".Canvas.velocity"
                                      registryID:regID
                                     pixelFormat:MTLPixelFormatRG16Float
                                        bundleID:kitBundleID
                                    vertexShader:@"KKVelocityVertexShader"
                                  fragmentShader:@"KKVelocityFragment"
                                       blendMode:KKBlendModeNone];
    id<MTLRenderPipelineState> morphVelPS = [cache
        buildAndRegisterPipelineStateForPluginID:@"co.overpolish.keyframeless"
                                                 @".Canvas.velocity.morph"
                                      registryID:regID
                                     pixelFormat:MTLPixelFormatRG16Float
                                        bundleID:kitBundleID
                                    vertexShader:@"KKVelocityMorphVertexShader"
                                  fragmentShader:@"KKVelocityFragment"
                                       blendMode:KKBlendModeNone];
    // Additive accumulation pipeline: averages N sub-frame samples of a draw-on
    // layer (each scaled by 1/N in the opacity fragment) into a scratch texture.
    // Draw-on is "appearing" content on a possibly-curved path, which velocity
    // reconstruction can't smear cleanly.
    id<MTLRenderPipelineState> compositePS = [cache
        buildAndRegisterPipelineStateForPluginID:@"co.overpolish.keyframeless"
                                                 @".Canvas.mbcomposite"
                                      registryID:regID
                                     pixelFormat:pf
                                        bundleID:kitBundleID
                                    vertexShader:@"KKVertexShader"
                                  fragmentShader:@"KKTexturePassthroughFragment"
                                       blendMode:KKBlendModePremultipliedAlpha];
    if (!velPS || !compositePS)
      return NO;

    self.mbColorTex = CanvasEnsureScratchTex(self.mbColorTex, device, iw, ih, pf);
    self.mbVelocityTex = CanvasEnsureScratchTex(self.mbVelocityTex, device, iw,
                                                ih, MTLPixelFormatRG16Float);
    self.mbBlurredTex =
        CanvasEnsureScratchTex(self.mbBlurredTex, device, iw, ih, pf);
    if (!self.mbColorTex || !self.mbVelocityTex || !self.mbBlurredTex)
      return NO;

    id<MTLCommandQueue> queue = [cache commandQueueWithRegistryID:regID
                                                      pixelFormat:pf];
    if (!queue)
      return NO;
    id<MTLTexture> srcTex =
        sourceImages.firstObject
            ? [sourceImages.firstObject metalTextureForDevice:device]
            : nil;

    // Shutter-start clip fraction (the velocity is the displacement from here to
    // `frac`). Fixed 90000 timescale so a sub-frame offset survives FCP's low
    // playback timescales (same reason as KKMotionBlur sampleTimes).
    double fPrev = fracForTime(
        CMTimeSubtract(renderTime, CMTimeMakeWithSeconds(mbState.shutterSec,
                                                         90000)));
    const float marginPx = 64.0f; // cover stroke width; smear handled by tiles
    simd_uint2 vp = {(unsigned int)iw, (unsigned int)ih};

    // Base: clear the dest + draw the un-blurred source frame.
    {
      id<MTLCommandBuffer> cb = [queue commandBuffer];
      MTLRenderPassDescriptor *rpd =
          [MTLRenderPassDescriptor renderPassDescriptor];
      rpd.colorAttachments[0].texture = destTex;
      rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
      rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
      rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
      id<MTLRenderCommandEncoder> e =
          [cb renderCommandEncoderWithDescriptor:rpd];
      [e setViewport:(MTLViewport){0, 0, (double)iw, (double)ih, -1, 1}];
      [e setVertexBytes:&vp
                 length:sizeof(vp)
                atIndex:KKVertexInputIndex_ViewportSize];
      [e setRenderPipelineState:imagePS];
      if (srcTex)
        CanvasEncodeSourceTile(e, srcTex, outputWidth, outputHeight, tileShiftX,
                               tileShiftY);
      [e endEncoding];
      [cb commit];
      [cb waitUntilCompleted];
    }

    KKVertex2D fsQuad[4] = {
        {{iw / 2.0f, -ih / 2.0f}, {1, 1}},
        {{-iw / 2.0f, -ih / 2.0f}, {0, 1}},
        {{iw / 2.0f, ih / 2.0f}, {1, 0}},
        {{-iw / 2.0f, ih / 2.0f}, {0, 0}},
    };

    // Composite mbBlurredTex over the dest (premultiplied "over"); shared by both
    // the reconstruction and accumulation branches below. (`fsQuad` is captured
    // via a pointer - blocks can't capture a C array by value.)
    KKVertex2D *fsQuadP = fsQuad;
    void (^compositeBlurredOverDest)(id<MTLCommandBuffer>) =
        ^(id<MTLCommandBuffer> cb) {
          MTLRenderPassDescriptor *rpd =
              [MTLRenderPassDescriptor renderPassDescriptor];
          rpd.colorAttachments[0].texture = destTex;
          rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
          rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
          id<MTLRenderCommandEncoder> e =
              [cb renderCommandEncoderWithDescriptor:rpd];
          [e setViewport:(MTLViewport){0, 0, (double)iw, (double)ih, -1, 1}];
          [e setVertexBytes:fsQuadP
                     length:sizeof(KKVertex2D) * 4
                    atIndex:KKVertexInputIndex_Vertices];
          [e setVertexBytes:&vp
                     length:sizeof(vp)
                    atIndex:KKVertexInputIndex_ViewportSize];
          [e setRenderPipelineState:compositePS];
          [e setFragmentTexture:self.mbBlurredTex
                        atIndex:KKTextureIndex_InputImage];
          [e drawPrimitives:MTLPrimitiveTypeTriangleStrip
                  vertexStart:0
                  vertexCount:4];
          [e endEncoding];
        };

    for (NSNumber *idxN in drawOrder) {
      NSInteger i = idxN.integerValue;
      id<MTLCommandBuffer> cb = [queue commandBuffer];

      // Size this layer's blur reach (= tile size) to its actual screen-space
      // motion, so a faster layer gets a longer trail instead of clamping at a
      // fixed radius. Sample count scales with trail length so a long blur stays
      // smooth (no ghosting between taps). A still layer (vel ~0) reconstructs to
      // a no-op, so the tile floor keeps it cheap.
      float maxVel = CanvasLayerMaxVelocityPx(layers, i, frac, fPrev, outputWidth,
                                              outputHeight, tileShiftX,
                                              tileShiftY, nil, nil);
      int tileSize = (int)fmaxf(16.0f, fminf(256.0f, ceilf(maxVel)));
      int taps = (int)fmaxf(9.0f, fminf(25.0f, ceilf((float)tileSize / 6.0f)));

      // 1. Colour: the layer alone over transparent (clears, no source). Passing
      // fPrev enables the analytic DRAW-ON reveal fade in the stroke shader, so a
      // (curving) progressive reveal blurs here in ONE render - no accumulation,
      // no gather. The velocity pass below still handles the layer's spatial
      // motion (transform / morph / width / corners), composing with the fade.
      renderSampleOrdered(self.mbColorTex, cb, nil, frac, fPrev, @[ idxN ]);

      // 2. Velocity: the layer's analytic screen-space displacement.
      {
        MTLRenderPassDescriptor *rpd =
            [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture = self.mbVelocityTex;
        rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> e =
            [cb renderCommandEncoderWithDescriptor:rpd];
        [e setViewport:(MTLViewport){0, 0, (double)iw, (double)ih, -1, 1}];
        [e setVertexBytes:&vp
                   length:sizeof(vp)
                  atIndex:KKVertexInputIndex_ViewportSize];
        [e setRenderPipelineState:velPS];
        CanvasEncodeLayerVelocityQuad(layers, e, i, frac, fPrev, outputWidth,
                                      outputHeight, tileShiftX, tileShiftY,
                                      marginPx, morphVelPS, nil, nil);
        // Animating stroke width: the edges move ⊥ even when the centreline
        // doesn't. Overwrites the stroke region with transform + width velocity.
        CanvasEncodeStrokeWidthVelocity(layers, e, i, frac, fPrev, outputWidth,
                                        outputHeight, tileShiftX, tileShiftY,
                                        morphVelPS, nil, nil);
        // Animating rounded corners: the fillet arc between anchors moves where
        // the fan's straight chords miss it. Overwrites the corner regions.
        CanvasEncodeCornerFilletVelocity(layers, e, i, frac, fPrev, outputWidth,
                                         outputHeight, tileShiftX, tileShiftY,
                                         morphVelPS, nil, nil);
        // Draw-on endpoint marker riding the tip (the stroke reveal itself blurs
        // via the analytic alpha fade in the colour pass, but the marker
        // translates, so it blurs by velocity here).
        CanvasEncodeMarkerVelocity(layers, e, i, frac, fPrev, outputWidth,
                                   outputHeight, tileShiftX, tileShiftY,
                                   morphVelPS, nil, nil);
        [e endEncoding];
      }

      // 3. Reconstruct the blurred layer from colour + velocity.
      if (![KKMotionBlurReconstruct
              encodeReconstructionToTexture:self.mbBlurredTex
                               colorTexture:self.mbColorTex
                            velocityTexture:self.mbVelocityTex
                                   tileSize:tileSize
                                sampleCount:taps
                                 registryID:regID
                                     device:device
                              commandBuffer:cb]) {
        [cb commit];
        [cb waitUntilCompleted];
        [cache returnCommandQueueToCache:queue];
        return NO;
      }

      // 4. Composite the blurred layer over the dest (premultiplied "over").
      compositeBlurredOverDest(cb);

      [cb commit];
      [cb waitUntilCompleted];
    }
    [cache returnCommandQueueToCache:queue];
    return YES;
  };

  // Motion blur: accumulate the composite across sub-frame sample times (the
  // shared KKMotionBlur infra averages N passes). Each pass composites the
  // layer stack at that sample's clip fraction over its time-matched source
  // frame, so both the layer animation and the underlying content smear.
  if (mbState.enabled) {
    // Fast technique = per-layer velocity reconstruction (fixed cost). If it
    // bails (setup failure), fall through to accumulate. Accurate technique skips
    // straight to the accumulate path below (footage smear / heavy correctness).
    if (mbState.technique == KKMotionBlurTechniqueFast && runFastBlur())
      return YES;
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
                      // Each sample renders the full per-layer-ordered stack
                      // (image/fill/stroke) over its time-matched source into the
                      // sample texture; KKMotionBlur averages the samples.
                      renderSampleOrdered(sampleDest, commandBuffer,
                                          inputTextures.firstObject, f, -1.0,
                                          drawOrder);
                      return YES;
                    }];
    if (applied)
      return YES;
  }

  // No blur (or the accumulate bailed): composite the per-layer-ordered stack
  // into the tracked intermediate and blit it to the dest (one command buffer).
  if (runLayersOrdered(frac))
    return YES;
  // Degenerate fallback (no device / texture / queue): pass the source through.
  return [self
      encodeRenderCommandsForDestinationImage:destinationImage
                                 sourceImages:sourceImages
                                     commands:^(
                                         id<MTLRenderCommandEncoder> enc,
                                         NSArray<id<MTLTexture>> *inputs) {
                                       if (!inputs.count || !imagePS)
                                         return;
                                       [enc setRenderPipelineState:imagePS];
                                       CanvasEncodeSourceTile(
                                           enc, inputs[0], outputWidth,
                                           outputHeight, tileShiftX, tileShiftY);
                                     }];
}

// Maintain-timing persistence, Canvas flavour: Canvas keeps each layer's timing
// in its own animationJSON inside the layer blob (kParamLayerData), not the
// single kKKParamTimelineData the base retimes. Retime EVERY animated layer from
// the old media anchor to the new clip range so the stored keyposes (and the
// inspector graph) match the media-locked render. Return nil - the base's
// single-timeline graph push doesn't fit a multi-layer graph, so we reload the
// layer list ourselves.
- (KKTimeline *)_retimeMaintainTimingBlobWithParamID:(UInt32)timelineParamID
                                              getAPI:
                                                  (id<FxParameterRetrievalAPI_v6>)
                                                      getAPI
                                              setAPI:
                                                  (id<FxParameterSettingAPI_v5>)
                                                      setAPI
                                           fromSrcIn:(double)fromSrcIn
                                             fromDur:(double)fromDur
                                             toSrcIn:(double)toSrcIn
                                               toDur:(double)toDur
                                             edgeEps:(double)edgeEps {
  NSString *b64 = KKReadCustomParamString(getAPI, timelineParamID);
  if (!b64.length)
    return nil;
  NSMutableArray<KKBezierPath *> *paths = [KKBezierPath
      pathsFromBlob:[[NSData alloc] initWithBase64EncodedString:b64 options:0]];
  if (!paths.count)
    return nil;
  NSArray<KKLane *> *templates = [CanvasPlugin availableLanes];
  BOOL any = NO;
  for (KKBezierPath *path in paths) {
    if (!path.animationJSON.length)
      continue; // static layer: nothing to retime
    KKTimeline *tl = CanvasLayerTimelineForPath(path, templates);
    if (!tl)
      continue;
    KKTimeline *retimed = KKTimelineRetimedForMediaAnchor(
        tl, fromSrcIn, fromDur, toSrcIn, toDur,
        ^NSArray<NSNumber *> *(KKLane *lane, double frac) {
          return KKLaneDisplayValueAtFraction(lane, frac);
        },
        edgeEps);
    CanvasApplyTimelineToPath(retimed, path);
    any = YES;
  }
  if (!any)
    return nil;
  NSData *blob = [KKBezierPath blobFromPaths:paths];
  KKWriteCustomParamString(setAPI, [blob base64EncodedStringWithOptions:0],
                           timelineParamID);
  __weak typeof(self) weak = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    __strong typeof(self) s = weak;
    [(CanvasInspectorView *)s.inspectorView reloadLayerList];
  });
  return nil;
}

@end
#pragma clang diagnostic pop
