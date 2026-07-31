/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMotionBlur.h"
#import "KKConstants.h"
#import "KKDataBlob.h"
#import "KKLog.h"
#import "KKMetalDeviceCache.h"
#import "KKShaderTypes.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKTimingEvaluation.h>
#import <KeyframelessKit/KKTimeline.h>

static NSString *const KKMotionBlurPipelineID =
    @"com.keyframeless.kit.motionblur";

/// Reusable sample-texture pool. Keyed by (registryID, width, height,
/// pixelFormat). FCP renders the same effect at many tile sizes
/// (full-canvas, scopes, thumbnails, etc.), so distinct keys accumulate.
/// LRU-capped: when more than `kKKMotionBlurPoolMaxKeys` keys are seen,
/// the oldest key (and all its textures) is dropped - bounding memory
/// regardless of how many sizes FCP throws at us.
static NSMutableDictionary<NSString *, NSMutableArray<id<MTLTexture>> *>
    *sKKMotionBlurPool;
static NSMutableArray<NSString *> *sKKMotionBlurPoolLRU; // tail = most recent
static dispatch_semaphore_t sKKMotionBlurPoolLock;

/// Pool of plugin-private "scratch" textures used inside renderBlocks
/// (e.g. blur intermediates). Same key/lock conventions as the
/// sample-dest pool, including LRU cap.
static NSMutableDictionary<NSString *, NSMutableArray<id<MTLTexture>> *>
    *sKKMotionBlurScratchPool;
static NSMutableArray<NSString *> *sKKMotionBlurScratchPoolLRU;
static dispatch_semaphore_t sKKMotionBlurScratchPoolLock;

static const NSUInteger kKKMotionBlurPoolMaxKeys = 4;
/// The scratch pool keys per SAMPLE as well as per size, so its cap has to
/// leave room for a full sample set at each tracked size or the LRU would evict
/// a texture the very next sample asks for.
static const NSUInteger kKKMotionBlurScratchPoolMaxKeys =
    kKKMotionBlurPoolMaxKeys * KK_MOTION_BLUR_MAX_SAMPLES;
static NSString *const kKKMotionBlurScratchContextThreadKey =
    @"com.keyframeless.kit.motionblur.scratchContext";

/// Caps concurrent in-flight `applyToDestinationImage:` calls to one.
/// FCP look-ahead can otherwise queue 3-5 frames in parallel, multiplying
/// peak GPU memory by that factor. Serializing keeps total working set
/// bounded to a single render's peak.
static dispatch_semaphore_t sKKMotionBlurInFlightSema;

@implementation KKMotionBlur

+ (void)initialize {
  if (self == [KKMotionBlur class]) {
    sKKMotionBlurPool = [NSMutableDictionary dictionary];
    sKKMotionBlurPoolLRU = [NSMutableArray array];
    sKKMotionBlurPoolLock = dispatch_semaphore_create(1);
    sKKMotionBlurScratchPool = [NSMutableDictionary dictionary];
    sKKMotionBlurScratchPoolLRU = [NSMutableArray array];
    sKKMotionBlurScratchPoolLock = dispatch_semaphore_create(1);
    sKKMotionBlurInFlightSema = dispatch_semaphore_create(1);
  }
}

/// Move `key` to the most-recent end of `lru`. If adding the key pushes
/// `dict.count` past the cap, evict the oldest key - its textures are
/// released by ARC when the array goes out of scope. Caller holds the
/// pool lock.
static void KKMBPoolTouchAndEvict(NSString *key, NSMutableDictionary *dict,
                                  NSMutableArray<NSString *> *lru,
                                  NSUInteger maxKeys) {
  [lru removeObject:key];
  [lru addObject:key];
  while (lru.count > maxKeys) {
    NSString *oldest = lru.firstObject;
    [lru removeObjectAtIndex:0];
    [dict removeObjectForKey:oldest];
  }
}

static NSString *KKMBScratchKey(NSString *key, int sampleIndex,
                                NSUInteger width, NSUInteger height,
                                MTLPixelFormat format) {
  // sampleIndex IS part of the key. All samples share one command buffer now,
  // so sample N's scratch is still being read when sample N+1 encodes: they
  // must not be handed the same physical texture. Distinct keys give each
  // sample its own slot, still pooled and reused across frames.
  return [NSString
      stringWithFormat:@"%@/%d/%lu/%lu/%lu", key, sampleIndex,
                       (unsigned long)width, (unsigned long)height,
                       (unsigned long)format];
}

