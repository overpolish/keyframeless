/* SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import "KFEffect.h"
@import RenderSupport;

@interface KFEffect (RenderHost)
- (id<MTLRenderPipelineState>)renderPipelineForImage:(FxImageTile *)image
                                              vertex:(NSString *)vertex
                                            fragment:(NSString *)fragment;
- (BOOL)encodeFullScreenQuadIntoTexture:(id<MTLTexture>)texture
                       destinationImage:(FxImageTile *)image
                          commandBuffer:(id<MTLCommandBuffer>)buffer
                         sourceTextures:(NSArray<id<MTLTexture>> *)sources
                               commands:(void (^)(id<MTLRenderCommandEncoder>,
                                                  NSArray<id<MTLTexture>> *))
                                            commands;
- (BOOL)
    encodeRenderCommandsForDestinationImage:(FxImageTile *)image
                               sourceImages:(NSArray<FxImageTile *> *)sources
                                      setup:
                                          (void (^)(id<MTLCommandBuffer>))setup
                                   commands:
                                       (void (^)(id<MTLRenderCommandEncoder>,
                                                 NSArray<id<MTLTexture>> *))
                                           commands;
@end
