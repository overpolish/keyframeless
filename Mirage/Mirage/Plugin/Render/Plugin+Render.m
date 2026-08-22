/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "MirageCustomShader.h"
#import "MirageDirectives.h"         // MirageCommonDefault
#import "MirageFeedbackSet.h"        // MirageNewBufferTexture
#import "MirageFrameOffsets.h"       // `// #frames` neighbour offsets
#import "MirageMiniViewerRenderer.h" // per-instance descriptor path
#import "MirageRenderUniforms.h"     // MirageMakeUniforms (shared with mini)
#import "MirageStateBlob.h"
#import "MirageSurfaceResponse.h"
#import "Plugin+Render_Internal.h"

#import <KeyframelessKit/KKLicense.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKMetalDeviceCache.h>
#import <KeyframelessKit/KKMiniViewerFeed.h>
#import <KeyframelessKit/KKMotionBlur.h>
#import <KeyframelessKit/KKWatermark.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

// Cleared code = passthrough (show the source unchanged), not the plasma
// default.
NSString *const kMiragePassthroughSource =
    @"void mainImage(out vec4 O, in vec2 fc){ O = "
    @"texture(iChannel0, fc / iResolution.xy); }";

static void MirageApplySelectionPreview(MirageShaderModel *model,
                                        NSString *source,
                                        MiragePluginState *state,
                                        NSInteger activeKey) {
  NSString *selectionKey = MirageSurfaceSelectionToggleForSource(source);
  NSString *activeKeyControl =
      MirageSurfaceActiveKeyControlForSource(source);
  if (!model || !state)
    return;
  const MirageScalarProp *props = model.scalarProps;
  for (int i = 0; i < model.scalarCount; i++)
    if ([selectionKey isEqualToString:@(props[i].name)] && props[i].isBool &&
        props[i].poolOffset >= 0 &&
        props[i].poolOffset < state->colorPoolCount) {
      state->colorPool[props[i].poolOffset].x = 1.0f;
    } else if ([activeKeyControl isEqualToString:@(props[i].name)] &&
               props[i].isChoice && props[i].poolOffset >= 0 &&
               props[i].poolOffset < state->colorPoolCount) {
      state->colorPool[props[i].poolOffset].x = (float)activeKey;
    }
}

// Every `// #frames` offset any ENABLED entry declares, deduped, in entry then
// declaration order. One entry - the pre-rack case - is exactly that entry's
// own list, in its own order.
//
// An NSArray rather than a MirageFrameOffsets: the struct's capacity is the
// per-shader ceiling (KK_SHADER_MAX_FRAME_OFFSETS), and a chain of eight
// entries can legitimately want more DISTINCT frames than any one of them may
// declare. This is only the schedule side; each entry still binds its own
// declared list, in its own order, from its own sections.
// Whether ANY byte of the blob mentions the `#frames` directive at all.
//
// The blob carries every entry's code sections verbatim, so this one scan
// answers for the whole chain what asking entry by entry would cost N section
// decodes (each rebuilding that entry's shader source as NSStrings) plus N
// directive parses - per scheduled frame, on the render thread, for the answer
// "no" that almost every project gives. A false positive (the word inside a
// comment or a string) only falls through to the exact parse below.
static BOOL MirageBlobMentionsFrames(NSData *pluginState) {
  if (pluginState.length < 7)
    return NO;
  static const char needle[] = "#frames";
  return memmem(pluginState.bytes, pluginState.length, needle,
                sizeof(needle) - 1) != NULL;
}

static NSArray<NSNumber *> *MirageUnionFrameOffsets(NSData *pluginState) {
  if (!MirageBlobMentionsFrames(pluginState))
    return @[];
  NSMutableOrderedSet<NSNumber *> *out = [NSMutableOrderedSet orderedSet];
  NSInteger entries = MirageStateBlobEntryCount(pluginState);
  for (NSInteger e = 0; e < entries; e++) {
    // Sample 0 is the render time: an entry switched off there encodes no pass
    // at all, so it schedules no frames either.
    if (!MirageStateBlobEntryEnabled(pluginState, e, 0))
      continue;
    NSString *image =
        MirageStateBlobReadSectionsAtIndex(pluginState, e)[@"Image"];
    MirageFrameOffsets fo = MirageFrameOffsetsForSource(image, NULL);
    for (int i = 0; i < fo.count; i++)
      [out addObject:@(fo.offsets[i])];
  }
  return out.array;
}

@implementation MiragePlugin (Render)

// Effect: request the clip we're applied to as the source (bound to iChannel0
// in the Custom render path). Motion blur averages the shader over a single
// source frame, so no sub-frame source requests. The boundary-value popover
// additionally pulls its requested clip fraction for the mini-viewer preview,
// and a `// #frames` shader pulls its declared neighbour frames.
//
// Callback order is pluginState -> scheduleInputs -> render, so the blob handed
// in here already carries the shader source: the offsets are re-derived from it
// rather than stashed between calls. That keeps this XPC-safe (no mutable
// statics, no per-instance scratch) and guarantees the schedule side and the
// render side read the same list.
- (BOOL)scheduleInputs:(NSArray<FxImageTileRequest *> *_Nullable *_Nullable)
                           inputImageRequests
       withPluginState:(NSData *)pluginState
                atTime:(CMTime)renderTime
                 error:(NSError **)error {
  NSArray<FxImageTileRequest *> *sourceReqs = KKBuildSourceRequests(
      renderTime,
      MirageMiniViewerRequestPathForUUID(KKInstanceUUIDForAPI(self.apiManager)),
      self.renderCache, ^id(CMTime t) {
        return [[FxImageTileRequest alloc]
            initWithSource:kFxImageTileRequestSourceEffectClip
                      time:t
            includeFilters:YES
               parameterID:0];
      });
  // Explicit Transition A/B wells. Ordinary effects still use the effect clip;
  // transition shaders prefer From for iChannel0 and retain an effect-clip
  // fallback for Motion templates saved before the From well existed.
  NSMutableArray<FxImageTileRequest *> *reqs = [sourceReqs mutableCopy];
  [reqs addObject:[[FxImageTileRequest alloc]
                      initWithSource:kFxImageTileRequestSourceParameter
                                time:renderTime
                      includeFilters:NO
                         parameterID:kParamFromImage]];
  [reqs addObject:[[FxImageTileRequest alloc]
                      initWithSource:kFxImageTileRequestSourceParameter
                                time:renderTime
                      includeFilters:NO
                         parameterID:kParamToImage]];
  // `// #frames`: one more effect-clip request per declared offset. APPENDED to
  // whatever is already in the list, so this composes with the boundary-preview
  // requests above and with any sub-frame source requests motion blur adds -
  // every request in this array is an independent frame FCP delivers, and the
  // render side pairs each back by mediaTime rather than by position.
  NSArray<NSNumber *> *offsets = MirageUnionFrameOffsets(pluginState);
  double frameDur = self.renderCache.frameDurSec;
  if (offsets.count > 0 && frameDur > 0.0) {
    int32_t scale = renderTime.timescale > 0 ? renderTime.timescale : 600;
    double base = CMTimeGetSeconds(renderTime);
    for (NSNumber *offset in offsets) {
      CMTime t =
          CMTimeMakeWithSeconds(base + offset.intValue * frameDur, scale);
      [reqs addObject:[[FxImageTileRequest alloc]
                          initWithSource:kFxImageTileRequestSourceEffectClip
                                    time:t
                          includeFilters:YES
                             parameterID:0]];
    }
  }
  *inputImageRequests = reqs;
  return YES;
}

