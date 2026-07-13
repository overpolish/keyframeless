/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "KKGLSLTranspiler.h" // GLSL -> MSL (glslang + SPIRV-Cross)
#import "Plugin_Private.h"
#import "ShaderColorSpace.h"
#import "ShaderCustomShader.h" // KKCustomUniforms + ShaderCustomFullSource (shared)
#import "ShaderMiniViewerRenderer.h" // per-instance descriptor path
#import "ShaderTypes.h"
#import <KeyframelessKit/KKMetalDeviceCache.h>
#import <KeyframelessKit/KKMiniViewerFeed.h>
#import <KeyframelessKit/KKMotionBlur.h>
#import <KeyframelessKit/KKRenderPrimitives.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

// Render-internal state builders (defined in the (Render) category below;
// declared here so the forward call from -buildState: doesn't warn).
@interface ShaderPlugin (RenderStateBuilders)
- (BOOL)buildState:(ShaderPluginState *)outState
            atTime:(CMTime)renderTime
             error:(NSError **)error;
- (BOOL)buildStates:(ShaderPluginState *)outStates
            atTimes:(const CMTime *)times
              count:(NSInteger)count
              error:(NSError **)error;
- (BOOL)renderCustomMultipassWithUniforms:(KKGLSLUniforms)u
                                colorPool:(const simd_float4 *)colorPool
                                poolCount:(int)poolCount
                              imageSource:(NSString *)imageSource
                            bufferSources:(NSArray<NSString *> *)bufferSources
                               frameIndex:(NSInteger)frameIndex
                               dtPerFrame:(float)dtPerFrame
                         destinationImage:(FxImageTile *)destinationImage
                             sourceImages:
                                 (NSArray<FxImageTile *> *)sourceImages;
@end

// The interpolated component values of the lane named `label` at clip fraction
// `frac`, or nil if there's no such lane.
static NSArray<NSNumber *> *
ShaderLaneValuesAtFraction(KKTimeline *timeline, NSString *label, double frac) {
  for (KKLane *lane in timeline.lanes) {
    if ([lane.label isEqualToString:label])
      return KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
  }
  return nil;
}

// Build the full plugin state from the timeline at one clip fraction. Pure (no
// timing/cache work) so a caller can refresh the render cache once and evaluate
// many sub-frame fractions cheaply (motion blur samples).
static void ShaderEvalStateAtFrac(KKTimeline *timeline, double frac,
                                  double durSec, ShaderPluginState *outState) {
  memset(outState, 0, sizeof(*outState));

  NSArray<NSNumber *> *speedV =
      ShaderLaneValuesAtFraction(timeline, @"Speed", frac);
  float speed =
      speedV.count ? speedV[0].floatValue : KK_SHADER_GRAD_DEFAULT_SPEED;
  NSArray<NSNumber *> *seedV =
      ShaderLaneValuesAtFraction(timeline, @"Seed", frac);
  float seed = seedV.count ? seedV[0].floatValue : KK_SHADER_GRAD_DEFAULT_SEED;
  float timeSec = (float)(frac * durSec);

  NSArray<NSNumber *> *grainV =
      ShaderLaneValuesAtFraction(timeline, @"Grain", frac);
  NSArray<NSNumber *> *grainSizeV =
      ShaderLaneValuesAtFraction(timeline, @"Grain Size", frac);
  // Only the shared params survive (Speed / Seed / Grain / Grain Size + time).
  // The user shader source drives everything else and rides in the blob tail.
  ShaderCommonUniforms common = ShaderCommonDefault();
  common.speed = speed;
  common.seed = seed;
  common.time = timeSec;
  common.grain =
      grainV.count ? grainV[0].floatValue / 100.0f : KK_CORE_GRAIN_DEFAULT;
  common.grainSize =
      grainSizeV.count ? grainSizeV[0].floatValue : KK_CORE_GRAINSIZE_DEFAULT;
  outState->common = common;

  // A shader's `// #color` properties -> the colour pool (the transpiled
  // block's std140 tail). Values come from the per-property lanes (fallback:
  // directive default count + the default palette). The directives are parsed
  // from the "Shader" code lane.
  NSString *shaderSrc = nil;
  for (KKLane *l in timeline.lanes)
    if ([l.label isEqualToString:@"Shader"] && l.codeString.length) {
      shaderSrc = l.codeString;
      break;
    }
  outState->colorPoolCount = ShaderFillColorPool(
      shaderSrc, outState->colorPool, ^NSArray<NSNumber *> *(NSString *label) {
        return ShaderLaneValuesAtFraction(timeline, label, frac);
      });
}

// ── Custom (user-supplied) shader ──
// Runtime-compiled user shader (the only render path). The user writes a
// GLSL Image shader (`void mainImage(out vec4, in vec2)`, bare
// iTime / iResolution / iChannelN). KKGLSLTranspiler wraps it into a full GLSL
// unit and transpiles it to MSL with glslang + SPIRV-Cross, so the real GLSL
// dialect (not a regex approximation) drives the result. The pipeline is cached
// on the emitted MSL hash. The default / error sources below are shared with
// the mini-viewer renderer (via ShaderCustomShader.h / Constants.h).

// The default shader: the classic cosine-palette plasma, so Custom
// renders something alive out of the box (and seeds the editor). Shared with
// the inspector via Constants.h.
NSString *ShaderCustomDefaultShaderSource(void) {
  return @"void mainImage( out vec4 fragColor, in vec2 fragCoord ) {\n"
         @"    vec2 uv = fragCoord / iResolution.xy;\n"
         @"    vec3 col = 0.5 + 0.5 * cos(iTime + uv.xyx * 3.0 + "
         @"vec3(0.0, 2.0, 4.0));\n"
         @"    fragColor = vec4(col, 1.0);\n"
         @"}\n";
}