+ (id<MTLTexture>)scratchTextureForKey:(NSString *)key
                           sampleIndex:(int)sampleIndex
                                 width:(NSUInteger)width
                                height:(NSUInteger)height
                                format:(MTLPixelFormat)format
                                 usage:(MTLTextureUsage)usage
                                device:(id<MTLDevice>)device {
  NSMutableDictionary<NSString *, id<MTLTexture>> *ctx =
      [NSThread currentThread]
          .threadDictionary[kKKMotionBlurScratchContextThreadKey];
  if (!ctx || !device)
    return nil;

  NSString *poolKey = KKMBScratchKey(key, sampleIndex, width, height, format);
  // Idempotent within a single apply call.
  id<MTLTexture> existing = ctx[poolKey];
  if (existing)
    return existing;

  // Try the shared pool first.
  id<MTLTexture> reused = nil;
  dispatch_semaphore_wait(sKKMotionBlurScratchPoolLock, DISPATCH_TIME_FOREVER);
  NSMutableArray<id<MTLTexture>> *available = sKKMotionBlurScratchPool[poolKey];
  if (available.count > 0) {
    reused = available.lastObject;
    [available removeLastObject];
    KKMBPoolTouchAndEvict(poolKey, sKKMotionBlurScratchPool,
                          sKKMotionBlurScratchPoolLRU,
                          kKKMotionBlurScratchPoolMaxKeys);
  }
  dispatch_semaphore_signal(sKKMotionBlurScratchPoolLock);

  if (reused) {
    ctx[poolKey] = reused;
    return reused;
  }

  // Allocate fresh. Caller specifies usage so this works for any
  // intermediate (render targets, MPS sources, etc.).
  MTLTextureDescriptor *desc =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                         width:width
                                                        height:height
                                                     mipmapped:NO];
  desc.usage = usage;
  desc.storageMode = MTLStorageModePrivate;
  id<MTLTexture> tex = [device newTextureWithDescriptor:desc];
  if (tex)
    ctx[poolKey] = tex;
  return tex;
}

+ (void)_returnScratchContextToPool:
    (NSMutableDictionary<NSString *, id<MTLTexture>> *)ctx {
  if (ctx.count == 0)
    return;
  dispatch_semaphore_wait(sKKMotionBlurScratchPoolLock, DISPATCH_TIME_FOREVER);
  for (NSString *poolKey in ctx) {
    NSMutableArray<id<MTLTexture>> *available =
        sKKMotionBlurScratchPool[poolKey];
    if (!available) {
      available = [NSMutableArray array];
      sKKMotionBlurScratchPool[poolKey] = available;
    }
    [available addObject:ctx[poolKey]];
    KKMBPoolTouchAndEvict(poolKey, sKKMotionBlurScratchPool,
                          sKKMotionBlurScratchPoolLRU,
                          kKKMotionBlurScratchPoolMaxKeys);
  }
  dispatch_semaphore_signal(sKKMotionBlurScratchPoolLock);
}

// Maps a shutter fraction (0–1 = shutter angle / 360°) + explicit sample count
// to a snapshot. Sample count is clamped here.
static KKMotionBlurState _kkMBState(double shutterFraction, int sampleCount,
                                    id<FxTimingAPI_v4> timingAPI) {
  KKMotionBlurState state = {
      .enabled = true, .sampleCount = 0, .shutterSec = 0.0};

  int samples = MAX(2, sampleCount);
  if (samples > KK_MOTION_BLUR_MAX_SAMPLES)
    samples = KK_MOTION_BLUR_MAX_SAMPLES;

  CMTime frameDuration = kCMTimeZero;
  if (timingAPI)
    [timingAPI frameDuration:&frameDuration];
  double frameSec = CMTimeGetSeconds(frameDuration);

  state.sampleCount = samples;
  state.shutterSec = frameSec * shutterFraction;
  return state;
}

