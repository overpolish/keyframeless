//
//  RoundedKFPlugIn.m
//  RoundedKF
//
//  Created by Dom on 23/02/2026.
//

#import "RoundedKFPlugIn.h"
#import <IOSurface/IOSurfaceObjC.h>
#import "TileableRemoteBrightnessShaderTypes.h"
#import "MetalDeviceCache.h"

@implementation RoundedKFPlugIn

//---------------------------------------------------------
// initWithAPIManager:
//
// This method is called when a plug-in is first loaded, and
// is a good point to conduct any checks for anti-piracy or
// system compatibility. Returning NULL means that a plug-in
// chooses not to be accessible for some reason.
//---------------------------------------------------------

- (nullable instancetype)initWithAPIManager:(id<PROAPIAccessing>)newApiManager;
{
    self = [super init];
    if (self != nil)
    {
        _apiManager = newApiManager;
    }
    return self;
}

//---------------------------------------------------------
// properties
//
// This method should return an NSDictionary defining the
// properties of the effect.
//---------------------------------------------------------

- (BOOL)properties:(NSDictionary * _Nonnull *)properties
             error:(NSError * _Nullable *)error
{
    *properties = @{
                    kFxPropertyKey_MayRemapTime : [NSNumber numberWithBool:NO],
                    kFxPropertyKey_PixelTransformSupport : [NSNumber numberWithInt:kFxPixelTransform_ScaleTranslate],
                    kFxPropertyKey_VariesWhenParamsAreStatic : [NSNumber numberWithBool:NO]
                    };
    
    return YES;
}

//---------------------------------------------------------
// addParametersWithError
//
// This method is where a plug-in defines its list of parameters.
//---------------------------------------------------------

- (BOOL)addParametersWithError:(NSError**)error
{
    id<FxParameterCreationAPI_v5>   paramAPI    = [_apiManager apiForProtocol:@protocol(FxParameterCreationAPI_v5)];
    if (paramAPI == nil)
    {
        NSDictionary*   userInfo    = @{
                                        NSLocalizedDescriptionKey : @"Unable to obtain an FxPlug API Object"
                                        };
        if (error != NULL)
            *error = [NSError errorWithDomain:FxPlugErrorDomain
                                         code:kFxError_APIUnavailable
                                     userInfo:userInfo];
        
        return NO;
    }
    
    if (![paramAPI addFloatSliderWithName:@"Brightness"
                              parameterID:1
                             defaultValue:1.0
                             parameterMin:0.0
                             parameterMax:100.0
                                sliderMin:0.0
                                sliderMax:10.0
                                    delta:0.1
                           parameterFlags:kFxParameterFlag_DEFAULT])
    {
        NSDictionary*   userInfo    = @{
                                        NSLocalizedDescriptionKey : @"Unable to add brightness slider"
                                        };
        if (error != NULL)
            *error = [NSError errorWithDomain:FxPlugErrorDomain
                                         code:kFxError_InvalidParameter
                                     userInfo:userInfo];
        
        return NO;
    }
    
    return YES;
}

//---------------------------------------------------------
// pluginState:atTime:quality:error
//
// Your plug-in should get its parameter values, do any calculations it needs to
// from those values, and package up the result to be used later with rendering.
// The host application will call this method before rendering. The
// FxParameterRetrievalAPI* is valid during this call. Use it to get the values of
// your plug-in's parameters, then put those values or the results of any calculations
// you need to do with those parameters to render into an NSData that you return
// to the host application. The host will pass it back to you during subsequent calls.
// Do not re-use the NSData; always create a new one as this method may be called
// on multiple threads at the same time.
//---------------------------------------------------------

