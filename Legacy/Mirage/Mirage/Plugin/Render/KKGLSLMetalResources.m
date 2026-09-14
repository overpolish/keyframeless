/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKGLSLTranspiler_Internal.h"

#import <KeyframelessKit/KKLog.h>

// The Metal side of a transpiled shader: the immutable per-device resources it
// samples (noise, samplers, the gamma-encode pipeline) and the binding calls
// the render paths make. Nothing here touches glslang or the GLSL text.

// A per-device cache for an immutable Metal object. Every resource below is
// device-scoped, built once, and then shared by the FCP render and the
// mini-viewer across threads - so each gets one of these rather than five
// copies of the same map-table/lock dance. `build` runs OUTSIDE the lock: a
// pipeline build takes milliseconds, and two devices have no reason to
// serialise. A rare duplicate build under a race is harmless - the objects are
// interchangeable.
@interface KKDeviceObjectCache : NSObject
// One shared cache per resource kind. Separate instances, not one table keyed
// by (kind, device): the device is the key, so a single table would collide.
+ (instancetype)cacheNamed:(NSString *)name;
- (nullable id)objectForDevice:(id<MTLDevice>)device
                         build:(id _Nullable (^)(id<MTLDevice> device))build;
@end

@implementation KKDeviceObjectCache {
  NSMapTable *_table;
  NSLock *_lock;
}
+ (instancetype)cacheNamed:(NSString *)name {
  static NSMutableDictionary<NSString *, KKDeviceObjectCache *> *caches;
  static NSLock *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    caches = [NSMutableDictionary dictionary];
    lock = [NSLock new];
  });
  [lock lock];
  KKDeviceObjectCache *c = caches[name];
  if (!c) {
    c = [KKDeviceObjectCache new];
    caches[name] = c;
  }
  [lock unlock];
  return c;
}
- (instancetype)init {
  if ((self = [super init])) {
    _table = [NSMapTable strongToStrongObjectsMapTable];
    _lock = [NSLock new];
  }
  return self;
}
- (id)objectForDevice:(id<MTLDevice>)device build:(id (^)(id<MTLDevice>))build {
  if (!device)
    return nil;
  [_lock lock];
  id hit = [_table objectForKey:device];
  [_lock unlock];
  if (hit)
    return hit;
  id built = build(device);
  if (!built)
    return nil; // a failed build must not be cached as a permanent nil
  [_lock lock];
  [_table setObject:built forKey:device];
  [_lock unlock];
  return built;
}
@end

id<MTLTexture> KKCustomChannelNoiseTexture(id<MTLDevice> device) {
  return [[KKDeviceObjectCache cacheNamed:@"channelNoise"]
      objectForDevice:device
                build:^id(id<MTLDevice> dev) {
                  const NSUInteger N = 256;
                  MTLTextureDescriptor *d = [MTLTextureDescriptor
                      texture2DDescriptorWithPixelFormat:
                          MTLPixelFormatRGBA8Unorm
                                                   width:N
                                                  height:N
                                               mipmapped:NO];
                  d.usage = MTLTextureUsageShaderRead;
                  id<MTLTexture> tex = [dev newTextureWithDescriptor:d];
                  if (!tex)
                    return nil;
                  uint8_t *bytes = (uint8_t *)malloc(N * N * 4);
                  arc4random_buf(bytes, N * N * 4);
                  [tex replaceRegion:MTLRegionMake2D(0, 0, N, N)
                         mipmapLevel:0
                           withBytes:bytes
                         bytesPerRow:N * 4];
                  free(bytes);
                  return tex;
                }];
}

id<MTLTexture> KKCustomTransparentTexture(id<MTLDevice> device) {
  return [[KKDeviceObjectCache cacheNamed:@"transparent"]
      objectForDevice:device
                build:^id(id<MTLDevice> dev) {
                  MTLTextureDescriptor *d = [MTLTextureDescriptor
                      texture2DDescriptorWithPixelFormat:
                          MTLPixelFormatRGBA8Unorm
                                                   width:1
                                                  height:1
                                               mipmapped:NO];
                  d.usage = MTLTextureUsageShaderRead;
                  id<MTLTexture> tex = [dev newTextureWithDescriptor:d];
                  if (!tex)
                    return nil;
                  const uint8_t clear[4] = {0, 0, 0, 0};
                  [tex replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                         mipmapLevel:0
                           withBytes:clear
                         bytesPerRow:4];
                  return tex;
                }];
}