// The delivered effect-clip tile whose mediaTime is nearest `wantSeconds`, or
// nil when nothing lands strictly inside `tolerance` (INFINITY accepts the
// nearest tile at any distance).
static FxImageTile *
MirageTileNearestMediaTime(NSArray<FxImageTile *> *sourceImages,
                           double wantSeconds, double tolerance) {
  FxImageTile *best = nil;
  double bestDelta = tolerance;
  for (FxImageTile *tile in sourceImages) {
    if (tile.imageSource != kFxImageTileRequestSourceEffectClip)
      continue;
    double delta = fabs(CMTimeGetSeconds(tile.mediaTime) - wantSeconds);
    if (delta < bestDelta) {
      bestDelta = delta;
      best = tile;
    }
  }
  return best;
}

FxImageTile *MirageCurrentFrameTile(NSArray<FxImageTile *> *sourceImages,
                                    CMTime renderTime) {
  return MirageTileNearestMediaTime(sourceImages, CMTimeGetSeconds(renderTime),
                                    INFINITY)
             ?: sourceImages.firstObject;
}

NSArray *MirageNeighborFrameTextures(
    NSString *source, NSArray<FxImageTile *> *sourceImages, CMTime renderTime,
    double frameDurSec, id<MTLDevice> device, id<MTLTexture> fallback,
    id<MTLTexture> (^convert)(id<MTLTexture> tex)) {
  MirageFrameOffsets fo = MirageFrameOffsetsForSource(source, NULL);
  if (fo.count <= 0 || !device)
    return @[];
  if (frameDurSec <= 0.0)
    frameDurSec = 1.0 / 60.0;
  double base = CMTimeGetSeconds(renderTime);
  double tolerance = frameDurSec * 0.5;
  NSMutableArray *out = [NSMutableArray arrayWithCapacity:(NSUInteger)fo.count];
  for (int i = 0; i < fo.count; i++) {
    double want = base + fo.offsets[i] * frameDurSec;
    FxImageTile *best =
        MirageTileNearestMediaTime(sourceImages, want, tolerance);
    id<MTLTexture> tex = best ? [best metalTextureForDevice:device] : nil;
    if (tex && convert)
      tex = convert(tex) ?: tex;
    if (tex)
      [out addObject:tex];
    else if (fallback)
      [out addObject:fallback];
    else
      [out addObject:[NSNull null]];
  }
  return out;
}

- (id<MTLTexture>)reusableGammaDestinationForKey:(NSInteger)key
                                          device:(id<MTLDevice>)device
                                           width:(NSUInteger)width
                                          height:(NSUInteger)height {
  if (!device || width == 0 || height == 0)
    return nil;
  if (!self.gammaDestinations)
    self.gammaDestinations = [NSMutableDictionary dictionary];
  NSNumber *k = @(key);
  id<MTLTexture> dst = self.gammaDestinations[k];
  // Keyed on size: the format is fixed by KKGammaConvertDestinationTexture, and
  // a render at another size (a thumbnail pass) rebuilds the slot rather than
  // reusing a mismatched one.
  if (dst && dst.width == width && dst.height == height)
    return dst;
  dst = KKGammaConvertDestinationTexture(device, width, height);
  if (dst)
    self.gammaDestinations[k] = dst;
  else
    [self.gammaDestinations removeObjectForKey:k];
  return dst;
}

- (id<MTLTexture>)reusableChainTextureForEntry:(NSString *)entryID
                                        device:(id<MTLDevice>)device
                                         width:(NSUInteger)width
                                        height:(NSUInteger)height {
  if (!device || width == 0 || height == 0 || !entryID.length)
    return nil;
  if (!self.chainTextures)
    self.chainTextures = [NSMutableDictionary dictionary];
  id<MTLTexture> tex = self.chainTextures[entryID];
  // Keyed on size for the same reason the gamma destinations are: a render at
  // another size (a thumbnail pass) rebuilds the slot rather than reusing a
  // mismatched one.
  if (tex && tex.width == width && tex.height == height)
    return tex;
  tex = MirageNewBufferTexture(device, width, height);
  if (tex)
    self.chainTextures[entryID] = tex;
  else
    [self.chainTextures removeObjectForKey:entryID];
  return tex;
}

- (NSArray *)gammaMatchNeighbors:(NSArray *)neighbors
                          decode:(BOOL)decode
                          device:(id<MTLDevice>)device
                          encode:(void (^__autoreleasing *)(
                                     id<MTLCommandBuffer>))outEncode {
  if (outEncode)
    *outEncode = nil;
  NSUInteger n = neighbors.count;
  if (n == 0 || !device || !KKGammaPipelineAvailable(device, decode))
    return neighbors;
  NSMutableArray *out = [NSMutableArray arrayWithCapacity:n];
  NSMutableArray *pairs = [NSMutableArray array]; // (src, dst) to encode
  for (NSUInteger i = 0; i < n; i++) {
    id entry = neighbors[i];
    if (entry == [NSNull null]) {
      [out addObject:entry];
      continue;
    }
    id<MTLTexture> src = entry;
    id<MTLTexture> dst = [self
        reusableGammaDestinationForKey:MirageGammaDestNeighbor0 + (NSInteger)i
                                device:device
                                 width:src.width
                                height:src.height];
    if (!dst) {
      // Allocation unavailable: bind the source unconverted, which is what the
      // allocating helper returns in the same situation.
      [out addObject:src];
      continue;
    }
    [out addObject:dst];
    [pairs addObject:@[ src, dst ]];
  }
  if (pairs.count == 0)
    return neighbors;
  if (outEncode)
    *outEncode = ^(id<MTLCommandBuffer> cb) {
      for (NSArray *pair in pairs)
        KKGammaConvertOnBufferInto(cb, pair[0], pair[1], decode);
    };
  return out;
}

// The fixed uniform block for this frame. `mediaW/H` are the output dimensions,
// which drive iResolution.
KKGLSLUniforms MirageBuildUniforms(const MiragePluginState *base,
                                   CGFloat mediaW, CGFloat mediaH,
                                   float encodeSRGB) {
  float iTime = base->common.time * base->common.speed +
                fmodf(base->common.seed, 10000.0f);
  // iProgress is the clip fraction paced by the transition's Easing lane (see
  // MirageEvalStateAtFrac), deliberately NOT scaled by Speed/Seed the way iTime
  // is - a transition's progress has to reach exactly 1.0 at the cut regardless
  // of the motion-rate params, and every easing curve maps 1 to 1. chanRes[0] =
  // the source clip resolution (iChannelResolution[0], filled from the bound
  // texture at draw time). Shared layout with the mini via MirageMakeUniforms.
  KKGLSLUniforms uniforms = MirageMakeUniforms(
      (float)mediaW, (float)mediaH, iTime, base->common.grain,
      base->common.grainSize, base->common.progress, encodeSRGB,
      (simd_float4){(float)mediaW, (float)mediaH, 1.0f, 0.0f});
  uniforms.transition.w = (float)base->transitionMode;
  return uniforms;
}