- (BOOL)pluginState:(NSData**)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError**)error
{
    BOOL    succeeded = NO;
    id<FxParameterRetrievalAPI_v6>  paramGetAPI = [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    if (paramGetAPI != nil)
    {
        double  brightness  = 1.0;
        [paramGetAPI getFloatValue:&brightness
                     fromParameter:1
                            atTime:renderTime];
        
        *pluginState = [NSData dataWithBytes:&brightness
                                      length:sizeof(brightness)];
        
        if (*pluginState != nil)
        {
            succeeded = YES;
        }
    }
    else
    {
        if (error != NULL)
            *error = [NSError errorWithDomain:FxPlugErrorDomain
                                         code:kFxError_ThirdPartyDeveloperStart + 20
                                     userInfo:@{
                                                NSLocalizedDescriptionKey :
                                                    @"Unable to retrieve FxParameterRetrievalAPI_v6 in \
                                                    [-pluginStateAtTime:]" }];
    }
    
    return succeeded;
}

//---------------------------------------------------------
// destinationImageRect:sourceImages:destinationImage:pluginState:atTime:error
//
// This method will calculate the rectangular bounds of the output
// image given the various inputs and plug-in state
// at the given render time.
// It will pass in an array of images, the plug-in state
// returned from your plug-in's -pluginStateAtTime:error: method,
// and the render time.
//---------------------------------------------------------

- (BOOL)destinationImageRect:(FxRect *)destinationImageRect
                sourceImages:(NSArray<FxImageTile *> *)sourceImages
            destinationImage:(nonnull FxImageTile *)destinationImage
                 pluginState:(NSData *)pluginState
                      atTime:(CMTime)renderTime
                       error:(NSError * _Nullable *)outError
{
    if (sourceImages.count < 1)
    {
        NSLog (@"No inputImages list");
        return NO;
    }
    
    // In the case of a filter that only changed RGB values,
    // the output rect is the same as the input rect.
    *destinationImageRect = sourceImages [ 0 ].imagePixelBounds;
    
    return YES;
    
}

//---------------------------------------------------------
// sourceTileRect:sourceImageIndex:sourceImages:destinationTileRect:destinationImage:pluginState:atTime:error
//
// Calculate tile of the source image we need
// to render the given output tile.
//---------------------------------------------------------

- (BOOL)sourceTileRect:(FxRect *)sourceTileRect
      sourceImageIndex:(NSUInteger)sourceImageIndex
          sourceImages:(NSArray<FxImageTile *> *)sourceImages
   destinationTileRect:(FxRect)destinationTileRect
      destinationImage:(FxImageTile *)destinationImage
           pluginState:(NSData *)pluginState
                atTime:(CMTime)renderTime
                 error:(NSError * _Nullable *)outError
{
    // Since this is a color-only filter, the input tile will be the same size as the output tile
    *sourceTileRect = destinationTileRect;
    
    return YES;
}

//---------------------------------------------------------
// renderDestinationImage:sourceImages:pluginState:atTime:error:
//
// The host will call this method when it wants your plug-in to render an image
// tile of the output image. It will pass in each of the input tiles needed as well
// as the plug-in state needed for the calculations. Your plug-in should do all its
// rendering in this method. It should not attempt to use the FxParameterRetrievalAPI*
// object as it is invalid at this time. Note that this method will be called on
// multiple threads at the same time.
//---------------------------------------------------------

- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError * _Nullable *)outError
{
    if ((pluginState == nil) || (sourceImages [ 0 ].ioSurface == nil) || (destinationImage.ioSurface == nil))
    {
        NSDictionary*   userInfo    = @{
                                        NSLocalizedDescriptionKey : @"Invalid plugin state received from host"
                                        };
        if (outError != NULL)
            *outError = [NSError errorWithDomain:FxPlugErrorDomain
                                            code:kFxError_InvalidParameter
                                        userInfo:userInfo];
        return NO;
    }
    
    // This is where you would access parameter values and other info about the source tile
    // from the pluginState.
    double  brightness = 0.0;
    [pluginState getBytes:&brightness
                   length:sizeof(brightness)];
    
    // Set up the renderer, in this case we are using Metal.
    
    MetalDeviceCache*  deviceCache     = [MetalDeviceCache deviceCache];
    MTLPixelFormat     pixelFormat     = [MetalDeviceCache MTLPixelFormatForImageTile:destinationImage];
    id<MTLCommandQueue> commandQueue   = [deviceCache commandQueueWithRegistryID:sourceImages[0].deviceRegistryID
                                                                     pixelFormat:pixelFormat];
    if (commandQueue == nil)
    {
        return NO;
    }
    
    id<MTLCommandBuffer>    commandBuffer   = [commandQueue commandBuffer];
    commandBuffer.label = @"DynamicRegXPC Command Buffer";
    [commandBuffer enqueue];
    
    id<MTLTexture>  inputTexture    = [sourceImages[0] metalTextureForDevice:[deviceCache deviceWithRegistryID:sourceImages[0].deviceRegistryID]];
    id<MTLTexture>  outputTexture   = [destinationImage metalTextureForDevice:[deviceCache deviceWithRegistryID:destinationImage.deviceRegistryID]];
    
    MTLRenderPassColorAttachmentDescriptor* colorAttachmentDescriptor   = [[MTLRenderPassColorAttachmentDescriptor alloc] init];
    colorAttachmentDescriptor.texture = outputTexture;
    colorAttachmentDescriptor.clearColor = MTLClearColorMake(1.0, 0.5, 0.0, 1.0);
    colorAttachmentDescriptor.loadAction = MTLLoadActionClear;
    MTLRenderPassDescriptor*    renderPassDescriptor    = [MTLRenderPassDescriptor renderPassDescriptor];
    renderPassDescriptor.colorAttachments [ 0 ] = colorAttachmentDescriptor;
    id<MTLRenderCommandEncoder>   commandEncoder  = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
    
    // Rendering
    float   outputWidth     = (float)(destinationImage.tilePixelBounds.right - destinationImage.tilePixelBounds.left);
    float   outputHeight    = (float)(destinationImage.tilePixelBounds.top - destinationImage.tilePixelBounds.bottom);
    Vertex2D    vertices[]  = {
        { {  outputWidth / 2.0, -outputHeight / 2.0 }, { 1.0, 1.0 } },
        { { -outputWidth / 2.0, -outputHeight / 2.0 }, { 0.0, 1.0 } },
        { {  outputWidth / 2.0,  outputHeight / 2.0 }, { 1.0, 0.0 } },
        { { -outputWidth / 2.0,  outputHeight / 2.0 }, { 0.0, 0.0 } }
    };
    
    MTLViewport viewport    = {
        0, 0, outputWidth, outputHeight, -1.0, 1.0
    };
    [commandEncoder setViewport:viewport];
    
    id<MTLRenderPipelineState>  pipelineState  = [deviceCache pipelineStateWithRegistryID:sourceImages[0].deviceRegistryID
                                                                              pixelFormat:pixelFormat];
    [commandEncoder setRenderPipelineState:pipelineState];
    
    [commandEncoder setVertexBytes:vertices
                            length:sizeof(vertices)
                           atIndex:BVI_Vertices];
    
    simd_uint2  viewportSize = {
        (unsigned int)(outputWidth),
        (unsigned int)(outputHeight)
    };
    [commandEncoder setVertexBytes:&viewportSize
                            length:sizeof(viewportSize)
                           atIndex:BVI_ViewportSize];
    
    [commandEncoder setFragmentTexture:inputTexture
                               atIndex:BTI_InputImage];
    
    float   fragmentBrightness = (float)brightness;
    [commandEncoder setFragmentBytes:&fragmentBrightness
                              length:sizeof(fragmentBrightness)
                             atIndex:BFI_Brightness];
    
    [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                       vertexStart:0
                       vertexCount:4];
    
    [commandEncoder endEncoding];
    [commandBuffer commit];
    
    [commandBuffer waitUntilCompleted];
    
    [colorAttachmentDescriptor release];
    
    [deviceCache returnCommandQueueToCache:commandQueue];
    
    return YES;
    
}

@end
