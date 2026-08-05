/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The mini preview's shader chain: which entries this draw renders, the
// intermediates they hand one another, and the per-entry encode.
//
// The chain SHAPE mirrors the FCP render's (Plugin+RenderRack.m) - same shared
// up-to-here / solo plan, same skip rule, same gamma-encoded intermediates and
// same shortened-chain fallback when an intermediate cannot be allocated.

#import "MirageMiniViewerRenderer.h"
#import "MirageMiniViewerRenderer_Internal.h"
#import <KeyframelessKit/KKLog.h>

#import "Constants.h"        // MirageCustomDefaultShaderSource
#import "KKGLSLTranspiler.h" // GLSL -> MSL + channel binding
#import "MirageAudioPool.h"
#import "MirageCustomShader.h" // MirageCustomErrorShaderSource
#import "MirageDirectives.h"
#import "MirageExprMiniSet.h"
#import "MirageFrameOffsets.h" // `// #frames` neighbour offsets
#import "MirageRack.h"
#import "MirageRenderUniforms.h" // MirageMakeUniforms (shared with FCP render)
#import "MirageTypes.h"
#import "Plugin+Render_Internal.h" // kMiragePassthroughSource
#import "Plugin_Private.h"
#import <KeyframelessKit/KKShaderTypes.h>
#import <KeyframelessKit/KKSlotInstances.h>
#import <KeyframelessKit/KeyframelessKit.h>
#import <Metal/Metal.h>
#import <math.h>
#import <simd/simd.h>

// Single-value `units="px"` lanes are authored in source-media pixels. The
// main renderer converts them to the active tile scale; do the same for the
// mini's render target so changing preview zoom cannot change their apparent
// size relative to the frame. Points and #multi pixel fields are normalized in
// lane storage and already scale themselves.
static void MirageScaleMiniPixelProps(MirageShaderModel *model,
                                      vector_float4 *pool, int poolCount,
                                      float renderW, float renderH,
                                      CGSize mediaSize) {
  if (!model || !pool || mediaSize.width <= 0.0 || mediaSize.height <= 0.0)
    return;
  float scaleX = renderW / (float)mediaSize.width;
  float scaleY = renderH / (float)mediaSize.height;
  float scale = fminf(scaleX, scaleY);
  if (!isfinite(scale) || scale <= 0.0f || scale == 1.0f)
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

// One colour-matched `// #frames` neighbour, held across draws. The conversion
// it caches is a full-frame render pass plus an RGBA16Float allocation, and the
// pixels behind it only move when the render process pumps a new frame - so the
// work belongs to the pump, not to the redraw.

@implementation MirageMiniViewerRenderer (Chain)

- (double)_previewFraction {
  return self.canvas.livePlaybackActive ? self.editFraction
                                        : self.playheadFraction;
}

// The entries this draw renders, in order. Nothing here is persisted: the
// preview mode is session UI state and the enabled flags come from the lanes.
//
// An EMPTY answer means "no entry renders" - every entry bypassed - which the
// chain driver draws as a passthrough, exactly as the FCP render does rather
// than leaving the destination cleared.
- (NSArray<NSString *> *)_previewChainEntryIDs {
  NSArray<NSString *> *entryIDs = MirageRackEntryIDs(self.timeline);
  double frac = [self _previewFraction];
  NSMutableSet<NSString *> *enabled = [NSMutableSet set];
  for (NSString *entryID in entryIDs)
    if (MirageRackEntryEnabledAtFraction(self.timeline, entryID, frac))
      [enabled addObject:entryID];
  return MirageRackViewerEntryPlan(
      entryIDs, enabled, self.rackPreviewMode, self.rackPreviewEntryID,
      self.selectionMatteActive, MirageRackEntryIDOrSentinel(self.rackEntryID));
}

// A reusable RGBA16Float intermediate for chain position `index`, at the
// preview's working resolution. Held across draws like _hiResTex: a chain
// redraws many times against a target that only changes when the popover is
// resized.
//
// The intermediates carry GAMMA-ENCODED values, the same contract the FCP
// render's do (Plugin+RenderRack.m), so a chain of ordinary Shadertoy shaders
// needs no conversion between entries at all.
- (id<MTLTexture>)_chainTextureAtIndex:(NSUInteger)index
                                device:(id<MTLDevice>)device
                                 width:(NSUInteger)width
                                height:(NSUInteger)height {
  if (!device || width == 0 || height == 0)
    return nil;
  if (!_chainTextures)
    _chainTextures = [NSMutableArray array];
  while (_chainTextures.count <= index)
    [_chainTextures addObject:[NSNull null]];
  id<MTLTexture> existing = [_chainTextures[index] isKindOfClass:[NSNull class]]
                                ? nil
                                : _chainTextures[index];
  if (existing && existing.width == width && existing.height == height)
    return existing;
  MTLTextureDescriptor *td = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                   width:width
                                  height:height
                               mipmapped:NO];
  td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  td.storageMode = MTLStorageModePrivate;
  id<MTLTexture> tex = [device newTextureWithDescriptor:td];
  _chainTextures[index] = tex ?: (id)[NSNull null];
  return tex;
}

