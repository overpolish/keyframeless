//
//  KKMetalDeviceCache.h
//  KeyframelessKit
//
//  Created by Dom on 25/02/2026.
//

#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

typedef NS_ENUM(NSUInteger, KKBlendMode)
{
    KKBlendModeNone,
    KKBlendModeStraightAlpha,
    KKBlendModePremultipliedAlpha
};

@class FxImageTile;

NS_ASSUME_NONNULL_BEGIN

@interface KKMetalDeviceCache : NSObject

+ (instancetype) sharedCache;

/// Build and register a pipeline state in one call. Returns an existing pipeline if already registered.
/// Pass nil for bundleID to use the calling plugin's default Metal library.
- (nullable id<MTLRenderPipelineState>)buildAndRegisterPipelineStateForPluginID:(NSString *)pluginID
                                                                     registryID:(uint64_t)registryID
                                                                    pixelFormat:(MTLPixelFormat)pixelFormat
                                                                       bundleID:(nullable NSString *)bundleID
                                                                   vertexShader:(NSString *)vertexShader
                                                                 fragmentShader:(NSString *)fragmentShader
                                                                      blendMode:(KKBlendMode)blendMode;

/// Register a pipeline state that was built externally.
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
