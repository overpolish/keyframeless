/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKOnScreenControl.h"
#import "KKOSCShaderTypes.h"
#import "NSColor+KKColors.h"
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKDataBlob.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKMetalDeviceCache.h>
#import <KeyframelessKit/KKPluginInstanceState.h>
#import <KeyframelessKit/KKRenderPrimitives.h>

@interface KKOnScreenControl () <FxOnScreenControl_v4>
- (void)kkToggleOSCElementHidden:(NSString *)key;
@end

@implementation KKOnScreenControl {
  BOOL _isHovered;
  BOOL _isDragging;
  // Per-interaction opt-hide arming (see
  // -kkArmOptHideForActivePart:modifiers:).
  BOOL _kkInteractionArmed;
  BOOL _kkInteractionIsOptHide;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super init];
  if (self) {
    _apiManager = apiManager;
    _isHovered = NO;
    _isDragging = NO;
    _clearsOnDraw = YES;
  }
  return self;
}

- (FxDrawingCoordinates)drawingCoordinates {
  return kFxDrawingCoordinates_CANVAS;
}

- (NSString *)pipelinePluginID {
  NSAssert(NO, @"%@ must override pipelinePluginID",
           NSStringFromClass([self class]));
  return nil;
}

- (NSString *)fragmentFunctionName {
  NSAssert(NO, @"%@ must override fragmentFunctionName",
           NSStringFromClass([self class]));
  return nil;
}

- (float)hitRadius {
  NSAssert(NO, @"%@ must override hitRadius", NSStringFromClass([self class]));
  return 0.0f;
}

- (float)oscSize {
  NSAssert(NO, @"%@ must override oscSize", NSStringFromClass([self class]));
  return 0.0f;
}

- (CGPoint)oscPositionAtTime:(CMTime)time {
  NSAssert(NO, @"KKOnScreenControl subclass must override oscPositionAtTime:");
  return CGPointZero;
}

- (BOOL)hitTestAtMousePositionX:(double)positionX
                      positionY:(double)positionY
                         atTime:(CMTime)time {
  CGPoint pos = [self oscPositionAtTime:time];
  double dx = positionX - pos.x;
  double dy = positionY - pos.y;
  return sqrt(dx * dx + dy * dy) < self.hitRadius;
}

- (void)drawAtCanvasPosition:(CGPoint)position
                   isHovered:(BOOL)isHovered
                    isActive:(BOOL)isActive
            destinationImage:(FxImageTile *)destinationImage
                      atTime:(CMTime)time {
  NSAssert(NO,
           @"KKOnScreenControl subclass must override "
           @"drawAtCanvasPosition:isHovered:isActive:destinationImage:atTime:");
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
      bundleWithIdentifier:@"co.overpolish.keyframeless.KeyframelessKit"];
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

