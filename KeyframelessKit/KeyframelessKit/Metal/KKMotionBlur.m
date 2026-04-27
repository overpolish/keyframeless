/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKMotionBlur.h"
#import "../KKLog.h"
#import "../Plugin/KKConstants.h"
#import "KKMetalDeviceCache.h"
#import "KKShaderTypes.h"
#import <FxPlug/FxPlugSDK.h>

static NSString *const KKMotionBlurPipelineID =
    @"co.overpolish.keyframeless.kit.motionblur";

/// Reusable sample-texture pool. Keyed by (registryID, width, height,
/// pixelFormat) — re-allocates if any dimension changes. A single FxPlug
/// instance renders one tile size per render call so the cache stays warm
/// across frames; multi-instance with differing sizes will re-allocate
/// the first time each new size is seen.
static NSMutableDictionary<NSString *, NSMutableArray<id<MTLTexture>> *>
    *sKKMotionBlurPool;
static dispatch_semaphore_t sKKMotionBlurPoolLock;

/// Pool of plugin-private "scratch" textures used inside renderBlocks
/// (e.g. Glow's blur intermediates). Same key/lock conventions as the
/// sample-dest pool, but acquisitions are tracked per apply-call via a
/// thread-local context so we can return everything to the pool after
/// `waitUntilCompleted`. Reuse across frames keeps memory bounded.
static NSMutableDictionary<NSString *, NSMutableArray<id<MTLTexture>> *>
    *sKKMotionBlurScratchPool;
static dispatch_semaphore_t sKKMotionBlurScratchPoolLock;
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
    sKKMotionBlurPoolLock = dispatch_semaphore_create(1);
    sKKMotionBlurScratchPool = [NSMutableDictionary dictionary];
    sKKMotionBlurScratchPoolLock = dispatch_semaphore_create(1);
    sKKMotionBlurInFlightSema = dispatch_semaphore_create(1);
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
  }
  dispatch_semaphore_signal(sKKMotionBlurScratchPoolLock);
}

+ (KKMotionBlurState)snapshotStateWithParameterAPI:
                         (id<FxParameterRetrievalAPI_v6>)paramAPI
                                         timingAPI:(id<FxTimingAPI_v4>)timingAPI
                                            atTime:(CMTime)time {
  KKMotionBlurState state = {.enabled = false,
                             .transitionsOnly = false,
                             .sampleCount = 0,
                             .shutterSec = 0.0};
  if (!paramAPI)
    return state;

  BOOL enabled = NO;
  [paramAPI getBoolValue:&enabled
           fromParameter:kKKParamMotionBlurEnabled
                  atTime:time];
  if (!enabled)
    return state;

  BOOL transitionsOnly = NO;
  [paramAPI getBoolValue:&transitionsOnly
           fromParameter:kKKParamMotionBlurTransitionsOnly
                  atTime:time];
  state.transitionsOnly = transitionsOnly;

  double shutter = 0.5, quality = 0.5;
  [paramAPI getFloatValue:&shutter
            fromParameter:kKKParamMotionBlurShutter
                   atTime:time];
  [paramAPI getFloatValue:&quality
            fromParameter:kKKParamMotionBlurQuality
                   atTime:time];

  // Exponential mapping mirrors standalone MotionBlur: 0%→2, 50%→16,
  // 100%→128.
  int samples = MAX(2, (int)(2.0 * pow(64.0, quality)));
  if (samples > KK_MOTION_BLUR_MAX_SAMPLES)
    samples = KK_MOTION_BLUR_MAX_SAMPLES;

  CMTime frameDuration = kCMTimeZero;
  if (timingAPI)
    [timingAPI frameDuration:&frameDuration];
  double frameSec = CMTimeGetSeconds(frameDuration);
  double shutterAngle = shutter * 360.0;

  state.enabled = true;
  state.sampleCount = samples;
  state.shutterSec = frameSec * (shutterAngle / 360.0);
  return state;
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
    CMTime sampleTime = CMTimeSubtract(
        renderTime, CMTimeMakeWithSeconds(offsetSec, renderTime.timescale));
    if (CMTimeCompare(sampleTime, kCMTimeZero) < 0)
      sampleTime = kCMTimeZero;
    [times addObject:[NSValue valueWithBytes:&sampleTime
                                    objCType:@encode(CMTime)]];
  }
  return times;
}

+ (BOOL)applyToDestinationImage:(FxImageTile *)dest
                   sourceImages:(NSArray<FxImageTile *> *)sourceImages
                          state:(KKMotionBlurState)state
                     renderTime:(CMTime)renderTime
                    renderBlock:
                        (BOOL (^)(int, id<MTLTexture>, id<MTLCommandBuffer>,
                                  NSArray<id<MTLTexture>> *))renderBlock {
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

  NSArray<id<MTLTexture>> *samples =
      [self acquireSampleTextures:(NSUInteger)sampleCount
                           device:device
                       registryID:registryID
                            width:w
                           height:h
                           format:pixelFormat];
  if (samples.count != (NSUInteger)sampleCount) {
    KKLogError(@"KKMotionBlur: failed to acquire %d sample textures",
               sampleCount);
    [self returnSampleTextures:samples
                    registryID:registryID
                         width:w
                        height:h
                        format:pixelFormat];
    [cache returnCommandQueueToCache:queue];
    dispatch_semaphore_signal(sKKMotionBlurInFlightSema);
    return NO;
  }

  NSMutableArray<id<MTLTexture>> *inputTextures =
      [NSMutableArray arrayWithCapacity:sourceImages.count];
  for (FxImageTile *src in sourceImages) {
    id<MTLTexture> tex = [src metalTextureForDevice:device];
    if (tex)
      [inputTextures addObject:tex];
  }

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

      BOOL ok = renderBlock(i, samples[i], sampleBuffer, inputTextures);

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
                         width:w
                        height:h
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
                         width:w
                        height:h
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
                       width:w
                      height:h
                      format:pixelFormat];
  [cache returnCommandQueueToCache:queue];
  dispatch_semaphore_signal(sKKMotionBlurInFlightSema);
  return YES;
}

@end
