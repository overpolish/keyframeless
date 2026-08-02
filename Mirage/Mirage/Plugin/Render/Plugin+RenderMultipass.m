/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "MirageCustomShader.h"
#import "MirageFeedbackSet.h"
#import "Plugin+Render_Internal.h"

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

@implementation MirageRackChainSlot
@end

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
  self.renderStrayWaitsRestore++; // restoreFrame blits and waits internally
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
                                        id<MTLTexture> toTex,
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
    } else if (c == 1) {
      ct = toTex; // no buffer on ch1 -> transition's incoming clip
    }
    [chArr addObject:ct ?: (id)[NSNull null]];
    if (ct)
      io->chanRes[c] =
          (simd_float4){(float)ct.width, (float)ct.height, 1.0f, 0.0f};
  }
  return chArr;
}

- (BOOL)
    renderCustomMultipassWithUniforms:(KKGLSLUniforms)u
                            colorPool:(const simd_float4 *)colorPool
                            poolCount:(int)poolCount
                          imageSource:(NSString *)imageSource
                        bufferSources:(NSArray<NSString *> *)bufferSources
                           frameIndex:(NSInteger)frameIndex
                           dtPerFrame:(float)dtPerFrame
                              mbState:(KKMotionBlurState)mbState
                           renderTime:(CMTime)renderTime
                       sampleUniforms:(MirageSampleUniformsBlock)sampleUniforms
                       transitionMode:(int)transitionMode
                                chain:(MirageRackChainSlot *)chain
                     destinationImage:(FxImageTile *)destinationImage
                         sourceImages:(NSArray<FxImageTile *> *)sourceImages {
  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  uint64_t registryID = destinationImage.deviceRegistryID;
  id<MTLDevice> device = [cache deviceWithRegistryID:registryID];
  if (!device)
    return NO;

  // Image pipeline (with error-pattern fallback). A chain entry that is not the
  // last one draws into an RGBA16F intermediate, so its pipeline is built
  // against THAT format rather than the destination tile's.
  MTLPixelFormat imagePF =
      chain.output
          ? MTLPixelFormatRGBA16Float
          : [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
  NSString *imgSrc = imageSource;
  id<MTLRenderPipelineState> imagePS =
      [self customPipelineForSource:imgSrc
                        pixelFormat:imagePF
                         registryID:registryID
                               pass:KKGLSLPassImage];
  if (!imagePS) {
    imgSrc = MirageCustomErrorShaderSource();
    imagePS = [self customPipelineForSource:imgSrc
                                pixelFormat:imagePF
                                 registryID:registryID
                                       pass:KKGLSLPassImage];
  }
  if (!imagePS)
    return NO;
  KKGLSLTranspileResult *imgTR = KKTranspileGLSL(imgSrc);

  id<MTLTexture> noiseTex = KKCustomChannelNoiseTexture(device);
  id<MTLSamplerState> chSampler = KKCustomChannelSampler(device);
  id<MTLSamplerState> srcSampler = KKCustomSourceSampler(device);
  id<MTLTexture> effectTex = [MirageCurrentFrameTile(sourceImages, renderTime)
      metalTextureForDevice:device];
  id<MTLTexture> fromTex =
      [KKImageTileForParameterID(sourceImages, kParamFromImage)
          metalTextureForDevice:device];
  BOOL transitionShader = KKLooksLikeTransitionShader(imageSource);
  id<MTLTexture> srcTex = transitionShader && fromTex ? fromTex : effectTex;
  // SHADER RACK: past the head of a chain the previous entry's output IS
  // iChannel0, and it WINS over a transition's From well. The well names the
  // clip on one side of the cut, which is what the head entry is applied to;
  // an entry further down the chain is applied to what the chain has made so
  // far, so honouring the well there would drop everything upstream of it.
  if (chain.input)
    srcTex = chain.input;
  id<MTLTexture> toTex = [KKImageTileForParameterID(sourceImages, kParamToImage)
      metalTextureForDevice:device];
  id<MTLTexture> transparentTex =
      transitionMode != 0 ? KKCustomTransparentTexture(device) : nil;
  if (transitionMode == 1)
    srcTex = transparentTex;
  if (transitionMode == 2)
    toTex = transparentTex;
  NSUInteger W = (NSUInteger)u.resTime.x, H = (NSUInteger)u.resTime.y;
  MTLPixelFormat pf =
      [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
  if (W == 0 || H == 0)
    return NO;

  BOOL colorTransform = KKLooksLikeColorTransformShader(imageSource);
  // The SURFACE's space, which is what decides how a delivered clip texture has
  // to be treated. Normally the output encode flag says it (a float FCP surface
  // is linear and takes an unencoded output); a chain entry writing an
  // intermediate always encodes, so it states the surface separately.
  BOOL floatDst = chain ? chain.surfaceLinear : (u.extra.w == 0.0f);
  BOOL decodeSources = !floatDst && colorTransform;
  // PLANNED, encoded later onto a buffer that is already being submitted - see
  // the single-pass path. Each of these used to be its own command buffer with
  // a blocking wait, and on a transition (which has both A and B) that was two
  // round trips of pure scheduling latency per frame.
  NSMutableArray *convertPairs = [NSMutableArray array];
  BOOL convertSources = decodeSources || (floatDst && !colorTransform);
  // A chain input does not arrive from FCP, it arrives from the previous
  // entry - always GAMMA-ENCODED, which is the space an ordinary shader wants
  // and so needs no conversion at all. A `color-transform` entry consumes
  // LINEAR, so mid-chain it decodes that input whatever the surface format is:
  // the mirror of the encode its own output branch applies for a gamma target.
  BOOL convertSrc = chain.input ? colorTransform : convertSources;
  BOOL decodeSrc = chain.input ? YES : decodeSources;
  if (srcTex && convertSrc && KKGammaPipelineAvailable(device, decodeSrc)) {
    id<MTLTexture> dst =
        [self reusableGammaDestinationForKey:MirageGammaDestSource
                                      device:device
                                       width:srcTex.width
                                      height:srcTex.height];
    if (dst) {
      [convertPairs addObject:@[ srcTex, dst, @(decodeSrc) ]];
      srcTex = dst;
    }
  }
  // The To well and the `#frames` neighbours are delivered clip textures on
  // every entry, chained or not, so they keep the surface-derived rule.
  if (toTex && transitionMode != 2 && convertSources &&
      KKGammaPipelineAvailable(device, decodeSources)) {
    id<MTLTexture> dst = [self reusableGammaDestinationForKey:MirageGammaDestTo
                                                       device:device
                                                        width:toTex.width
                                                       height:toTex.height];
    if (dst) {
      [convertPairs addObject:@[ toTex, dst, @(decodeSources) ]];
      toTex = dst;
    }
  }
  void (^encodeConversions)(id<MTLCommandBuffer>) =
      convertPairs.count ? ^(id<MTLCommandBuffer> cb) {
        for (NSArray *pair in convertPairs)
          KKGammaConvertOnBufferInto(cb, pair[0], pair[1],
                                     [pair[2] boolValue]);
      } : nil;

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
                                        pass:KKGLSLPassBuffer];
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
  // Keyed by entry too: two chain entries each running a Buffer feedback chain
  // at the same output resolution would otherwise share one ping-pong set and
  // one checkpoint history, and each would see the other's frame as its own
  // previous one. The unracked key is the bare resolution it always was.
  NSString *fbKey =
      chain.entryID.length
          ? [NSString stringWithFormat:@"%lux%lu#%@", (unsigned long)W,
                                       (unsigned long)H, chain.entryID]
          : [NSString stringWithFormat:@"%lux%lu", (unsigned long)W,
                                       (unsigned long)H];
  MirageFeedbackSet *fb = [MirageFeedbackSet setInStore:self.feedbackSets
                                                 forKey:fbKey
                                                  width:bufW
                                                 height:bufH];

  // ONE queue for the whole frame: the buffer passes, the checkpoint blits and
  // the image pass all ride it, so commit order alone orders them and only the
  // image pass has to wait. Two queues from the pool are interchangeable
  // objects with no ordering between them, which is why this must be shared
  // explicitly. A chain supplies the queue - ONE for the whole frame across
  // every entry, not just across one entry's passes - and owns returning it.
  id<MTLCommandQueue> frameQueue =
      chain.queue
          ?: [cache commandQueueWithRegistryID:registryID pixelFormat:pf];
  NSInteger F = frameIndex;
  // Only a FEEDBACK chain can reuse a previous render's buffers: its state is a
  // function of history, so once frame F is simulated it stays valid. A
  // non-feedback chain is a pure function of the CURRENT uniforms, and the
  // reuse path returns an empty range that skips the passes entirely - so any
  // parameter change while parked on one frame left the buffers holding the
  // last render's result. Crop the window, then raise the glow, and the glow
  // was still built from the UNCROPPED silhouette (alpha 1 everywhere = a
  // white wash), correcting itself only when a scrub changed the frame index.
  MirageSimRange sim = needsFeedback
                           ? [self simRangeForSet:fb
                                       frameIndex:F
                                           device:device
                                            queue:frameQueue]
                           : (MirageSimRange){0, 0, NO}; // always recompute

  // ONE command buffer for every buffer pass this render encodes, created on
  // first use. Metal runs render passes on a buffer in encode order and
  // hazard-tracks the reads between them (these textures come from
  // -newTextureWithDescriptor:, not an untracked heap), so the ordering the old
  // per-pass wait enforced is automatic here - and a re-simulation of N steps
  // costs one round trip instead of N.
  __block id<MTLCommandBuffer> passBuffer = nil;
  __block BOOL conversionsEncoded = NO;
  id<MTLCommandBuffer> (^ensurePassBuffer)(void) = ^id<MTLCommandBuffer>(void) {
    if (passBuffer)
      return passBuffer;
    if (!frameQueue)
      return nil;
    passBuffer = [frameQueue commandBuffer];
    passBuffer.label = @"Mirage buffer passes";
    // The buffer passes SAMPLE the converted sources, so the conversions have
    // to be encoded ahead of them on this same buffer.
    if (encodeConversions && !conversionsEncoded) {
      conversionsEncoded = YES;
      encodeConversions(passBuffer);
    }
    return passBuffer;
  };
  // Submit WITHOUT waiting. Everything that reads these textures - a checkpoint
  // blit, and the image pass - is committed to the SAME queue afterwards, and a
  // queue runs its command buffers in commit order, so the ordering the old
  // per-pass wait enforced still holds while the frame keeps ONE round trip.
  void (^submitPassBuffer)(void) = ^{
    if (!passBuffer)
      return;
    [passBuffer commit];
    passBuffer = nil;
  };

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
                                               noPrev, srcTex, toTex, &bufU);
      id<MTLCommandBuffer> cb = ensurePassBuffer();
      if (cb) {
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
      }
    }
    fb->prevIdx = curI; // this step's set is the newest
    // Checkpoints exist ONLY so a later cold seek can restore feedback history,
    // and the only reader - simRangeForSet: - is called only for a feedback
    // chain. A non-feedback chain recomputes from the current uniforms every
    // render and never consults them, so its checkpoints were pure cost.
    //
    // And they were not occasional: a non-feedback chain runs the fixed range
    // {0, 0}, so `f` is 0 on every render and `f % kCheckpointEvery == 0` is
    // true EVERY FRAME. That is the per-frame snapshot wait the canary caught.
    if (needsFeedback && F >= 0 && f >= 0 && (f % kCheckpointEvery == 0)) {
      // The snapshot blits these textures. It runs on the SAME queue, committed
      // after the passes that wrote them, so commit order already serialises it
      // behind them - no flush needed. It does wait internally, which is why
      // the canary counts checkpoint frames.
      submitPassBuffer();
      self.renderStrayWaitsSnapshot++;
      [fb snapshotFrame:f device:device queue:frameQueue];
    }
  }
  submitPassBuffer();
  if (F >= 0 && sim.to >= sim.from) {
    fb->lastFrame = F;
    fb->hasState = YES;
  } else if (F < 0) {
    fb->hasState = YES;
  }

  // `// #frames` neighbours, gamma-matched to the source exactly as the single-
  // pass path does. Bound on the IMAGE pass only: a Buffer pass stores data for
  // a later pass and never declares them, so its transpile reports none.
  // Resolved RAW, then gamma-matched as ONE batch - see the single-pass path.
  // An undeliverable offset stays NSNull and `neighborFallback` substitutes the
  // current frame at bind time, exactly as the per-entry fallback used to.
  NSArray *neighborTex = MirageNeighborFrameTextures(
      imageSource, sourceImages, renderTime, self.renderCache.frameDurSec,
      device, nil, nil);
  void (^neighborEncode)(id<MTLCommandBuffer>) = nil;
  if (convertSources && neighborTex.count)
    neighborTex = [self gammaMatchNeighbors:neighborTex
                                     decode:decodeSources
                                     device:device
                                     encode:&neighborEncode];
  // Whatever preparation has not already ridden the buffer-pass submission goes
  // onto the image pass's own command buffer. With no buffer passes to run -
  // the carry-forward case, which is the common one on a parked or looping
  // playhead - that leaves the render at ONE round trip for the whole frame.
  BOOL conversionsPending = encodeConversions && !conversionsEncoded;
  void (^imageSetup)(id<MTLCommandBuffer>) =
      (conversionsPending || neighborEncode) ? ^(id<MTLCommandBuffer> cb) {
        if (conversionsPending)
          encodeConversions(cb);
        if (neighborEncode)
          neighborEncode(cb);
      } : nil;
  id<MTLTexture> neighborFallback = srcTex ?: noiseTex;

  // Image pass reads the newest (this-frame) set.
  int newestI = fb->prevIdx;
  NSMutableArray *imgCh = [NSMutableArray arrayWithCapacity:4];
  KKGLSLUniforms imgU = u;
  if (F >= 0)
    imgU.extra.y = (float)F; // iFrame
  for (int c = 0; c < 4; c++) {
    id<MTLTexture> ct = present[c] ? fb->tex[newestI][c]
                                   : (c == 0 ? srcTex : (c == 1 ? toTex : nil));
    [imgCh addObject:ct ?: (id)[NSNull null]];
    if (ct)
      imgU.chanRes[c] =
          (simd_float4){(float)ct.width, (float)ct.height, 1.0f, 0.0f};
  }
  // Accumulate motion blur over a multi-pass chain. Only the IMAGE pass re-runs
  // per sub-sample; the buffers above were encoded ONCE and every sample reads
  // the same textures. That is sound precisely because this chain has no
  // feedback: a non-feedback buffer is a pure function of the current uniforms,
  // identical at every sub-sample, so re-simulating it N times would compute
  // the same pixels N times. A FEEDBACK chain is a function of history and
  // cannot be shared like this - hence the guard.
  //
  // A CHAIN follows the same shape one level up: an upstream entry encodes once
  // per frame and only the last one - the entry that owns the destination -
  // re-runs per sample. So an entry drawing an intermediate never accumulates,
  // and the caller hands it no samples to accumulate over either.
  BOOL mbAccumulate = mbState.enabled && sampleUniforms != nil &&
                      !needsFeedback && !chain.output;
  __block BOOL imageSetupEncoded = NO;
  if (mbAccumulate) {
    // Blur submits on the FRAME's queue, so commit order puts it after the
    // buffer passes already committed there - no drain, and its single wait
    // covers both.
    BOOL blurred = [KKMotionBlur
        applyToDestinationImage:destinationImage
                   sourceImages:sourceImages
                          state:mbState
                     renderTime:renderTime
                   commandQueue:frameQueue
                    renderBlock:^BOOL(int sampleIndex,
                                      id<MTLTexture> sampleDest,
                                      id<MTLCommandBuffer> commandBuffer,
                                      NSArray<id<MTLTexture>> *inputTextures) {
                      KKGLSLUniforms su = imgU;
                      const simd_float4 *sPool = colorPool;
                      int sCount = poolCount;
                      sampleUniforms(sampleIndex, &su, &sPool, &sCount);
                      // Once, on the first sample's buffer: every sample reads
                      // the same prepared inputs.
                      if (imageSetup && !imageSetupEncoded) {
                        imageSetupEncoded = YES;
                        imageSetup(commandBuffer);
                      }
                      // The buffer chain's own channel resolutions still apply:
                      // only the animation clock and pool differ per sample.
                      for (int c = 0; c < 4; c++)
                        su.chanRes[c] = imgU.chanRes[c];
                      return [self
                          encodeFullScreenQuadIntoTexture:sampleDest
                                         destinationImage:destinationImage
                                            commandBuffer:commandBuffer
                                           sourceTextures:inputTextures
                                                 commands:^(
                                                     id<MTLRenderCommandEncoder>
                                                         enc,
                                                     NSArray<id<MTLTexture>>
                                                         *inputs) {
                                                   [enc setRenderPipelineState:
                                                            imagePS];
                                                   KKBindGLSLUniforms(
                                                       enc, &su, sPool, sCount);
                                                   KKBindCustomChannelTextures(
                                                       enc, imgTR, imgCh,
                                                       srcSampler, noiseTex,
                                                       chSampler);
                                                   KKBindCustomNeighborTextures(
                                                       enc, imgTR, neighborTex,
                                                       srcSampler,
                                                       neighborFallback);
                                                   [enc
                                                       drawPrimitives:
                                                           MTLPrimitiveTypeTriangleStrip
                                                          vertexStart:0
                                                          vertexCount:4];
                                                 }];
                    }];
    if (blurred) {
      if (frameQueue && !chain.queue)
        [cache returnCommandQueueToCache:frameQueue];
      return YES;
    }
    // Fall through to a single pass on any bail.
  }

  // A chain entry that is not the last one draws into its intermediate and
  // COMMITS WITHOUT WAITING. Everything that reads it - the next entry's
  // passes, and eventually the destination pass - is committed to this same
  // queue afterwards, so commit order chains them and the frame still pays
  // exactly one round trip, the one the final entry's destination pass makes.
  if (chain.output) {
    id<MTLCommandBuffer> cb = [frameQueue commandBuffer];
    if (!cb)
      return NO;
    cb.label = @"Mirage chain entry";
    if (imageSetup && !imageSetupEncoded)
      imageSetup(cb);
    BOOL encoded = [self
        encodeFullScreenQuadIntoTexture:chain.output
                       destinationImage:destinationImage
                          commandBuffer:cb
                         sourceTextures:@[]
                               commands:^(id<MTLRenderCommandEncoder> encoder,
                                          NSArray<id<MTLTexture>> *inputs) {
                                 [encoder setRenderPipelineState:imagePS];
                                 KKBindGLSLUniforms(encoder, &imgU, colorPool,
                                                    poolCount);
                                 KKBindCustomChannelTextures(
                                     encoder, imgTR, imgCh, srcSampler,
                                     noiseTex, chSampler);
                                 KKBindCustomNeighborTextures(
                                     encoder, imgTR, neighborTex, srcSampler,
                                     neighborFallback);
                                 [encoder drawPrimitives:
                                              MTLPrimitiveTypeTriangleStrip
                                             vertexStart:0
                                             vertexCount:4];
                               }];
    [cb commit];
    return encoded;
  }

  BOOL ok = [self
      encodeRenderCommandsForDestinationImage:destinationImage
                                 sourceImages:sourceImages
                                 commandQueue:frameQueue
                                        setup:imageSetupEncoded ? nil
                                                                : imageSetup
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
                                       KKBindCustomNeighborTextures(
                                           encoder, imgTR, neighborTex,
                                           srcSampler, neighborFallback);
                                       [encoder
                                           drawPrimitives:
                                               MTLPrimitiveTypeTriangleStrip
                                              vertexStart:0
                                              vertexCount:4];
                                     }];
  if (frameQueue && !chain.queue)
    [cache returnCommandQueueToCache:frameQueue];
  return ok;
}

@end