+ (KKMotionBlurState)snapshotStateFromJSON:(NSString *)json
                                 timingAPI:(id<FxTimingAPI_v4>)timingAPI
                                    atTime:(CMTime)time {
  KKMotionBlurState disabled = {
      .enabled = false, .sampleCount = 0, .shutterSec = 0.0};
  if (!json.length)
    return disabled;

  NSDictionary *dict = [NSJSONSerialization
      JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                 options:0
                   error:nil];
  if (![dict isKindOfClass:[NSDictionary class]] ||
      ![dict[@"enabled"] boolValue])
    return disabled;

  // Custom-UI blob stores meaningful units: shutter angle in degrees (0–360,
  // default 180) and an explicit sample count (default 16).
  double shutterAngle =
      dict[@"shutterAngle"] ? [dict[@"shutterAngle"] doubleValue] : 180.0;
  int samples = dict[@"samples"] ? [dict[@"samples"] intValue] : 16;
  KKMotionBlurState state =
      _kkMBState(shutterAngle / 360.0, samples, timingAPI);

  // Technique (Fast/Accurate). Migrate a legacy blob that only has the old
  // when-to-fire `mode`: the old "Always" (2) was the footage-smear case, which
  // is Accurate; everything else maps to Fast.
  KKMotionBlurTechnique technique = KKMotionBlurTechniqueFast;
  if (dict[@"technique"]) {
    int t = [dict[@"technique"] intValue];
    technique = (t == KKMotionBlurTechniqueAccurate)
                    ? KKMotionBlurTechniqueAccurate
                    : KKMotionBlurTechniqueFast;
  } else if (dict[@"mode"]) {
    technique = ([dict[@"mode"] intValue] == KKMotionBlurModeAlways)
                    ? KKMotionBlurTechniqueAccurate
                    : KKMotionBlurTechniqueFast;
  }
  state.technique = technique;
  // Derive the internal when-to-fire gate from the technique: Fast skips fully
  // static frames (per-layer still-skip handles the rest); Accurate blurs every
  // frame so moving footage smears (and requests sub-frame source frames).
  state.mode = (technique == KKMotionBlurTechniqueAccurate)
                   ? KKMotionBlurModeAlways
                   : KKMotionBlurModeValueChanging;
  return state;
}

+ (BOOL)frameShouldBlurForMode:(KKMotionBlurMode)mode
                      timeline:(KKTimeline *)timeline
                     fracStart:(double)fracStart
                       fracEnd:(double)fracEnd {
  if (mode == KKMotionBlurModeAlways)
    return YES;
  if (!timeline.lanes.count)
    return YES;

  double lo = MIN(fracStart, fracEnd);
  double hi = MAX(fracStart, fracEnd);
  // Movement smaller than this is below sub-pixel and not worth a multi-pass.
  static const double kMoveEps = 1e-4;

  if (mode == KKMotionBlurModeValueChanging) {
    for (KKLane *lane in timeline.lanes) {
      NSArray<NSNumber *> *a =
          KKLaneDisplayValueAtFraction(lane, lo);
      NSArray<NSNumber *> *b =
          KKLaneDisplayValueAtFraction(lane, hi);
      NSUInteger n = MIN(a.count, b.count);
      for (NSUInteger i = 0; i < n; i++)
        if (fabs(a[i].doubleValue - b[i].doubleValue) > kMoveEps)
          return YES;
    }
    return NO;
  }

  // TransitionsOnly: structural - any keypose interval overlapping the window
  // whose endpoint values differ is a real transition. Modulation lives on the
  // interval but never changes its endpoints, so a modulated hold (equal
  // endpoints) is correctly excluded.
  for (KKLane *lane in timeline.lanes) {
    NSArray<KKKeyPose *> *kps = lane.keyposes;
    for (NSUInteger i = 0; i + 1 < kps.count; i++) {
      KKKeyPose *p = kps[i];
      KKKeyPose *q = kps[i + 1];
      if (q.time <= lo || p.time >= hi)
        continue; // interval doesn't overlap the shutter window
      NSUInteger n = MIN(p.values.count, q.values.count);
      for (NSUInteger c = 0; c < n; c++)
        if (fabs(p.values[c].doubleValue - q.values[c].doubleValue) > kMoveEps)
          return YES;
    }
  }
  return NO;
}

+ (NSString *)poolKeyForRegistryID:(uint64_t)registryID
                             width:(NSUInteger)width
                            height:(NSUInteger)height
                            format:(MTLPixelFormat)format {
  return [NSString stringWithFormat:@"%llu/%lu/%lu/%lu",
                                    (unsigned long long)registryID,
                                    (unsigned long)width, (unsigned long)height,
                                    (unsigned long)format];
}

