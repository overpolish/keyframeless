/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMotionBlurReconstruct.h"
#import "KKLog.h"
#import "KKMetalDeviceCache.h"
#import "KKShaderTypes.h"

static NSString *const kKKMBRTileMaxID =
    @"com.keyframeless.kit.mbreconstruct.tilemax";
static NSString *const kKKMBRNeighborMaxID =
    @"com.keyframeless.kit.mbreconstruct.neighbormax";
static NSString *const kKKMBRGatherID =
    @"com.keyframeless.kit.mbreconstruct.gather";

@implementation KKMotionBlurReconstruct

/// Draw a full-screen quad (the kit `KKVertexShader` maps centered-pixel verts to
/// clip space) into `target` with `ps` bound; `bind` sets the per-pass fragment
/// resources. One render encoder per pass on the shared command buffer - Metal's
/// intra-buffer hazard tracking serialises a written tile texture before the next
/// pass reads it, so no waits are needed between passes.
static void kkMBFullscreenPass(id<MTLCommandBuffer> cb, id<MTLTexture> target,
                               id<MTLRenderPipelineState> ps,
                               void (^bind)(id<MTLRenderCommandEncoder>)) {
  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture = target;
  rpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> e =
      [cb renderCommandEncoderWithDescriptor:rpd];

  float w = (float)target.width, h = (float)target.height;
  [e setViewport:(MTLViewport){0, 0, w, h, -1.0, 1.0}];
  KKVertex2D verts[] = {
      {{w / 2.0f, -h / 2.0f}, {1.0f, 1.0f}},
      {{-w / 2.0f, -h / 2.0f}, {0.0f, 1.0f}},
      {{w / 2.0f, h / 2.0f}, {1.0f, 0.0f}},
      {{-w / 2.0f, h / 2.0f}, {0.0f, 0.0f}},
  };
  simd_uint2 vp = {(unsigned int)w, (unsigned int)h};
  [e setVertexBytes:verts
             length:sizeof(verts)
            atIndex:KKVertexInputIndex_Vertices];
  [e setVertexBytes:&vp length:sizeof(vp) atIndex:KKVertexInputIndex_ViewportSize];
  [e setRenderPipelineState:ps];
  if (bind)
    bind(e);
  [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  [e endEncoding];
}

+ (BOOL)encodeReconstructionToTexture:(id<MTLTexture>)dest
                         colorTexture:(id<MTLTexture>)color
                      velocityTexture:(id<MTLTexture>)velocity
                             tileSize:(int)tileSize
                          sampleCount:(int)sampleCount
                           registryID:(uint64_t)registryID
                               device:(id<MTLDevice>)device
                        commandBuffer:(id<MTLCommandBuffer>)cb {
  if (!dest || !color || !velocity || !device || !cb)
    return NO;

  int K = MAX(tileSize, 1);
  int S = sampleCount;
  if (S < 3)
    S = 3;
  if (S > 31)
    S = 31;

  NSUInteger W = color.width;
  NSUInteger H = color.height;
  if (W == 0 || H == 0)
    return NO;
  NSUInteger gw = (W + (NSUInteger)K - 1) / (NSUInteger)K;
  NSUInteger gh = (H + (NSUInteger)K - 1) / (NSUInteger)K;

  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  NSString *bundleID = [NSBundle bundleForClass:self].bundleIdentifier;
  MTLPixelFormat destPF = dest.pixelFormat;

  // Three pipelines, distinct plugin IDs so the (id, registryID, format) cache
  // key doesn't collide (the two tile passes share RG16Float). All overwrite
  // their target (no blend); the caller composites the gather result.
  id<MTLRenderPipelineState> tileMaxPS = [cache
      buildAndRegisterPipelineStateForPluginID:kKKMBRTileMaxID
                                    registryID:registryID
                                   pixelFormat:MTLPixelFormatRG16Float
                                      bundleID:bundleID
                                  vertexShader:@"KKVertexShader"
                                fragmentShader:@"KKMBVelocityTileMaxFragment"
                                     blendMode:KKBlendModeNone];
  id<MTLRenderPipelineState> neighborMaxPS = [cache
      buildAndRegisterPipelineStateForPluginID:kKKMBRNeighborMaxID
                                    registryID:registryID
                                   pixelFormat:MTLPixelFormatRG16Float
                                      bundleID:bundleID
                                  vertexShader:@"KKVertexShader"
                                fragmentShader:@"KKMBVelocityNeighborMaxFragment"
                                     blendMode:KKBlendModeNone];
  id<MTLRenderPipelineState> gatherPS = [cache
      buildAndRegisterPipelineStateForPluginID:kKKMBRGatherID
                                    registryID:registryID
                                   pixelFormat:destPF
                                      bundleID:bundleID
                                  vertexShader:@"KKVertexShader"
                                fragmentShader:@"KKMBReconstructFragment"
                                     blendMode:KKBlendModeNone];
  if (!tileMaxPS || !neighborMaxPS || !gatherPS) {
    KKLogError(@"KKMotionBlurReconstruct: pipeline build failed");
    return NO;
  }

  // Two tile-grid intermediates (RG16Float). They are tiny (W/K x H/K), so they
  // are allocated fresh per call for now; a pooled path is a later perf pass if
  // the allocation churn ever shows up.
  MTLTextureDescriptor *td =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float
                                                         width:gw
                                                        height:gh
                                                     mipmapped:NO];
  td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  td.storageMode = MTLStorageModePrivate;
  id<MTLTexture> tileMaxTex = [device newTextureWithDescriptor:td];
  id<MTLTexture> neighborMaxTex = [device newTextureWithDescriptor:td];
  if (!tileMaxTex || !neighborMaxTex) {
    KKLogError(@"KKMotionBlurReconstruct: tile texture alloc failed");
    return NO;
  }

  KKMBReconstructParams params = {.tileSize = K, .sampleCount = S};

  kkMBFullscreenPass(cb, tileMaxTex, tileMaxPS,
                     ^(id<MTLRenderCommandEncoder> e) {
                       [e setFragmentTexture:velocity atIndex:0];
                       [e setFragmentBytes:&params
                                    length:sizeof(params)
                                   atIndex:0];
                     });
  kkMBFullscreenPass(cb, neighborMaxTex, neighborMaxPS,
                     ^(id<MTLRenderCommandEncoder> e) {
                       [e setFragmentTexture:tileMaxTex atIndex:0];
                     });
  kkMBFullscreenPass(cb, dest, gatherPS, ^(id<MTLRenderCommandEncoder> e) {
    [e setFragmentTexture:color atIndex:0];
    [e setFragmentTexture:velocity atIndex:1];
    [e setFragmentTexture:neighborMaxTex atIndex:2];
    [e setFragmentBytes:&params length:sizeof(params) atIndex:0];
  });

  return YES;
}

@end
