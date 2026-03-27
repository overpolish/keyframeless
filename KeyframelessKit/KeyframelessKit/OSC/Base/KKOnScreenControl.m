/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKOnScreenControl.h"
#import "../../Style/NSColor+KKColors.h"
#import "KKOSCShaderTypes.h"
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKMetalDeviceCache.h>
#import <KeyframelessKit/KKRenderPrimitives.h>

@interface KKOnScreenControl () <FxOnScreenControl_v4>
@end

@implementation KKOnScreenControl {
  KKLog *_log;
  BOOL _isHovered;
  BOOL _isDragging;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super init];
  _log = [KKLog loggerForPlugin:@"co.overpolish.keyframeless"];
  if (self) {
    _apiManager = apiManager;
    _isHovered = NO;
    _isDragging = NO;
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
    [_log error:@"%@: Failed to load Metal library: %@",
                NSStringFromClass([self class]), error];
    return nil;
  }

  id<MTLFunction> vertFn = [lib newFunctionWithName:@"KKVertexShader"];
  id<MTLFunction> fragFn =
      [lib newFunctionWithName:[self fragmentFunctionName]];

  if (!vertFn || !fragFn) {
    [_log error:@"%@: Required shaders not found.",
                NSStringFromClass([self class])];
    return nil;
  }

  MTLRenderPipelineDescriptor *desc = [KKRenderPrimitives
      createPipelineDescriptorWithVertexFunction:vertFn
                                fragmentFunction:fragFn
                                     pixelFormat:pixelFormat
                                       blendMode:KKBlendModeStraightAlpha];

  ps = [device newRenderPipelineStateWithDescriptor:desc error:&error];
  if (!ps || error) {
    [_log error:@"%@: Failed to create pipeline state: %@",
                NSStringFromClass([self class]), error];
    return nil;
  }

  [cache registerPipelineState:ps
                   forPluginID:[self pipelinePluginID]
                    registryID:registryID
                   pixelFormat:pixelFormat];
  return ps;
}

- (void)drawQuadForDestinationImage:(FxImageTile *)destinationImage
                     canvasPosition:(CGPoint)canvasPosition
                      pipelineState:(id<MTLRenderPipelineState>)pipelineState
                       fragmentData:(const void *)fragmentData
                   fragmentDataSize:(size_t)fragmentDataSize
                               size:(float)size {
  [self drawQuadForDestinationImage:destinationImage
                     canvasPosition:canvasPosition
                   clearDestination:YES
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
  _isDragging = (activePart == 1);
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

@end
