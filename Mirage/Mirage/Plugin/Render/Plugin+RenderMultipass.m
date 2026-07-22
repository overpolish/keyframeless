/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Plugin+Render_Internal.h"
#import "MirageCustomShader.h"
#import "MirageFeedbackSet.h"

#import <KeyframelessKit/KKMetalDeviceCache.h>

// Frames re-simmed on a cold seek (no checkpoint at or before the target).
static const NSInteger kFeedbackWindow = 90;
// Snapshot interval, in frames.
static const NSInteger kCheckpointEvery = 20;

// The inclusive frame range [from, to] a render must step, given the set's
// current state. `clearStart` means the first step begins from empty (self/back
// refs read noise) because no checkpoint was close enough to restore.
typedef struct {
  NSInteger from, to;
  BOOL clearStart;
} MirageSimRange;

@implementation MiragePlugin (RenderMultipass)

// Decide which frames to step, restoring a checkpoint when that makes a seek
// cheap. `to < from` means "reuse the existing state, step nothing".
- (MirageSimRange)simRangeForSet:(MirageFeedbackSet *)fb
                      frameIndex:(NSInteger)F
                          device:(id<MTLDevice>)device
                           queue:(id<MTLCommandQueue>)queue {
  if (F < 0) // unknown frame index: plain one-step advance (non-deterministic)
    return (MirageSimRange){0, 0, NO};
  if (fb->hasState && F == fb->lastFrame)
    return (MirageSimRange){1, 0, NO}; // reuse existing state
  if (fb->hasState && F == fb->lastFrame + 1)
    return (MirageSimRange){F, F, NO}; // sequential: one step forward
  NSInteger cp = [fb nearestCheckpointAtMost:F];
  if (cp < 0) // cold seek: re-sim a bounded window from clear
    return (MirageSimRange){MAX((NSInteger)0, F - kFeedbackWindow), F, YES};
  [fb restoreFrame:cp device:device queue:queue];
  fb->lastFrame = cp;
  fb->hasState = YES;
  return (MirageSimRange){cp + 1, F, NO};
}

// The textures each channel reads for buffer `k` on this step, as a 4-element
// array (NSNull = none -> noise). Earlier buffers come from this step's set
// (`curI`); self / later buffers from the previous frame (`prevI`) - that IS
// the feedback. `noPrev` (the first re-sim step) has no history to read.
static NSArray *MirageChannelsForBuffer(int k, MirageFeedbackSet *fb, int curI,
                                        int prevI, const BOOL *present,
                                        BOOL noPrev, id<MTLTexture> srcTex,
                                        KKGLSLUniforms *io) {
  NSMutableArray *chArr = [NSMutableArray arrayWithCapacity:4];
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
      io->chanRes[c] =
          (simd_float4){(float)ct.width, (float)ct.height, 1.0f, 0.0f};
  }
  return chArr;
}

// Gamma-encode the linear source so a Shadertoy shader (which assumes
// gamma-space iChannel input, and whose output wrapper re-decodes it for a
// float dest) round-trips it instead of double-decoding + darkening.
// u.extra.w==0 marks the float/linear dest; an 8-bit dest already carries gamma
// source.
- (id<MTLTexture>)gammaEncodedSource:(id<MTLTexture>)srcTex
                          registryID:(uint64_t)registryID
                         pixelFormat:(MTLPixelFormat)pf {
  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  id<MTLCommandQueue> gq = [cache commandQueueWithRegistryID:registryID
                                                 pixelFormat:pf];
  id<MTLTexture> g = KKGammaEncodeSourceTexture(gq, srcTex);
  if (gq)
    [cache returnCommandQueueToCache:gq];
  return g ?: srcTex;
}

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
    imgSrc = MirageCustomErrorShaderSource();
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

  if (srcTex && u.extra.w == 0.0f)
    srcTex = [self gammaEncodedSource:srcTex
                           registryID:registryID
                          pixelFormat:pf];

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
      if (bufTR[k].declaredChannelMask & (1u << c))
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
  if (!self.feedbackSets)
    self.feedbackSets = [NSMutableDictionary dictionary];
  NSString *fbKey = [NSString
      stringWithFormat:@"%lux%lu", (unsigned long)W, (unsigned long)H];
  MirageFeedbackSet *fb = [MirageFeedbackSet setInStore:self.feedbackSets
                                                 forKey:fbKey
                                                  width:bufW
                                                 height:bufH];

  // Checkpoint queue for snapshot / restore blits (returned to the cache
  // below).
  id<MTLCommandQueue> ckptQueue = [cache commandQueueWithRegistryID:registryID
                                                        pixelFormat:pf];
  NSInteger F = frameIndex;
  MirageSimRange sim = [self simRangeForSet:fb
                                 frameIndex:F
                                     device:device
                                      queue:ckptQueue];

  for (NSInteger f = sim.from; f <= sim.to; f++) {
    int prevI = fb->prevIdx, curI = 1 - prevI;
    BOOL noPrev = sim.clearStart && (f == sim.from); // no history to read
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
        cur = MirageNewBufferTexture(device, bufW, bufH);
        fb->tex[curI][k] = cur;
      }
      if (!cur)
        continue;
      KKGLSLUniforms bufU = fu;
      NSArray *chArr = MirageChannelsForBuffer(k, fb, curI, prevI, present,
                                               noPrev, srcTex, &bufU);
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
      [fb snapshotFrame:f device:device queue:ckptQueue];
  }
  if (F >= 0 && sim.to >= sim.from) {
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

@end
