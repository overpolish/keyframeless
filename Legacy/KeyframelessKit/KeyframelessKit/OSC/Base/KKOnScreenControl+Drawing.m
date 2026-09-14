/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKOSCShaderTypes.h"
#import "KKOnScreenControl.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKMetalDeviceCache.h>
#import <KeyframelessKit/KKRenderPrimitives.h>

// Transient OSC draw batch (see -beginOSCDrawBatchForDestinationImage:). While
// armed, every encodeRenderCommandsForDestinationImage: across ALL control
// instances encodes into this one command buffer + encoder instead of creating
// and committing its own. Process-global because the participating controls are
// distinct instances (the path-edit surface plus its anchor / handle / ring
// glyphs); safe as a static because viewer-OSC drawing is single-threaded and
// one synchronous pass at a time, and each FxPlug instance is its own XPC
// process. Cleared by -endOSCDrawBatch; nil when not batching.
static id<MTLCommandQueue> sOSCBatchQueue = nil;
static id<MTLCommandBuffer> sOSCBatchCmdBuf = nil;
static id<MTLRenderCommandEncoder> sOSCBatchEncoder = nil;
static simd_uint2 sOSCBatchViewport = {0, 0};

// Pipeline construction and the Metal line/quad/encode primitives shared by
// every OSC control. Subclasses reach these via the public KKOnScreenControl
// interface; the bevel-glyph subclasses use -pipelineStateForDestinationImage:.
@implementation KKOnScreenControl (Drawing)

