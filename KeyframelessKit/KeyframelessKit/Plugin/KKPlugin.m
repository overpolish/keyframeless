//
//  KKPlugin.m
//  KeyframelessKit
//
//  Created by Dom on 26/02/2026.
//

#import "KKPlugin.h"
#import "KKHostInfo.h"
#import "KKMetalDeviceCache.h"
#import "KKRenderHelpers.h"
#import <FxPlug/FxPlugSDK.h>

@interface KKPrincipalDelegate : NSObject <FxPrincipalDelegate>
+ (instancetype)shared;
@end

@implementation KKPrincipalDelegate

+ (instancetype)shared {
    static KKPrincipalDelegate *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[KKPrincipalDelegate alloc] init]; });
    return instance;
}

- (void)didEstablishConnectionWithHost:(NSString *)hostBundleIdentifier
                               version:(NSString *)hostVersionString {
    [KKHostInfo shared].hostID = hostBundleIdentifier;
}

@end

@implementation KKPlugin

+ (id)servicePrincipalDelegate {
    return [KKPrincipalDelegate shared];
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
{
    self = [super init];
    if (self) {
        _apiManager = apiManager;
    }
    return self;
}

- (nullable id<MTLRenderPipelineState>)pipelineStateForPluginID:(NSString *)pluginID
                                               destinationImage:(FxImageTile *)destinationImage
                                                   vertexShader:(NSString *)vertexShader
                                                 fragmentShader:(NSString *)fragmentShader
                                                      blendMode:(KKBlendMode)blendMode
{
    MTLPixelFormat pixelFormat = [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
    uint64_t registryID = destinationImage.deviceRegistryID;
    
    return [[KKMetalDeviceCache sharedCache] buildAndRegisterPipelineStateForPluginID:pluginID
                                                                           registryID:registryID
                                                                          pixelFormat:pixelFormat
                                                                             bundleID:nil
                                                                         vertexShader:vertexShader
                                                                       fragmentShader:fragmentShader
                                                                            blendMode:blendMode];
}

- (BOOL)encodeRenderCommandsForDestinationImage:(FxImageTile *)destinationImage
                                   sourceImages:(NSArray<FxImageTile *> *)sourceImages
                                       commands:(void (^)(id<MTLRenderCommandEncoder> encoder,
                                                          NSArray<id<MTLTexture>> *inputTextures))commands
{
    KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
    MTLPixelFormat pixelFormat = [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
    uint64_t registryID = destinationImage.deviceRegistryID;
    
    id<MTLCommandQueue> commandQueue = [cache commandQueueWithRegistryID:registryID pixelFormat:pixelFormat];
    if (!commandQueue) return NO;
    
    id<MTLDevice> device = [cache deviceWithRegistryID:registryID];
    id<MTLTexture> outputTexture = [destinationImage metalTextureForDevice:device];
    
    // Build input texture array - empty for generators, one or more for filters/compositors
    NSMutableArray<id<MTLTexture>> *inputTextures = [[NSMutableArray alloc] initWithCapacity:sourceImages.count];
    for (FxImageTile *sourceTile in sourceImages)
    {
        id<MTLTexture> texture = [sourceTile metalTextureForDevice:device];
        if (texture) [inputTextures addObject:texture];
    }
    
    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
    commandBuffer.label = @"KKPlugin Command Buffer";
    [commandBuffer enqueue];
    
    MTLRenderPassColorAttachmentDescriptor *colorAttachment = [[MTLRenderPassColorAttachmentDescriptor alloc] init];
    colorAttachment.texture = outputTexture;
    colorAttachment.clearColor = MTLClearColorMake(0, 0, 0, 0);
    colorAttachment.loadAction = MTLLoadActionClear;
    
    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0] = colorAttachment;
    
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:rpd];
    
    float outputWidth = (float)(destinationImage.tilePixelBounds.right - destinationImage.tilePixelBounds.left);
    float outputHeight = (float)(destinationImage.tilePixelBounds.top - destinationImage.tilePixelBounds.bottom);
    
    MTLViewport viewport = { 0, 0, outputWidth, outputHeight, -1.0, 1.0 };
    [encoder setViewport:viewport];
    
    KKVertex2D vertices[] = {
        { { outputWidth / 2.0f, -outputHeight / 2.0f }, { 1.0, 1.0 } },
        { { -outputWidth / 2.0f, -outputHeight / 2.0f }, { 0.0, 1.0 } },
        { { outputWidth / 2.0f, outputHeight / 2.0f }, { 1.0, 0.0 } },
        { { -outputWidth / 2.0f, outputHeight / 2.0f }, { 0.0, 0.0 } },
    };
    
    simd_uint2 viewportSize = { (unsigned int)outputWidth, (unsigned int)outputHeight };
    
    [encoder setVertexBytes:vertices length:sizeof(vertices) atIndex:KKVertexInputIndex_Vertices];
    [encoder setVertexBytes:&viewportSize length:sizeof((viewportSize)) atIndex:KKVertexInputIndex_ViewportSize];
    
    commands(encoder, inputTextures);
    
    [encoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    
    [cache returnCommandQueueToCache:commandQueue];
    
    return YES;
}

@end