// A prepared single-pass draw: binds the per-sample uniforms + colour pool and
// issues the full-screen shader draw into whatever encoder it is handed. The
// source-dependent setup (pipeline, transpile, gamma-encoded source textures,
// noise/samplers) is captured ONCE, so motion blur can reuse it across N
// sub-frame samples, varying only the uniforms and pool per sample.
// What varies per draw, grouped so the block signature stays readable.
typedef struct MirageDrawArgs {
  KKGLSLUniforms u;
  const simd_float4 *pool;
  int poolCount;
} MirageDrawArgs;

typedef void (^MirageSinglePassDraw)(id<MTLRenderCommandEncoder> encoder,
                                     NSArray<id<MTLTexture>> *inputTextures,
                                     MirageDrawArgs args);

typedef void (^MirageGammaSetup)(id<MTLCommandBuffer>);

// The texture to BIND for `src` once this render's gamma conversion has been
// planned: the reusable destination (with the (src, dst) pair appended to
// `pairs` for the setup block to encode) or `src` itself when there is nothing
// to convert or no destination could be allocated.
static id<MTLTexture> MiragePlanGammaConversion(MiragePlugin *plugin,
                                                id<MTLTexture> src,
                                                MirageGammaDestKey key,
                                                id<MTLDevice> device,
                                                NSMutableArray *pairs) {
  if (!src)
    return src;
  id<MTLTexture> dst = [plugin reusableGammaDestinationForKey:key
                                                       device:device
                                                        width:src.width
                                                       height:src.height];
  if (!dst)
    return src;
  [pairs addObject:@[ src, dst ]];
  return dst;
}

// Every planned conversion for this render as ONE block, or nil when there is
// nothing to encode.
static MirageGammaSetup
MirageGammaSetupBlock(NSArray *pairs, BOOL decode,
                      void (^neighborEncode)(id<MTLCommandBuffer>)) {
  if (pairs.count == 0 && !neighborEncode)
    return nil;
  return ^(id<MTLCommandBuffer> cb) {
    for (NSArray *pair in pairs)
      KKGammaConvertOnBufferInto(cb, pair[0], pair[1], decode);
    if (neighborEncode)
      neighborEncode(cb);
  };
}

// Builds a MirageSinglePassDraw for `effectiveSource`. `linearDst` (float dest)
// triggers the gamma-encode of the linear sources - PLANNED once here and
// shared across all samples, with `outSetup` carrying the encoding to whatever
// command buffer the caller is about to render on (nil when nothing needs
// converting). Returns nil if even the error-pattern pipeline fails.
- (nullable MirageSinglePassDraw)
    _singlePassDrawForSource:(NSString *)effectiveSource
            destinationImage:(FxImageTile *)destinationImage
                sourceImages:(NSArray<FxImageTile *> *)sourceImages
            transitionShader:(BOOL)transitionShader
              transitionMode:(int)transitionMode
                   linearDst:(BOOL)linearDst
                  renderTime:(CMTime)renderTime
                       setup:(void (^__autoreleasing *)(id<MTLCommandBuffer>))
                                 outSetup {
  id<MTLRenderPipelineState> customPS =
      [self customPipelineForSource:effectiveSource
                   destinationImage:destinationImage];
  if (!customPS) {
    effectiveSource = MirageCustomErrorShaderSource();
    customPS = [self customPipelineForSource:effectiveSource
                            destinationImage:destinationImage];
  }
  if (!customPS)
    return nil;
  KKGLSLTranspileResult *tr = KKTranspileGLSL(effectiveSource);
  KKMetalDeviceCache *dc = [KKMetalDeviceCache sharedCache];
  uint64_t registryID = destinationImage.deviceRegistryID;
  id<MTLDevice> device = [dc deviceWithRegistryID:registryID];
  id<MTLTexture> noiseTex =
      tr.declaredChannelMask ? KKCustomChannelNoiseTexture(device) : nil;
  id<MTLSamplerState> chSampler =
      tr.declaredChannelMask ? KKCustomChannelSampler(device) : nil;
  id<MTLSamplerState> srcSampler =
      tr.declaredChannelMask ? KKCustomSourceSampler(device) : nil;
  id<MTLTexture> transparentTex = tr.declaredChannelMask && transitionMode != 0
                                      ? KKCustomTransparentTexture(device)
                                      : nil;
  id<MTLTexture> rawEffect = [MirageCurrentFrameTile(sourceImages, renderTime)
      metalTextureForDevice:device];
  id<MTLTexture> rawFrom =
      [KKImageTileForParameterID(sourceImages, kParamFromImage)
          metalTextureForDevice:device];
  id<MTLTexture> rawTo = [KKImageTileForParameterID(sourceImages, kParamToImage)
      metalTextureForDevice:device];
  id<MTLTexture> rawSrc = transitionShader && rawFrom ? rawFrom : rawEffect;
  // Gamma-encode the linear sources so a Shadertoy shader (gamma-space input,
  // output re-decoded for the float dest) round-trips them instead of
  // double-decoding + darkening. linearDst == float/linear dest; an 8-bit dest
  // already carries gamma source, so leave it untouched. BOTH channels get the
  // same treatment: a transition blending a gamma A against a linear B would
  // tear across the mix.
  //
  // Capture the selected source here because a transition's explicit From well
  // is not the encoder's first effect-clip texture.
  id<MTLTexture> gammaSrc = rawSrc, gammaTo = rawTo;
  // A color transform inverts the contract: it consumes and produces LINEAR, so
  // it is the float dest that needs no conversion and the 8-bit dest whose
  // gamma source must be decoded - the mirror of the encode its output branch
  // already applies for that same 8-bit target.
  BOOL colorTransform = KKLooksLikeColorTransformShader(effectiveSource);
  BOOL decodeSources = !linearDst && colorTransform;
  BOOL convertSources = decodeSources || (linearDst && !colorTransform);
  // PLANNED, not encoded: each conversion used to be its own command buffer
  // with a commit and a blocking wait, and that scheduling latency - not the
  // work, which measures under a tenth of a millisecond - was most of the
  // render callback. The pairs are encoded later onto the render's own command
  // buffer, where Metal orders them ahead of the draw that reads them.
  NSMutableArray *convertPairs = [NSMutableArray array];
  if (convertSources && (rawSrc || rawTo) &&
      KKGammaPipelineAvailable(device, decodeSources)) {
    gammaSrc = MiragePlanGammaConversion(self, rawSrc, MirageGammaDestSource,
                                         device, convertPairs);
    gammaTo = MiragePlanGammaConversion(self, rawTo, MirageGammaDestTo, device,
                                        convertPairs);
  }
  // `// #frames` neighbours get the SAME conversion iChannel0 just got. Any
  // other treatment - even leaving them raw - would make every temporal blend
  // mix a gamma value against a linear one and shift the colour of the trail
  // relative to the frame it trails behind.
  // Resolved RAW here, with no per-texture fallback: an undeliverable offset
  // stays NSNull and `neighborFallback` below substitutes the current frame at
  // bind time - the same texture the old per-entry fallback put in the array,
  // without paying a conversion for it. The whole set is then gamma-matched in
  // one batch instead of one blocking round trip per neighbour.
  NSArray *neighborTex = MirageNeighborFrameTextures(
      effectiveSource, sourceImages, renderTime, self.renderCache.frameDurSec,
      device, nil, nil);
  void (^neighborEncode)(id<MTLCommandBuffer>) = nil;
  if (convertSources && neighborTex.count)
    neighborTex = [self gammaMatchNeighbors:neighborTex
                                     decode:decodeSources
                                     device:device
                                     encode:&neighborEncode];
  if (outSetup)
    *outSetup = MirageGammaSetupBlock([convertPairs copy], decodeSources,
                                      neighborEncode);
  id<MTLTexture> toTex = gammaTo;
  id<MTLTexture> neighborFallback = gammaSrc ?: noiseTex;
  return ^(id<MTLRenderCommandEncoder> encoder,
           NSArray<id<MTLTexture>> *inputTextures, MirageDrawArgs args) {
    [encoder setRenderPipelineState:customPS];
    id<MTLTexture> src =
        gammaSrc ?: (inputTextures.count ? inputTextures[0] : nil);
    if (transitionMode == 1)
      src = transparentTex;
    id<MTLTexture> channel1 = transitionMode == 2 ? transparentTex : toTex;
    KKGLSLUniforms uu = args.u;
    const simd_float4 *colorPool = args.pool;
    int poolCount = args.poolCount;
    if (src)
      uu.chanRes[0] =
          (simd_float4){(float)src.width, (float)src.height, 1.0f, 0.0f};
    if (channel1)
      uu.chanRes[1] = (simd_float4){(float)channel1.width,
                                    (float)channel1.height, 1.0f, 0.0f};
    KKBindGLSLUniforms(encoder, &uu, colorPool, poolCount);
    KKBindCustomChannelTextures(encoder, tr,
                                @[
                                  src ?: (id)[NSNull null],
                                  channel1 ?: (id)[NSNull null], [NSNull null],
                                  [NSNull null]
                                ],
                                srcSampler, noiseTex, chSampler);
    KKBindCustomNeighborTextures(encoder, tr, neighborTex, srcSampler,
                                 neighborFallback);
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0
                vertexCount:4];
  };
}

