//
//  MetalDeviceCache.h
//  Rounded
//
//  Created by Dom on 23/02/2026.
//

#import <Metal/Metal.h>
#import <FxPlug/FxPlugSDK.h>

@interface MetalDeviceCache : NSObject

+ (MetalDeviceCache*)deviceCache;

- (id<MTLRenderPipelineState>)pipelineStateWithRegistryID:(uint64_t)registryID
                                              pixelFormat:(MTLPixelFormat)pixFormat;
- (id<MTLDevice>)deviceWithRegistryID:(uint64_t)registryID;
- (id<MTLCommandQueue>)commandQueueWithRegistryID:(uint64_t)registryID
                                      pixelFormat:(MTLPixelFormat)pixFormat;
- (void)returnCommandQueueToCache:(id<MTLCommandQueue>)commandQueue;

@end
