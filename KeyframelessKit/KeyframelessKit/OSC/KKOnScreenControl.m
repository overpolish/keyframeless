//
//  KKOnScreenControl.m
//  KeyframelessKit
//
//  Created by Dom on 25/02/2026.
//

#import <FxPlug/FxPlugSDK.h>
#import "KKOnScreenControl.h"
#import "KKMetalDeviceCache.h"
#import "KKRenderHelpers.h"

@interface KKOnScreenControl () <FxOnScreenControl_v4>
@end

@implementation KKOnScreenControl {
    BOOL _isHovered;
    BOOL _isDragging;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
{
    self = [super init];
    if (self)
    {
        _apiManager = apiManager;
        _isHovered = NO;
        _isDragging = NO;
    }
    return self;
}

- (FxDrawingCoordinates)drawingCoordinates
{
    return kFxDrawingCoordinates_CANVAS;
}

- (CGPoint)oscPositionAtTime:(CMTime)time
{
    NSAssert(NO, @"KKOnScreenControl subclass must override oscPositionAtTime:");
    return CGPointZero;
}

- (BOOL)hitTestAtMousePositionX:(double)mousePositionX
                      mousePositionY:(double)mousePositionY
                         atTime:(CMTime)time
{
    NSAssert(NO, @"KKOnScreenControl subclass must override hitTestAtMousePositionX:positionY:atTime:");
    return NO;
}

- (void)drawAtCanvasPosition:(CGPoint)position
                   isHovered:(BOOL)isHovered
                    isActive:(BOOL)isActive
            destinationImage:(FxImageTile *)destinationImage
                      atTime:(CMTime)time
{
    NSAssert(NO, @"KKOnScreenControl subclass must override drawAtCanvasPosition:isHovered:isActive:destinationImage:atTime:");
}

- (void)encodeRenderCommandsForDestinationImage:(FxImageTile *)destinationImage
                                 canvasPosition:(CGPoint)canvasPosition
                                       commands:(void (^)(id<MTLRenderCommandEncoder> encoder,
                                                          CGPoint metalPosition,
                                                          simd_uint2 viewportSize))commands
{
    KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
    
    id<MTLDevice> gpuDevice = [cache deviceWithRegistryID:destinationImage.deviceRegistryID];
    id<MTLCommandQueue> queue = [cache commandQueueWithRegistryID:destinationImage.deviceRegistryID
                                                      pixelFormat:MTLPixelFormatRGBA8Unorm];
    
    if (!gpuDevice || !queue) return;
    
    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    commandBuffer.label = @"KKOnScreenControl Command Buffer";
    [commandBuffer enqueue];
    
    id<MTLTexture> outputTexture = [destinationImage metalTextureForDevice:gpuDevice];
    MTLRenderPassDescriptor *rpd = [KKRenderHelpers createClearRenderPassWithTexture:outputTexture
                                                                                       clearColor:MTLClearColorMake(0, 0, 0, 0)];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:rpd];
    
    float ioSurfaceWidth = [destinationImage.ioSurface width];
    float ioSurfaceHeight = [destinationImage.ioSurface height];
    
    MTLViewport viewport = { 0, 0, ioSurfaceWidth, ioSurfaceHeight, -1.0, 1.0 };
    [encoder setViewport:viewport];
    
    CGPoint metalPosition = {
        canvasPosition.x - ioSurfaceWidth / 2.0f,
        ioSurfaceHeight / 2.0f - canvasPosition.y
    };
    
    simd_uint2 viewportSize = {
        (unsigned int)ioSurfaceWidth,
        (unsigned int)ioSurfaceHeight
    };
    
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
                  atTime:(CMTime)time
{
    CGPoint position = [self oscPositionAtTime:time];
    [self drawAtCanvasPosition:position
                     isHovered:_isHovered
                      isActive:_isDragging
              destinationImage:destinationImage
                        atTime:time];
}

- (void)hitTestOSCAtMousePositionX:(double)mousePositionX
                    mousePositionY:(double)mousePositionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time
{
    _isHovered = NO;
    *activePart = 0;
    
    if ([self hitTestAtMousePositionX:mousePositionX
                       mousePositionY:mousePositionY
                               atTime:time]) {
        _isHovered = YES;
        *activePart = 1;
    }
}

- (void)mouseEnteredAtPositionX:(double)mousePositionX
                      positionY:(double)mousePositionY
                      modifiers:(FxModifierKeys)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time {}

- (void)mouseExitedAtPositionX:(double)mousePositionX
                     positionY:(double)mousePositionY
                     modifiers:(FxModifierKeys)modifiers
                   forceUpdate:(BOOL *)forceUpdate
                        atTime:(CMTime)time
{
    _isHovered = NO;
    *forceUpdate = YES;
}

- (void)mouseDownAtPositionX:(double)mousePositionX
                   positionY:(double)mousePositionY
                  activePart:(NSInteger)activePart
                   modifiers:(FxModifierKeys)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time
{
    _isDragging = (activePart == 1);
    *forceUpdate = YES;
}

- (void)mouseDraggedAtPositionX:(double)mousePositionX
                   positionY:(double)mousePositionY
                  activePart:(NSInteger)activePart
                   modifiers:(FxModifierKeys)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {}

- (void)mouseUpAtPositionX:(double)mousePositionX
                 positionY:(double)mousePositionY
                activePart:(NSInteger)activePart
                 modifiers:(FxModifierKeys)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time
{
    _isDragging = NO;
    *forceUpdate = YES;
}

- (void)keyDownAtPositionX:(double)mousePositionX
                 positionY:(double)mousePositionY
                keyPressed:(unsigned short)asciiKey
                 modifiers:(FxModifierKeys)modifiers
               forceUpdate:(BOOL *)forceUpdate
                 didHandle:(BOOL *)didHandle
                    atTime:(CMTime)time
{
    *forceUpdate = NO;
    *didHandle = NO;
}

- (void)keyUpAtPositionX:(double)mousePositionX
               positionY:(double)mousePositionY
              keyPressed:(unsigned short)asciiKey
               modifiers:(FxModifierKeys)modifiers
             forceUpdate:(BOOL *)forceUpdate
               didHandle:(BOOL *)didHandle
                  atTime:(CMTime)time
{
    *forceUpdate = NO;
    *didHandle = NO;
}

@end
