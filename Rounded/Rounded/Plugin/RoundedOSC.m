//
//  RoundedOSC.m
//  Rounded
//
//  Created by Dom on 23/02/2026.
//

#import "RoundedOSC.h"
#import "RoundedPlugIn.h"
#import "MetalDeviceCache.h"
#import "KeyframelessKit/ShaderTypes.h"

@implementation RoundedOSC

- (nullable instancetype)initWithAPIManager:(id<PROAPIAccessing>)newApiManager
{
    self = [super init];
    if (self != nil)
    {
        _apiManager = newApiManager;
    }
    return self;
}

- (FxDrawingCoordinates)drawingCoordinates
{
    return kFxDrawingCoordinates_CANVAS;
}

static void GenerateQuadVertices(KeyframelessKitVertex2D *vertices, CGPoint center, float size)
{
    vertices[0].position = (simd_float2){ center.x - size, center.y - size };
    vertices[0].textureCoordinate = (simd_float2){ -1.0, -1.0 };
    
    vertices[1].position = (simd_float2){ center.x + size, center.y - size };
    vertices[1].textureCoordinate = (simd_float2){ 1.0, -1.0 };
    
    vertices[2].position = (simd_float2){ center.x + size, center.y + size };
    vertices[2].textureCoordinate = (simd_float2){ 1.0, 1.0 };
    
    vertices[3].position = (simd_float2){ center.x - size, center.y - size };
    vertices[3].textureCoordinate = (simd_float2){ -1.0, -1.0 };
    
    vertices[4].position = (simd_float2){ center.x + size, center.y + size };
    vertices[4].textureCoordinate = (simd_float2){ 1.0, 1.0 };
    
    vertices[5].position = (simd_float2){ center.x - size, center.y + size };
    vertices[5].textureCoordinate = (simd_float2){ -1.0, 1.0 };
}

- (void)drawOSCWithWidth:(NSInteger)width
                  height:(NSInteger)height
              activePart:(NSInteger)activePart
        destinationImage:(FxImageTile *)destinationImage
                  atTime:(CMTime)time
{
    MetalDeviceCache *deviceCache = [MetalDeviceCache deviceCache];
    id<MTLDevice> gpuDevice = [deviceCache deviceWithRegistryID:destinationImage.deviceRegistryID];
    id<MTLCommandQueue> commandQueue = [deviceCache commandQueueWithRegistryID:destinationImage.deviceRegistryID pixelFormat:MTLPixelFormatRGBA16Float];
    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
    commandBuffer.label = @"Rounded OSC Command Buffer";
    [commandBuffer enqueue];
    
    // Color attachment
    id<MTLTexture> outputTexture = [destinationImage metalTextureForDevice:gpuDevice];
    MTLRenderPassColorAttachmentDescriptor *colorAttachment = [[MTLRenderPassColorAttachmentDescriptor alloc] init];
    colorAttachment.texture = outputTexture;
    colorAttachment.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
    colorAttachment.loadAction = MTLLoadActionClear;
    
    MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    renderPassDescriptor.colorAttachments[0] = colorAttachment;
    
    id<MTLRenderCommandEncoder> commandEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
    
    id<MTLRenderPipelineState> pipelineState = [deviceCache oscPipelineStateWithRegistryID:destinationImage.deviceRegistryID];
    [commandEncoder setRenderPipelineState:pipelineState];
    
    // Viewport
    float ioSurfaceWidth = [destinationImage.ioSurface width];
    float ioSurfaceHeight = [destinationImage.ioSurface height];
    
    // Get the center of the image and convert to shader coordinates
    id<FxOnScreenControlAPI_v4> oscAPI = [_apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    CGPoint center = { 0.0, 0.0 };
    
    if (oscAPI) {
        // Convert image center (0.5, 0.5 in normalized object coordinates) to canvas coordinates
        [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                                fromX:0.5
                                fromY:0.5
                              toSpace:kFxDrawingCoordinates_CANVAS
                                  toX:&center.x
                                  toY:&center.y];
        
        // Convert canvas coordinates to shader coordinates (viewport-centered with Y-flip)
        center.x -= ioSurfaceWidth / 2.0;
        center.y = ioSurfaceHeight / 2.0 - center.y;
        
    }
    
    MTLViewport viewport = {
        0, 0, ioSurfaceWidth, ioSurfaceHeight, -1.0, 1.0
    };
    [commandEncoder setViewport:viewport];
    
    float radius = 25.0;
    float strokeWidth = 12.0;
    float outlineWidth = 2.0;
    float gapAngle = 0.0;
    float outerRadius = radius;
    
    // Make quad bigger to accommodate the outline
    KeyframelessKitVertex2D quadVertices[6];
    GenerateQuadVertices(quadVertices, center, outerRadius);
    
    [commandEncoder setVertexBytes:quadVertices
                            length:sizeof(quadVertices)
                           atIndex:KKVertexInputIndex_Vertices];
    
    [commandEncoder setVertexBytes:quadVertices
                            length:sizeof(quadVertices)
                           atIndex:KKVertexInputIndex_Vertices];
    
    simd_uint2 viewportSize = {
        (unsigned int)(ioSurfaceWidth),
        (unsigned int)(ioSurfaceHeight)
    };
    [commandEncoder setVertexBytes:&viewportSize
                            length:sizeof(viewportSize)
                           atIndex:KKVertexInputIndex_ViewportSize];
    
    // Single pass with outline
    float params[8] = {
        (radius - strokeWidth) / outerRadius,       // innerRadius (normalized)
        1.0,                                        // outerRadius (normalized)
        gapAngle,                                   // gapAngle
        outlineWidth / outerRadius,                 // outlineWidth (normalized)
        1.0, 1.0, 1.0, 1.0                         // fillColor (white)
    };

    [commandEncoder setFragmentBytes:params length:sizeof(params) atIndex:KKOSCFragmentIndex_DrawColor];
    [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    
    // Clean up
    [commandEncoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilScheduled];
    
    [deviceCache returnCommandQueueToCache:commandQueue];
    [colorAttachment release];
}

- (void)hitTestOSCAtMousePositionX:(double)mousePositionX
                    mousePositionY:(double)mousePositionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time
{
    *activePart = 0;
}

- (void)mouseDownAtPositionX:(double)mousePositionX
                   positionY:(double)mousePositionY
                  activePart:(NSInteger)activePart
                   modifiers:(FxModifierKeys)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time
{
    *forceUpdate = NO;
}

- (void)mouseDraggedAtPositionX:(double)mousePositionX
                      positionY:(double)mousePositionY
                     activePart:(NSInteger)activePart
                      modifiers:(FxModifierKeys)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time
{
    
}

- (void)mouseUpAtPositionX:(double)mousePositionX
                 positionY:(double)mousePositionY
                activePart:(NSInteger)activePart
                 modifiers:(FxModifierKeys)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time
{
    *forceUpdate = NO;
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
