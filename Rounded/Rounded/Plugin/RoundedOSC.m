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

static const float kOSCRadius     = 25.0f;
static const float kOSCStroke     = 12.0f;
static const float kOSCOutline    = 2.0f;
static const NSInteger kOSCNoPart = 0;
static const NSInteger kOSCHandle = 1;

@implementation RoundedOSC {
    NSInteger _hoveredPart;
    BOOL _isDragging;
}

- (nullable instancetype)initWithAPIManager:(id<PROAPIAccessing>)newApiManager
{
    self = [super init];
    if (self != nil)
    {
        _apiManager = newApiManager;
        _hoveredPart = kOSCNoPart;
        _isDragging = NO;
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
    
    MTLViewport viewport = {
        0, 0, ioSurfaceWidth, ioSurfaceHeight, -1.0, 1.0
    };
    [commandEncoder setViewport:viewport];
    
    CGPoint canvasPosition = [self oscPositionAtTime:time];
    CGPoint position = {
        canvasPosition.x - ioSurfaceWidth / 2.0f,
        ioSurfaceHeight / 2.0 - canvasPosition.y // Y flip for Metal
    };
    
    float outerRadius = kOSCRadius;
    
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
    
    BOOL isHovered = (_hoveredPart == kOSCHandle) && !_isDragging;
    BOOL isActive  = _isDragging;
    
    float r = 1.0f, g = 1.0f, b = 1.0f;
    if (isActive) {
        r = 0.2f; g = 0.9f; b = 0.2f; // brighter green while pressing
    } else if (isHovered) {
        r = 0.4f; g = 0.8f; b = 0.4f; // softer green on hover
    }
    
    // Single pass with outline
    float params[8] = {
        (kOSCRadius - kOSCStroke) / outerRadius,        // innerRadius (normalized)
        1.0f,                                           // outerRadius (normalized)
        0.0f,                                           // gapAngle
        kOSCOutline / outerRadius,                      // outlineWidth (normalized)
        r, g, b, 1.0f                                   // fillColor (white)
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

- (CGPoint)oscPositionAtTime:(CMTime)time
{
    id<FxOnScreenControlAPI_v4> oscAPI = [_apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    if (!oscAPI) return CGPointZero;
    
    CGPoint topRight = {0, 0}, bottomLeft = {0, 0};
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT fromX:1.0 fromY:1.0
                          toSpace:kFxDrawingCoordinates_CANVAS toX:&topRight.x toY:&topRight.y];
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT fromX:0.0 fromY:0.0
                          toSpace:kFxDrawingCoordinates_CANVAS toX:&bottomLeft.x toY:&bottomLeft.y];
    
    float canvasImageWidth  = topRight.x - bottomLeft.x;
    float canvasImageHeight = topRight.y - bottomLeft.y;
    BOOL isFlippedX = canvasImageWidth  < 0;
    BOOL isFlippedY = canvasImageHeight < 0;
    
    float minDim = fminf(fabsf(canvasImageWidth), fabsf(canvasImageHeight));
    float padding = minDim * 0.05f;
    
    id<FxParameterRetrievalAPI_v6> paramGetAPI = [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    if (paramGetAPI) {
        double paramRadius = 0.0;
        [paramGetAPI getFloatValue:&paramRadius fromParameter:1 atTime:time];
        float t = paramRadius / 100.0f;
        float power = 5.0f * (1.0f - t) + 2.0f * t;
        float cornerRadiusPixels  = minDim * 0.5f * t;
        float circleInsetFactor   = 1.0f - 1.0f / sqrtf(2.0f);
        float squircleInsetFactor = 1.0f - 1.0f / powf(2.0f, 1.0f / power);
        float insetFactor         = squircleInsetFactor * (1.0f - t) + circleInsetFactor * t;
        float squircleCorrection  = 1.0f - 0.22f * sinf(t * M_PI);
        padding += cornerRadiusPixels * insetFactor * squircleCorrection;
    }
    
    float oscSize      = (kOSCRadius + kOSCStroke + kOSCOutline) / 2.0f;
    float offsetX = isFlippedX ? -(oscSize + padding) : (oscSize + padding);
    float offsetY = isFlippedY ? -(oscSize + padding) : (oscSize + padding);
    
    return CGPointMake(topRight.x - offsetX, topRight.y - offsetY);
}

- (void)hitTestOSCAtMousePositionX:(double)mousePositionX
                    mousePositionY:(double)mousePositionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time
{
    _hoveredPart = kOSCNoPart;
    *activePart = kOSCNoPart;
    
    CGPoint oscPos = [self oscPositionAtTime:time];
    float hitRadius = kOSCRadius + kOSCOutline;
    
    double dx = mousePositionX - oscPos.x;
    double dy = mousePositionY - oscPos.y;
    
    if (sqrt(dx*dx + dy*dy) <= hitRadius) {
        _hoveredPart = kOSCHandle;
        *activePart = kOSCHandle;
    }
}

- (void)mouseEnteredAtPositionX:(double)mousePositionX positionY:(double)mousePositionY modifiers:(FxModifierKeys)modifiers forceUpdate:(BOOL *)forceUpdate atTime:(CMTime)time
{
    
}

- (void)mouseExitedAtPositionX:(double)mousePositionX positionY:(double)mousePositionY modifiers:(FxModifierKeys)modifiers forceUpdate:(BOOL *)forceUpdate atTime:(CMTime)time
{
    _hoveredPart = kOSCNoPart;
    *forceUpdate = YES;
}

- (void)mouseDownAtPositionX:(double)mousePositionX
                   positionY:(double)mousePositionY
                  activePart:(NSInteger)activePart
                   modifiers:(FxModifierKeys)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time
{
    _isDragging = (activePart == kOSCHandle);
    *forceUpdate = YES;
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