// The three samplers differ only in address mode + filter.
static id<MTLSamplerState> KKSampler(NSString *name, id<MTLDevice> device,
                                     MTLSamplerAddressMode address,
                                     MTLSamplerMinMagFilter filter) {
  return [[KKDeviceObjectCache cacheNamed:name]
      objectForDevice:device
                build:^id(id<MTLDevice> dev) {
                  MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
                  sd.minFilter = filter;
                  sd.magFilter = filter;
                  sd.sAddressMode = address;
                  sd.tAddressMode = address;
                  return [dev newSamplerStateWithDescriptor:sd];
                }];
}

// Repeat + linear: the noise an unused iChannel samples is meant to tile.
id<MTLSamplerState> KKCustomChannelSampler(id<MTLDevice> device) {
  return KKSampler(@"channelSampler", device, MTLSamplerAddressModeRepeat,
                   MTLSamplerMinMagFilterLinear);
}

// Clamp + linear: footage must NOT wrap when a shader samples outside [0,1].
id<MTLSamplerState> KKCustomSourceSampler(id<MTLDevice> device) {
  return KKSampler(@"sourceSampler", device, MTLSamplerAddressModeClampToEdge,
                   MTLSamplerMinMagFilterLinear);
}

// Clamp + nearest: a 1:1 encode pass, so filtering would only blur it.
static id<MTLSamplerState> KKGammaEncodeSampler(id<MTLDevice> device) {
  return KKSampler(@"gammaSampler", device, MTLSamplerAddressModeClampToEdge,
                   MTLSamplerMinMagFilterNearest);
}

// Cached render pipeline (fullscreen quad, vertex + fragment) that samples a
// linear source and writes its sRGB/gamma encode, or with `decode` the exact
// inverse. Sampling (not compute .read) matches exactly how the shader reads
// the source, so any texture the shader can sample this pass can sample too.
static id<MTLRenderPipelineState> KKGammaPipeline(id<MTLDevice> device,
                                                  BOOL decode) {
  return [[KKDeviceObjectCache
      cacheNamed:(decode ? @"gammaDecodePipeline" : @"gammaPipeline")]
      objectForDevice:device
                build:^id(id<MTLDevice> dev) {
                  NSString *src =
                      @"#include <metal_stdlib>\n"
                      @"using namespace metal;\n"
                      @"struct KKGEOut { float4 pos [[position]]; float2 uv; "
                      @"};\n"
                      @"vertex KKGEOut kkGammaVS(uint vid [[vertex_id]]) {\n"
                      @"  float2 c[4] = { float2(-1,-1), float2(-1,1), "
                      @"float2(1,-1), float2(1,1) };\n"
                      @"  float2 p = c[vid];\n"
                      @"  KKGEOut o;\n"
                      @"  o.pos = float4(p, 0.0, 1.0);\n"
                      @"  o.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);\n"
                      @"  return o;\n"
                      @"}\n"
                      @"static inline float3 kk_lin2srgb(float3 c) {\n"
                      @"  c = clamp(c, 0.0, 1.0);\n"
                      @"  float3 lo = c * 12.92;\n"
                      @"  float3 hi = 1.055 * pow(c, 1.0 / 2.4) - 0.055;\n"
                      @"  return select(hi, lo, c <= 0.0031308);\n"
                      @"}\n"
                      @"static inline float3 kk_srgb2lin(float3 c) {\n"
                      @"  c = clamp(c, 0.0, 1.0);\n"
                      @"  float3 lo = c / 12.92;\n"
                      @"  float3 hi = pow((c + 0.055) / 1.055, 2.4);\n"
                      @"  return select(hi, lo, c <= 0.04045);\n"
                      @"}\n"
                      @"fragment float4 kkGammaFS(KKGEOut in [[stage_in]],\n"
                      @"                          texture2d<float> tex "
                      @"[[texture(0)]],\n"
                      @"                          sampler smp [[sampler(0)]]) "
                      @"{\n"
                      @"  float4 c = tex.sample(smp, in.uv);\n"
                      @"  return float4(kk_lin2srgb(c.rgb), c.a);\n"
                      @"}\n"
                      @"fragment float4 kkGammaDecodeFS(KKGEOut in "
                      @"[[stage_in]],\n"
                      @"                                texture2d<float> tex "
                      @"[[texture(0)]],\n"
                      @"                                sampler smp "
                      @"[[sampler(0)]]) {\n"
                      @"  float4 c = tex.sample(smp, in.uv);\n"
                      @"  return float4(kk_srgb2lin(c.rgb), c.a);\n"
                      @"}\n";
                  NSError *err = nil;
                  id<MTLLibrary> lib = [dev newLibraryWithSource:src
                                                         options:nil
                                                           error:&err];
                  id<MTLFunction> vfn = [lib newFunctionWithName:@"kkGammaVS"];
                  id<MTLFunction> ffn =
                      [lib newFunctionWithName:(decode ? @"kkGammaDecodeFS"
                                                       : @"kkGammaFS")];
                  if (!vfn || !ffn) {
                    KKLogError(
                        @"[Custom] gamma-convert shader build failed: %@", err);
                    return nil;
                  }
                  MTLRenderPipelineDescriptor *desc =
                      [MTLRenderPipelineDescriptor new];
                  desc.vertexFunction = vfn;
                  desc.fragmentFunction = ffn;
                  desc.colorAttachments[0].pixelFormat =
                      MTLPixelFormatRGBA16Float;
                  id<MTLRenderPipelineState> ps =
                      [dev newRenderPipelineStateWithDescriptor:desc
                                                          error:&err];
                  if (!ps)
                    KKLogError(@"[Custom] gamma-convert pipeline build failed: "
                               @"%@",
                               err);
                  return ps;
                }];
}

