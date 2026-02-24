//
//  RoundedOSC.m
//  Rounded
//
//  Created by Dom on 23/02/2026.
//

#import "RoundedOSC.h"
#import "RoundedPlugIn.h"
#import "MetalDeviceCache.h"
#import "RoundedShaderTypes.h"

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
    float destImageWidth = destinationImage.imagePixelBounds.right - destinationImage.imagePixelBounds.left;
    float destImageHeight = destinationImage.imagePixelBounds.top - destinationImage.imagePixelBounds.bottom;
    float ioSurfaceHeight = [destinationImage.ioSurface height];
    MTLViewport viewport = {
        0, ioSurfaceHeight - destImageHeight, destImageWidth, destImageHeight, -1.0, 1.0
    };
    [commandEncoder setViewport:viewport];
    
    // Circle in the center
    CGPoint center = { 0.0, 0.0 }; // canvas coords
    float radius = 50.0;
    
#define kNumAngles 24
#define kDegreesPerIteration (360 / kNumAngles)
#define kNumCircleVertices (3 * kNumAngles)
    
    Vertex2D circleVertices[kNumCircleVertices];
    simd_float2 zeroZero = { 0.0, 0.0 };
    
    for (int i = 0; i < kNumAngles; ++i)
    {
        // Center
        circleVertices[i * 3 + 0].position.x = center.x;
        circleVertices[i * 3 + 0].position.y = center.y;
        circleVertices[i * 3 + 0].textureCoordinate = zeroZero;
        
        // Point at i degrees on outer edge
        double radians = (double)(i * kDegreesPerIteration) * M_PI / 180.0;
        circleVertices[i * 3 + 1].position.x = center.x + cos(radians) * radius;
        circleVertices[i * 3 + 1].position.y = center.y + sin(radians) * radius;
        circleVertices[i * 3 + 1].textureCoordinate = zeroZero;
        
        // Point at (i + 1) degrees on outer edge
        radians = (double)((i + 1) * kDegreesPerIteration) * M_PI / 180.0;
        circleVertices[i * 3 + 2].position.x = center.x + cos(radians) * radius;
        circleVertices[i * 3 + 2].position.y = center.y + sin(radians) * radius;
        circleVertices[i * 3 + 2].textureCoordinate = zeroZero;
    }
    
    [commandEncoder setVertexBytes:circleVertices
                            length:sizeof(circleVertices)
                           atIndex:RVI_Vertices];
    
    simd_uint2 viewportSize = {
        (unsigned int)(destImageWidth),
        (unsigned int)(destImageHeight)
    };
    [commandEncoder setVertexBytes:&viewportSize
                            length:sizeof(viewportSize)
                           atIndex:RVI_ViewportSize];
    
    simd_float4 whiteColor = { 1.0, 1.0, 1.0, 1.0 };
    [commandEncoder setFragmentBytes:&whiteColor
                              length:sizeof(whiteColor)
                             atIndex:ROFI_DrawColor];
    
    [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                        vertexStart:0
                       vertexCount:kNumCircleVertices];
    
#undef kNumAngles
#undef kDegreesPerIteration
#undef kNumCircleVertices
    
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