- (BOOL)beginOSCDrawBatchForDestinationImage:(FxImageTile *)destinationImage
                            clearDestination:(BOOL)clear {
  if (sOSCBatchEncoder)
    return YES; // already armed (nested begin): reuse the open pass
  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  id<MTLDevice> gpuDevice =
      [cache deviceWithRegistryID:destinationImage.deviceRegistryID];
  MTLPixelFormat pixelFormat =
      [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
  id<MTLCommandQueue> queue =
      [cache commandQueueWithRegistryID:destinationImage.deviceRegistryID
                            pixelFormat:pixelFormat];
  id<MTLTexture> outputTexture =
      gpuDevice ? [destinationImage metalTextureForDevice:gpuDevice] : nil;
  if (!gpuDevice || !queue || !outputTexture) {
    if (queue)
      [cache returnCommandQueueToCache:queue];
    return NO;
  }
  id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
  commandBuffer.label = @"KKOnScreenControl OSC Batch";
  [commandBuffer enqueue];
  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture = outputTexture;
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
  if (clear) {
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  } else {
    rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
  }
  id<MTLRenderCommandEncoder> encoder =
      [commandBuffer renderCommandEncoderWithDescriptor:rpd];
  float w = [destinationImage.ioSurface width];
  float h = [destinationImage.ioSurface height];
  [encoder setViewport:(MTLViewport){0, 0, w, h, -1.0, 1.0}];
  sOSCBatchQueue = queue;
  sOSCBatchCmdBuf = commandBuffer;
  sOSCBatchEncoder = encoder;
  sOSCBatchViewport = (simd_uint2){(unsigned int)w, (unsigned int)h};
  return YES;
}

- (void)endOSCDrawBatch {
  if (!sOSCBatchEncoder)
    return;
  [sOSCBatchEncoder endEncoding];
  [sOSCBatchCmdBuf commit];
  [sOSCBatchCmdBuf waitUntilScheduled];
  [[KKMetalDeviceCache sharedCache] returnCommandQueueToCache:sOSCBatchQueue];
  sOSCBatchEncoder = nil;
  sOSCBatchCmdBuf = nil;
  sOSCBatchQueue = nil;
}

- (void)drawOSCBatchedForDestinationImage:(FxImageTile *)destinationImage
                         clearDestination:(BOOL)clear
                                    block:(NS_NOESCAPE void (^)(void))block {
  if (!block)
    return;
  // @finally guarantees the batch closes on every exit (early return / throw),
  // so a half-open batch can never leak into the next draw pass.
  BOOL batched = [self beginOSCDrawBatchForDestinationImage:destinationImage
                                           clearDestination:clear];
  @try {
    block();
  } @finally {
    if (batched)
      [self endOSCDrawBatch];
  }
}

- (nullable id<MTLRenderPipelineState>)pipelineStateForDestinationImage:
    (FxImageTile *)destinationImage {
  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  uint64_t registryID = destinationImage.deviceRegistryID;
  MTLPixelFormat pixelFormat =
      [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];

  id<MTLRenderPipelineState> ps =
      [cache pipelineStateForPluginID:[self pipelinePluginID]
                           registryID:registryID
                          pixelFormat:pixelFormat];
  if (ps)
    return ps;

  id<MTLDevice> device = [cache deviceWithRegistryID:registryID];
  NSBundle *bundle = [NSBundle
      bundleWithIdentifier:@"com.keyframeless.KeyframelessKit"];
  NSError *error = nil;

  id<MTLLibrary> lib = [device newDefaultLibraryWithBundle:bundle error:&error];
  if (!lib || error) {
    KKLogError(@"%@: Failed to load Metal library: %@",
               NSStringFromClass([self class]), error);
    return nil;
  }

  id<MTLFunction> vertFn = [lib newFunctionWithName:@"KKVertexShader"];
  id<MTLFunction> fragFn =
      [lib newFunctionWithName:[self fragmentFunctionName]];

  if (!vertFn || !fragFn) {
    KKLogError(@"%@: Required shaders not found.",
               NSStringFromClass([self class]));
    return nil;
  }

  MTLRenderPipelineDescriptor *desc = [KKRenderPrimitives
      createPipelineDescriptorWithVertexFunction:vertFn
                                fragmentFunction:fragFn
                                     pixelFormat:pixelFormat
                                       blendMode:KKBlendModeStraightAlpha];

  ps = [device newRenderPipelineStateWithDescriptor:desc error:&error];
  if (!ps || error) {
    KKLogError(@"%@: Failed to create pipeline state: %@",
               NSStringFromClass([self class]), error);
    return nil;
  }

  [cache registerPipelineState:ps
                   forPluginID:[self pipelinePluginID]
                    registryID:registryID
                   pixelFormat:pixelFormat];
  return ps;
}

// Shared "Line" pipeline (premultiplied-alpha KKLineFragment) used by all the
// line-drawing helpers below. Cached/registered per device by
// KKMetalDeviceCache.
- (nullable id<MTLRenderPipelineState>)_linePipelineForDestinationImage:
    (FxImageTile *)destinationImage {
  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  uint64_t registryID = destinationImage.deviceRegistryID;
  MTLPixelFormat pixelFormat =
      [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
  return [cache
      buildAndRegisterPipelineStateForPluginID:
          @"com.keyframeless.kit.Line"
                                    registryID:registryID
                                   pixelFormat:pixelFormat
                                      bundleID:@"com.keyframeless.KeyframelessKit"
                                  vertexShader:@"KKVertexShader"
                                fragmentShader:@"KKLineFragment"
                                     blendMode:KKBlendModePremultipliedAlpha];
}

- (void)drawLineFrom:(CGPoint)canvasA
                  to:(CGPoint)canvasB
               color:(simd_float4)lineColor
           halfWidth:(float)hw
    destinationImage:(FxImageTile *)destinationImage {
  id<MTLRenderPipelineState> ps =
      [self _linePipelineForDestinationImage:destinationImage];
  if (!ps)
    return;

  CGPoint mid =
      CGPointMake((canvasA.x + canvasB.x) / 2.0, (canvasA.y + canvasB.y) / 2.0);

  [self
      encodeRenderCommandsForDestinationImage:destinationImage
                               canvasPosition:mid
                             clearDestination:NO
                                     commands:^(
                                         id<MTLRenderCommandEncoder> encoder,
                                         CGPoint metalMid,
                                         simd_uint2 viewportSize) {
                                       float ioW = viewportSize.x;
                                       float ioH = viewportSize.y;
                                       simd_float2 mA = {
                                           (float)(canvasA.x - ioW / 2.0),
                                           (float)(ioH / 2.0 - canvasA.y)};
                                       simd_float2 mB = {
                                           (float)(canvasB.x - ioW / 2.0),
                                           (float)(ioH / 2.0 - canvasB.y)};

                                       simd_float2 d = mB - mA;
                                       float len = simd_length(d);
                                       if (len < 0.001f)
                                         return;
                                       simd_float2 dir = d / len;
                                       simd_float2 perp = {-dir.y, dir.x};
                                       float pad = hw + 1.0f;

                                       simd_float2 v0 = mA + perp * pad;
                                       simd_float2 v1 = mA - perp * pad;
                                       simd_float2 v2 = mB + perp * pad;
                                       simd_float2 v3 = mB - perp * pad;

                                       float edge = pad / hw;
                                       KKVertex2D verts[6] = {
                                           {v0, {0, edge}},  {v1, {0, -edge}},
                                           {v2, {0, edge}},  {v1, {0, -edge}},
                                           {v3, {0, -edge}}, {v2, {0, edge}},
                                       };

                                       simd_float4 color = lineColor;
                                       [encoder setRenderPipelineState:ps];
                                       [encoder
                                           setVertexBytes:verts
                                                   length:sizeof(verts)
                                                  atIndex:
                                                      KKVertexInputIndex_Vertices];
                                       [encoder
                                           setVertexBytes:&viewportSize
                                                   length:sizeof(viewportSize)
                                                  atIndex:
                                                      KKVertexInputIndex_ViewportSize];
                                       [encoder setFragmentBytes:&color
                                                          length:sizeof(color)
                                                         atIndex:0];
                                       [encoder drawPrimitives:
                                                    MTLPrimitiveTypeTriangle
                                                   vertexStart:0
                                                   vertexCount:6];
                                     }];
}

- (void)drawLineStripWithPoints:(const CGPoint *)points
                          count:(NSUInteger)count
                          color:(simd_float4)lineColor
                      halfWidth:(float)hw
               destinationImage:(FxImageTile *)destinationImage {
  if (count < 2)
    return;

  id<MTLRenderPipelineState> ps =
      [self _linePipelineForDestinationImage:destinationImage];
  if (!ps)
    return;

  CGPoint center = points[0];
  [self
      encodeRenderCommandsForDestinationImage:destinationImage
                               canvasPosition:center
                             clearDestination:NO
                                     commands:^(
                                         id<MTLRenderCommandEncoder> encoder,
                                         CGPoint metalMid,
                                         simd_uint2 viewportSize) {
                                       float ioW = viewportSize.x;
                                       float ioH = viewportSize.y;
                                       float pad = hw + 1.0f;
                                       float edge = pad / hw;

                                       NSUInteger segCount = count - 1;
                                       NSUInteger vertCount = segCount * 6;
                                       KKVertex2D *verts = malloc(
                                           sizeof(KKVertex2D) * vertCount);
                                       NSUInteger vi = 0;

                                       for (NSUInteger i = 0; i < segCount;
                                            i++) {
                                         simd_float2 mA = {
                                             (float)(points[i].x - ioW / 2.0),
                                             (float)(ioH / 2.0 - points[i].y)};
                                         simd_float2 mB = {
                                             (float)(points[i + 1].x -
                                                     ioW / 2.0),
                                             (float)(ioH / 2.0 -
                                                     points[i + 1].y)};

                                         simd_float2 d = mB - mA;
                                         float len = simd_length(d);
                                         if (len < 0.001f)
                                           continue;
                                         simd_float2 dir = d / len;
                                         simd_float2 perp = {-dir.y, dir.x};

                                         simd_float2 v0 = mA + perp * pad;
                                         simd_float2 v1 = mA - perp * pad;
                                         simd_float2 v2 = mB + perp * pad;
                                         simd_float2 v3 = mB - perp * pad;

                                         verts[vi++] =
                                             (KKVertex2D){v0, {0, edge}};
                                         verts[vi++] =
                                             (KKVertex2D){v1, {0, -edge}};
                                         verts[vi++] =
                                             (KKVertex2D){v2, {0, edge}};
                                         verts[vi++] =
                                             (KKVertex2D){v1, {0, -edge}};
                                         verts[vi++] =
                                             (KKVertex2D){v3, {0, -edge}};
                                         verts[vi++] =
                                             (KKVertex2D){v2, {0, edge}};
                                       }

                                       if (vi > 0) {
                                         NSUInteger byteLen =
                                             sizeof(KKVertex2D) * vi;
                                         simd_float4 color = lineColor;
                                         [encoder setRenderPipelineState:ps];
                                         if (byteLen <= 4096) {
                                           [encoder
                                               setVertexBytes:verts
                                                       length:byteLen
                                                      atIndex:
                                                          KKVertexInputIndex_Vertices];
                                         } else {
                                           id<MTLDevice> dev = encoder.device;
                                           id<MTLBuffer> buf = [dev
                                               newBufferWithBytes:verts
                                                           length:byteLen
                                                          options:
                                                              MTLResourceStorageModeShared];
                                           [encoder
                                               setVertexBuffer:buf
                                                        offset:0
                                                       atIndex:
                                                           KKVertexInputIndex_Vertices];
                                         }
                                         [encoder
                                             setVertexBytes:&viewportSize
                                                     length:sizeof(viewportSize)
                                                    atIndex:
                                                        KKVertexInputIndex_ViewportSize];
                                         [encoder setFragmentBytes:&color
                                                            length:sizeof(color)
                                                           atIndex:0];
                                         [encoder drawPrimitives:
                                                      MTLPrimitiveTypeTriangle
                                                     vertexStart:0
                                                     vertexCount:vi];
                                       }

                                       free(verts);
                                     }];
}

- (void)drawLineSegmentsWithPoints:(const CGPoint *)points
                             count:(NSUInteger)count
                             color:(simd_float4)lineColor
                         halfWidth:(float)hw
                  destinationImage:(FxImageTile *)destinationImage {
  if (count < 2)
    return;

  id<MTLRenderPipelineState> ps =
      [self _linePipelineForDestinationImage:destinationImage];
  if (!ps)
    return;

  CGPoint center = points[0];
  [self
      encodeRenderCommandsForDestinationImage:destinationImage
                               canvasPosition:center
                             clearDestination:NO
                                     commands:^(
                                         id<MTLRenderCommandEncoder> encoder,
                                         CGPoint metalMid,
                                         simd_uint2 viewportSize) {
                                       float ioW = viewportSize.x;
                                       float ioH = viewportSize.y;
                                       float pad = hw + 1.0f;
                                       float edge = pad / hw;

                                       NSUInteger pairCount = count / 2;
                                       NSUInteger vertCount = pairCount * 6;
                                       KKVertex2D *verts = malloc(
                                           sizeof(KKVertex2D) * vertCount);
                                       NSUInteger vi = 0;

                                       for (NSUInteger i = 0; i < pairCount;
                                            i++) {
                                         simd_float2 mA = {
                                             (float)(points[i * 2].x -
                                                     ioW / 2.0),
                                             (float)(ioH / 2.0 -
                                                     points[i * 2].y)};
                                         simd_float2 mB = {
                                             (float)(points[i * 2 + 1].x -
                                                     ioW / 2.0),
                                             (float)(ioH / 2.0 -
                                                     points[i * 2 + 1].y)};

                                         simd_float2 d = mB - mA;
                                         float len = simd_length(d);
                                         if (len < 0.001f)
                                           continue;
                                         simd_float2 dir = d / len;
                                         simd_float2 perp = {-dir.y, dir.x};

                                         simd_float2 v0 = mA + perp * pad;
                                         simd_float2 v1 = mA - perp * pad;
                                         simd_float2 v2 = mB + perp * pad;
                                         simd_float2 v3 = mB - perp * pad;

                                         verts[vi++] =
                                             (KKVertex2D){v0, {0, edge}};
                                         verts[vi++] =
                                             (KKVertex2D){v1, {0, -edge}};
                                         verts[vi++] =
                                             (KKVertex2D){v2, {0, edge}};
                                         verts[vi++] =
                                             (KKVertex2D){v1, {0, -edge}};
                                         verts[vi++] =
                                             (KKVertex2D){v3, {0, -edge}};
                                         verts[vi++] =
                                             (KKVertex2D){v2, {0, edge}};
                                       }

                                       if (vi > 0) {
                                         NSUInteger byteLen =
                                             sizeof(KKVertex2D) * vi;
                                         simd_float4 color = lineColor;
                                         [encoder setRenderPipelineState:ps];
                                         if (byteLen <= 4096) {
                                           [encoder
                                               setVertexBytes:verts
                                                       length:byteLen
                                                      atIndex:
                                                          KKVertexInputIndex_Vertices];
                                         } else {
                                           id<MTLDevice> dev = encoder.device;
                                           id<MTLBuffer> buf = [dev
                                               newBufferWithBytes:verts
                                                           length:byteLen
                                                          options:
                                                              MTLResourceStorageModeShared];
                                           [encoder
                                               setVertexBuffer:buf
                                                        offset:0
                                                       atIndex:
                                                           KKVertexInputIndex_Vertices];
                                         }
                                         [encoder
                                             setVertexBytes:&viewportSize
                                                     length:sizeof(viewportSize)
                                                    atIndex:
                                                        KKVertexInputIndex_ViewportSize];
                                         [encoder setFragmentBytes:&color
                                                            length:sizeof(color)
                                                           atIndex:0];
                                         [encoder drawPrimitives:
                                                      MTLPrimitiveTypeTriangle
                                                     vertexStart:0
                                                     vertexCount:vi];
                                       }

                                       free(verts);
                                     }];
}

- (void)drawQuadForDestinationImage:(FxImageTile *)destinationImage
                     canvasPosition:(CGPoint)canvasPosition
                      pipelineState:(id<MTLRenderPipelineState>)pipelineState
                       fragmentData:(const void *)fragmentData
                   fragmentDataSize:(size_t)fragmentDataSize
                               size:(float)size {
  [self drawQuadForDestinationImage:destinationImage
                     canvasPosition:canvasPosition
                   clearDestination:self.clearsOnDraw
                      pipelineState:pipelineState
                       fragmentData:fragmentData
                   fragmentDataSize:fragmentDataSize
                               size:size];
}

- (void)drawQuadForDestinationImage:(FxImageTile *)destinationImage
                     canvasPosition:(CGPoint)canvasPosition
                   clearDestination:(BOOL)clear
                      pipelineState:(id<MTLRenderPipelineState>)pipelineState
                       fragmentData:(const void *)fragmentData
                   fragmentDataSize:(size_t)fragmentDataSize
                               size:(float)size {
  [self
      encodeRenderCommandsForDestinationImage:destinationImage
                               canvasPosition:canvasPosition
                             clearDestination:clear
                                     commands:^(
                                         id<MTLRenderCommandEncoder> encoder,
                                         CGPoint metalPosition,
                                         simd_uint2 viewportSize) {
                                       KKVertex2D quadVertices[6];
                                       [KKRenderPrimitives
                                           generateQuadVertices:quadVertices
                                                         center:metalPosition
                                                           size:size];
                                       [encoder setRenderPipelineState:
                                                    pipelineState];
                                       [encoder
                                           setVertexBytes:quadVertices
                                                   length:sizeof(quadVertices)
                                                  atIndex:
                                                      KKVertexInputIndex_Vertices];
                                       [encoder
                                           setVertexBytes:&viewportSize
                                                   length:sizeof(viewportSize)
                                                  atIndex:
                                                      KKVertexInputIndex_ViewportSize];
                                       [encoder
                                           setFragmentBytes:fragmentData
                                                     length:fragmentDataSize
                                                    atIndex:
                                                        KKOSCFragmentIndex_DrawColor];
                                       [encoder drawPrimitives:
                                                    MTLPrimitiveTypeTriangle
                                                   vertexStart:0
                                                   vertexCount:6];
                                     }];
}

- (void)
    encodeRenderCommandsForDestinationImage:(FxImageTile *)destinationImage
                             canvasPosition:(CGPoint)canvasPosition
                                   commands:
                                       (void (^)(
                                           id<MTLRenderCommandEncoder> encoder,
                                           CGPoint metalPosition,
                                           simd_uint2 viewportSize))commands {
  [self encodeRenderCommandsForDestinationImage:destinationImage
                                 canvasPosition:canvasPosition
                               clearDestination:YES
                                       commands:commands];
}

- (void)
    encodeRenderCommandsForDestinationImage:(FxImageTile *)destinationImage
                             canvasPosition:(CGPoint)canvasPosition
                           clearDestination:(BOOL)clear
                                   commands:
                                       (void (^)(
                                           id<MTLRenderCommandEncoder> encoder,
                                           CGPoint metalPosition,
                                           simd_uint2 viewportSize))commands {
  // Batched: encode into the shared pass instead of a private command buffer.
  // The batch already loaded/cleared the destination on open, so an individual
  // clear request is dropped (a mid-pass clear would wipe earlier primitives).
  // metalPosition uses the batch's viewport, same centring math as below.
  if (sOSCBatchEncoder) {
    float w = (float)sOSCBatchViewport.x, h = (float)sOSCBatchViewport.y;
    CGPoint metalPosition = {canvasPosition.x - w / 2.0f,
                             h / 2.0f - canvasPosition.y};
    commands(sOSCBatchEncoder, metalPosition, sOSCBatchViewport);
    return;
  }

  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];

  id<MTLDevice> gpuDevice =
      [cache deviceWithRegistryID:destinationImage.deviceRegistryID];
  MTLPixelFormat pixelFormat =
      [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
  id<MTLCommandQueue> queue =
      [cache commandQueueWithRegistryID:destinationImage.deviceRegistryID
                            pixelFormat:pixelFormat];

  if (!gpuDevice || !queue)
    return;

  id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
  commandBuffer.label = @"KKOnScreenControl Command Buffer";
  [commandBuffer enqueue];

  id<MTLTexture> outputTexture =
      [destinationImage metalTextureForDevice:gpuDevice];
  if (!outputTexture) {
    [cache returnCommandQueueToCache:queue];
    return;
  }

  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture = outputTexture;
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
  if (clear) {
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  } else {
    rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
  }

  id<MTLRenderCommandEncoder> encoder =
      [commandBuffer renderCommandEncoderWithDescriptor:rpd];

  float ioSurfaceWidth = [destinationImage.ioSurface width];
  float ioSurfaceHeight = [destinationImage.ioSurface height];

  MTLViewport viewport = {0, 0, ioSurfaceWidth, ioSurfaceHeight, -1.0, 1.0};
  [encoder setViewport:viewport];

  CGPoint metalPosition = {canvasPosition.x - ioSurfaceWidth / 2.0f,
                           ioSurfaceHeight / 2.0f - canvasPosition.y};

  simd_uint2 viewportSize = {(unsigned int)ioSurfaceWidth,
                             (unsigned int)ioSurfaceHeight};

  commands(encoder, metalPosition, viewportSize);

  [encoder endEncoding];
  [commandBuffer commit];
  [commandBuffer waitUntilScheduled];

  [cache returnCommandQueueToCache:queue];
}

@end