+ (NSArray<id<MTLTexture>> *)acquireSampleTextures:(NSUInteger)count
                                            device:(id<MTLDevice>)device
                                        registryID:(uint64_t)registryID
                                             width:(NSUInteger)width
                                            height:(NSUInteger)height
                                            format:(MTLPixelFormat)format {
  NSString *key = [self poolKeyForRegistryID:registryID
                                       width:width
                                      height:height
                                      format:format];
  NSMutableArray<id<MTLTexture>> *result =
      [NSMutableArray arrayWithCapacity:count];

  dispatch_semaphore_wait(sKKMotionBlurPoolLock, DISPATCH_TIME_FOREVER);
  NSMutableArray<id<MTLTexture>> *available = sKKMotionBlurPool[key];
  if (!available) {
    available = [NSMutableArray array];
    sKKMotionBlurPool[key] = available;
  }
  while (result.count < count && available.count > 0) {
    [result addObject:available.lastObject];
    [available removeLastObject];
  }
  KKMBPoolTouchAndEvict(key, sKKMotionBlurPool, sKKMotionBlurPoolLRU,
                        kKKMotionBlurPoolMaxKeys);
  dispatch_semaphore_signal(sKKMotionBlurPoolLock);

  while (result.count < count) {
    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> tex = [device newTextureWithDescriptor:td];
    if (!tex)
      break;
    [result addObject:tex];
  }
  return result;
}

+ (void)returnSampleTextures:(NSArray<id<MTLTexture>> *)textures
                  registryID:(uint64_t)registryID
                       width:(NSUInteger)width
                      height:(NSUInteger)height
                      format:(MTLPixelFormat)format {
  if (textures.count == 0)
    return;
  NSString *key = [self poolKeyForRegistryID:registryID
                                       width:width
                                      height:height
                                      format:format];
  dispatch_semaphore_wait(sKKMotionBlurPoolLock, DISPATCH_TIME_FOREVER);
  NSMutableArray<id<MTLTexture>> *available = sKKMotionBlurPool[key];
  if (!available) {
    available = [NSMutableArray array];
    sKKMotionBlurPool[key] = available;
  }
  [available addObjectsFromArray:textures];
  KKMBPoolTouchAndEvict(key, sKKMotionBlurPool, sKKMotionBlurPoolLRU,
                        kKKMotionBlurPoolMaxKeys);
  dispatch_semaphore_signal(sKKMotionBlurPoolLock);
}

+ (NSArray<NSValue *> *)sampleTimesForState:(KKMotionBlurState)state
                                 renderTime:(CMTime)renderTime {
  if (!state.enabled || state.sampleCount < 2)
    return @[];
  int n = state.sampleCount;
  if (n > KK_MOTION_BLUR_MAX_SAMPLES)
    n = KK_MOTION_BLUR_MAX_SAMPLES;
  NSMutableArray<NSValue *> *times = [NSMutableArray arrayWithCapacity:n];
  for (int i = 0; i < n; i++) {
    double t = (double)i / (double)(n - 1);
    double offsetSec = state.shutterSec * t;
    // Build the sub-frame offset in a fixed high timescale, NOT
    // renderTime.timescale: FCP delivers varying (sometimes low) timescales
    // during playback, and a sub-frame offset rounds to 0 at low timescale →
    // samples collapse onto renderTime → blur flickers off frame-to-frame.
    CMTime sampleTime =
        CMTimeSubtract(renderTime, CMTimeMakeWithSeconds(offsetSec, 90000));
    if (CMTimeCompare(sampleTime, kCMTimeZero) < 0)
      sampleTime = kCMTimeZero;
    [times addObject:[NSValue valueWithBytes:&sampleTime
                                    objCType:@encode(CMTime)]];
  }
  return times;
}

+ (void)appendSourceRequestsForState:(KKMotionBlurState)state
                          renderTime:(CMTime)renderTime
                                  to:(NSMutableArray<FxImageTileRequest *> *)
                                         requests
                             builder:(FxImageTileRequest * (^)(CMTime))builder {
  if (!state.enabled || !builder || !requests)
    return;
  NSArray<NSValue *> *times = [self sampleTimesForState:state
                                             renderTime:renderTime];
  // Skip index 0 (== renderTime) - the plugin already requests the current
  // frame in its own scheduleInputs:.
  for (NSUInteger i = 1; i < times.count; i++) {
    CMTime t = kCMTimeZero;
    [times[i] getValue:&t];
    FxImageTileRequest *r = builder(t);
    if (r)
      [requests addObject:r];
  }
}