- (void)drawLineFrom:(CGPoint)canvasA
                  to:(CGPoint)canvasB
               color:(simd_float4)lineColor
           halfWidth:(float)hw
    destinationImage:(FxImageTile *)destinationImage {
  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  uint64_t registryID = destinationImage.deviceRegistryID;
  MTLPixelFormat pixelFormat =
      [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
  id<MTLRenderPipelineState> ps = [cache
      buildAndRegisterPipelineStateForPluginID:
          @"co.overpolish.keyframelesskit.Line"
                                    registryID:registryID
                                   pixelFormat:pixelFormat
                                      bundleID:@"co.overpolish"
                                                ".keyframeless"
                                                ".KeyframelessKit"
                                  vertexShader:@"KKVertexShader"
                                fragmentShader:@"KKLineFragment"
                                     blendMode:KKBlendModePremultipliedAlpha];
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

  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  uint64_t registryID = destinationImage.deviceRegistryID;
  MTLPixelFormat pixelFormat =
      [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
  id<MTLRenderPipelineState> ps = [cache
      buildAndRegisterPipelineStateForPluginID:
          @"co.overpolish.keyframelesskit.Line"
                                    registryID:registryID
                                   pixelFormat:pixelFormat
                                      bundleID:@"co.overpolish"
                                                ".keyframeless"
                                                ".KeyframelessKit"
                                  vertexShader:@"KKVertexShader"
                                fragmentShader:@"KKLineFragment"
                                     blendMode:KKBlendModePremultipliedAlpha];
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

  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  uint64_t registryID = destinationImage.deviceRegistryID;
  MTLPixelFormat pixelFormat =
      [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
  id<MTLRenderPipelineState> ps = [cache
      buildAndRegisterPipelineStateForPluginID:
          @"co.overpolish.keyframelesskit.Line"
                                    registryID:registryID
                                   pixelFormat:pixelFormat
                                      bundleID:@"co.overpolish"
                                                ".keyframeless"
                                                ".KeyframelessKit"
                                  vertexShader:@"KKVertexShader"
                                fragmentShader:@"KKLineFragment"
                                     blendMode:KKBlendModePremultipliedAlpha];
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
                   clearDestination:_clearsOnDraw
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

- (void)drawOSCWithWidth:(NSInteger)width
                  height:(NSInteger)height
              activePart:(NSInteger)activePart
        destinationImage:(FxImageTile *)destinationImage
                  atTime:(CMTime)time {
  CGPoint position = [self oscPositionAtTime:time];
  [self drawAtCanvasPosition:position
                   isHovered:_isHovered
                    isActive:_isDragging
            destinationImage:destinationImage
                      atTime:time];
}

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  _isHovered = NO;
  *activePart = 0;

  if ([self hitTestAtMousePositionX:positionX
                          positionY:positionY
                             atTime:time]) {
    _isHovered = YES;
    *activePart = 1;
  }
}

- (void)mouseEnteredAtPositionX:(double)positionX
                      positionY:(double)positionY
                      modifiers:(FxModifierKeys)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time {
}

- (void)mouseExitedAtPositionX:(double)positionX
                     positionY:(double)positionY
                     modifiers:(FxModifierKeys)modifiers
                   forceUpdate:(BOOL *)forceUpdate
                        atTime:(CMTime)time {
  _isHovered = NO;
  *forceUpdate = YES;
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(FxModifierKeys)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  _isDragging = (activePart != 0);
  *forceUpdate = YES;
}

- (void)mouseDraggedAtPositionX:(double)positionX
                      positionY:(double)positionY
                     activePart:(NSInteger)activePart
                      modifiers:(FxModifierKeys)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time {
}

- (void)mouseUpAtPositionX:(double)positionX
                 positionY:(double)positionY
                activePart:(NSInteger)activePart
                 modifiers:(FxModifierKeys)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time {
  _isDragging = NO;
  *forceUpdate = YES;
}

- (void)keyDownAtPositionX:(double)positionX
                 positionY:(double)positionY
                keyPressed:(unsigned short)asciiKey
                 modifiers:(FxModifierKeys)modifiers
               forceUpdate:(BOOL *)forceUpdate
                 didHandle:(BOOL *)didHandle
                    atTime:(CMTime)time {
  *forceUpdate = NO;
  *didHandle = NO;
}

- (void)keyUpAtPositionX:(double)positionX
               positionY:(double)positionY
              keyPressed:(unsigned short)asciiKey
               modifiers:(FxModifierKeys)modifiers
             forceUpdate:(BOOL *)forceUpdate
               didHandle:(BOOL *)didHandle
                  atTime:(CMTime)time {
  *forceUpdate = NO;
  *didHandle = NO;
}

#pragma mark - On-screen-control visibility (opt-hide / opt-reveal)

// Default hooks make the feature inert; plugin OSCs override the first two.
- (NSArray<NSString *> *)oscElementKeys {
  return @[];
}
- (NSString *)oscElementKeyForActivePart:(NSInteger)activePart {
  return nil;
}
- (UInt32)oscVisibilityParamID {
  return 201; // the established kParamUIState id, shared across plugins
}

- (BOOL)kkOSCElementVisible:(NSString *)label {
  KKPluginInstanceState *st = KKInstanceStateForAPI(self.apiManager);
  if (!st)
    return YES; // no per-instance state yet => visible (pre-toggle default)
  if (!st.oscMasterVisible)
    return NO;
  return !(st.hiddenOSCElements && [st.hiddenOSCElements containsObject:label]);
}

- (void)kkUpdateOptRevealWithModifiers:(NSUInteger)modifiers
                           forceUpdate:(BOOL *)forceUpdate {
  // Hover is the gap between interactions: reset the per-press arming so the
  // next press is judged fresh, and track the opt-reveal state for ghosts.
  _kkInteractionArmed = NO;
  BOOL reveal = (modifiers & kFxModifierKey_OPTION) != 0;
  if (reveal != self.optRevealActive) {
    self.optRevealActive = reveal;
    if (forceUpdate)
      *forceUpdate = YES;
  }
}

- (void)kkResetOptHideArming {
  _kkInteractionArmed = NO;
}

// FCP doesn't hand the viewer a reliable mouseDown, but it drives the press /
// drag cycle (the same one carrying Shift / Cmd). We latch the interaction's
// nature on its FIRST event: opt held over a hideable part => hide-click; opt
// absent => normal drag. The armed flag makes the decision stick for the rest
// of the interaction so it stays a no-op rather than half-dragging.
- (BOOL)kkArmOptHideForActivePart:(NSInteger)activePart
                        modifiers:(NSUInteger)modifiers {
  if (_kkInteractionArmed)
    return _kkInteractionIsOptHide;
  _kkInteractionArmed = YES;
  _kkInteractionIsOptHide = NO;
  if ((modifiers & kFxModifierKey_OPTION) && activePart != 0) {
    NSString *key = [self oscElementKeyForActivePart:activePart];
    if (key) {
      [self kkToggleOSCElementHidden:key];
      _kkInteractionIsOptHide = YES;
    }
  }
  return _kkInteractionIsOptHide;
}

// Flip one element's hidden state in this instance's KKPluginInstanceState
// (immediate viewer redraw) and persist it into the UI-state blob's
// `oscElements` map (stored as VISIBLE bools, matching the inspector pills).
// The write echoes through the effect's parameterChanged, syncing the inspector
// + mini-canvas. Rebuild the FULL map from the authoritative in-memory hidden
// set and base it on the cached lastUIState (the OSC's own scope read lags its
// writes - a stale base drops a sibling hidden a tick earlier, or a stale
// activeTab/loopEnabled).
- (void)kkToggleOSCElementHidden:(NSString *)key {
  KKPluginInstanceState *st = KKInstanceStateForAPI(self.apiManager);
  NSMutableSet<NSString *> *hidden =
      [(st.hiddenOSCElements ?: [NSSet set]) mutableCopy];
  if ([hidden containsObject:key])
    [hidden removeObject:key];
  else
    [hidden addObject:key];
  st.hiddenOSCElements = hidden;

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!actionAPI)
    return;
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  UInt32 paramID = [self oscVisibilityParamID];
  NSMutableDictionary *state = [st.lastUIState mutableCopy];
  if (!state) {
    NSString *existing = KKReadCustomParamString(getAPI, paramID);
    state = [(existing.length
                  ? [NSJSONSerialization
                        JSONObjectWithData:
                            [existing dataUsingEncoding:NSUTF8StringEncoding]
                                   options:0
                                     error:nil]
                  : nil) ?: @{} mutableCopy];
  }
  NSMutableDictionary<NSString *, NSNumber *> *els =
      [NSMutableDictionary dictionary];
  for (NSString *k in [self oscElementKeys])
    els[k] = @(![hidden containsObject:k]);
  state[@"oscElements"] = els;
  st.lastUIState = state;
  NSString *json = [[NSString alloc]
      initWithData:[NSJSONSerialization dataWithJSONObject:state
                                                   options:0
                                                     error:nil]
          encoding:NSUTF8StringEncoding];
  KKWriteCustomParamString(setAPI, json, paramID);
  [actionAPI endAction:self];
}

@end