// One rack entry's mini render: Buffer A-D render into offscreen RGBA16F
// textures on the shared command buffer, then the Image pass draws into `out` -
// the chain's next intermediate, or the final target. Mirrors the FCP render's
// multi-pass routing (iChannelN->Buffer[N], source/noise fallback); Common is
// prepended to each. A FEEDBACK shader (a buffer reading itself / a later
// buffer) re-simulates a short window at capped resolution so the static
// preview accumulates; others do a single full-res step. The mini keeps no
// state across renders (unlike the FCP render), so this is an approximate
// preview, not a frame-exact match.
//
// `chainInput` is the previous entry's output (nil at the head of the chain, so
// the entry reads the clip) and `encodeSRGB` describes what `out` IS - a chain
// intermediate always stores gamma, so only the last entry answers to the
// destination surface's own encoding.
- (BOOL)_encodeRackEntry:(NSString *)entryID
                sections:(NSDictionary<NSString *, NSString *> *)sections
              chainInput:(id<MTLTexture>)chainInput
                  inputs:(_MirageMiniChainInputs *)inputs
                    into:(id<MTLTexture>)out
              encodeSRGB:(int)encodeSRGB
           commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
  id<MTLDevice> device = out.device;
  NSString *common = sections[@"Common"] ?: @"";
  NSString *image = sections[@"Image"];
  if (image.length == 0)
    image = kMiragePassthroughSource;
  MirageShaderModel *poolModel = [MirageShaderModel modelForSource:image];
  NSString * (^withCommon)(NSString *) = ^NSString *(NSString *s) {
    return common.length ? [NSString stringWithFormat:@"%@\n%@", common, s] : s;
  };

  id<MTLTexture> renderTex = out;
  MTLPixelFormat fmt = renderTex.pixelFormat;
  float W = (float)renderTex.width, H = (float)renderTex.height;
  // Match the FCP render's iTime, which uses seconds (frac * durSec), not the
  // bare 0..1 fraction - otherwise the preview animates durSec-times too slow.
  // Fall back to the raw fraction when the duration hasn't been pushed yet.
  float timeSec = (float)(self.editFraction * (self.clipDurationSeconds > 0.0
                                                   ? self.clipDurationSeconds
                                                   : 1.0));
  NSArray<NSNumber *> *seedV = [self valuesForLabel:@"Seed"];
  float seed = seedV.count ? seedV[0].floatValue : KK_SHADER_GRAD_DEFAULT_SEED;
  NSArray<NSNumber *> *speedV = [self valuesForLabel:@"Speed"];
  float speed =
      speedV.count ? speedV[0].floatValue : KK_SHADER_GRAD_DEFAULT_SPEED;
  float iTime = timeSec * speed + fmodf(seed, 10000.0f);
  // Grain is opt-in. -defaultValuesForLabel: supplies the subtle 6% starting
  // value for a shader that declares `#grain`, but asking for that bare label
  // on every shader used to apply the fallback to templates that never
  // declared it. The FCP renderer correctly treats no directive/lane as zero;
  // gate the mini on the same source declaration.
  MirageBuiltins builtins = poolModel.builtins;
  NSArray<NSNumber *> *grV =
      builtins.grain.present ? [self valuesForLabel:@"Grain"] : @[];
  NSArray<NSNumber *> *grSzV =
      builtins.grain.present ? [self valuesForLabel:@"Grain Size"] : @[];
  float grain = grV.count ? grV[0].floatValue / 100.0f : 0.0f;
  float grainSize =
      grSzV.count ? grSzV[0].floatValue : KK_CORE_GRAINSIZE_DEFAULT;

  // Shares the uniform-struct layout with the FCP render (MirageMakeUniforms)
  // so the CPU<->shader contract can't drift. chanRes[0] = the render
  // resolution {W,H}, matching the main render (its iChannelResolution[0]
  // equals iResolution) so aspect-reading shaders preview the same as output.
  // FCP's polled playhead advances in coarse ~4-frame steps during playback
  // (~14Hz). The mini-viewer draw path already derives a smooth, lead-corrected
  // 60fps fraction from the published feed and places it in `editFraction`.
  // Use that same clock for every live shader input; otherwise iTime moves
  // smoothly while iProgress and #audio visibly stair-step at ~14-20fps.
  // Outside live playback, playheadFraction remains the correct scrub/static
  // value (editFraction may instead be the keypose whose popover is open).
  BOOL livePlayback = self.canvas.livePlaybackActive;
  double previewFraction =
      livePlayback ? self.editFraction : self.playheadFraction;
  // The transition's Easing lane, applied exactly as the FCP render applies it
  // (MirageEvalStateAtFrac): iProgress is the EASED fraction, iTime is not.
  // The lane exists only for a `#template transition`, and Linear is the
  // identity, so every other shader previews on the raw fraction it always
  // did.
  NSArray<NSNumber *> *easingV = [self valuesForLabel:@"Easing"];
  KKEasingCurve easingCurve =
      easingV.count ? (KKEasingCurve)MAX(0, MIN(KKEasingCurveCount - 1,
                                                lround(easingV[0].doubleValue)))
                    : KKEasingCurveLinear;
  double easedFraction = KKApplyEasing(previewFraction, easingCurve, 0.5, 0.5);
  KKGLSLUniforms base =
      MirageMakeUniforms(W, H, iTime, grain, grainSize, (float)easedFraction,
                         (float)encodeSRGB, (simd_float4){W, H, 1.0f, 0.0f});
  // `// #motionblur native`: the shader does its own blur, so hand it the same
  // shutter the viewer does or the preview shows a different image (a trail
  // pinned to its floor decay). Gated on the mode exactly as the FCP render is,
  // so accumulate / off / absent all keep iMotionBlur at 0 in both paths.
  if (MirageMotionBlurModeForSource(image) == MirageMotionBlurModeNative) {
    base.transition.y = self.motionBlurShutterFraction;
    base.transition.z = (float)self.previewMotionBlurSamples;
  }
  // A shader's `// #color` properties -> the colour pool (bound after the fixed
  // uniforms, same as the FCP render).
  simd_float4 colorPool[KK_SHADER_COLOR_POOL];
  // The model asks by BARE label - what the directive declared - and this is
  // where that becomes THIS ENTRY's real lane key, exactly as the FCP render's
  // MirageEvalStateAtFrac does. For the sentinel every key passes through
  // unchanged, so a project that has never been racked reads the lanes it
  // always did. The shared built-ins above (Speed / Seed / Grain / Grain Size /
  // Transition Mode / Easing) stay bare on purpose: they drive the common
  // uniform block, which the whole chain shares.
  NSString *owner = MirageRackEntryIDOrSentinel(entryID);
  KKTimeline *progressTimeline = self.timeline;
  double progressDurSec = self.clipDurationSeconds;
  double progressTimelineSec =
      self.clipTimelineStartSec >= 0.0
          ? self.clipTimelineStartSec + previewFraction * progressDurSec
          : 0.0;
  NSArray<NSNumber *> * (^values)(NSString *) =
      ^NSArray<NSNumber *> *(NSString *label) {
    // A `// #progress` lane is read on the EASED clock, the way the FCP render
    // reads it (MirageEvalStateAtFrac), so the preview composes the two
    // reshapers in the same order the output does. It can't go through
    // -valuesForLabel:, which always evaluates at the preview's own fraction,
    // so it evaluates the lane directly - the same kit resolver, one fraction
    // along.
    if (MirageProgressLabel(poolModel, label)) {
      NSString *key = MirageRackLaneKey(owner, label);
      for (KKLane *lane in progressTimeline.lanes)
        if ([lane.key isEqualToString:key]) {
          NSArray<NSNumber *> *resolved = KKLinkResolvedLaneValue(
              lane, easedFraction, progressTimelineSec, progressDurSec);
          if (resolved.count)
            return resolved;
          break;
        }
      // Same identity-ramp fallback the FCP render applies: a `// #progress`
      // uniform with no lane in the blob yet reads the preview's own sweep, so
      // the mini shows what the render will instead of the prop's parsed
      // default of 0.
      return @[ @(easedFraction * 100.0) ];
    }
    return [self valuesForLabel:MirageRackLaneKey(owner, label)];
  };
  // The same registry order the FCP render packs by, so the preview shows the
  // instance the user is editing at the array element the shader reads. Scoped
  // to the entry, so two entries running the same template keep separate
  // instance registries.
  KKTimeline *slotTimeline = self.timeline;
  NSArray<NSString *> * (^slotInstances)(NSString *) =
      ^NSArray<NSString *> *(NSString *groupName) {
    return KKTimelineSlotInstanceIDs(
        slotTimeline, MirageRackScopedSlotGroupName(owner, groupName));
  };
  int colorPoolN = [poolModel fillColorPool:colorPool
                             valuesForLabel:values
                              slotInstances:slotInstances];
  colorPoolN = [poolModel fillScalarPool:colorPool
                          valuesForLabel:values
                           slotInstances:slotInstances];
  MirageScaleMiniPixelProps(poolModel, colorPool, colorPoolN, W, H,
                            self.canvas.sourceMediaSize);
  // Sampled at the playhead's PROJECT time, pushed by the inspector - the same
  // instant the viewer is showing, so the preview and the render agree. Still
  // called when that's unknown (a large negative reads as outside the
  // spectrogram = silence): the audio members must be COUNTED either way, or
  // the block's tail goes unwritten and samples whatever the buffer last held.
  double audioTimeSec = self.audioTimelineTimeSec;
  if (livePlayback && self.clipTimelineStartSec >= 0.0 &&
      self.clipDurationSeconds > 0.0)
    audioTimeSec =
        self.clipTimelineStartSec + previewFraction * self.clipDurationSeconds;
  colorPoolN = MirageFillAudioPool(poolModel, colorPool, audioTimeSec, values);
  // `// #gradient` ramps last, so the three pools above keep their offsets.
  colorPoolN = [poolModel fillGradientPool:colorPool valuesForLabel:values];
  // The injected `#slots` counts close the pool.
  colorPoolN = [poolModel fillSlotCountPool:colorPool
                              slotInstances:slotInstances];
  NSArray<NSNumber *> *transitionModeV =
      [self valuesForLabel:@"Transition Mode"];
  int transitionMode =
      transitionModeV.count
          ? (int)MAX(0, MIN(2, lround(transitionModeV[0].doubleValue)))
          : 0;
  base.transition.w = (float)transitionMode;
  BOOL technicalTransform = KKLooksLikeColorTransformShader(image);
  // iChannel0. At the HEAD of the chain that is the clip, in whichever space
  // this entry consumes (see -_clipTextureFor:...). Past the head it is the
  // previous entry's output, which is always GAMMA-ENCODED - the space an
  // ordinary Shadertoy shader wants, so an ordinary entry needs no conversion
  // at all mid-chain, while a `color-transform` entry decodes it whatever the
  // target format is. The exact rule the FCP chain applies
  // (Plugin+RenderMultipass.m's convertSrc / decodeSrc).
  id<MTLTexture> srcLin = chainInput;
  if (srcLin) {
    if (technicalTransform)
      srcLin =
          KKGammaDecodeSourceTextureOnBuffer(commandBuffer, srcLin) ?: srcLin;
  } else {
    srcLin = [self _clipTextureFor:inputs
                             gamma:!technicalTransform
                     commandBuffer:commandBuffer];
  }
  id<MTLSamplerState> srcSampler = KKCustomSourceSampler(device);
  id<MTLTexture> noiseTex = KKCustomChannelNoiseTexture(device);
  id<MTLTexture> transparentTex =
      transitionMode != 0 ? KKCustomTransparentTexture(device) : nil;
  if (transitionMode == 1)
    srcLin = transparentTex;
  // The To well is a delivered clip texture on every entry, chained or not, so
  // it keeps the source-derived rule the whole way down.
  id<MTLTexture> toLin = [self _channel1TextureFor:inputs
                                             gamma:!technicalTransform
                                     commandBuffer:commandBuffer];
  if (transitionMode == 2)
    toLin = transparentTex;
  // `// #frames` neighbours resolve HERE, alongside srcLin/toLin and ahead of
  // every render encoder below, because their colour match is itself a render
  // pass on this same command buffer - and a command buffer allows exactly one
  // live encoder. Resolving them at the bind site asked for a second encoder
  // while the image pass was open, which Metal aborts on.
  NSArray *neighborTex = [self _neighborTexturesForSource:image
                                       technicalTransform:technicalTransform
                                            commandBuffer:commandBuffer];
  id<MTLSamplerState> noiseSampler = KKCustomChannelSampler(device);

  // Precompile buffer pipelines + transpile; detect FEEDBACK (a buffer reading
  // itself or a later buffer, i.e. any channel c >= its own index).
  NSArray<NSString *> *bufNames =
      @[ @"Buffer A", @"Buffer B", @"Buffer C", @"Buffer D" ];
  id<MTLRenderPipelineState> bufPS[4] = {nil, nil, nil, nil};
  KKGLSLTranspileResult *bufTR[4] = {nil, nil, nil, nil};
  BOOL present[4] = {NO, NO, NO, NO};
  BOOL needsFeedback = NO;
  for (int k = 0; k < 4; k++) {
    NSString *bs = sections[bufNames[k]];
    if (bs.length == 0 || W == 0 || H == 0)
      continue;
    NSString *bsrc = withCommon(bs);
    bufPS[k] = [self _customPipelineForDevice:device
                                  pixelFormat:MTLPixelFormatRGBA16Float
                                       source:bsrc
                                   bufferMode:YES];
    if (!bufPS[k])
      continue;
    present[k] = YES;
    bufTR[k] = KKTranspileGLSLBuffer(bsrc);
    for (int c = k; c < 4; c++)
      if (bufTR[k].declaredChannelMask & (1u << c))
        needsFeedback = YES;
  }

  // Feedback shaders re-sim a short window (so the static preview accumulates)
  // at a capped resolution (the mini is a preview - keep it cheap).
  // Non-feedback buffers do a single full-res step. `srcLin` is only bound to a
  // channel that has no buffer, so re-sim reads its own previous frame, not the
  // source.
  NSUInteger bufW = (NSUInteger)W, bufH = (NSUInteger)H;
  if (needsFeedback && bufH > (NSUInteger)KK_FEEDBACK_SIM_MAXDIM) {
    bufH = KK_FEEDBACK_SIM_MAXDIM;
    bufW = (NSUInteger)llround((double)W * (double)KK_FEEDBACK_SIM_MAXDIM /
                               (double)H);
  }
  NSInteger frames = needsFeedback ? 48 : 1;
  float dt = (1.0f / 60.0f) * speed; // approximate per-frame iTime step

  id<MTLTexture> setTex[2][4] = {{nil, nil, nil, nil}, {nil, nil, nil, nil}};
  int prevI = 0;
  for (NSInteger f = 0; f < frames; f++) {
    int curI = 1 - prevI;
    BOOL first = (f == 0);
    KKGLSLUniforms fu = base;
    fu.resTime = (simd_float4){(float)bufW, (float)bufH, 1.0f,
                               iTime - (float)(frames - 1 - f) * dt};
    fu.extra.y = (float)f; // iFrame: 0 on the first step (seed-on-frame-0 sims)
    fu.extra.w = 1.0f;     // buffers store raw data (no sRGB encode)
    for (int k = 0; k < 4; k++) {
      if (!bufPS[k])
        continue;
      id<MTLTexture> cur = setTex[curI][k];
      if (!cur) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                         width:bufW
                                        height:bufH
                                     mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        cur = [device newTextureWithDescriptor:td];
        setTex[curI][k] = cur;
      }
      if (!cur)
        continue;
      NSMutableArray *chArr = [NSMutableArray arrayWithCapacity:4];
      KKGLSLUniforms bufU = fu;
      for (int c = 0; c < 4; c++) {
        id<MTLTexture> ct = nil;
        if (present[c]) {
          if (c < k)
            ct = setTex[curI][c];
          else if (!first)
            ct = setTex[prevI][c];
        } else if (c == 0) {
          ct = srcLin;
        } else if (c == 1) {
          ct = toLin;
        }
        [chArr addObject:ct ?: (id)[NSNull null]];
        if (ct)
          bufU.chanRes[c] =
              (simd_float4){(float)ct.width, (float)ct.height, 1.0f, 0.0f};
      }
      MTLRenderPassDescriptor *rpd =
          [MTLRenderPassDescriptor renderPassDescriptor];
      rpd.colorAttachments[0].texture = cur;
      rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
      rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
      rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
      id<MTLRenderCommandEncoder> be =
          [commandBuffer renderCommandEncoderWithDescriptor:rpd];
      [be setViewport:(MTLViewport){0, 0, (double)bufW, (double)bufH, -1.0,
                                    1.0}];
      [be setRenderPipelineState:bufPS[k]];
      KKBindGLSLUniforms(be, &bufU, colorPool, colorPoolN);
      KKBindCustomChannelTextures(be, bufTR[k], chArr, srcSampler, noiseTex,
                                  noiseSampler);
      [be drawPrimitives:MTLPrimitiveTypeTriangleStrip
             vertexStart:0
             vertexCount:4];
      [be endEncoding];
    }
    prevI = curI;
  }
  id<MTLTexture> bufTex[4];
  for (int c = 0; c < 4; c++)
    bufTex[c] = setTex[prevI][c];

  NSString *imgSrc = withCommon(image);
  id<MTLRenderPipelineState> imagePS = [self _customPipelineForDevice:device
                                                          pixelFormat:fmt
                                                               source:imgSrc
                                                           bufferMode:NO];
  if (!imagePS) {
    imgSrc = withCommon(MirageCustomErrorShaderSource());
    imagePS = [self _customPipelineForDevice:device
                                 pixelFormat:fmt
                                      source:imgSrc
                                  bufferMode:NO];
  }
  if (!imagePS)
    return NO;
  KKGLSLTranspileResult *imgTR = KKTranspileGLSL(imgSrc);
  // iChannel1 = the feed's second texture (Mirage's "To" image well, i.e. a
  // transition's incoming clip) when one was published. Same colour handling as
  // iChannel0 above, so a two-texture shader previews the way it renders.
  NSMutableArray *imgCh = [NSMutableArray arrayWithCapacity:4];
  KKGLSLUniforms imgU = base;
  for (int c = 0; c < 4; c++) {
    id<MTLTexture> ct = bufTex[c];
    if (!ct && c == 0)
      ct = srcLin;
    if (!ct && c == 1)
      ct = toLin; // nil when no well -> NSNull -> noise, as before
    [imgCh addObject:ct ?: (id)[NSNull null]];
    if (ct)
      imgU.chanRes[c] =
          (simd_float4){(float)ct.width, (float)ct.height, 1.0f, 0.0f};
  }
  MTLRenderPassDescriptor *irpd =
      [MTLRenderPassDescriptor renderPassDescriptor];
  irpd.colorAttachments[0].texture = renderTex;
  irpd.colorAttachments[0].loadAction = MTLLoadActionClear;
  irpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  irpd.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> e =
      [commandBuffer renderCommandEncoderWithDescriptor:irpd];
  [e setViewport:(MTLViewport){0, 0, W, H, -1.0, 1.0}];
  [e setRenderPipelineState:imagePS];
  KKBindGLSLUniforms(e, &imgU, colorPool, colorPoolN);
  KKBindCustomChannelTextures(e, imgTR, imgCh, srcSampler, noiseTex,
                              noiseSampler);
  KKBindCustomNeighborTextures(e, imgTR, neighborTex, srcSampler,
                               (bufTex[0] ?: srcLin) ?: noiseTex);
  [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  [e endEncoding];

  return YES;
}