static id<MTLTexture> KKGammaConvertOnBuffer(id<MTLCommandBuffer> commandBuffer,
                                             id<MTLTexture> src, BOOL decode) {
  if (!commandBuffer || !src)
    return src;
  id<MTLDevice> device = commandBuffer.device;
  if (!KKGammaPipeline(device, decode))
    return src;
  id<MTLTexture> dst =
      KKGammaConvertDestinationTexture(device, src.width, src.height);
  if (!dst)
    return src;
  return KKGammaConvertOnBufferInto(commandBuffer, src, dst, decode) ? dst
                                                                     : src;
}

BOOL KKGammaPipelineAvailable(id<MTLDevice> device, BOOL decode) {
  return device != nil && KKGammaPipeline(device, decode) != nil;
}

id<MTLTexture> KKGammaConvertDestinationTexture(id<MTLDevice> device,
                                                NSUInteger width,
                                                NSUInteger height) {
  if (!device || width == 0 || height == 0)
    return nil;
  MTLTextureDescriptor *td = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                   width:width
                                  height:height
                               mipmapped:NO];
  td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  td.storageMode = MTLStorageModePrivate;
  return [device newTextureWithDescriptor:td];
}

BOOL KKGammaConvertOnBufferInto(id<MTLCommandBuffer> commandBuffer,
                                id<MTLTexture> src, id<MTLTexture> dst,
                                BOOL decode) {
  if (!commandBuffer || !src || !dst)
    return NO;
  id<MTLDevice> device = commandBuffer.device;
  id<MTLRenderPipelineState> ps = KKGammaPipeline(device, decode);
  if (!ps)
    return NO;
  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture = dst;
  rpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> e =
      [commandBuffer renderCommandEncoderWithDescriptor:rpd];
  [e setViewport:(MTLViewport){0, 0, (double)src.width, (double)src.height,
                               -1.0, 1.0}];
  [e setRenderPipelineState:ps];
  [e setFragmentTexture:src atIndex:0];
  [e setFragmentSamplerState:KKGammaEncodeSampler(device) atIndex:0];
  [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  [e endEncoding];
  return YES;
}

static id<MTLTexture> KKGammaConvert(id<MTLCommandQueue> queue,
                                     id<MTLTexture> src, BOOL decode) {
  if (!queue || !src)
    return src;
  id<MTLCommandBuffer> cb = [queue commandBuffer];
  id<MTLTexture> dst = KKGammaConvertOnBuffer(cb, src, decode);
  if (dst == src)
    return src;
  [cb commit];
  [cb waitUntilCompleted];
  return dst;
}

id<MTLTexture>
KKGammaEncodeSourceTextureOnBuffer(id<MTLCommandBuffer> commandBuffer,
                                   id<MTLTexture> src) {
  return KKGammaConvertOnBuffer(commandBuffer, src, NO);
}

id<MTLTexture> KKGammaEncodeSourceTexture(id<MTLCommandQueue> queue,
                                          id<MTLTexture> src) {
  return KKGammaConvert(queue, src, NO);
}

id<MTLTexture>
KKGammaDecodeSourceTextureOnBuffer(id<MTLCommandBuffer> commandBuffer,
                                   id<MTLTexture> src) {
  return KKGammaConvertOnBuffer(commandBuffer, src, YES);
}

id<MTLTexture> KKGammaDecodeSourceTexture(id<MTLCommandQueue> queue,
                                          id<MTLTexture> src) {
  return KKGammaConvert(queue, src, YES);
}

void KKBindGLSLUniforms(id<MTLRenderCommandEncoder> encoder,
                        const KKGLSLUniforms *u, const simd_float4 *pool,
                        int poolCount) {
  if (poolCount <= 0 || !pool) {
    [encoder setFragmentBytes:u length:sizeof(*u) atIndex:0];
    return;
  }
  size_t poolBytes = (size_t)poolCount * sizeof(simd_float4);
  size_t total = sizeof(*u) + poolBytes;
  void *buf = malloc(total);
  memcpy(buf, u, sizeof(*u));
  memcpy((char *)buf + sizeof(*u), pool, poolBytes);
  [encoder setFragmentBytes:buf length:total atIndex:0];
  free(buf);
}

void KKBindCustomChannels(id<MTLRenderCommandEncoder> encoder,
                          KKGLSLTranspileResult *tr, id<MTLTexture> source,
                          id<MTLSamplerState> sourceSampler,
                          id<MTLTexture> noise, id<MTLSamplerState> sampler) {
  for (NSUInteger ch = 0; ch < 4; ch++) {
    NSInteger ti = [tr textureIndexForChannel:ch];
    if (ti == NSNotFound)
      continue;
    BOOL useSource = (ch == 0 && source != nil);
    [encoder setFragmentTexture:(useSource ? source : noise)
                        atIndex:(NSUInteger)ti];
    NSInteger si = [tr samplerIndexForChannel:ch];
    if (si != NSNotFound) {
      id<MTLSamplerState> smp =
          (useSource && sourceSampler) ? sourceSampler : sampler;
      [encoder setFragmentSamplerState:smp atIndex:(NSUInteger)si];
    }
  }
}

void KKBindCustomNeighborTextures(id<MTLRenderCommandEncoder> encoder,
                                  KKGLSLTranspileResult *tr,
                                  NSArray *frameTextures,
                                  id<MTLSamplerState> sampler,
                                  id<MTLTexture> fallback) {
  for (NSUInteger i = 0; i < (NSUInteger)tr.neighborCount; i++) {
    NSInteger ti = [tr textureIndexForNeighbor:i];
    if (ti == NSNotFound)
      continue;
    id entry = (i < frameTextures.count) ? frameTextures[i] : (id)[NSNull null];
    id<MTLTexture> tex =
        (entry != [NSNull null]) ? (id<MTLTexture>)entry : fallback;
    // A declared-but-unbound sampler aborts under Metal API Validation, and the
    // caller always has a current frame to stand in for a slot FCP could not
    // fill, so there is nothing to skip for.
    if (!tex)
      continue;
    [encoder setFragmentTexture:tex atIndex:(NSUInteger)ti];
    NSInteger si = [tr samplerIndexForNeighbor:i];
    if (si != NSNotFound && sampler)
      [encoder setFragmentSamplerState:sampler atIndex:(NSUInteger)si];
  }
}

void KKBindCustomChannelTextures(id<MTLRenderCommandEncoder> encoder,
                                 KKGLSLTranspileResult *tr, NSArray *chTex,
                                 id<MTLSamplerState> sampler,
                                 id<MTLTexture> noise,
                                 id<MTLSamplerState> noiseSampler) {
  for (NSUInteger ch = 0; ch < 4; ch++) {
    NSInteger ti = [tr textureIndexForChannel:ch];
    if (ti == NSNotFound)
      continue;
    id t = (ch < chTex.count) ? chTex[ch] : (id)[NSNull null];
    BOOL real = (t != [NSNull null]);
    [encoder setFragmentTexture:(real ? (id<MTLTexture>)t : noise)
                        atIndex:(NSUInteger)ti];
    NSInteger si = [tr samplerIndexForChannel:ch];
    if (si != NSNotFound)
      [encoder setFragmentSamplerState:(real ? sampler : noiseSampler)
                               atIndex:(NSUInteger)si];
  }
}
