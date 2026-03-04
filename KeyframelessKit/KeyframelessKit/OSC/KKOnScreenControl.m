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
#import "KKColors.h"

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
        _primaryColor = KKColor_Primary;
        _outlineColor = KKColor_Outline;
        _hoverColor = KKColor_Hover;
        _activeColor = KKColor_Active;
    }
    return self;
}

- (FxDrawingCoordinates)drawingCoordinates
{
    return kFxDrawingCoordinates_CANVAS;
}

- (NSString *)pipelinePluginID
{
    NSAssert(NO, @"%@ must override pipelinePluginID", NSStringFromClass([self class]));
    return nil;
}

- (NSString *)fragmentFunctionName
{
    NSAssert(NO, @"%@ must override fragmentFunctionName", NSStringFromClass([self class]));
    return nil;
}

- (float)hitRadius
{
    NSAssert(NO, @"%@ must override hitRadius", NSStringFromClass([self class]));
    return 0.0f;
}

- (float)oscSize
{
    NSAssert(NO, @"%@ must override oscSize", NSStringFromClass([self class]));
    return 0.0f;
}

- (CGPoint)oscPositionAtTime:(CMTime)time
{
    NSAssert(NO, @"KKOnScreenControl subclass must override oscPositionAtTime:");
    return CGPointZero;
}

- (BOOL)hitTestAtMousePositionX:(double)positionX
                      positionY:(double)positionY
                         atTime:(CMTime)time
{
    CGPoint pos = [self oscPositionAtTime:time];
    double dx = positionX - pos.x;
    double dy = positionY - pos.y;
    return sqrt(dx*dx + dy*dy) < self.hitRadius;
}

- (void)drawAtCanvasPosition:(CGPoint)position
                   isHovered:(BOOL)isHovered
                    isActive:(BOOL)isActive
            destinationImage:(FxImageTile *)destinationImage
                      atTime:(CMTime)time
{
    NSAssert(NO, @"KKOnScreenControl subclass must override drawAtCanvasPosition:isHovered:isActive:destinationImage:atTime:");
}

- (simd_float4)colorForHovered:(BOOL)isHovered active:(BOOL)isActive
{
    return isActive ? _activeColor : (isHovered ? _hoverColor : _primaryColor);
}

- (nullable id<MTLRenderPipelineState>)pipelineStateForRegistryID:(uint64_t)registryID
{
    KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
    
    id<MTLRenderPipelineState> ps = [cache pipelineStateForPluginID:[self pipelinePluginID]
                                                         registryID:registryID
                                                        pixelFormat:MTLPixelFormatRGBA8Unorm];
    if (ps) return ps;
    
    id<MTLDevice> device = [cache deviceWithRegistryID:registryID];
    NSBundle *bundle = [NSBundle bundleWithIdentifier:@"co.overpolish.keyframeless.KeyframelessKit"];
    NSError *error = nil;
    
    id<MTLLibrary> lib = [device newDefaultLibraryWithBundle:bundle error:&error];
    if (!lib || error)
    {
        NSLog(@"%@: Failed to load Metal library: %@", NSStringFromClass([self class]), error);
        return nil;
    }
    
    id<MTLFunction> vertFn = [lib newFunctionWithName:@"KKVertexShader"];
    id<MTLFunction> fragFn = [lib newFunctionWithName:[self fragmentFunctionName]];
    
    if (!vertFn || !fragFn)
    {
        NSLog(@"%@: Required shaders not found.", NSStringFromClass([self class]));
        return nil;
    }
    
    MTLRenderPipelineDescriptor *desc = [KKRenderHelpers createPipelineDescriptorWithVertexFunction:vertFn
                                                                                   fragmentFunction:fragFn
                                                                                        pixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                          blendMode:KKBlendModeStraightAlpha];
    
    ps = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!ps || error)
    {
        NSLog(@"%@: Failed to create pipeline state: %@", NSStringFromClass([self class]), error);
        return nil;
    }
    
    [cache registerPipelineState:ps
                     forPluginID:[self pipelinePluginID]
                      registryID:registryID
                     pixelFormat:MTLPixelFormatRGBA8Unorm];
    return ps;
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

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time
{
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
                         atTime:(CMTime)time {}

- (void)mouseExitedAtPositionX:(double)positionX
                     positionY:(double)positionY
                     modifiers:(FxModifierKeys)modifiers
                   forceUpdate:(BOOL *)forceUpdate
                        atTime:(CMTime)time
{
    _isHovered = NO;
    *forceUpdate = YES;
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(FxModifierKeys)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time
{
    _isDragging = (activePart == 1);
    *forceUpdate = YES;
}

- (void)mouseDraggedAtPositionX:(double)positionX
                      positionY:(double)positionY
                     activePart:(NSInteger)activePart
                      modifiers:(FxModifierKeys)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time {}

- (void)mouseUpAtPositionX:(double)positionX
                 positionY:(double)positionY
                activePart:(NSInteger)activePart
                 modifiers:(FxModifierKeys)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time
{
    _isDragging = NO;
    *forceUpdate = YES;
}

- (void)keyDownAtPositionX:(double)positionX
                 positionY:(double)positionY
                keyPressed:(unsigned short)asciiKey
                 modifiers:(FxModifierKeys)modifiers
               forceUpdate:(BOOL *)forceUpdate
                 didHandle:(BOOL *)didHandle
                    atTime:(CMTime)time
{
    *forceUpdate = NO;
    *didHandle = NO;
}

- (void)keyUpAtPositionX:(double)positionX
               positionY:(double)positionY
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