// The clip as iChannel0, converted at most once per draw whichever entries ask
// for it.
//
// The cross-process feed is always sRGB-encoded BGRA8, even for a technical
// transform. Recover the same linear values the main FxPlug render receives;
// the distinction is only that an ordinary Shadertoy shader is encoded back to
// gamma (Shadertoy assumes display space, and our output wrapper re-decodes for
// a float dest, so feeding it linear would double-decode and darken the clip)
// while `color-transform` consumes those host values directly.
- (id<MTLTexture>)_clipTextureFor:(_MirageMiniChainInputs *)inputs
                            gamma:(BOOL)gamma
                    commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
  if (!inputs->_sourceLinear)
    return nil;
  if (!gamma)
    return inputs->_sourceLinear;
  if (!inputs->_sourceGamma)
    inputs->_sourceGamma =
        KKGammaEncodeSourceTextureOnBuffer(commandBuffer, inputs->_sourceLinear)
            ?: inputs->_sourceLinear;
  return inputs->_sourceGamma;
}

// iChannel1 = the feed's second texture (Mirage's "To" image well, i.e. a
// transition's incoming clip) when one was published. Same colour handling, and
// the same per-draw memo, as iChannel0.
- (id<MTLTexture>)_channel1TextureFor:(_MirageMiniChainInputs *)inputs
                                gamma:(BOOL)gamma
                        commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
  if (!inputs->_channel1Resolved) {
    inputs->_channel1Resolved = YES;
    id<MTLTexture> raw = self.canvas.channel1Texture;
    inputs->_channel1Linear = raw ? [self _linearSourceView:raw] : nil;
  }
  if (!inputs->_channel1Linear)
    return nil;
  if (!gamma)
    return inputs->_channel1Linear;
  if (!inputs->_channel1Gamma)
    inputs->_channel1Gamma = KKGammaEncodeSourceTextureOnBuffer(
                                 commandBuffer, inputs->_channel1Linear)
                                 ?: inputs->_channel1Linear;
  return inputs->_channel1Gamma;
}

