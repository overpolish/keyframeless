//
//  RoundedPlugIn.m
//  Rounded
//
//  Created by Dom on 23/02/2026.
//

#import "RoundedPlugIn.h"
#import <IOSurface/IOSurfaceObjC.h>
#import <KeyframelessKit/KeyframelessKit.h>
#import "RoundedShaderTypes.h"

@implementation RoundedPlugIn

- (nullable instancetype)initWithAPIManager:(id<PROAPIAccessing>)newApiManager;
{
    NSLog(@"RoundedPlugIn: initWithAPIManager called - plugin is loading");
    self = [super init];
    if (self != nil)
    {
        _apiManager = newApiManager;
        NSLog(@"RoundedPlugIn: Successfully initialized");
    }
    return self;
}

- (BOOL)properties:(NSDictionary * _Nonnull *)properties
             error:(NSError * _Nullable *)error
{
    *properties = @{
        kFxPropertyKey_MayRemapTime : @NO,
        kFxPropertyKey_PixelTransformSupport : @(kFxPixelTransform_ScaleTranslate),
        kFxPropertyKey_VariesWhenParamsAreStatic : @NO
    };
    
    return YES;
}

- (BOOL)addParametersWithError:(NSError**)error
{
    id<FxParameterCreationAPI_v5>   paramAPI    = [_apiManager apiForProtocol:@protocol(FxParameterCreationAPI_v5)];
    if (paramAPI == nil)
    {
        if (error != NULL)
        {
            *error = [NSError errorWithDomain:FxPlugErrorDomain
                                         code:kFxError_APIUnavailable
                                     userInfo:@{ NSLocalizedDescriptionKey : @"Unable to obtain an FxPlug API Object" }];
        }
        
        return NO;
    }
    
    if (![paramAPI addFloatSliderWithName:@"Radius"
                              parameterID:1
                             defaultValue:20.0
                             parameterMin:0.0
                             parameterMax:100.0
                                sliderMin:0.0
                                sliderMax:100.0
                                    delta:1.0
                           parameterFlags:kFxParameterFlag_DEFAULT])
    {
        if (error != NULL)
        {
            *error = [NSError errorWithDomain:FxPlugErrorDomain
                                         code:kFxError_InvalidParameter
                                     userInfo:@{ NSLocalizedDescriptionKey : @"Unable to add radius slider" }];
        }
        
        return NO;
    }
    
    return YES;
}