// Single pass: source clip -> iChannel0, the "To" well -> iChannel1, noise ->
// the rest.
- (BOOL)_renderSinglePassWithUniforms:(KKGLSLUniforms)u
                                 base:(const MiragePluginState *)base
                               source:(NSString *)effectiveSource
                           renderTime:(CMTime)renderTime
                     destinationImage:(FxImageTile *)destinationImage
                         sourceImages:(NSArray<FxImageTile *> *)sourceImages {
  void (^setup)(id<MTLCommandBuffer>) = nil;
  MirageSinglePassDraw draw = [self
      _singlePassDrawForSource:effectiveSource
              destinationImage:destinationImage
                  sourceImages:sourceImages
              transitionShader:KKLooksLikeTransitionShader(effectiveSource)
                transitionMode:base->transitionMode
                     linearDst:(u.extra.w == 0.0f)
                    renderTime:renderTime
                         setup:&setup];
  if (!draw)
    return NO;
  MiragePluginState baseCopy = *base;
  return [self
      encodeRenderCommandsForDestinationImage:destinationImage
                                 sourceImages:sourceImages
                                        setup:setup
                                     commands:^(
                                         id<MTLRenderCommandEncoder> encoder,
                                         NSArray<id<MTLTexture>>
                                             *inputTextures) {
                                       draw(encoder, inputTextures,
                                            (MirageDrawArgs){
                                                .u = u,
                                                .pool = baseCopy.colorPool,
                                                .poolCount =
                                                    baseCopy.colorPoolCount});
                                     }];
}

// Motion blur (single pass only): re-render the shader at N sub-frame samples
// and average via KKMotionBlur. states[i] carries that sample's animation clock
// (iTime/iProgress) and colour pool; the source-dependent setup is shared. The
// source frame is the same for every sample (scheduleInputs: requests no extra
// sub-frame source), so only the shader's own animation smears.
- (BOOL)_renderSinglePassMotionBlurWithStates:(const MiragePluginState *)states
                                        count:(NSInteger)count
                                      mbState:(KKMotionBlurState)mbState
                                   renderTime:(CMTime)renderTime
                                       source:(NSString *)effectiveSource
                                       mediaW:(CGFloat)mediaW
                                       mediaH:(CGFloat)mediaH
                                   encodeSRGB:(float)encodeSRGB
                             destinationImage:(FxImageTile *)destinationImage
                                 sourceImages:
                                     (NSArray<FxImageTile *> *)sourceImages {
  void (^setup)(id<MTLCommandBuffer>) = nil;
  MirageSinglePassDraw draw = [self
      _singlePassDrawForSource:effectiveSource
              destinationImage:destinationImage
                  sourceImages:sourceImages
              transitionShader:KKLooksLikeTransitionShader(effectiveSource)
                transitionMode:states[0].transitionMode
                     linearDst:(encodeSRGB == 0.0f)
                    renderTime:renderTime
                         setup:&setup];
  if (!draw)
    return NO;
  // Every sample reads the same converted sources, so the conversion is encoded
  // ONCE, on the first sample's command buffer, ahead of that sample's encoder.
  __block BOOL setupEncoded = NO;
  return [KKMotionBlur
      applyToDestinationImage:destinationImage
                 sourceImages:sourceImages
                        state:mbState
                   renderTime:renderTime
                  renderBlock:^BOOL(int sampleIndex, id<MTLTexture> sampleDest,
                                    id<MTLCommandBuffer> commandBuffer,
                                    NSArray<id<MTLTexture>> *inputTextures) {
                    NSInteger si =
                        sampleIndex < 0
                            ? 0
                            : (sampleIndex >= count ? count - 1 : sampleIndex);
                    const MiragePluginState *s = &states[si];
                    KKGLSLUniforms su =
                        MirageBuildUniforms(s, mediaW, mediaH, encodeSRGB);
                    if (setup && !setupEncoded) {
                      setupEncoded = YES;
                      setup(commandBuffer);
                    }
                    return [self
                        encodeFullScreenQuadIntoTexture:sampleDest
                                       destinationImage:destinationImage
                                          commandBuffer:commandBuffer
                                         sourceTextures:inputTextures
                                               commands:^(
                                                   id<MTLRenderCommandEncoder>
                                                       encoder,
                                                   NSArray<id<MTLTexture>>
                                                       *inputs) {
                                                 draw(
                                                     encoder, inputs,
                                                     (MirageDrawArgs){
                                                         .u = su,
                                                         .pool = s->colorPool,
                                                         .poolCount =
                                                             s->colorPoolCount});
                                               }];
                  }];
}

