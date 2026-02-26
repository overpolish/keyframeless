//
//  KKMetalDeviceCache.h
//  KeyframelessKit
//
//  Created by Dom on 25/02/2026.
//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

@class FxImageTile;

NS_ASSUME_NONNULL_BEGIN

@interface KKMetalDeviceCache : NSObject

+ (instancetype) sharedCache;

/// Register a pipeline state for a given plugin ID, registry ID, and pixel format.
/// Call this on first render, passing a pipeline built from your local shader library.
- (void)registerPipelineState:(id<MTLRenderPipelineState>)pipelineState
                  forPluginID:(NSString *)pluginID
                   registryID:(uint64_t)registryID
                  pixelFormat:(MTLPixelFormat)pixelFormat;

/// Retrieve a previously registered pipeline state.
- (nullable id<MTLRenderPipelineState>)pipelineStateForPluginID:(NSString *)pluginID
                                                     registryID:(uint64_t)registryID
                                                    pixelFormat:(MTLPixelFormat)pixelFormat;

- (nullable id<MTLDevice>)deviceWithRegistryID:(uint64_t)registryID;

- (nullable id<MTLCommandQueue>)commandQueueWithRegistryID:(uint64_t)registryID
                                              pixelFormat:(MTLPixelFormat)pixelFormat;

- (void) returnCommandQueueToCache:(id<MTLCommandQueue>)commandQueue;

+ (MTLPixelFormat)pixelFormatForImageTile:(FxImageTile *)imageTile;

@end

NS_ASSUME_NONNULL_END