// The SHADER RACK, mini side: the same chain the FCP render draws, in the same
// order, from the same timeline. Each entry runs its whole pipeline (its own
// sections, its own uniform pool, its own gamma planning) into a reusable
// RGBA16Float intermediate; the next entry binds that as its iChannel0; the
// last one draws into the preview's target.
//
// Everything rides the ONE command buffer the mini viewer handed in, so a chain
// costs the redraw exactly one submission however long it is - the one-wait
// discipline the FCP render keeps, one process over.
//
// A single-entry rack takes this loop once with the sentinel's id, which is the
// pre-rack render byte for byte: `MirageRackLaneKey` passes every bare key
// through, the sections come from the same lane, and no intermediate is
// allocated.
- (BOOL)_encodeCustomEffectFromSource:(id<MTLTexture>)source
                                 into:(id<MTLTexture>)dest
                        commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
  id<MTLTexture> renderTex = [self hiResTargetForDest:dest];
  BOOL downscale = (renderTex != nil);
  if (!renderTex)
    renderTex = dest;
  // What the DESTINATION is, which only the last entry answers to: an
  // intermediate always stores gamma.
  int destEncodeSRGB = (dest.pixelFormat == MTLPixelFormatRGBA8Unorm ||
                        dest.pixelFormat == MTLPixelFormatBGRA8Unorm)
                           ? 1
                           : 0;

  _MirageMiniChainInputs *inputs = [[_MirageMiniChainInputs alloc] init];
  inputs->_sourceLinear = source ? [self _linearSourceView:source] : nil;

  NSArray<NSString *> *plan = [self _previewChainEntryIDs];
  // Every entry bypassed: pass the clip through rather than leaving the target
  // cleared, encoded as one entry running the passthrough shader so it takes
  // the ordinary destination path. The same answer the FCP render gives.
  NSUInteger count = MAX((NSUInteger)1, plan.count);
  id<MTLTexture> carried = nil;
  BOOL ok = YES;
  for (NSUInteger i = 0; i < count; i++) {
    NSString *entryID = i < plan.count ? plan[i] : nil;
    NSDictionary<NSString *, NSString *> *sections =
        entryID ? [self _customSectionsForEntry:entryID]
                : @{@"Image" : kMiragePassthroughSource};
    BOOL isFinal = (i + 1 == count);
    id<MTLTexture> out = renderTex;
    if (!isFinal) {
      out = [self _chainTextureAtIndex:i
                                device:renderTex.device
                                 width:renderTex.width
                                height:renderTex.height];
      // No intermediate to draw into (allocation refused): stop and let this
      // entry own the target, which is a shortened chain rather than a black
      // frame - the FCP path's fallback too.
      if (!out) {
        out = renderTex;
        isFinal = YES;
      }
    }
    ok = [self _encodeRackEntry:entryID
                       sections:sections
                     chainInput:carried
                         inputs:inputs
                           into:out
                     encodeSRGB:isFinal ? destEncodeSRGB : 1
                  commandBuffer:commandBuffer];
    if (!ok || isFinal)
      break;
    carried = out;
  }

  if (downscale)
    [self blitFrom:renderTex into:dest commandBuffer:commandBuffer];
  return ok;
}