// Publish the source (and the "To" well) to the inspector's mini-viewer feed.
// The renderer applies the shader locally, so these are the RAW textures.
// Which entry's Image the pumped `// #frames` neighbours follow: the first one
// in the chain that declares the directive, `fallback` (entry 0's) when none
// does. A single-template project answers `fallback` without touching the blob.
static NSString *MirageChainNeighborSource(NSData *pluginState,
                                           NSString *fallback) {
  NSInteger entryCount = MirageStateBlobEntryCount(pluginState);
  if (entryCount <= 1)
    return fallback;
  // Nothing in the chain declares the directive: skip the per-entry section
  // decode entirely (see MirageBlobMentionsFrames). The pump then finds no
  // offsets in `fallback` either, which is the same answer the loop reaches.
  if (!MirageBlobMentionsFrames(pluginState))
    return fallback;
  for (NSInteger i = 0; i < entryCount; i++) {
    NSString *image =
        MirageStateBlobReadSectionsAtIndex(pluginState, i)[@"Image"];
    if ([image rangeOfString:@"#frames"].location != NSNotFound)
      return image;
  }
  return fallback;
}

- (void)_publishMiniViewerFeeds:(FxImageTile *)destinationImage
                   sourceImages:(NSArray<FxImageTile *> *)sourceImages
                     renderTime:(CMTime)renderTime
                 neighborSource:(NSString *)neighborSource
               transitionShader:(BOOL)transitionShader
             technicalTransform:(BOOL)technicalTransform {
  // Per slot: single-slot = playhead, multi-slot = boundary preview / filmstrip
  // / onion. Shared glue in KKPlugin (MiniViewerFeed). The single-slot tag is
  // this frame's clip fraction (not a hard 0), so during playback/scrub the
  // open popover's mini-viewer sets editFraction to it and advances iTime with
  // the playhead - otherwise the preview stays frozen at t=0 while the timeline
  // moves (the popover live-playback plumbing the rest of the kit already
  // does).
  FxImageTile *fromTile =
      transitionShader
          ? KKImageTileForParameterID(sourceImages, kParamFromImage)
          : nil;
  NSArray<FxImageTile *> *primarySources =
      fromTile.ioSurface ? @[ fromTile ] : sourceImages;
  [self
      kkPublishMiniViewerFeedForDestination:destinationImage
                               sourceImages:primarySources
                             descriptorPath:
                                 MirageMiniViewerDescriptorPathForUUID(
                                     KKInstanceUUIDForAPI(self.apiManager))
                            boundaryReqSecs:self.renderCache.boundaryReqSecs
                           boundaryReqFracs:self.renderCache.boundaryReqFracs
                            multiSlotActive:self.renderCache.boundaryFeedActive
                          changesOutputSize:NO
                                // Every Mirage shader is re-evaluated in the
                                // mini. An 8-bit display-coded feed introduces
                                // a second quantisation before threshold
                                // effects such as Dither; values on a boundary
                                // can then choose a different Bayer cell than
                                // the main render. Preserve the host's linear
                                // source in half-float for every shader.
                                linearFloat:YES
                             fullResolution:YES
                                 defaultTag:
                                     [self.renderCache
                                         clipFractionAtSeconds:CMTimeGetSeconds(
                                                                   renderTime)]
                                renderCache:self.renderCache];
  // The "To" well as a second feed texture, so the mini-viewer can preview a
  // two-texture (GL-transition) shader instead of falling through to
  // iChannel1's noise.
  [self kkPublishMiniViewerChannel1ForDestination:destinationImage
                                     sourceImages:sourceImages
                                  wellParameterID:kParamToImage];
  [self _publishMiniViewerNeighbors:destinationImage
                       sourceImages:sourceImages
                         renderTime:renderTime
                        imageSource:neighborSource];
}

// `// #frames`: pump the neighbour frames THIS render just resolved into the
// feed's auxiliary textures, so the inspector-side preview binds the real
// neighbours instead of clamping every one of them to the current frame.
//
// RAW like the source slot, not gamma-converted: the feed writes whatever it is
// handed through one encoding, and the mini renderer then applies to a
// neighbour exactly the treatment it applies to iChannel0. Converting here
// would put the neighbours one encode ahead of the frame they trail, which is
// the same colour shift the FCP render path takes care to avoid.
//
// An offset FCP could not deliver falls back to the CURRENT frame, matching the
// render's edge-of-clip clamp, so the pumped count always equals the
// directive's count and the consumer never has to guess which offset is
// missing.
- (void)_publishMiniViewerNeighbors:(FxImageTile *)destinationImage
                       sourceImages:(NSArray<FxImageTile *> *)sourceImages
                         renderTime:(CMTime)renderTime
                        imageSource:(NSString *)imageSource {
  // Literal gate before the parse. MirageFrameOffsetsForSource builds a fresh
  // NSRegularExpression and matches it over the whole shader on every call, and
  // this runs per render tick for EVERY instance - including the ones with no
  // `#frames` at all, which paid none of it before neighbours were pumped. A
  // source without the text cannot carry the directive, so the outcome is
  // identical and only the regex is skipped.
  if ([imageSource rangeOfString:@"#frames"].location == NSNotFound) {
    if (self.miniViewerFeed.auxTextureCount)
      [self kkPublishMiniViewerAuxTexturesForDestination:destinationImage
                                                textures:@[]];
    return;
  }
  MirageFrameOffsets fo = MirageFrameOffsetsForSource(imageSource, NULL);
  if (fo.count <= 0) {
    if (self.miniViewerFeed.auxTextureCount)
      [self kkPublishMiniViewerAuxTexturesForDestination:destinationImage
                                                textures:@[]];
    return;
  }
  KKMetalDeviceCache *dc = [KKMetalDeviceCache sharedCache];
  id<MTLDevice> device =
      [dc deviceWithRegistryID:destinationImage.deviceRegistryID];
  if (!device)
    return;
  id<MTLTexture> current = [MirageCurrentFrameTile(sourceImages, renderTime)
      metalTextureForDevice:device];
  NSArray *neighbors = MirageNeighborFrameTextures(
      imageSource, sourceImages, renderTime, self.renderCache.frameDurSec,
      device, current, nil);
  if (neighbors.count != self.miniViewerFeed.auxTextureCount)
    KKLogDebug(@"[Mirage] mini aux neighbours n=%lu firstOffset=%+d",
               (unsigned long)neighbors.count, fo.offsets[0]);
  [self kkPublishMiniViewerAuxTexturesForDestination:destinationImage
                                            textures:neighbors];
}

// FCP renders browser / effect-library thumbnails at a REDUCED pixel size, but
// a `units="px"` control (Frame's Border Width, Glow Size, Noise Scale) is an
// absolute pixel count authored against the canonical frame. Unscaled, the same
// 30px covers ~6x more of a thumbnail than of the full render - which is why a
// Frame thumbnail's border and glow looked massive next to the real thing.
//
// FxTileableEffect exposes no render-scale API. The reliable idiom is the
// SOURCE image's inversePixelTransform (pixel -> canonical); the destination's
// pixelTransform is both the wrong matrix and the wrong direction.
float MirageRenderScale(NSArray<FxImageTile *> *sourceImages) {
  if (sourceImages.count == 0)
    return 1.0f;
  FxImageTile *src = sourceImages[0];
  FxMatrix44 *inv = src.inversePixelTransform;
  if (!inv)
    return 1.0f;
  FxRect sp = src.imagePixelBounds;
  FxPoint2D ll =
      [inv transform2DPoint:(FxPoint2D){(float)sp.left, (float)sp.bottom}];
  FxPoint2D ur =
      [inv transform2DPoint:(FxPoint2D){(float)sp.right, (float)sp.top}];
  float canonW = ur.x - ll.x;
  float pxW = (float)(sp.right - sp.left);
  if (canonW <= 0.0f || pxW <= 0.0f)
    return 1.0f;
  float scale = pxW / canonW;
  return isfinite(scale) && scale > 0.0f ? scale : 1.0f;
}