- (BOOL)pluginState:(NSData**)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError**)error
{
    id<FxParameterRetrievalAPI_v6>  paramGetAPI = [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    if (paramGetAPI != nil)
    {
        if (error != NULL)
        {
            *error = [NSError errorWithDomain:FxPlugErrorDomain
                                         code:kFxError_ThirdPartyDeveloperStart + 20
                                     userInfo:@{ NSLocalizedDescriptionKey: @"Unable to retrieve FxParameterRetrievalAPI_v6" }];
        }
    }
    double  radius  = 20.0;
    [paramGetAPI getFloatValue:&radius fromParameter:1 atTime:renderTime];
    *pluginState = [NSData dataWithBytes:&radius length:sizeof(radius)];
    return (*pluginState != nil);
}

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

- (BOOL)sourceTileRect:(FxRect *)sourceTileRect
      sourceImageIndex:(NSUInteger)sourceImageIndex
          sourceImages:(NSArray<FxImageTile *> *)sourceImages
   destinationTileRect:(FxRect)destinationTileRect
      destinationImage:(FxImageTile *)destinationImage
           pluginState:(NSData *)pluginState
                atTime:(CMTime)renderTime
                 error:(NSError * _Nullable *)outError
{
    *sourceTileRect = destinationTileRect;
    return YES;
}

- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError * _Nullable *)outError
{
    if (!pluginState || !sourceImages [ 0 ].ioSurface || !destinationImage.ioSurface)
    {
        if (outError != NULL)
        {
            *outError = [NSError errorWithDomain:FxPlugErrorDomain
                                            code:kFxError_InvalidParameter
                                        userInfo:@{ NSLocalizedDescriptionKey: @"Invalid plugin state received from host"}];
        }
        
        return NO;
    }
    
    double  radius = 0.0;
    [pluginState getBytes:&radius length:sizeof(radius)];
    
    KKMetalDeviceCache  *cache     = [KKMetalDeviceCache sharedCache];
    MTLPixelFormat     pixelFormat     = [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
    uint64_t registryID = sourceImages[0].deviceRegistryID;
    
    id<MTLCommandQueue> commandQueue   = [cache commandQueueWithRegistryID:registryID
                                                                     pixelFormat:pixelFormat];
    if (commandQueue == nil)
    {
        return NO;
    }
    
    id<MTLCommandBuffer>    commandBuffer   = [commandQueue commandBuffer];
    commandBuffer.label = @"Rounded Command Buffer";
    [commandBuffer enqueue];
    
    id<MTLDevice> device = [cache deviceWithRegistryID:registryID];
    id<MTLTexture>  inputTexture    = [sourceImages[0] metalTextureForDevice:device];
    id<MTLTexture>  outputTexture   = [destinationImage metalTextureForDevice:device];
    
    MTLRenderPassColorAttachmentDescriptor* colorAttachment   = [[MTLRenderPassColorAttachmentDescriptor alloc] init];
    colorAttachment.texture = outputTexture;
    colorAttachment.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
    colorAttachment.loadAction = MTLLoadActionClear;
    
    MTLRenderPassDescriptor *rpd    = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments [0] = colorAttachment;
    
    id<MTLRenderCommandEncoder>   commandEncoder  = [commandBuffer renderCommandEncoderWithDescriptor:rpd];
    
    float   outputWidth     = (float)(destinationImage.tilePixelBounds.right - destinationImage.tilePixelBounds.left);
    float   outputHeight    = (float)(destinationImage.tilePixelBounds.top - destinationImage.tilePixelBounds.bottom);
    KeyframelessKitVertex2D    vertices[]  = {
        { {  outputWidth / 2.0, -outputHeight / 2.0 }, { 1.0, 1.0 } },
        { { -outputWidth / 2.0, -outputHeight / 2.0 }, { 0.0, 1.0 } },
        { {  outputWidth / 2.0,  outputHeight / 2.0 }, { 1.0, 0.0 } },
        { { -outputWidth / 2.0,  outputHeight / 2.0 }, { 0.0, 0.0 } }
    };
    
    MTLViewport viewport    = {
        0, 0, outputWidth, outputHeight, -1.0, 1.0
    };
    [commandEncoder setViewport:viewport];
    
    id<MTLRenderPipelineState>  pipelineState  = [cache pipelineStateForPluginID:@"co.overpolish.rounded"
                                                                      registryID:registryID pixelFormat:pixelFormat];
    
    if (!pipelineState)
    {
        // Build and register on first render
        id<MTLLibrary> library = [device newDefaultLibrary];
        id<MTLFunction> vertFn = [library newFunctionWithName:@"vertexShader"];
        id<MTLFunction> fragFn = [library newFunctionWithName:@"fragmentShader"];
        MTLRenderPipelineDescriptor *desc = [KeyframelessKitRenderHelpers createPipelineDescriptorWithVertexFunction:vertFn
                                                                                                    fragmentFunction:fragFn pixelFormat:pixelFormat
                                                                                                           blendMode:KKBlendModePremultipliedAlpha];
        
        NSError *pipelineError = nil;
        pipelineState = [device newRenderPipelineStateWithDescriptor:desc error:&pipelineError];
        if (pipelineState) NSLog(@"RoundedPlugin: pipeline error: %@", pipelineError);
        [cache registerPipelineState:pipelineState
                         forPluginID:@"co.overpolish.rounded"
                          registryID:registryID
                         pixelFormat:pixelFormat];
    }
    
    [commandEncoder setRenderPipelineState:pipelineState];
    [commandEncoder setVertexBytes:vertices
                            length:sizeof(vertices)
                           atIndex:KKVertexInputIndex_Vertices];
    
    simd_uint2  viewportSize = {
        (unsigned int)(outputWidth),
        (unsigned int)(outputHeight)
    };
    [commandEncoder setVertexBytes:&viewportSize
                            length:sizeof(viewportSize)
                           atIndex:KKVertexInputIndex_ViewportSize];
    
    [commandEncoder setFragmentTexture:inputTexture
                               atIndex:KKTextureIndex_InputImage];
    
    float   fragmentRadius = (float)radius;
    [commandEncoder setFragmentBytes:&fragmentRadius
                              length:sizeof(fragmentRadius)
                             atIndex:RFragmentIndex_Radius];
    
    simd_float2 imageSize = {
        (float)(destinationImage.imagePixelBounds.right - destinationImage.imagePixelBounds.left),
        (float)(destinationImage.imagePixelBounds.top - destinationImage.imagePixelBounds.bottom)
    };
    [commandEncoder setFragmentBytes:&imageSize length:(sizeof(imageSize)) atIndex:RFragmentIndex_ImageSize];
    
    simd_float2 tileOffset = {
        roundf((float)(destinationImage.tilePixelBounds.left - destinationImage.imagePixelBounds.left)),
        roundf((float)(destinationImage.tilePixelBounds.bottom - destinationImage.imagePixelBounds.bottom))
    };
    [commandEncoder setFragmentBytes:&tileOffset length:sizeof(tileOffset) atIndex:RFragmentIndex_TileOffset];
    
    [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                       vertexStart:0
                       vertexCount:4];
    [commandEncoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    
    [cache returnCommandQueueToCache:commandQueue];
    
    return YES;
    
}

@end
