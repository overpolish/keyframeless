/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMotionBlur.h"
#import "../KKLog.h"
#import "../Plugin/KKConstants.h"
#import "../Plugin/KKDataBlob.h"
#import "KKMetalDeviceCache.h"
#import "KKShaderTypes.h"
#import <FxPlug/FxPlugSDK.h>

static NSString *const KKMotionBlurPipelineID =
    @"co.overpolish.keyframeless.kit.motionblur";

/// Reusable sample-texture pool. Keyed by (registryID, width, height,
/// pixelFormat). FCP renders the same effect at many tile sizes
/// (full-canvas, scopes, thumbnails, etc.), so distinct keys accumulate.
/// LRU-capped: when more than `kKKMotionBlurPoolMaxKeys` keys are seen,
/// the oldest key (and all its textures) is dropped — bounding memory
/// regardless of how many sizes FCP throws at us.
static NSMutableDictionary<NSString *, NSMutableArray<id<MTLTexture>> *>
    *sKKMotionBlurPool;
static NSMutableArray<NSString *> *sKKMotionBlurPoolLRU; // tail = most recent
static dispatch_semaphore_t sKKMotionBlurPoolLock;

/// Pool of plugin-private "scratch" textures used inside renderBlocks
/// (e.g. Glow's blur intermediates). Same key/lock conventions as the
/// sample-dest pool, including LRU cap.
static NSMutableDictionary<NSString *, NSMutableArray<id<MTLTexture>> *>
    *sKKMotionBlurScratchPool;
static NSMutableArray<NSString *> *sKKMotionBlurScratchPoolLRU;
static dispatch_semaphore_t sKKMotionBlurScratchPoolLock;

static const NSUInteger kKKMotionBlurPoolMaxKeys = 4;
static NSString *const kKKMotionBlurScratchContextThreadKey =
    @"co.overpolish.keyframeless.kit.motionblur.scratchContext";

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
/// `dict.count` past the cap, evict the oldest key — its textures are
/// released by ARC when the array goes out of scope. Caller holds the
/// pool lock.
static void KKMBPoolTouchAndEvict(NSString *key, NSMutableDictionary *dict,
                                  NSMutableArray<NSString *> *lru) {
  [lru removeObject:key];
  [lru addObject:key];
  while (lru.count > kKKMotionBlurPoolMaxKeys) {
    NSString *oldest = lru.firstObject;
    [lru removeObjectAtIndex:0];
    [dict removeObjectForKey:oldest];
  }
}

static NSString *KKMBScratchKey(NSString *key, NSUInteger width,
                                NSUInteger height, MTLPixelFormat format) {
  // sampleIndex deliberately omitted: per-sample commit means sample N's
  // scratch is fully released back to the pool before sample N+1 starts,
  // so all samples reuse the same physical texture for the same purpose.
  return
      [NSString stringWithFormat:@"%@/%lu/%lu/%lu", key, (unsigned long)width,
                                 (unsigned long)height, (unsigned long)format];
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

  (void)sampleIndex; // Reserved in API; not part of pool key under
                     // per-sample commit (samples reuse the same scratch).
  NSString *poolKey = KKMBScratchKey(key, width, height, format);
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
                          sKKMotionBlurScratchPoolLRU);
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
                          sKKMotionBlurScratchPoolLRU);
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
  return _kkMBState(shutterAngle / 360.0, samples, timingAPI);
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
  KKMBPoolTouchAndEvict(key, sKKMotionBlurPool, sKKMotionBlurPoolLRU);
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
  KKMBPoolTouchAndEvict(key, sKKMotionBlurPool, sKKMotionBlurPoolLRU);
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
  // Skip index 0 (== renderTime) — the plugin already requests the current
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

  id<MTLCommandQueue> queue = [cache commandQueueWithRegistryID:registryID
                                                    pixelFormat:pixelFormat];
  if (!queue) {
    dispatch_semaphore_signal(sKKMotionBlurInFlightSema);
    return NO;
  }
  id<MTLDevice> device = [cache deviceWithRegistryID:registryID];
  id<MTLTexture> destTexture = [dest metalTextureForDevice:device];
  if (!device || !destTexture) {
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
  // every sample resolves to it — unchanged behavior.
  NSArray<NSValue *> *sampleTimes = [self sampleTimesForState:state
                                                   renderTime:renderTime];

  // Per-sample commit + wait keeps peak intermediate-texture working set
  // bounded to one sample's worth (instead of all N alive simultaneously
  // on a shared command buffer). Sample-dest textures stay alive across
  // samples because the accumulation pass reads them all at the end.
  BOOL allOk = YES;
  for (int i = 0; i < sampleCount; i++) {
    @autoreleasepool {
      id<MTLCommandBuffer> sampleBuffer = [queue commandBuffer];
      sampleBuffer.label =
          [NSString stringWithFormat:@"KKMotionBlur sample %d", i];

      NSMutableDictionary<NSString *, id<MTLTexture>> *scratchCtx =
          [NSMutableDictionary dictionary];
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

      if (ok) {
        [sampleBuffer commit];
        [sampleBuffer waitUntilCompleted];
      } else {
        KKLogWarn(@"KKMotionBlur: renderBlock returned NO at sample %d", i);
        allOk = NO;
      }

      [self _returnScratchContextToPool:scratchCtx];
      [[NSThread currentThread].threadDictionary
          removeObjectForKey:kKKMotionBlurScratchContextThreadKey];

      if (!ok)
        break;
    }
  }

  if (!allOk) {
    [self returnSampleTextures:samples
                    registryID:registryID
                         width:sampleW
                        height:sampleH
                        format:pixelFormat];
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
    [self returnSampleTextures:samples
                    registryID:registryID
                         width:sampleW
                        height:sampleH
                        format:pixelFormat];
    [cache returnCommandQueueToCache:queue];
    dispatch_semaphore_signal(sKKMotionBlurInFlightSema);
    return NO;
  }

  // Accumulation runs on its own command buffer after all sample passes
  // have committed and completed.
  id<MTLCommandBuffer> accBuffer = [queue commandBuffer];
  accBuffer.label = @"KKMotionBlur accumulate";

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

  [accBuffer commit];
  [accBuffer waitUntilCompleted];

  [self returnSampleTextures:samples
                  registryID:registryID
                       width:sampleW
                      height:sampleH
                      format:pixelFormat];
  [cache returnCommandQueueToCache:queue];
  dispatch_semaphore_signal(sKKMotionBlurInFlightSema);
  return YES;
}

@end