// Scale every RAW-pixel scalar in a filled pool. Points and #multi px fields
// are stored normalised (0..1 of the frame) and already scale themselves, so
// only the single-value `units="px"` scalars need it.
void MirageScalePixelProps(MirageShaderModel *model, vector_float4 *pool,
                           int poolCount, float scale) {
  if (!model || !pool || scale == 1.0f)
    return;
  const MirageScalarProp *props = model.scalarProps;
  for (int i = 0; i < model.scalarCount; i++) {
    const MirageScalarProp *p = &props[i];
    if (p->isPoint || p->isMulti || p->fieldUnit[0] != 'p')
      continue;
    // A repeatable control is one vec4 PER INSTANCE; the dead slots are zero,
    // and zero scales to zero, so the whole span goes through unconditionally.
    int span = p->slotMax > 0 ? p->slotMax : 1;
    for (int e = 0; e < span; e++) {
      int off = p->poolOffset + e;
      if (off < 0 || off >= poolCount)
        continue;
      pool[off].x *= scale;
    }
  }
}

// The four buffer sources in fixed A, B, C, D order, each with Common already
// prepended and an absent one left as an empty string so the index still names
// the buffer. `*outAny` is YES when any buffer is present at all, which is what
// selects the multi-pass path (buffer textures feed the passes' iChannels).
NSArray<NSString *> *
MirageBufferSourcesFromSections(NSDictionary<NSString *, NSString *> *sections,
                                NSString * (^withCommon)(NSString *),
                                BOOL *outAny) {
  NSArray<NSString *> *bufNames =
      @[ @"Buffer A", @"Buffer B", @"Buffer C", @"Buffer D" ];
  NSMutableArray<NSString *> *bufSources = [NSMutableArray arrayWithCapacity:4];
  for (NSString *bn in bufNames) {
    NSString *bs = sections[bn];
    if (bs.length > 0) {
      [bufSources addObject:withCommon(bs)];
      if (outAny)
        *outAny = YES;
    } else {
      [bufSources addObject:@""];
    }
  }
  return bufSources;
}

- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError *_Nullable *)outError {
  BOOL ok = [self _renderDestinationImageInner:destinationImage
                                  sourceImages:sourceImages
                                   pluginState:pluginState
                                        atTime:renderTime
                                         error:outError];
  if (ok)
    [self _applyViewerCompareToDestination:destinationImage
                              sourceImages:sourceImages
                               pluginState:pluginState
                                renderTime:renderTime];
  // Unconditional: a render that reports failure still leaves pixels in the
  // destination surface, and "make the shader fail" must not be a way to get a
  // clean frame out of the trial.
  KKWatermarkApplyIfUnlicensed(KKLicenseProductMirage, destinationImage);
  [self _reportStrayRenderWaits];
  return ok;
}