+ (BOOL)applyToDestinationImage:(FxImageTile *)dest
                   sourceImages:(NSArray<FxImageTile *> *)sourceImages
                          state:(KKMotionBlurState)state
                     renderTime:(CMTime)renderTime
                    renderBlock:
                        (BOOL (^)(int, id<MTLTexture>, id<MTLCommandBuffer>,
                                  NSArray<id<MTLTexture>> *))renderBlock {
  return [self applyToDestinationImage:dest
                          sourceImages:sourceImages
                                 state:state
                            renderTime:renderTime
                          commandQueue:nil
                           renderBlock:renderBlock];
}

+ (BOOL)applyToDestinationImage:(FxImageTile *)dest
                   sourceImages:(NSArray<FxImageTile *> *)sourceImages
                          state:(KKMotionBlurState)state
                     renderTime:(CMTime)renderTime
                   commandQueue:(id<MTLCommandQueue>)suppliedQueue
                    renderBlock:
                        (BOOL (^)(int, id<MTLTexture>, id<MTLCommandBuffer>,
                                  NSArray<id<MTLTexture>> *))renderBlock {
  (void)renderTime;
  if (!state.enabled)
    return NO;
  if (!dest || !renderBlock)
    return NO;

  // Cap concurrent in-flight motion-blur renders to one. FCP look-ahead
  // can otherwise multiply peak GPU memory by the number of pre-rendered
  // frames in flight. Released at every subsequent return path below.
  dispatch_semaphore_wait(sKKMotionBlurInFlightSema, DISPATCH_TIME_FOREVER);

  int sampleCount = state.sampleCount;
  if (sampleCount < 2)
    sampleCount = 2;
  if (sampleCount > KK_MOTION_BLUR_MAX_SAMPLES)
    sampleCount = KK_MOTION_BLUR_MAX_SAMPLES;

  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  MTLPixelFormat pixelFormat =
      [KKMetalDeviceCache pixelFormatForImageTile:dest];
  uint64_t registryID = dest.deviceRegistryID;

  id<MTLCommandQueue> queue =
      suppliedQueue ?: [cache commandQueueWithRegistryID:registryID
                                             pixelFormat:pixelFormat];
  if (!queue) {
    dispatch_semaphore_signal(sKKMotionBlurInFlightSema);
    return NO;
  }
  id<MTLDevice> device = [cache deviceWithRegistryID:registryID];
  id<MTLTexture> destTexture = [dest metalTextureForDevice:device];
  if (!device || !destTexture) {
    if (!suppliedQueue)
      [cache returnCommandQueueToCache:queue];
    dispatch_semaphore_signal(sKKMotionBlurInFlightSema);
    return NO;
  }

  NSUInteger w = destTexture.width;
  NSUInteger h = destTexture.height;
  NSUInteger sampleW = w;
  NSUInteger sampleH = h;

  NSArray<id<MTLTexture>> *samples =
      [self acquireSampleTextures:(NSUInteger)sampleCount
                           device:device
                       registryID:registryID
                            width:sampleW
                           height:sampleH
                           format:pixelFormat];
  if (samples.count != (NSUInteger)sampleCount) {
    KKLogError(@"KKMotionBlur: failed to acquire %d sample textures",
               sampleCount);
    [self returnSampleTextures:samples
                    registryID:registryID
                         width:sampleW
                        height:sampleH
                        format:pixelFormat];
    if (!suppliedQueue)
      [cache returnCommandQueueToCache:queue];
    dispatch_semaphore_signal(sKKMotionBlurInFlightSema);
    return NO;
  }

  NSMutableArray<id<MTLTexture>> *inputTextures =
      [NSMutableArray arrayWithCapacity:sourceImages.count];
  NSMutableArray<NSNumber *> *inputMediaSecs =
      [NSMutableArray arrayWithCapacity:sourceImages.count];
  for (FxImageTile *src in sourceImages) {
    id<MTLTexture> tex = [src metalTextureForDevice:device];
    if (tex) {
      [inputTextures addObject:tex];
      [inputMediaSecs addObject:@(CMTimeGetSeconds(src.mediaTime))];
    }
  }

  // Per-sample source selection (REAL motion blur): if the plugin requested
  // the source at each sub-frame time (via -sampleInputRequestsForState:), FCP
  // delivers multiple frames here. FCP does NOT honor request order, so match
  // each sample to the delivered tile whose mediaTime is nearest the sample's
  // time. When only the current frame was delivered (parameter-only blur),
  // every sample resolves to it - unchanged behavior.
  NSArray<NSValue *> *sampleTimes = [self sampleTimesForState:state
                                                   renderTime:renderTime];

  // ONE command buffer for every sample AND the accumulate, committed once and
  // waited on once. It used to be a commit + waitUntilCompleted per sample plus
  // one for the accumulate: N+1 blocking round trips per frame, whose cost is
  // queue-depth latency rather than GPU time - measured at 12-32ms of callback
  // against ~1ms of actual GPU work.
  //
  // The per-sample wait bounded only the SCRATCH working set, not the sample
  // destinations: -acquireSampleTextures: allocates all N up front and the
  // accumulate reads them all at the end, so those were always simultaneously
  // live. Scratch is returned to the pool from the completion handler instead,
  // and no batching is needed - see the note there for the arithmetic.
  id<MTLCommandBuffer> blurBuffer = [queue commandBuffer];
  blurBuffer.label = @"KKMotionBlur";
  NSMutableArray<NSMutableDictionary<NSString *, id<MTLTexture>> *>
      *scratchContexts = [NSMutableArray arrayWithCapacity:sampleCount];

  BOOL allOk = YES;
  for (int i = 0; i < sampleCount; i++) {
    @autoreleasepool {
      id<MTLCommandBuffer> sampleBuffer = blurBuffer;

      NSMutableDictionary<NSString *, id<MTLTexture>> *scratchCtx =
          [NSMutableDictionary dictionary];
      [scratchContexts addObject:scratchCtx];
      [NSThread currentThread]
          .threadDictionary[kKKMotionBlurScratchContextThreadKey] = scratchCtx;

      // Resolve this sample's source: nearest delivered tile by mediaTime,
      // surfaced at index 0 (plugins read inputTextures[0]). Falls back to the
      // existing array untouched when there's only one source.
      NSArray<id<MTLTexture>> *sampleInputs = inputTextures;
      if (inputTextures.count > 1 && i < (int)sampleTimes.count) {
        CMTime st = kCMTimeZero;
        [sampleTimes[i] getValue:&st];
        double want = CMTimeGetSeconds(st);
        NSUInteger best = 0;
        double bestDt = INFINITY;
        for (NSUInteger k = 0; k < inputMediaSecs.count; k++) {
          double dt = fabs(inputMediaSecs[k].doubleValue - want);
          if (dt < bestDt) {
            bestDt = dt;
            best = k;
          }
        }
        if (best != 0) {
          NSMutableArray<id<MTLTexture>> *reordered =
              [inputTextures mutableCopy];
          reordered[0] = inputTextures[best];
          sampleInputs = reordered;
        }
      }

      BOOL ok = renderBlock(i, samples[i], sampleBuffer, sampleInputs);

      if (!ok) {
        KKLogWarn(@"KKMotionBlur: renderBlock returned NO at sample %d", i);
        allOk = NO;
      }

      // The scratch context is only consulted while ENCODING, so it comes off
      // the thread here as before. Returning its textures to the shared pool,
      // though, has to wait for the GPU - see the completion handler.
      [[NSThread currentThread].threadDictionary
          removeObjectForKey:kKKMotionBlurScratchContextThreadKey];

      if (!ok)
        break;
    }
  }

  // Bail-out paths abandon `blurBuffer` without committing it, so nothing is in
  // flight and the scratch textures can go back to the pool immediately.
  void (^returnScratchNow)(void) = ^{
    for (NSMutableDictionary<NSString *, id<MTLTexture>> *ctx in scratchContexts)
      [KKMotionBlur _returnScratchContextToPool:ctx];
  };

  if (!allOk) {
    returnScratchNow();
    [self returnSampleTextures:samples
                    registryID:registryID
                         width:sampleW
                        height:sampleH
                        format:pixelFormat];
    if (!suppliedQueue)
      [cache returnCommandQueueToCache:queue];
    dispatch_semaphore_signal(sKKMotionBlurInFlightSema);
    return NO;
  }

  NSString *bundleID = [NSBundle bundleForClass:self].bundleIdentifier;
  id<MTLRenderPipelineState> accPipeline = [cache
      buildAndRegisterPipelineStateForPluginID:KKMotionBlurPipelineID
                                    registryID:registryID
                                   pixelFormat:pixelFormat
                                      bundleID:bundleID
                                  vertexShader:@"KKVertexShader"
                                fragmentShader:@"KKMotionBlurAccumulateFragment"
                                     blendMode:KKBlendModePremultipliedAlpha];
  if (!accPipeline) {
    returnScratchNow();
    [self returnSampleTextures:samples
                    registryID:registryID
                         width:sampleW
                        height:sampleH
                        format:pixelFormat];
    if (!suppliedQueue)
      [cache returnCommandQueueToCache:queue];
    dispatch_semaphore_signal(sKKMotionBlurInFlightSema);
    return NO;
  }

  // Accumulation is the LAST pass on the same buffer as the samples. Metal runs
  // a buffer's render passes in encode order and hazard-tracks the sample
  // textures it reads, so it still sees every completed sample - the ordering
  // the old per-sample wait provided is structural here.
  id<MTLCommandBuffer> accBuffer = blurBuffer;

  MTLRenderPassColorAttachmentDescriptor *colorAttachment =
      [[MTLRenderPassColorAttachmentDescriptor alloc] init];
  colorAttachment.texture = destTexture;
  colorAttachment.clearColor = MTLClearColorMake(0, 0, 0, 0);
  colorAttachment.loadAction = MTLLoadActionClear;

  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0] = colorAttachment;

  id<MTLRenderCommandEncoder> encoder =
      [accBuffer renderCommandEncoderWithDescriptor:rpd];

  float dw = (float)w, dh = (float)h;
  MTLViewport viewport = {0, 0, dw, dh, -1.0, 1.0};
  [encoder setViewport:viewport];

  KKVertex2D vertices[] = {
      {{dw / 2.0f, -dh / 2.0f}, {1.0, 1.0}},
      {{-dw / 2.0f, -dh / 2.0f}, {0.0, 1.0}},
      {{dw / 2.0f, dh / 2.0f}, {1.0, 0.0}},
      {{-dw / 2.0f, dh / 2.0f}, {0.0, 0.0}},
  };
  simd_uint2 viewportSize = {(unsigned int)dw, (unsigned int)dh};
  [encoder setVertexBytes:vertices
                   length:sizeof(vertices)
                  atIndex:KKVertexInputIndex_Vertices];
  [encoder setVertexBytes:&viewportSize
                   length:sizeof(viewportSize)
                  atIndex:KKVertexInputIndex_ViewportSize];

  [encoder setRenderPipelineState:accPipeline];
  for (NSUInteger i = 0; i < samples.count; i++) {
    [encoder setFragmentTexture:samples[i] atIndex:i];
  }
  int sc = sampleCount;
  [encoder setFragmentBytes:&sc length:sizeof(sc) atIndex:0];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
              vertexStart:0
              vertexCount:4];
  [encoder endEncoding];

  // Scratch goes back to the pool only once the GPU is done with it. Returning
  // it synchronously (which the per-sample wait used to make safe) would let the
  // next sample - or the next frame - pull the same physical texture out of the
  // pool while this buffer still reads it.
  //
  // Peak cost of holding it this long: the sample DESTINATIONS are unchanged,
  // already N x W x H x 8 bytes for RGBA16F (4 samples at 1920x1080 = 66MB) and
  // always simultaneously live. Only scratch changes, from one set to N. Every
  // caller in this repo allocates ZERO scratch - `scratchTextureForKey:` has no
  // call sites - so the measured increase is 0 bytes and batching would buy
  // nothing. A future caller that does use scratch pays N sets at its own size;
  // if that ever bites, encode in batches of K with a wait between them, which
  // still divides the round trips by K.
  NSArray<NSMutableDictionary<NSString *, id<MTLTexture>> *> *ctxs =
      [scratchContexts copy];
  [blurBuffer addCompletedHandler:^(id<MTLCommandBuffer> done) {
    for (NSMutableDictionary<NSString *, id<MTLTexture>> *ctx in ctxs)
      [KKMotionBlur _returnScratchContextToPool:ctx];
  }];

  [accBuffer commit];
  [accBuffer waitUntilCompleted];

  [self returnSampleTextures:samples
                  registryID:registryID
                       width:sampleW
                      height:sampleH
                      format:pixelFormat];
  if (!suppliedQueue)
      [cache returnCommandQueueToCache:queue];
  dispatch_semaphore_signal(sKKMotionBlurInFlightSema);
  return YES;
}

@end
