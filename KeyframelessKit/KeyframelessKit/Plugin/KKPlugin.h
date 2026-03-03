//
//  KKPlugin.h
//  KeyframelessKit
//
//  Created by Dom on 26/02/2026.
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Metal/Metal.h>
#import <KeyframelessKit/KKMetalDeviceCache.h>

@class FxImageTile;
@protocol  PROAPIAccessing;

NS_ASSUME_NONNULL_BEGIN

@interface KKPlugin : NSObject

@property (nonatomic, weak) id<PROAPIAccessing> apiManager;

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager;

/// Convenience wrapper around KKMetalDeviceCache buildAndRegisterPipelineState.
/// Call from renderDestinationImage: to get or build the pipeline state for this plugin.
- (nullable id<MTLRenderPipelineState>)pipelineStateForPluginID:(NSString *)pluginID
                                               destinationImage:(FxImageTile *)destinationImage
                                                   vertexShader:(NSString *)vertexShader
                                                 fragmentShader:(NSString *)fragmentShader
                                                      blendMode:(KKBlendMode)blendMode;

/// Shared rendering infrastructure for any plugin render pass.
/// Handles command buffer, render pass, viewport, fullscreen quad, and cleanup.
/// Your block receives the encoder and input texture - set pipeline state, fragment bytes, and draw.
- (BOOL)encodeRenderCommandsForDestinationImage:(FxImageTile *)destinationImage
                                    sourceImages:(NSArray<FxImageTile *> *)sourceImages
                                        commands:(void (^)(id<MTLRenderCommandEncoder> encoder,
                                                           NSArray<id<MTLTexture>> *inputTextures))commands;

/// Returns the shared FxPrincipalDelegate that captures the host ID into KKHostInfo.
/// Pass to +[FxPrincipal startServicePrincipalWithDelegate:] in main().
+ (id)servicePrincipalDelegate;

@end

NS_ASSUME_NONNULL_END