// Shown when the user's shader fails to compile (e.g. uses iChannel textures or
// has a syntax error): animated dark-red hazard stripes, so a broken shader
// reads as clearly broken instead of a stale / blank frame. Always valid.
NSString *ShaderCustomErrorShaderSource(void) {
  return @"void mainImage( out vec4 fragColor, in vec2 fragCoord ) {\n"
         @"    vec2 uv = fragCoord / iResolution.xy;\n"
         @"    float s = step(0.5, fract((uv.x + uv.y) * 10.0 - iTime));\n"
         @"    vec3 col = mix(vec3(0.22,0.0,0.0), vec3(0.5,0.02,0.02), s);\n"
         @"    fragColor = vec4(col, 1.0);\n"
         @"}\n";
}

// Multi-pass code sections ride in the plugin-state blob after the state
// sample(s), each as [uint32 nameLen][name UTF8][uint32 codeLen][code UTF8].
// Only the Custom type writes this tail. Names identify the pass ("Image",
// "Common", "Buffer A").
static void ShaderAppendLenString(NSMutableData *data, NSString *s) {
  NSData *b = [(s ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
  uint32_t n = (uint32_t)b.length;
  [data appendBytes:&n length:sizeof(n)];
  [data appendData:b];
}

static NSDictionary<NSString *, NSString *> *
ShaderParseSections(NSData *data, NSUInteger off) {
  NSMutableDictionary<NSString *, NSString *> *out =
      [NSMutableDictionary dictionary];
  const uint8_t *bytes = (const uint8_t *)data.bytes;
  NSUInteger p = off, len = data.length;
  while (p + 4 <= len) {
    uint32_t nlen;
    memcpy(&nlen, bytes + p, 4);
    p += 4;
    if (p + nlen > len)
      break;
    NSString *name = [[NSString alloc] initWithBytes:bytes + p
                                              length:nlen
                                            encoding:NSUTF8StringEncoding];
    p += nlen;
    if (p + 4 > len)
      break;
    uint32_t clen;
    memcpy(&clen, bytes + p, 4);
    p += 4;
    if (p + clen > len)
      break;
    NSString *code = [[NSString alloc] initWithBytes:bytes + p
                                              length:clen
                                            encoding:NSUTF8StringEncoding];
    p += clen;
    if (name)
      out[name] = code ?: @"";
  }
  return out;
}

// Persistent per-resolution feedback state: two ping-pong sets of 4 buffer
// textures. A buffer that reads itself / a later buffer samples the PREVIOUS
// frame's set; `prevIdx` names it. Reset when the resolution changes.
@interface _ShaderFeedbackSet : NSObject {
@public
  id<MTLTexture> tex[2][4];
  int prevIdx;
  NSUInteger w, h;
  NSInteger lastFrame; // frame index currently held in the `prevIdx` set
  BOOL hasState;       // NO until the first frame has been simulated
  // Periodic snapshots: frame index -> NSArray of 4 texture copies (NSNull =
  // absent buffer). A seek restores the nearest checkpoint <= F, then re-sims
  // to F, so a deep seek is exact + bounded instead of a fixed window from
  // clear.
  NSMutableDictionary<NSNumber *, NSArray *> *checkpoints;
}
@end
@implementation _ShaderFeedbackSet
@end

// A fresh RGBA16F feedback/checkpoint buffer texture (render target + sampled).
static id<MTLTexture> ShaderNewBufferTexture(id<MTLDevice> device, NSUInteger w,
                                             NSUInteger h) {
  MTLTextureDescriptor *td = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                   width:w
                                  height:h
                               mipmapped:NO];
  td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  td.storageMode = MTLStorageModePrivate;
  return [device newTextureWithDescriptor:td];
}

@implementation ShaderPlugin (Render)

// Display pipeline for the final Image pass: derives the pixel format from the
// destination tile.
- (id<MTLRenderPipelineState>)customPipelineForSource:(NSString *)userSource
                                     destinationImage:
                                         (FxImageTile *)destinationImage {
  return [self
      customPipelineForSource:userSource
                  pixelFormat:[KKMetalDeviceCache
                                  pixelFormatForImageTile:destinationImage]
                   registryID:destinationImage.deviceRegistryID
                   bufferMode:NO];
}

// Build (or fetch the cached) runtime-compiled pipeline for `userSource` at an
// explicit pixel format. The GLSL is transpiled to MSL via glslang +
// SPIRV-Cross (memoised), then compiled and cached per device+pixel-format
// keyed on the emitted MSL hash. `bufferMode` selects the raw-output wrapper
// for a Buffer pass. Returns nil (and logs) on a bad shader; the caller draws
// the error pattern.
- (id<MTLRenderPipelineState>)customPipelineForSource:(NSString *)userSource
                                          pixelFormat:(MTLPixelFormat)pf
                                           registryID:(uint64_t)registryID
                                           bufferMode:(BOOL)bufferMode {
  KKGLSLTranspileResult *tr = bufferMode ? KKTranspileGLSLBuffer(userSource)
                                         : KKTranspileGLSL(userSource);
  if (!tr.msl) {
    KKLogError(@"[Custom] GLSL transpile failed: %@", tr.errorLog);
    return nil;
  }
  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  NSString *pluginID = [NSString
      stringWithFormat:@"%@.custom.%lu", kPluginID, (unsigned long)tr.msl.hash];
  id<MTLRenderPipelineState> existing =
      [cache pipelineStateForPluginID:pluginID
                           registryID:registryID
                          pixelFormat:pf];
  if (existing)
    return existing;

  id<MTLDevice> device = [cache deviceWithRegistryID:registryID];
  if (!device)
    return nil;
  NSError *err = nil;
  id<MTLLibrary> lib = [device newLibraryWithSource:tr.msl
                                            options:nil
                                              error:&err];
  if (!lib) {
    KKLogError(@"[Custom] MSL compile failed: %@", err);
    return nil;
  }
  id<MTLFunction> vfn = [lib newFunctionWithName:tr.vertexName];
  id<MTLFunction> ffn = [lib newFunctionWithName:tr.fragmentName];
  if (!vfn || !ffn)
    return nil;
  MTLRenderPipelineDescriptor *desc = [KKRenderPrimitives
      createPipelineDescriptorWithVertexFunction:vfn
                                fragmentFunction:ffn
                                     pixelFormat:pf
                                       blendMode:KKBlendModePremultipliedAlpha];
  id<MTLRenderPipelineState> ps =
      [device newRenderPipelineStateWithDescriptor:desc error:&err];
  if (!ps) {
    KKLogError(@"[Custom] pipeline build failed: %@", err);
    return nil;
  }
  [cache registerPipelineState:ps
                   forPluginID:pluginID
                    registryID:registryID
                   pixelFormat:pf];
  return ps;
}

// Nearest checkpoint frame <= F held by this set, or -1.
- (NSInteger)nearestCheckpointForSet:(_ShaderFeedbackSet *)fb
                              atMost:(NSInteger)F {
  NSInteger best = -1;
  for (NSNumber *k in fb->checkpoints)
    if (k.integerValue <= F && k.integerValue > best)
      best = k.integerValue;
  return best;
}

// Snapshot the set's newest (prevIdx) buffers into a checkpoint at `frame`,
// evicting the oldest when over the cap.
- (void)snapshotSet:(_ShaderFeedbackSet *)fb
              frame:(NSInteger)frame
             device:(id<MTLDevice>)device
              queue:(id<MTLCommandQueue>)queue {
  if (!queue)
    return;
  static const NSInteger kMaxCheckpoints = 24;
  int from = fb->prevIdx;
  NSMutableArray *snap = [NSMutableArray arrayWithCapacity:4];
  id<MTLCommandBuffer> cb = [queue commandBuffer];
  id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
  for (int k = 0; k < 4; k++) {
    id<MTLTexture> src = fb->tex[from][k];
    if (!src) {
      [snap addObject:[NSNull null]];
      continue;
    }
    id<MTLTexture> copy = ShaderNewBufferTexture(device, fb->w, fb->h);
    if (copy)
      [bl copyFromTexture:src toTexture:copy];
    [snap addObject:copy ?: (id)[NSNull null]];
  }
  [bl endEncoding];
  [cb commit];
  [cb waitUntilCompleted];
  if (!fb->checkpoints)
    fb->checkpoints = [NSMutableDictionary dictionary];
  fb->checkpoints[@(frame)] = snap;
  while ((NSInteger)fb->checkpoints.count > kMaxCheckpoints) {
    NSNumber *oldest = [[fb->checkpoints.allKeys
        sortedArrayUsingSelector:@selector(compare:)] firstObject];
    [fb->checkpoints removeObjectForKey:oldest];
  }
}

// Restore checkpoint `frame` into the set's prevIdx slot (the "previous frame"
// the next re-sim step reads).
- (void)restoreSet:(_ShaderFeedbackSet *)fb
             frame:(NSInteger)frame
            device:(id<MTLDevice>)device
             queue:(id<MTLCommandQueue>)queue {
  NSArray *snap = fb->checkpoints[@(frame)];
  if (!snap || !queue)
    return;
  int into = fb->prevIdx;
  id<MTLCommandBuffer> cb = [queue commandBuffer];
  id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
  for (int k = 0; k < 4; k++) {
    id t = snap[k];
    if (t == [NSNull null]) {
      fb->tex[into][k] = nil;
      continue;
    }
    id<MTLTexture> dst = fb->tex[into][k];
    if (!dst) {
      dst = ShaderNewBufferTexture(device, fb->w, fb->h);
      fb->tex[into][k] = dst;
    }
    if (dst)
      [bl copyFromTexture:(id<MTLTexture>)t toTexture:dst];
  }
  [bl endEncoding];
  [cb commit];
  [cb waitUntilCompleted];
}

// Multi-pass Custom render with PERSISTENT (ping-pong) feedback buffers, made
// deterministic under scrubbing by frame tracking. Channel routing (the common
// image convention): iChannelN -> Buffer[N]; a buffer reading an EARLIER buffer
// (index < its own) sees this frame, reading ITSELF or a LATER buffer sees the
// previous frame (feedback). No buffer on a channel -> source clip (ch0) /
// noise. `bufferSources` is 4 entries (A,B,C,D), empty = absent, Common already
// prepended. `frameIndex` (-1 = unknown) + `dtPerFrame` (iTime step) drive the
// determinism: a sequential frame advances ONE step (cheap), the same frame is
// reused, a seek re-simulates a bounded window from a clean start. (Checkpoints
// to make deep seeks exact + bounded are the next increment.)
- (BOOL)renderCustomMultipassWithUniforms:(KKGLSLUniforms)u
                                colorPool:(const simd_float4 *)colorPool
                                poolCount:(int)poolCount
                              imageSource:(NSString *)imageSource
                            bufferSources:(NSArray<NSString *> *)bufferSources
                               frameIndex:(NSInteger)frameIndex
                               dtPerFrame:(float)dtPerFrame
                         destinationImage:(FxImageTile *)destinationImage
                             sourceImages:
                                 (NSArray<FxImageTile *> *)sourceImages {
  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  uint64_t registryID = destinationImage.deviceRegistryID;
  id<MTLDevice> device = [cache deviceWithRegistryID:registryID];
  if (!device)
    return NO;

  // Image pipeline (with error-pattern fallback).
  NSString *imgSrc = imageSource;
  id<MTLRenderPipelineState> imagePS =
      [self customPipelineForSource:imgSrc destinationImage:destinationImage];
  if (!imagePS) {
    imgSrc = ShaderCustomErrorShaderSource();
    imagePS = [self customPipelineForSource:imgSrc
                           destinationImage:destinationImage];
  }
  if (!imagePS)
    return NO;
  KKGLSLTranspileResult *imgTR = KKTranspileGLSL(imgSrc);

  id<MTLTexture> noiseTex = KKCustomChannelNoiseTexture(device);
  id<MTLSamplerState> chSampler = KKCustomChannelSampler(device);
  id<MTLSamplerState> srcSampler = KKCustomSourceSampler(device);
  id<MTLTexture> srcTex =
      sourceImages.count ? [sourceImages[0] metalTextureForDevice:device] : nil;
  NSUInteger W = (NSUInteger)u.resTime.x, H = (NSUInteger)u.resTime.y;
  MTLPixelFormat pf =
      [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
  if (W == 0 || H == 0)
    return NO;

  // Shadertoy expects gamma/display-space iChannel input; the output wrapper
  // re-decodes it (kkSrgbToLinear) for a float dest. FCP's linear source would
  // therefore double-decode and darken, so gamma-encode it first. u.extra.w==0
  // marks the float/linear dest (an 8-bit dest already carries gamma source).
  if (srcTex && u.extra.w == 0.0f) {
    id<MTLCommandQueue> gq = [cache commandQueueWithRegistryID:registryID
                                                   pixelFormat:pf];
    id<MTLTexture> g = KKGammaEncodeSourceTexture(gq, srcTex);
    if (gq)
      [cache returnCommandQueueToCache:gq];
    if (g)
      srcTex = g;
  }

  BOOL present[4];
  for (int c = 0; c < 4; c++)
    present[c] =
        (c < (int)bufferSources.count && [bufferSources[c] length] > 0);

  // Precompile each present buffer's pipeline + transpile once (reused across
  // every re-sim step this render). Detect FEEDBACK: a buffer reading itself /
  // a later buffer (any channel c >= its own index).
  id<MTLRenderPipelineState> bufPS[4] = {nil, nil, nil, nil};
  KKGLSLTranspileResult *bufTR[4] = {nil, nil, nil, nil};
  BOOL needsFeedback = NO;
  for (int k = 0; k < 4; k++) {
    if (!present[k])
      continue;
    bufPS[k] = [self customPipelineForSource:bufferSources[k]
                                 pixelFormat:MTLPixelFormatRGBA16Float
                                  registryID:registryID
                                  bufferMode:YES];
    if (!bufPS[k]) {
      present[k] = NO;
      continue;
    }
    bufTR[k] = KKTranspileGLSLBuffer(bufferSources[k]);
    for (int c = k; c < 4; c++)
      if (bufTR[k].usedChannelMask & (1u << c))
        needsFeedback = YES;
  }

  // Feedback sims run at a capped resolution (pattern scale is a few cells, so
  // a fine grid barely develops; also cuts per-pass cost + checkpoint memory),
  // matching the mini so a shader looks the same in both. Precompute chains
  // (no feedback) stay full-res.
  NSUInteger bufW = W, bufH = H;
  if (needsFeedback && H > (NSUInteger)KK_FEEDBACK_SIM_MAXDIM) {
    bufH = KK_FEEDBACK_SIM_MAXDIM;
    bufW = (NSUInteger)llround((double)W * (double)KK_FEEDBACK_SIM_MAXDIM /
                               (double)H);
  }

  // Persistent ping-pong feedback set for this OUTPUT resolution (its textures
  // are at the capped buffer res `bufW x bufH`).
  NSString *fbKey = [NSString
      stringWithFormat:@"%lux%lu", (unsigned long)W, (unsigned long)H];
  if (!self.feedbackSets)
    self.feedbackSets = [NSMutableDictionary dictionary];
  _ShaderFeedbackSet *fb = self.feedbackSets[fbKey];
  if (!fb) {
    fb = [_ShaderFeedbackSet new];
    self.feedbackSets[fbKey] = fb;
  }
  if (fb->w != bufW || fb->h != bufH) { // buffer resolution changed: reset
    for (int s = 0; s < 2; s++)
      for (int c = 0; c < 4; c++)
        fb->tex[s][c] = nil;
    [fb->checkpoints removeAllObjects];
    fb->prevIdx = 0;
    fb->hasState = NO;
    fb->w = bufW;
    fb->h = bufH;
  }

  // Checkpoint queue for snapshot / restore blits (returned to the cache
  // below).
  id<MTLCommandQueue> ckptQueue = [cache commandQueueWithRegistryID:registryID
                                                        pixelFormat:pf];

  // Decide which frames to step this render. [simFrom, simTo] inclusive; a
  // `clearStart` re-sim begins from empty (self/back refs read noise).
  static const NSInteger kFeedbackWindow =
      90; // frames re-simmed on a cold seek
  static const NSInteger kCheckpointEvery = 20; // snapshot interval
  NSInteger F = frameIndex;
  NSInteger simFrom = 0, simTo = 0;
  BOOL clearStart = NO;
  if (F <
      0) { // unknown frame index: plain one-step advance (non-deterministic)
    simFrom = simTo = 0;
  } else if (fb->hasState && F == fb->lastFrame) {
    simFrom = 1; // reuse existing state; step nothing
    simTo = 0;
  } else if (fb->hasState && F == fb->lastFrame + 1) {
    simFrom = simTo = F; // sequential: one step forward
  } else { // seek: restore the nearest checkpoint <= F, else re-sim a window.
    NSInteger cp = [self nearestCheckpointForSet:fb atMost:F];
    if (cp >= 0) {
      [self restoreSet:fb frame:cp device:device queue:ckptQueue];
      fb->lastFrame = cp;
      fb->hasState = YES;
      simFrom = cp + 1;
      simTo = F;
    } else {
      simFrom = MAX((NSInteger)0, F - kFeedbackWindow);
      simTo = F;
      clearStart = YES;
    }
  }

  for (NSInteger f = simFrom; f <= simTo; f++) {
    int prevI = fb->prevIdx, curI = 1 - prevI;
    BOOL noPrev = clearStart && (f == simFrom); // first re-sim step: no history
    // Per-frame uniforms: iTime for frame f, iFrame = f (F<0 keeps u as-is).
    KKGLSLUniforms fu = u;
    fu.resTime.x = (float)bufW; // buffer passes run at the capped sim res
    fu.resTime.y = (float)bufH;
    if (F >= 0) {
      fu.resTime.w = u.resTime.w - (float)(F - f) * dtPerFrame;
      fu.extra.y = (float)f;
    }
    for (int k = 0; k < 4; k++) {
      id<MTLRenderPipelineState> ps = bufPS[k];
      KKGLSLTranspileResult *tr = bufTR[k];
      if (!ps)
        continue;
      id<MTLTexture> cur = fb->tex[curI][k];
      if (!cur) {
        cur = ShaderNewBufferTexture(device, bufW, bufH);
        fb->tex[curI][k] = cur;
      }
      if (!cur)
        continue;
      // Earlier buffers this step (curI); self / later from the previous frame
      // (prevI), except the first re-sim step which has no history -> noise.
      NSMutableArray *chArr = [NSMutableArray arrayWithCapacity:4];
      KKGLSLUniforms bufU = fu;
      for (int c = 0; c < 4; c++) {
        id<MTLTexture> ct = nil;
        if (present[c]) {
          if (c < k)
            ct = fb->tex[curI][c];
          else if (!noPrev)
            ct = fb->tex[prevI][c];
        } else if (c == 0) {
          ct = srcTex; // no buffer on ch0 -> source clip
        }
        [chArr addObject:ct ?: (id)[NSNull null]];
        if (ct)
          bufU.chanRes[c] =
              (simd_float4){(float)ct.width, (float)ct.height, 1.0f, 0.0f};
      }
      id<MTLCommandQueue> queue = [cache commandQueueWithRegistryID:registryID
                                                        pixelFormat:pf];
      if (queue) {
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        [self encodeFullScreenQuadIntoTexture:cur
                             destinationImage:destinationImage
                                commandBuffer:cb
                               sourceTextures:@[]
                                     commands:^(id<MTLRenderCommandEncoder> enc,
                                                NSArray<id<MTLTexture>> *texs) {
                                       [enc setRenderPipelineState:ps];
                                       KKBindGLSLUniforms(enc, &bufU, colorPool,
                                                          poolCount);
                                       KKBindCustomChannelTextures(
                                           enc, tr, chArr, srcSampler, noiseTex,
                                           chSampler);
                                       [enc drawPrimitives:
                                                MTLPrimitiveTypeTriangleStrip
                                               vertexStart:0
                                               vertexCount:4];
                                     }];
        [cb commit];
        [cb waitUntilCompleted]; // must finish before later passes read it
        [cache returnCommandQueueToCache:queue];
      }
    }
    fb->prevIdx = curI; // this step's set is the newest
    if (F >= 0 && f >= 0 && (f % kCheckpointEvery == 0))
      [self snapshotSet:fb frame:f device:device queue:ckptQueue];
  }
  if (F >= 0 && simTo >= simFrom) {
    fb->lastFrame = F;
    fb->hasState = YES;
  } else if (F < 0) {
    fb->hasState = YES;
  }

  // Image pass reads the newest (this-frame) set.
  int newestI = fb->prevIdx;
  NSMutableArray *imgCh = [NSMutableArray arrayWithCapacity:4];
  KKGLSLUniforms imgU = u;
  if (F >= 0)
    imgU.extra.y = (float)F; // iFrame
  for (int c = 0; c < 4; c++) {
    id<MTLTexture> ct =
        present[c] ? fb->tex[newestI][c] : (c == 0 ? srcTex : nil);
    [imgCh addObject:ct ?: (id)[NSNull null]];
    if (ct)
      imgU.chanRes[c] =
          (simd_float4){(float)ct.width, (float)ct.height, 1.0f, 0.0f};
  }
  BOOL ok = [self
      encodeRenderCommandsForDestinationImage:destinationImage
                                 sourceImages:sourceImages
                                     commands:^(
                                         id<MTLRenderCommandEncoder> encoder,
                                         NSArray<id<MTLTexture>>
                                             *inputTextures) {
                                       [encoder setRenderPipelineState:imagePS];
                                       KKBindGLSLUniforms(encoder, &imgU,
                                                          colorPool, poolCount);
                                       KKBindCustomChannelTextures(
                                           encoder, imgTR, imgCh, srcSampler,
                                           noiseTex, chSampler);
                                       [encoder
                                           drawPrimitives:
                                               MTLPrimitiveTypeTriangleStrip
                                              vertexStart:0
                                              vertexCount:4];
                                     }];
  if (ckptQueue)
    [cache returnCommandQueueToCache:ckptQueue];
  return ok;
}

// Effect: request the clip we're applied to as the source (bound to iChannel0
// in the Custom render path). Motion blur averages the shader over a single
// source frame, so no sub-frame source requests. The boundary-value popover
// additionally pulls its requested clip fraction for the mini-viewer preview.
- (BOOL)scheduleInputs:(NSArray<FxImageTileRequest *> *_Nullable *_Nullable)
                           inputImageRequests
       withPluginState:(NSData *)pluginState
                atTime:(CMTime)renderTime
                 error:(NSError **)error {
  *inputImageRequests = KKBuildSourceRequests(
      renderTime,
      ShaderMiniViewerRequestPathForUUID(KKInstanceUUIDForAPI(self.apiManager)),
      self.renderCache, ^id(CMTime t) {
        return [[FxImageTileRequest alloc]
            initWithSource:kFxImageTileRequestSourceEffectClip
                      time:t
            includeFilters:YES
               parameterID:0];
      });
  return YES;
}

// Builds the full plugin state (active type + both types' uniform blocks) from
// the lanes at renderTime, and does the timing work (render-cache refresh,
// maintain-timing, playhead poller) the timing popover's live preview relies
// on. Runs where FxParameterRetrievalAPI is valid (pluginState:), not at render
// time.
- (BOOL)buildState:(ShaderPluginState *)outState
            atTime:(CMTime)renderTime
             error:(NSError **)error {
  return [self buildStates:outState atTimes:&renderTime count:1 error:error];
}

// Build N plugin states, one per requested time, refreshing the render cache /
// timing ONCE. Motion-blur sample-accumulate evaluates several sub-frame times
// per frame; times[0] should be the frame's renderTime.
- (BOOL)buildStates:(ShaderPluginState *)outStates
            atTimes:(const CMTime *)times
              count:(NSInteger)count
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
  // Live scrubber: render ticks stop ~1s before the clip end (FCP pre-render
  // buffer - renderTime leads currentTime). Arm the self-terminating poll so it
  // follows currentTime through the tail.
  if (hasTiming) {
    KKPlayheadPoller *poller = self.playheadPoller;
    dispatch_async(dispatch_get_main_queue(), ^{
      [poller ensureRunning];
    });
  }

  // Cache refreshed once above; evaluate each requested (sub-frame) time. The
  // per-time work (frac + lane eval + type builders) lives in
  // ShaderEvalStateAtFrac.
  for (NSInteger i = 0; i < count; i++) {
    double frac = (hasTiming && durSec > 0.0)
                      ? MAX(0.0, MIN(1.0, (CMTimeGetSeconds(times[i]) -
                                           self.renderCache.effectStartSec) /
                                              durSec))
                      : 0.0;
    frac = KKMaintainTimingRemappedFraction(frac, self.renderCache);
    ShaderEvalStateAtFrac(timeline, frac, durSec, &outStates[i]);
  }
  return YES;
}

- (BOOL)pluginState:(NSData **)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error {
  // Motion blur (Accurate / sample-accumulate): a generator owns every pixel,
  // so instead of requesting extra source frames we re-render the shader at N
  // sub-frame times across the shutter and average them (KKMotionBlur). Layout:
  // [KKMotionBlurState][state@sample0 == renderTime][state@sample1]... Render
  // reads sample `sampleIndex` at sizeof(mbState) +
  // i*sizeof(ShaderPluginState).
  id<FxParameterRetrievalAPI_v6> paramAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  NSString *mbJSON = KKReadCustomParamString(paramAPI, kKKParamMotionBlurData);
  KKMotionBlurState mbState = [KKMotionBlur snapshotStateFromJSON:mbJSON
                                                        timingAPI:timingAPI
                                                           atTime:renderTime];

  NSArray<NSValue *> *times =
      mbState.enabled
          ? [KKMotionBlur sampleTimesForState:mbState renderTime:renderTime]
          : @[ [NSValue valueWithBytes:&renderTime objCType:@encode(CMTime)] ];
  NSInteger n = (NSInteger)times.count;
  if (n < 1)
    n = 1;

  CMTime *ct = malloc(sizeof(CMTime) * (size_t)n);
  for (NSInteger i = 0; i < n; i++)
    [times[i] getValue:&ct[i]];
  ShaderPluginState *states = malloc(sizeof(ShaderPluginState) * (size_t)n);
  BOOL ok = [self buildStates:states atTimes:ct count:n error:error];
  free(ct);
  if (!ok) {
    free(states);
    return NO;
  }

  // The Custom (GLSL) path is the only render path now: it owns its own
  // animation (the shader's own time via Speed) and its source rides in the
  // blob tail, so it never uses the sample-accumulate motion-blur path.
  mbState.enabled = NO;

  NSMutableData *data = [NSMutableData
      dataWithCapacity:sizeof(mbState) + sizeof(ShaderPluginState) *
                                             (size_t)(mbState.enabled ? n : 1)];
  [data appendBytes:&mbState length:sizeof(mbState)];
  [data appendBytes:&states[0] length:sizeof(ShaderPluginState)];
  if (mbState.enabled)
    for (NSInteger i = 1; i < n; i++)
      [data appendBytes:&states[i] length:sizeof(ShaderPluginState)];
  free(states);

  // Append the user shader source (UTF-8) after the single state sample. The
  // source lives in the timeline's "Shader" code lane (codeString). MB is
  // forced off above, so the layout is a fixed [mbState][state][source...] and
  // render reads the tail from a known offset. Empty = the baked default.
  {
    NSString *timelineJSON =
        KKReadCustomParamString(paramAPI, kKKParamTimelineData);
    KKTimeline *tl =
        timelineJSON.length ? [KKTimeline timelineFromJSON:timelineJSON] : nil;
    KKLane *shaderLane = nil;
    for (KKLane *lane in tl.lanes)
      if ([lane.label isEqualToString:@"Shader"]) {
        shaderLane = lane;
        break;
      }
    // Image (the lane's codeString) + any non-empty extra tabs (Common /
    // Buffer A), each a length-prefixed [name][code] section.
    if (shaderLane.codeString.length) {
      ShaderAppendLenString(data, @"Image");
      ShaderAppendLenString(data, shaderLane.codeString);
    } else if (!shaderLane) {
      // Fresh instance: the timeline blob hasn't been persisted yet (default is
      // an empty blob, written only on the first param change / UI edit). The
      // constants editor already shows the catalog default (plasma) because it
      // rebuilds its lanes from the catalog, so seed that same default here to
      // match — otherwise the first render falls to passthrough and the plasma
      // only appears after the user nudges a param. A present-but-empty
      // codeString means the user explicitly cleared it => passthrough, so only
      // fall back when the Shader lane is absent entirely.
      ShaderAppendLenString(data, @"Image");
      ShaderAppendLenString(data, ShaderCustomDefaultShaderSource());
    }
    for (NSDictionary *t in shaderLane.codeTabs) {
      NSString *n =
          [t[@"name"] isKindOfClass:[NSString class]] ? t[@"name"] : nil;
      NSString *c =
          [t[@"code"] isKindOfClass:[NSString class]] ? t[@"code"] : nil;
      if (n.length && c.length) {
        ShaderAppendLenString(data, n);
        ShaderAppendLenString(data, c);
      }
    }
  }

  *pluginState = data;
  return (*pluginState != nil);
}

- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
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

  // Mini-viewer source feed: publish the raw source per slot (single-slot =
  // playhead, multi-slot = boundary preview / filmstrip / onion). Shared glue
  // in KKPlugin (MiniViewerFeed); the renderer applies the shader locally.
  [self
      kkPublishMiniViewerFeedForDestination:destinationImage
                               sourceImages:sourceImages
                             descriptorPath:
                                 ShaderMiniViewerDescriptorPathForUUID(
                                     KKInstanceUUIDForAPI(self.apiManager))
                            boundaryReqSecs:self.renderCache.boundaryReqSecs
                           boundaryReqFracs:self.renderCache.boundaryReqFracs
                            multiSlotActive:self.renderCache.boundaryFeedActive
                          changesOutputSize:NO
                                 defaultTag:0.0];

  // Output dimensions drive the shader's resolution uniform (iResolution etc.).
  CGFloat mediaW = destinationImage.imagePixelBounds.right -
                   destinationImage.imagePixelBounds.left;
  CGFloat mediaH = destinationImage.imagePixelBounds.top -
                   destinationImage.imagePixelBounds.bottom;

  // State(s) built in -pluginState: (params API is invalid here). Layout is
  // [KKMotionBlurState][state@sample0]...; read the header + the base sample.
  // Fall back to defaults if the blob is missing/short.
  KKMotionBlurState mbState;
  ShaderPluginState base;
  if (pluginState.length >= sizeof(mbState) + sizeof(base)) {
    [pluginState getBytes:&mbState length:sizeof(mbState)];
    [pluginState getBytes:&base
                    range:NSMakeRange(sizeof(mbState), sizeof(base))];
  } else {
    memset(&mbState, 0, sizeof(mbState)); // disabled
    memset(&base, 0, sizeof(base));
    base.common = ShaderCommonDefault();
  }

  // Custom (user-supplied) shader(s): runtime-compiled. The only render path
  // now. Multi-pass: an optional Buffer A renders into a texture bound as the
  // Image pass's iChannel0; Common is prepended to each. iTime respects the
  // shared Speed / Seed.
  {
    float iTime = base.common.time * base.common.speed +
                  fmodf(base.common.seed, 10000.0f);
    KKGLSLUniforms u;
    u.resTime = (simd_float4){(float)mediaW, (float)mediaH, 1.0f, iTime};
    u.mouse = (simd_float4){0.0f, 0.0f, 0.0f, 0.0f};
    u.date = (simd_float4){0.0f, 0.0f, 0.0f, 0.0f};
    float encodeSRGB =
        (destinationImage.ioSurface.pixelFormat == kCVPixelFormatType_32BGRA)
            ? 1.0f
            : 0.0f;
    // x=iTimeDelta (approx), y=float(iFrame) (approx), z=flipY (FCP dest is
    // reverse-Y, no flip), w=encodeSRGB.
    u.extra = (simd_float4){1.0f / 60.0f, iTime * 60.0f, 0.0f, encodeSRGB};
    // Core film grain (Grain / Grain Size lanes), same as the built-in Types.
    u.grain =
        (simd_float4){base.common.grain, base.common.grainSize, 0.0f, 0.0f};
    // iChannelResolution: 0 = source clip (filled from the bound texture
    // below), 1-3 = the 256x256 noise texture.
    u.chanRes[0] = (simd_float4){(float)mediaW, (float)mediaH, 1.0f, 0.0f};
    for (int c = 1; c < 4; c++)
      u.chanRes[c] = (simd_float4){256.0f, 256.0f, 1.0f, 0.0f};

    // Multi-pass sections from the blob tail (Image / Common / Buffer A).
    NSUInteger head = sizeof(mbState) + sizeof(ShaderPluginState);
    NSDictionary<NSString *, NSString *> *sections =
        (pluginState.length > head) ? ShaderParseSections(pluginState, head)
                                    : @{};
    NSString *common = sections[@"Common"] ?: @"";
    NSString *imageSrc = sections[@"Image"];
    if (imageSrc.length == 0)
      // Cleared code = passthrough (show the source unchanged), not the plasma
      // default.
      imageSrc = @"void mainImage(out vec4 O, in vec2 fc){ O = "
                 @"texture(iChannel0, fc / iResolution.xy); }";
    NSString * (^withCommon)(NSString *) = ^NSString *(NSString *s) {
      return common.length ? [NSString stringWithFormat:@"%@\n%@", common, s]
                           : s;
    };

    // Any Buffer A-D present -> multi-pass (buffer textures feed the passes'
    // iChannels).
    NSArray<NSString *> *bufNames =
        @[ @"Buffer A", @"Buffer B", @"Buffer C", @"Buffer D" ];
    NSMutableArray<NSString *> *bufSources =
        [NSMutableArray arrayWithCapacity:4];
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
    if (anyBuffer) {
      // Frame index + per-frame iTime step, so feedback buffers advance
      // deterministically (carry-forward on a sequential frame, re-sim on a
      // seek). frameDurSec comes from the render cache; -1 = unknown (fall back
      // to a plain one-step advance).
      double frameDur = self.renderCache.frameDurSec;
      NSInteger frameIndex =
          (frameDur > 0.0) ? (NSInteger)llround(base.common.time / frameDur)
                           : -1;
      float dtPerFrame = (float)(frameDur * base.common.speed);
      return [self renderCustomMultipassWithUniforms:u
                                           colorPool:base.colorPool
                                           poolCount:base.colorPoolCount
                                         imageSource:withCommon(imageSrc)
                                       bufferSources:bufSources
                                          frameIndex:frameIndex
                                          dtPerFrame:dtPerFrame
                                    destinationImage:destinationImage
                                        sourceImages:sourceImages];
    }

    // Single pass: source clip -> iChannel0, noise -> 1-3.
    NSString *effectiveSource = withCommon(imageSrc);
    id<MTLRenderPipelineState> customPS =
        [self customPipelineForSource:effectiveSource
                     destinationImage:destinationImage];
    if (!customPS) {
      effectiveSource = ShaderCustomErrorShaderSource();
      customPS = [self customPipelineForSource:effectiveSource
                              destinationImage:destinationImage];
    }
    if (!customPS)
      return NO;
    KKGLSLTranspileResult *tr = KKTranspileGLSL(effectiveSource);
    id<MTLDevice> device = [[KKMetalDeviceCache sharedCache]
        deviceWithRegistryID:destinationImage.deviceRegistryID];
    id<MTLTexture> noiseTex =
        tr.usedChannelMask ? KKCustomChannelNoiseTexture(device) : nil;
    id<MTLSamplerState> chSampler =
        tr.usedChannelMask ? KKCustomChannelSampler(device) : nil;
    id<MTLSamplerState> srcSampler =
        tr.usedChannelMask ? KKCustomSourceSampler(device) : nil;
    // Gamma-encode the linear source so a Shadertoy shader (gamma-space input,
    // output re-decoded for the float dest) round-trips it instead of
    // double-decoding + darkening. encodeSRGB==0 == float/linear dest; an 8-bit
    // dest already carries gamma source, so leave it untouched.
    id<MTLTexture> gammaSrc = nil;
    if (encodeSRGB == 0.0f && sourceImages.count) {
      id<MTLTexture> rawSrc = [sourceImages[0] metalTextureForDevice:device];
      if (rawSrc) {
        KKMetalDeviceCache *dc = [KKMetalDeviceCache sharedCache];
        id<MTLCommandQueue> gq = [dc
            commandQueueWithRegistryID:destinationImage.deviceRegistryID
                           pixelFormat:
                               [KKMetalDeviceCache
                                   pixelFormatForImageTile:destinationImage]];
        gammaSrc = KKGammaEncodeSourceTexture(gq, rawSrc);
        if (gq)
          [dc returnCommandQueueToCache:gq];
      }
    }
    return [self
        encodeRenderCommandsForDestinationImage:destinationImage
                                   sourceImages:sourceImages
                                       commands:^(
                                           id<MTLRenderCommandEncoder> encoder,
                                           NSArray<id<MTLTexture>>
                                               *inputTextures) {
                                         [encoder
                                             setRenderPipelineState:customPS];
                                         id<MTLTexture> src =
                                             gammaSrc
                                                 ?: (inputTextures.count
                                                         ? inputTextures[0]
                                                         : nil);
                                         KKGLSLUniforms uu = u;
                                         if (src)
                                           uu.chanRes[0] = (simd_float4){
                                               (float)src.width,
                                               (float)src.height, 1.0f, 0.0f};
                                         KKBindGLSLUniforms(
                                             encoder, &uu, base.colorPool,
                                             base.colorPoolCount);
                                         KKBindCustomChannels(
                                             encoder, tr, src, srcSampler,
                                             noiseTex, chSampler);
                                         [encoder
                                             drawPrimitives:
                                                 MTLPrimitiveTypeTriangleStrip
                                                vertexStart:0
                                                vertexCount:4];
                                       }];
  }
}

@end
#pragma clang diagnostic pop
