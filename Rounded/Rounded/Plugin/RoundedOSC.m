//
//  RoundedOSC.m
//  Rounded
//
//  Created by Dom on 23/02/2026.
//

#import "RoundedOSC.h"
#import "RoundedPlugIn.h"
#import "MetalDeviceCache.h"
#import "KeyframelessKit/KeyframelessKit.h"

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
    
    id<MTLTexture> outputTexture = [destinationImage metalTextureForDevice:gpuDevice];
    MTLRenderPassDescriptor *renderPassDescriptor = [KeyframelessKitRenderHelpers createClearRenderPassWithTexture:outputTexture clearColor:MTLClearColorMake(0.0, 0.0, 0.0, 0.0)];
    
    id<MTLRenderCommandEncoder> commandEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
    
    id<MTLRenderPipelineState> pipelineState = [deviceCache oscPipelineStateWithRegistryID:destinationImage.deviceRegistryID];
    [commandEncoder setRenderPipelineState:pipelineState];
    
    // Viewport
    float ioSurfaceWidth = [destinationImage.ioSurface width];
    float ioSurfaceHeight = [destinationImage.ioSurface height];
    
    // Get the center of the image and convert to shader coordinates
    id<FxOnScreenControlAPI_v4> oscAPI = [_apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    CGPoint position = { 0.0, 0.0 };
    CGPoint topRight = { 0.0, 0.0 };
    CGPoint bottomLeft = { 0.0, 0.0 };
    
    if (oscAPI) {
        // Get the top-right position (where we want to place the control)
        [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                                fromX:1.0
                                fromY:1.0
                              toSpace:kFxDrawingCoordinates_CANVAS
                                  toX:&position.x
                                  toY:&position.y];
        
        // Get the top-right corner (1.0, 1.0)
        [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                                fromX:1.0
                                fromY:1.0
                              toSpace:kFxDrawingCoordinates_CANVAS
                                  toX:&topRight.x
                                  toY:&topRight.y];
        
        // Get the bottom-left corner (0.0, 0.0)
        [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                                fromX:0.0
                                fromY:0.0
                              toSpace:kFxDrawingCoordinates_CANVAS
                                  toX:&bottomLeft.x
                                  toY:&bottomLeft.y];
        
        // Convert canvas coordinates to shader coordinates (viewport-centered with Y-flip)
        position.x -= ioSurfaceWidth / 2.0;
        position.y = ioSurfaceHeight / 2.0 - position.y;
        
    }
    
    MTLViewport viewport = {
        0, 0, ioSurfaceWidth, ioSurfaceHeight, -1.0, 1.0
    };
    [commandEncoder setViewport:viewport];
    
    float oscRadius = 25.0;
    float strokeWidth = 12.0;
    float outlineWidth = 2.0;
    float gapAngle = 0.0;
    float outerRadius = oscRadius;
    float oscSize = (oscRadius + strokeWidth + outlineWidth) / 2.0;
    
    // Calculate image dimensions in canvas space
    float canvasImageWidth = topRight.x - bottomLeft.x;
    float canvasImageHeight = topRight.y - bottomLeft.y;
    
    // Detect if scale is flipped
    BOOL isFlippedX = canvasImageWidth < 0;
    BOOL isFlippedY = canvasImageHeight < 0;
    
    float absCanvasWidth = fabsf(canvasImageWidth);
    float absCanvasHeight = fabsf(canvasImageHeight);
    float minCanvasDimension = fminf(absCanvasWidth, absCanvasHeight);
    
    float basePaddingPercent = 0.05; // 5% consistent gap from edge
    float padding = minCanvasDimension * basePaddingPercent;
    
    id<FxParameterRetrievalAPI_v6> paramGetAPI = [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    
    if (paramGetAPI != nil)
    {
        double paramRadius = 0.0;
        [paramGetAPI getFloatValue:&paramRadius fromParameter:1 atTime:time];
        
        float t = paramRadius / 100.0f;
        float power = 5.0f * (1.0f - t) + 2.0f * t;

        float cornerRadiusPixels = minCanvasDimension * 0.5f * t;

        float circleInsetFactor = 1.0f - 1.0f / sqrtf(2.0f);
        float squircleInsetFactor = 1.0f - 1.0f / powf(2.0f, 1.0f / power);
        float insetFactor = squircleInsetFactor * (1.0f - t) + circleInsetFactor * t;

        // Squircle corners are tighter than circle, reduce inset slightly in the middle
        float squircleCorrection = 1.0f - 0.22f * sinf(t * M_PI);

        float cornerInset = cornerRadiusPixels * insetFactor * squircleCorrection;

        padding += cornerInset;
    }
    
    float offsetX = isFlippedX ? -(oscSize + padding) : (oscSize + padding);
    float offsetY = isFlippedY ? -(oscSize + padding) : (oscSize + padding);
    
    position.x -= offsetX;
    position.y += offsetY;
    
    // Make quad bigger to accommodate the outline
    KeyframelessKitVertex2D quadVertices[6];
    [KeyframelessKitRenderHelpers generateQuadVertices:quadVertices center:position size:outerRadius];
    
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
        (oscRadius - strokeWidth) / outerRadius,       // innerRadius (normalized)
        1.0,                                        // outerRadius (normalized)
        gapAngle,                                   // gapAngle
        outlineWidth / outerRadius,                 // outlineWidth (normalized)
        1.0, 1.0, 1.0, 1.0                          // fillColor (white)
    };
    
    [commandEncoder setFragmentBytes:params
                              length:sizeof(params)
                             atIndex:KKOSCFragmentIndex_DrawColor];
    [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                       vertexStart:0
                       vertexCount:6];
    
    // Clean up
    [commandEncoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilScheduled];
    
    [deviceCache returnCommandQueueToCache:commandQueue];
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