// Before/split must replace pixels in the effect output, not alpha-blend a raw
// frame over the already-composited viewer. The latter looks right only while
// the shader preserves the source's alpha footprint: a layout such as Frame or
// Cards leaves its generated/glow pixels visible wherever the raw source is
// transparent. Copying here writes transparent pixels too, before Final Cut
// composites the effect over the timeline below it.
- (BOOL)_applyViewerCompareToDestination:(FxImageTile *)destinationImage
                            sourceImages:(NSArray<FxImageTile *> *)sourceImages
                             pluginState:(NSData *)pluginState
                              renderTime:(CMTime)renderTime {
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  BOOL before = state.mirageCompareBypassing;
  BOOL split = state.mirageCompareSplitEnabled && !before;
  if ((!before && !split) || !destinationImage.ioSurface)
    return YES;

  NSString *imageSource = MirageStateBlobReadSections(pluginState)[@"Image"];
  FxImageTile *sourceTile =
      KKLooksLikeTransitionShader(imageSource)
          ? KKImageTileForParameterID(sourceImages, kParamFromImage)
          : nil;
  sourceTile = sourceTile ?: MirageCurrentFrameTile(sourceImages, renderTime);
  if (!sourceTile.ioSurface)
    return NO;

  KKMetalDeviceCache *cache = KKMetalDeviceCache.sharedCache;
  uint64_t registryID = destinationImage.deviceRegistryID;
  MTLPixelFormat pixelFormat =
      [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
  id<MTLDevice> device = [cache deviceWithRegistryID:registryID];
  id<MTLCommandQueue> queue = [cache commandQueueWithRegistryID:registryID
                                                    pixelFormat:pixelFormat];
  id<MTLTexture> destination = [destinationImage metalTextureForDevice:device];
  id<MTLTexture> source = [sourceTile metalTextureForDevice:device];
  id<MTLRenderPipelineState> pipeline = [cache
      buildAndRegisterPipelineStateForPluginID:
          @"com.keyframeless.Mirage.viewer-compare-copy"
                                    registryID:registryID
                                   pixelFormat:pixelFormat
                                      bundleID:
                                          @"com.keyframeless.KeyframelessKit"
                                  vertexShader:@"KKVertexShader"
                                fragmentShader:@"KKTexturePassthroughFragment"
                                     blendMode:KKBlendModeNone];
  if (!device || !queue || !destination || !source || !pipeline) {
    if (queue)
      [cache returnCommandQueueToCache:queue];
    return NO;
  }

  const float width = (float)destination.width;
  const float height = (float)destination.height;
  FxRect tile = destinationImage.tilePixelBounds;
  FxRect image = destinationImage.imagePixelBounds;
  float imageW = (float)(image.right - image.left);
  float imageH = (float)(image.top - image.bottom);
  if (imageW <= 0.0f)
    imageW = 1.0f;
  if (imageH <= 0.0f)
    imageH = 1.0f;
  float uvL = (float)(tile.left - image.left) / imageW;
  float uvR = (float)(tile.right - image.left) / imageW;
  float uvT = (float)(image.top - tile.top) / imageH;
  float uvB = (float)(image.top - tile.bottom) / imageH;
  KKVertex2D vertices[4] = {
      {{width / 2.0f, -height / 2.0f}, {uvR, uvB}},
      {{-width / 2.0f, -height / 2.0f}, {uvL, uvB}},
      {{width / 2.0f, height / 2.0f}, {uvR, uvT}},
      {{-width / 2.0f, height / 2.0f}, {uvL, uvT}},
  };
  simd_uint2 viewport = {(unsigned)destination.width,
                         (unsigned)destination.height};

  NSInteger splitLocalX = 0;
  if (split) {
    double seam = image.left +
                  MAX(0.0, MIN(1.0, state.mirageCompareSplitFraction)) * imageW;
    splitLocalX = (NSInteger)floor(seam - tile.left);
    splitLocalX = MAX(0, MIN((NSInteger)destination.width, splitLocalX));
    if (splitLocalX >= (NSInteger)destination.width) {
      [cache returnCommandQueueToCache:queue];
      return YES;
    }
  }

  MTLRenderPassDescriptor *rpd = MTLRenderPassDescriptor.renderPassDescriptor;
  rpd.colorAttachments[0].texture = destination;
  rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLCommandBuffer> cb = queue.commandBuffer;
  id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
  [enc setViewport:(MTLViewport){0, 0, width, height, -1.0, 1.0}];
  if (split) {
    // The fraction is in full-image space; intersect its right half with this
    // destination tile so partial/tiled renders keep the seam in one place.
    [enc setScissorRect:(MTLScissorRect){(NSUInteger)splitLocalX, 0,
                                         destination.width -
                                             (NSUInteger)splitLocalX,
                                         destination.height}];
  }
  [enc setRenderPipelineState:pipeline];
  [enc setVertexBytes:vertices
               length:sizeof(vertices)
              atIndex:KKVertexInputIndex_Vertices];
  [enc setVertexBytes:&viewport
               length:sizeof(viewport)
              atIndex:KKVertexInputIndex_ViewportSize];
  [enc setFragmentTexture:source atIndex:KKTextureIndex_InputImage];
  [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip
          vertexStart:0
          vertexCount:4];
  [enc endEncoding];
  [cb commit];
  [cb waitUntilCompleted];
  [cache returnCommandQueueToCache:queue];
  return YES;
}

// Canary: ONE mandatory wait per callback is the architecture, on every path -
// motion blur included, since it shares the frame's queue and commits once.
// Steady playback prints nothing at all; a checkpoint or a cold seek on a
// feedback chain is the only expected source. Anything else names a path that
// reintroduced a second round trip, which is what made playback crawl before.
- (void)_reportStrayRenderWaits {
  NSInteger strays = self.renderStrayWaitsSnapshot +
                     self.renderStrayWaitsRestore +
                     self.renderStrayWaitsBlurDrain;
  if (strays <= 0)
    return;
  NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
  if (now - self.renderStrayWaitsLastLog <= 2.0)
    return;
  self.renderStrayWaitsLastLog = now;
  KKLogDebug(@"[RenderGuard] render STRAY WAITS n=%ld | snapshot=%ld "
             @"restore=%ld blurDrain=%ld | mbSamples=%ld (each is a "
             @"KKMotionBlur commit+wait of its own)",
             (long)strays, (long)self.renderStrayWaitsSnapshot,
             (long)self.renderStrayWaitsRestore,
             (long)self.renderStrayWaitsBlurDrain,
             (long)self.lastRenderBlurSamples);
  self.renderStrayWaitsSnapshot = 0;
  self.renderStrayWaitsRestore = 0;
  self.renderStrayWaitsBlurDrain = 0;
}

- (BOOL)_renderDestinationImageInner:(FxImageTile *)destinationImage
                        sourceImages:(NSArray<FxImageTile *> *)sourceImages
                         pluginState:(NSData *)pluginState
                              atTime:(CMTime)renderTime
                               error:(NSError *_Nullable *)outError {
  if (sourceImages.count == 0 || !sourceImages[0].ioSurface ||
      !destinationImage.ioSurface) {
    if (outError != NULL) {
      *outError = [NSError errorWithDomain:FxPlugErrorDomain
                                      code:kFxError_InvalidParameter
                                  userInfo:@{
                                    NSLocalizedDescriptionKey :
                                        @"No source/destination IOSurface"
                                  }];
    }
    return NO;
  }

  // Output dimensions drive the shader's resolution uniform (iResolution etc.).
  CGFloat mediaW = destinationImage.imagePixelBounds.right -
                   destinationImage.imagePixelBounds.left;
  CGFloat mediaH = destinationImage.imagePixelBounds.top -
                   destinationImage.imagePixelBounds.bottom;

  // State built in -pluginState: (the params API is invalid here). The blob
  // codec owns the layout and carries the sample count; a missing/short blob
  // decodes as motion blur disabled with one default sample.
  MirageStateBlobHeader blob = MirageStateBlobReadHeader(pluginState);
  KKMotionBlurState mbState = blob.mbState;
  MiragePluginState base = blob.base;
  NSInteger n = blob.sampleCount;

  float encodeSRGB =
      (destinationImage.ioSurface.pixelFormat == kCVPixelFormatType_32BGRA)
          ? 1.0f
          : 0.0f;
  KKGLSLUniforms u = MirageBuildUniforms(&base, mediaW, mediaH, encodeSRGB);

  // Multi-pass sections from the blob tail (Image / Common / Buffer A-D).
  // Common is prepended to every pass.
  NSDictionary<NSString *, NSString *> *sections =
      MirageStateBlobReadSections(pluginState);
  NSString *common = sections[@"Common"] ?: @"";
  NSString *imageSrc = sections[@"Image"];
  if (imageSrc.length == 0)
    imageSrc = kMiragePassthroughSource;
  BOOL transitionShader = KKLooksLikeTransitionShader(imageSrc);
  // The feed publishes the RAW clip and the inspector's preview applies the
  // whole chain to it locally, so what the head entry is decides how the clip
  // is delivered (which well, which colour space) - and that is entry 0, whose
  // sections these are.
  //
  // `// #frames` is the exception: the neighbours are pumped ONCE and any entry
  // in the chain may be the one that declares them, so the pump follows the
  // first entry that does. One set can be published, so a second declaring
  // entry falls back to the current frame in the preview (the mini binds only
  // when the pumped count matches its own directive) rather than binding
  // another entry's offsets.
  [self _publishMiniViewerFeeds:destinationImage
                   sourceImages:sourceImages
                     renderTime:renderTime
                 neighborSource:MirageChainNeighborSource(pluginState, imageSrc)
               transitionShader:transitionShader
             technicalTransform:KKLooksLikeColorTransformShader(imageSrc)];

  // SHADER RACK: more than one entry and the chain renderer owns the frame -
  // each entry runs its own full pipeline, entry k + 1 reading entry k's
  // output. Everything above is entry 0's and stands either way; everything
  // below is the single-template render, reached unchanged by every project
  // that has one (the blob carries exactly one entry, which is what a pre-rack
  // project can only ever produce).
  if (MirageStateBlobEntryCount(pluginState) > 1)
    return [self renderRackChainForDestinationImage:destinationImage
                                       sourceImages:sourceImages
                                        pluginState:pluginState
                                             atTime:renderTime
                                             mediaW:mediaW
                                             mediaH:mediaH
                                         encodeSRGB:encodeSRGB];

  NSString * (^withCommon)(NSString *) = ^NSString *(NSString *s) {
    return common.length ? [NSString stringWithFormat:@"%@\n%@", common, s] : s;
  };

  // Absolute-pixel controls scale with the render (thumbnail vs full frame).
  // Applied to the decoded pool here, so every downstream path - single pass,
  // multi-pass, and each motion-blur sample below - binds already-scaled
  // values.
  const float pixelScale = MirageRenderScale(sourceImages);
  MirageShaderModel *pxModel = [MirageShaderModel modelForSource:imageSrc];
  KKPluginInstanceState *compareState = KKInstanceStateForAPI(self.apiManager);
  if (compareState.mirageCompareSelectionEnabled)
    MirageApplySelectionPreview(pxModel, imageSrc, &base,
                                compareState.mirageCompareActiveKey);
  MirageScalePixelProps(pxModel, base.colorPool, base.colorPoolCount,
                        pixelScale);

  // Who owns the blur (the shader's `// #motionblur` directive, default
  // accumulate). Native shaders blur themselves (feedback trails / an internal
  // loop), so hand them the popover settings as uniforms and skip the plugin's
  // accumulate. iMotionBlur stays 0 for accumulate/off so those never
  // self-blur on top of the plugin's averaging.
  MirageMotionBlurMode mbMode = MirageMotionBlurModeForSource(imageSrc);
  self.lastRenderBlurSamples =
      (mbMode == MirageMotionBlurModeAccumulate && mbState.enabled) ? n : 0;
  if (mbMode == MirageMotionBlurModeNative && mbState.enabled) {
    double frameDur = self.renderCache.frameDurSec;
    // Shutter as a fraction of a frame (1.0 == 360deg). A trail shader maps
    // this onto its decay; frameDur unknown -> approximate against 60fps.
    float shutterFrac =
        frameDur > 0.0
            ? (float)MIN(1.0, MAX(0.0, mbState.shutterSec / frameDur))
            : (float)MIN(1.0, MAX(0.0, mbState.shutterSec * 60.0));
    u.transition.y = shutterFrac;
    u.transition.z = (float)mbState.sampleCount;
  }

  BOOL anyBuffer = NO;
  NSArray<NSString *> *bufSources =
      MirageBufferSourcesFromSections(sections, withCommon, &anyBuffer);
  if (!anyBuffer) {
    // Accumulate blur is plugin-owned + single-pass only (feedback buffers
    // can't be re-simulated per sub-frame sample cheaply). Only in accumulate
    // mode: native shaders blur themselves, off opts out. On any bail, fall
    // through to a single pass.
    if (mbMode == MirageMotionBlurModeAccumulate && mbState.enabled && n > 1) {
      MiragePluginState *states = malloc(sizeof(MiragePluginState) * (size_t)n);
      BOOL readOK = MirageStateBlobReadStates(pluginState, states, n);
      // Only when the matte is ON: this decodes fresh states per render, but
      // applying unconditionally forced uShowSelection=1 into every SAMPLE
      // state, so with motion blur enabled the viewer rendered the matte
      // regardless of the toggle (the base state above is correctly guarded -
      // which is why the probe read pool=0 while the drawn frame showed the
      // matte).
      if (readOK && compareState.mirageCompareSelectionEnabled)
        for (NSInteger si = 0; si < n; si++)
          MirageApplySelectionPreview(pxModel, imageSrc, &states[si],
                                      compareState.mirageCompareActiveKey);
      if (readOK)
        for (NSInteger si = 0; si < n; si++)
          MirageScalePixelProps(pxModel, states[si].colorPool,
                                states[si].colorPoolCount, pixelScale);
      BOOL ok = readOK &&
                [self _renderSinglePassMotionBlurWithStates:states
                                                      count:n
                                                    mbState:mbState
                                                 renderTime:renderTime
                                                     source:withCommon(imageSrc)
                                                     mediaW:mediaW
                                                     mediaH:mediaH
                                                 encodeSRGB:encodeSRGB
                                           destinationImage:destinationImage
                                               sourceImages:sourceImages];
      free(states);
      if (ok)
        return YES;
    }
    BOOL spOK = [self _renderSinglePassWithUniforms:u
                                               base:&base
                                             source:withCommon(imageSrc)
                                         renderTime:renderTime
                                   destinationImage:destinationImage
                                       sourceImages:sourceImages];
    return spOK;
  }

  // Frame index + per-frame iTime step, so feedback buffers advance
  // deterministically (carry-forward on a sequential frame, re-sim on a seek).
  // frameDurSec comes from the render cache; -1 = unknown (fall back to a plain
  // one-step advance).
  double frameDur = self.renderCache.frameDurSec;
  NSInteger frameIndex =
      (frameDur > 0.0) ? (NSInteger)llround(base.common.time / frameDur) : -1;
  float dtPerFrame = (float)(frameDur * base.common.speed);

  // Accumulate blur over a multi-pass chain. The chain's buffers are encoded
  // once and every sub-sample reads them; only the image pass re-runs. The
  // multipass call refuses this for a FEEDBACK chain (it needs history per
  // sample, which cannot be shared), falling back to a single pass - so this is
  // safe to offer unconditionally and the shader decides by what it declares.
  MiragePluginState *mpStates = NULL;
  MirageSampleUniformsBlock sampleUniforms = nil;
  KKMotionBlurState mpMB = mbState;
  if (mbMode == MirageMotionBlurModeAccumulate && mbState.enabled && n > 1) {
    mpStates = malloc(sizeof(MiragePluginState) * (size_t)n);
    if (MirageStateBlobReadStates(pluginState, mpStates, n)) {
      // Guarded like the single-pass samples above: unconditional application
      // baked the matte into every sub-sample whenever motion blur ran.
      if (compareState.mirageCompareSelectionEnabled)
        for (NSInteger si = 0; si < n; si++)
          MirageApplySelectionPreview(pxModel, imageSrc, &mpStates[si],
                                      compareState.mirageCompareActiveKey);
      for (NSInteger si = 0; si < n; si++)
        MirageScalePixelProps(pxModel, mpStates[si].colorPool,
                              mpStates[si].colorPoolCount, pixelScale);
      NSInteger sampleCount = n;
      sampleUniforms = ^(NSInteger i, KKGLSLUniforms *outU,
                         const simd_float4 **outPool, int *outCount) {
        NSInteger si = i < 0 ? 0 : (i >= sampleCount ? sampleCount - 1 : i);
        const MiragePluginState *st = &mpStates[si];
        *outU = MirageBuildUniforms(st, mediaW, mediaH, encodeSRGB);
        *outPool = st->colorPool;
        *outCount = st->colorPoolCount;
      };
    } else {
      free(mpStates);
      mpStates = NULL;
      mpMB.enabled = NO;
    }
  } else {
    mpMB.enabled = NO;
  }

  BOOL mpOK = [self renderCustomMultipassWithUniforms:u
                                            colorPool:base.colorPool
                                            poolCount:base.colorPoolCount
                                          imageSource:withCommon(imageSrc)
                                        bufferSources:bufSources
                                           frameIndex:frameIndex
                                           dtPerFrame:dtPerFrame
                                              mbState:mpMB
                                           renderTime:renderTime
                                       sampleUniforms:sampleUniforms
                                       transitionMode:base.transitionMode
                                                chain:nil
                                     destinationImage:destinationImage
                                         sourceImages:sourceImages];
  if (mpStates)
    free(mpStates);
  return mpOK;
}

@end

#pragma clang diagnostic pop
