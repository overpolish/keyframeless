/* SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "RenderSupport.h"
#import "RenderSupportTypes.h"
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <dispatch/dispatch.h>
#import <math.h>

static const NSUInteger kMaxQueues = 5, kMaxPoolKeys = 4;
static NSMutableDictionary<NSNumber *, NSMutableArray<id<MTLCommandQueue>> *>
    *sQueues;
static NSMutableDictionary<NSString *, NSMutableArray<id<MTLTexture>> *>
    *sTextures;
static NSMutableSet<id<MTLCommandQueue>> *sBusyQueues;
static NSMutableArray<NSString *> *sTextureLRU;
static dispatch_semaphore_t sLock, sInFlight;
static dispatch_once_t sOnce;

static void InitializePools(void) {
  dispatch_once(&sOnce, ^{
    sQueues = [NSMutableDictionary dictionary];
    sTextures = [NSMutableDictionary dictionary];
    sBusyQueues = [NSMutableSet set];
    sTextureLRU = [NSMutableArray array];
    sLock = dispatch_semaphore_create(1);
    sInFlight = dispatch_semaphore_create(1);
  });
}

NSArray<NSValue *> *RSRenderBlurSampleTimes(RSRenderBlurState state,
                                            CMTime time) {
  if (!state.enabled || state.sampleCount < 2 || !CMTIME_IS_NUMERIC(time) ||
      !isfinite(state.shutterSec) || state.shutterSec < 0)
    return @[];
  int n = MIN(MAX(state.sampleCount, 2), RS_RENDER_BLUR_MAX_SAMPLES);
  NSMutableArray *out = [NSMutableArray arrayWithCapacity:n];
  for (int i = 0; i < n; i++) {
    CMTime t = CMTimeSubtract(
        time, CMTimeMakeWithSeconds(state.shutterSec * i / (n - 1), 90000));
    if (CMTimeCompare(t, kCMTimeZero) < 0)
      t = kCMTimeZero;
    [out addObject:[NSValue valueWithBytes:&t objCType:@encode(CMTime)]];
  }
  return out;
}

id<MTLTexture> RSRenderBlurredTexture(id<MTLTexture> source, float pixels,
                                      id<MTLCommandBuffer> cb) {
  if (!source || !cb || !isfinite(pixels) || pixels < .5f)
    return source;
  MTLTextureDescriptor *d = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:source.pixelFormat
                                   width:source.width
                                  height:source.height
                               mipmapped:NO];
  d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite |
            MTLTextureUsageRenderTarget;
  d.storageMode = MTLStorageModePrivate;
  id<MTLTexture> out = [source.device newTextureWithDescriptor:d];
  if (!out)
    return source;
  MPSImageGaussianBlur *b =
      [[MPSImageGaussianBlur alloc] initWithDevice:source.device
                                             sigma:fminf(pixels, 256)];
  b.edgeMode = MPSImageEdgeModeClamp;
  [b encodeToCommandBuffer:cb sourceTexture:source destinationTexture:out];
  return out;
}
static NSString *TextureKey(id<MTLDevice> d, NSUInteger w, NSUInteger h,
                            MTLPixelFormat f) {
  return [NSString stringWithFormat:@"%llu/%lu/%lu/%lu", d.registryID, w, h, f];
}
static void TouchTextureKey(NSString *k) {
  [sTextureLRU removeObject:k];
  [sTextureLRU addObject:k];
  while (sTextureLRU.count > kMaxPoolKeys) {
    [sTextures removeObjectForKey:sTextureLRU.firstObject];
    [sTextureLRU removeObjectAtIndex:0];
  }
}
id<MTLCommandQueue> RSRenderCheckoutQueue(id<MTLDevice> d) {
  if (!d)
    return nil;
  InitializePools();
  dispatch_semaphore_wait(sLock, DISPATCH_TIME_FOREVER);
  NSNumber *k = @(d.registryID);
  NSMutableArray *q = sQueues[k];
  if (!q) {
    q = [NSMutableArray array];
    for (NSUInteger i = 0; i < kMaxQueues; i++) {
      id<MTLCommandQueue> x = [d newCommandQueue];
      if (x)
        [q addObject:x];
    }
    sQueues[k] = q;
  }
  id<MTLCommandQueue> r = nil;
  for (id<MTLCommandQueue> x in q)
    if (![sBusyQueues containsObject:x]) {
      [sBusyQueues addObject:x];
      r = x;
      break;
    }
  dispatch_semaphore_signal(sLock);
  return r;
}
void RSRenderReturnQueue(id<MTLCommandQueue> q) {
  if (!q)
    return;
  InitializePools();
  dispatch_semaphore_wait(sLock, DISPATCH_TIME_FOREVER);
  [sBusyQueues removeObject:q];
  dispatch_semaphore_signal(sLock);
}
static id<MTLTexture> CheckoutTexture(id<MTLDevice> d, NSUInteger w,
                                      NSUInteger h, MTLPixelFormat f) {
  NSString *k = TextureKey(d, w, h, f);
  dispatch_semaphore_wait(sLock, DISPATCH_TIME_FOREVER);
  NSMutableArray *a = sTextures[k];
  id<MTLTexture> t = a.lastObject;
  if (t)
    [a removeLastObject];
  if (t)
    TouchTextureKey(k);
  dispatch_semaphore_signal(sLock);
  if (t)
    return t;
  MTLTextureDescriptor *x =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f
                                                         width:w
                                                        height:h
                                                     mipmapped:NO];
  x.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  x.storageMode = MTLStorageModePrivate;
  return [d newTextureWithDescriptor:x];
}
static void ReturnTextures(NSArray *a) {
  if (!a.count)
    return;
  id<MTLTexture> t = a[0];
  NSString *k = TextureKey(t.device, t.width, t.height, t.pixelFormat);
  dispatch_semaphore_wait(sLock, DISPATCH_TIME_FOREVER);
  NSMutableArray *v = sTextures[k] ?: (sTextures[k] = [NSMutableArray array]);
  [v addObjectsFromArray:a];
  TouchTextureKey(k);
  dispatch_semaphore_signal(sLock);
}

// Adapted from KKMotionBlur's accurate path. Keep a single in-flight blur to
// bound FCP look-ahead memory, and submit all samples plus accumulation once.
BOOL RSRenderApplyBlur(id<MTLTexture> destination,
                       NSArray<id<MTLTexture>> *sources,
                       RSRenderBlurState state, CMTime renderTime,
                       id<MTLRenderPipelineState> pipeline,
                       BOOL (^block)(int, id<MTLTexture>, id<MTLCommandBuffer>,
                                     NSArray<id<MTLTexture>> *)) {
  // The host adapter evaluates sample times before this GPU pass.
  (void)renderTime;
  if (!state.enabled || !destination || !pipeline || !block ||
      sources.count == 0)
    return NO;
  InitializePools();
  dispatch_semaphore_wait(sInFlight, DISPATCH_TIME_FOREVER);
  id<MTLCommandQueue> queue = nil;
  NSMutableArray<id<MTLTexture>> *samples = [NSMutableArray array];
  @try {
    queue = RSRenderCheckoutQueue(destination.device);
    if (!queue)
      return NO;
    int count = MIN(MAX(state.sampleCount, 2), RS_RENDER_BLUR_MAX_SAMPLES);
    for (int i = 0; i < count; i++) {
      id<MTLTexture> texture =
          CheckoutTexture(destination.device, destination.width,
                          destination.height, destination.pixelFormat);
      if (!texture)
        return NO;
      [samples addObject:texture];
    }
    id<MTLCommandBuffer> buffer = [queue commandBuffer];
    if (!buffer)
      return NO;
    buffer.label = @"RenderSupport Motion Blur";
    for (int i = 0; i < count; i++) {
      @autoreleasepool {
        // On failure abandon the uncommitted buffer; pooled textures are safe
        // to return immediately because no encoded work has reached the GPU.
        if (!block(i, samples[i], buffer, sources))
          return NO;
      }
    }
    MTLRenderPassDescriptor *pass =
        [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = destination;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    id<MTLRenderCommandEncoder> encoder =
        [buffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder)
      return NO;
    float w = destination.width, h = destination.height;
    [encoder setViewport:(MTLViewport){0, 0, w, h, -1, 1}];
    RSRenderVertex2D vertices[] = {{{w / 2, -h / 2}, {1, 1}},
                                   {{-w / 2, -h / 2}, {0, 1}},
                                   {{w / 2, h / 2}, {1, 0}},
                                   {{-w / 2, h / 2}, {0, 0}}};
    simd_uint2 size = {(uint)w, (uint)h};
    [encoder setVertexBytes:vertices
                     length:sizeof(vertices)
                    atIndex:RSRenderVertexIndexVertices];
    [encoder setVertexBytes:&size
                     length:sizeof(size)
                    atIndex:RSRenderVertexIndexViewportSize];
    [encoder setRenderPipelineState:pipeline];
    for (int i = 0; i < count; i++)
      [encoder setFragmentTexture:samples[i] atIndex:i];
    [encoder setFragmentBytes:&count length:sizeof(count) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0
                vertexCount:4];
    [encoder endEncoding];
    [buffer commit];
    [buffer waitUntilCompleted];
    return buffer.status == MTLCommandBufferStatusCompleted;
  } @finally {
    ReturnTextures(samples);
    RSRenderReturnQueue(queue);
    dispatch_semaphore_signal(sInFlight);
  }
}