// Effect render: the plugin is Custom-only, so this always runs the Custom
// (single- or multi-pass) GLSL path. `source` is the mini-viewer's source frame
// (bound as iChannel0).
- (BOOL)encodeEffectFromSource:(id<MTLTexture>)source
                          into:(id<MTLTexture>)dest
                 commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
  return [self _encodeCustomEffectFromSource:source
                                        into:dest
                               commandBuffer:commandBuffer];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    processSourceTexture:(id<MTLTexture>)source
             intoTexture:(id<MTLTexture>)dest
           commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
  // The generic mini renderer knows only the inspector's blur switch; Mirage's
  // per-shader mode lives in the Image source. Native shaders render ONCE and
  // consume iMotionBlur/iMotionBlurSamples themselves, while Off shaders also
  // render once. Letting either fall through to the generic Accurate path
  // multiplies the whole custom render by N. For a feedback preview that is
  // especially pathological: 16 samples x 48 warm-up frames = 768 buffer
  // passes per displayed frame. Temporarily suppress only the generic wrapper;
  // Mirage's separate motionBlurShutterFraction/motionBlurSamples properties
  // still reach a Native shader in -_encodeRackEntry:.
  //
  // In a rack the question belongs to the entry that owns the TARGET - the last
  // one the preview is drawing - matching the FCP render, where only the final
  // entry accumulates and every upstream one is encoded once per frame.
  NSString *lastEntryID = [self _previewChainEntryIDs].lastObject;
  NSDictionary<NSString *, NSString *> *sections =
      lastEntryID ? [self _customSectionsForEntry:lastEntryID] : @{};
  NSString *imageSource = sections[@"Image"] ?: @"";
  MirageMotionBlurMode blurMode = MirageMotionBlurModeForSource(imageSource);
  BOOL bypassGenericBlur = (blurMode != MirageMotionBlurModeAccumulate);
  BOOL savedPreviewBlurEnabled = self.previewMotionBlurEnabled;
  if (bypassGenericBlur)
    self.previewMotionBlurEnabled = NO;

  BOOL ok = [super miniViewer:canvas
         processSourceTexture:source
                  intoTexture:dest
                commandBuffer:commandBuffer];
  if (bypassGenericBlur)
    self.previewMotionBlurEnabled = savedPreviewBlurEnabled;
  return ok;
}
@end
