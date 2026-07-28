/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "MirageCustomShader.h"
#import "MirageDirectives.h"         // MirageCommonDefault
#import "MirageMiniViewerRenderer.h" // per-instance descriptor path
#import "MirageRenderUniforms.h"     // MirageMakeUniforms (shared with mini)
#import "MirageStateBlob.h"
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
static NSString *const kMiragePassthroughSource =
    @"void mainImage(out vec4 O, in vec2 fc){ O = "
    @"texture(iChannel0, fc / iResolution.xy); }";

@implementation MiragePlugin (Render)

// Effect: request the clip we're applied to as the source (bound to iChannel0
// in the Custom render path). Motion blur averages the shader over a single
// source frame, so no sub-frame source requests. The boundary-value popover
// additionally pulls its requested clip fraction for the mini-viewer preview.
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
  // Also ask for the "To" image well. In a Motion transition template it is
  // wired to "Drop Zone Transition B", which lands the incoming clip alongside
  // the effect clip in -renderDestinationImage: - the only way an FxPlug filter
  // gets a second texture, and so the whole basis of transition support.
  NSMutableArray<FxImageTileRequest *> *reqs = [sourceReqs mutableCopy];
  [reqs addObject:[[FxImageTileRequest alloc]
                      initWithSource:kFxImageTileRequestSourceParameter
                                time:renderTime
                      includeFilters:NO
                         parameterID:kParamToImage]];
  *inputImageRequests = reqs;
  return YES;
}

// The fixed uniform block for this frame. `mediaW/H` are the output dimensions,
// which drive iResolution.
static KKGLSLUniforms MirageBuildUniforms(const MiragePluginState *base,
                                          CGFloat mediaW, CGFloat mediaH,
                                          float encodeSRGB) {
  float iTime = base->common.time * base->common.speed +
                fmodf(base->common.seed, 10000.0f);
  // iProgress is the raw clip fraction, deliberately NOT scaled by Speed/Seed
  // the way iTime is - a transition's progress has to reach exactly 1.0 at the
  // cut regardless of the motion-rate params. chanRes[0] = the source clip
  // resolution (iChannelResolution[0], filled from the bound texture at draw
  // time). Shared layout with the mini via MirageMakeUniforms.
  return MirageMakeUniforms(
      (float)mediaW, (float)mediaH, iTime, base->common.grain,
      base->common.grainSize, base->common.progress, encodeSRGB,
      (simd_float4){(float)mediaW, (float)mediaH, 1.0f, 0.0f});
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

// Builds a MirageSinglePassDraw for `effectiveSource`. `linearDst` (float dest)
// triggers the gamma-encode of the linear sources - done once here and shared
// across all samples. Returns nil if even the error-pattern pipeline fails.
- (nullable MirageSinglePassDraw)
    _singlePassDrawForSource:(NSString *)effectiveSource
            destinationImage:(FxImageTile *)destinationImage
                sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   linearDst:(BOOL)linearDst {
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
  // The clip we're applied to -> iChannel0, the "To" image well -> iChannel1.
  // In a Motion transition template the well is wired to "Drop Zone Transition
  // B", so a GL transition samples the outgoing and incoming clips together.
  id<MTLTexture> rawTo = [KKImageTileForParameterID(sourceImages, kParamToImage)
      metalTextureForDevice:device];
  // Gamma-encode the linear sources so a Shadertoy shader (gamma-space input,
  // output re-decoded for the float dest) round-trips them instead of
  // double-decoding + darkening. linearDst == float/linear dest; an 8-bit dest
  // already carries gamma source, so leave it untouched. BOTH channels get the
  // same treatment: a transition blending a gamma A against a linear B would
  // tear across the mix.
  //
  // gammaSrc stays nil when nothing was encoded - the draw block below then
  // falls back to its own inputTextures[0].
  id<MTLTexture> gammaSrc = nil, gammaTo = rawTo;
  if (linearDst && (sourceImages.count || rawTo)) {
    id<MTLTexture> rawSrc = sourceImages.count
                                ? [sourceImages[0] metalTextureForDevice:device]
                                : nil;
    id<MTLCommandQueue> gq = [dc
        commandQueueWithRegistryID:registryID
                       pixelFormat:[KKMetalDeviceCache pixelFormatForImageTile:
                                                           destinationImage]];
    if (rawSrc)
      gammaSrc = KKGammaEncodeSourceTexture(gq, rawSrc);
    if (rawTo)
      gammaTo = KKGammaEncodeSourceTexture(gq, rawTo) ?: rawTo;
    if (gq)
      [dc returnCommandQueueToCache:gq];
  }
  id<MTLTexture> toTex = gammaTo;
  return ^(id<MTLRenderCommandEncoder> encoder,
           NSArray<id<MTLTexture>> *inputTextures, MirageDrawArgs args) {
    [encoder setRenderPipelineState:customPS];
    id<MTLTexture> src =
        gammaSrc ?: (inputTextures.count ? inputTextures[0] : nil);
    KKGLSLUniforms uu = args.u;
    const simd_float4 *colorPool = args.pool;
    int poolCount = args.poolCount;
    if (src)
      uu.chanRes[0] =
          (simd_float4){(float)src.width, (float)src.height, 1.0f, 0.0f};
    if (toTex)
      uu.chanRes[1] =
          (simd_float4){(float)toTex.width, (float)toTex.height, 1.0f, 0.0f};
    KKBindGLSLUniforms(encoder, &uu, colorPool, poolCount);
    KKBindCustomChannelTextures(encoder, tr,
                                @[
                                  src ?: (id)[NSNull null],
                                  toTex ?: (id)[NSNull null], [NSNull null],
                                  [NSNull null]
                                ],
                                srcSampler, noiseTex, chSampler);
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
                     destinationImage:(FxImageTile *)destinationImage
                         sourceImages:(NSArray<FxImageTile *> *)sourceImages {
  MirageSinglePassDraw draw =
      [self _singlePassDrawForSource:effectiveSource
                    destinationImage:destinationImage
                        sourceImages:sourceImages
                           linearDst:(u.extra.w == 0.0f)];
  if (!draw)
    return NO;
  MiragePluginState baseCopy = *base;
  return [self
      encodeRenderCommandsForDestinationImage:destinationImage
                                 sourceImages:sourceImages
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
  MirageSinglePassDraw draw =
      [self _singlePassDrawForSource:effectiveSource
                    destinationImage:destinationImage
                        sourceImages:sourceImages
                           linearDst:(encodeSRGB == 0.0f)];
  if (!draw)
    return NO;
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
- (void)_publishMiniViewerFeeds:(FxImageTile *)destinationImage
                   sourceImages:(NSArray<FxImageTile *> *)sourceImages
                     renderTime:(CMTime)renderTime {
  // Per slot: single-slot = playhead, multi-slot = boundary preview / filmstrip
  // / onion. Shared glue in KKPlugin (MiniViewerFeed). The single-slot tag is
  // this frame's clip fraction (not a hard 0), so during playback/scrub the
  // open popover's mini-viewer sets editFraction to it and advances iTime with
  // the playhead - otherwise the preview stays frozen at t=0 while the timeline
  // moves (the popover live-playback plumbing the rest of the kit already
  // does).
  [self
      kkPublishMiniViewerFeedForDestination:destinationImage
                               sourceImages:sourceImages
                             descriptorPath:
                                 MirageMiniViewerDescriptorPathForUUID(
                                     KKInstanceUUIDForAPI(self.apiManager))
                            boundaryReqSecs:self.renderCache.boundaryReqSecs
                           boundaryReqFracs:self.renderCache.boundaryReqFracs
                            multiSlotActive:self.renderCache.boundaryFeedActive
                          changesOutputSize:NO
                                 defaultTag:[self.renderCache
                                                clipFractionAtSeconds:
                                                    CMTimeGetSeconds(
                                                        renderTime)]
                                renderCache:self.renderCache];
  // The "To" well as a second feed texture, so the mini-viewer can preview a
  // two-texture (GL-transition) shader instead of falling through to
  // iChannel1's noise.
  [self kkPublishMiniViewerChannel1ForDestination:destinationImage
                                     sourceImages:sourceImages
                                  wellParameterID:kParamToImage];
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
static float MirageRenderScale(NSArray<FxImageTile *> *sourceImages) {
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
static void MirageScalePixelProps(MirageShaderModel *model, vector_float4 *pool,
                                  int poolCount, float scale) {
  if (!model || !pool || scale == 1.0f)
    return;
  const MirageScalarProp *props = model.scalarProps;
  for (int i = 0; i < model.scalarCount; i++) {
    const MirageScalarProp *p = &props[i];
    if (p->isPoint || p->isMulti || p->fieldUnit[0] != 'p')
      continue;
    if (p->poolOffset < 0 || p->poolOffset >= poolCount)
      continue;
    pool[p->poolOffset].x *= scale;
  }
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
  // Unconditional: a render that reports failure still leaves pixels in the
  // destination surface, and "make the shader fail" must not be a way to get a
  // clean frame out of the trial.
  KKWatermarkApplyIfUnlicensed(KKLicenseProductMirage, destinationImage);
  return ok;
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

  [self _publishMiniViewerFeeds:destinationImage
                   sourceImages:sourceImages
                     renderTime:renderTime];

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
  NSString * (^withCommon)(NSString *) = ^NSString *(NSString *s) {
    return common.length ? [NSString stringWithFormat:@"%@\n%@", common, s] : s;
  };

  // Absolute-pixel controls scale with the render (thumbnail vs full frame).
  // Applied to the decoded pool here, so every downstream path - single pass,
  // multi-pass, and each motion-blur sample below - binds already-scaled
  // values.
  const float pixelScale = MirageRenderScale(sourceImages);
  MirageShaderModel *pxModel = [MirageShaderModel modelForSource:imageSrc];
  MirageScalePixelProps(pxModel, base.colorPool, base.colorPoolCount,
                        pixelScale);

  // Who owns the blur (the shader's `// #motionblur` directive, default
  // accumulate). Native shaders blur themselves (feedback trails / an internal
  // loop), so hand them the popover settings as uniforms and skip the plugin's
  // accumulate. iMotionBlur stays 0 for accumulate/off so those never
  // self-blur on top of the plugin's averaging.
  MirageMotionBlurMode mbMode = MirageMotionBlurModeForSource(imageSrc);
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

  // Any Buffer A-D present -> multi-pass (buffer textures feed the passes'
  // iChannels).
  NSArray<NSString *> *bufNames =
      @[ @"Buffer A", @"Buffer B", @"Buffer C", @"Buffer D" ];
  NSMutableArray<NSString *> *bufSources = [NSMutableArray arrayWithCapacity:4];
  BOOL anyBuffer = NO;
  for (NSString *bn in bufNames) {
    NSString *bs = sections[bn];
    if (bs.length > 0) {
      [bufSources addObject:withCommon(bs)];
      anyBuffer = YES;
    } else {
      [bufSources addObject:@""];
    }
  }
  if (!anyBuffer) {
    // Accumulate blur is plugin-owned + single-pass only (feedback buffers
    // can't be re-simulated per sub-frame sample cheaply). Only in accumulate
    // mode: native shaders blur themselves, off opts out. On any bail, fall
    // through to a single pass.
    if (mbMode == MirageMotionBlurModeAccumulate && mbState.enabled && n > 1) {
      MiragePluginState *states = malloc(sizeof(MiragePluginState) * (size_t)n);
      BOOL readOK = MirageStateBlobReadStates(pluginState, states, n);
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
    return [self _renderSinglePassWithUniforms:u
                                          base:&base
                                        source:withCommon(imageSrc)
                              destinationImage:destinationImage
                                  sourceImages:sourceImages];
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
                                     destinationImage:destinationImage
                                         sourceImages:sourceImages];
  if (mpStates)
    free(mpStates);
  return mpOK;
}

@end

#pragma clang diagnostic pop
