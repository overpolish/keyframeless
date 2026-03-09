/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <FxPlug/FxPlugSDK.h>
#import <Metal/Metal.h>

@interface MetalDeviceCache : NSObject

+ (MetalDeviceCache *)deviceCache;

- (id<MTLRenderPipelineState>)pipelineStateWithRegistryID:(uint64_t)registryID
                                              pixelFormat:
                                                  (MTLPixelFormat)pixFormat;
- (id<MTLDevice>)deviceWithRegistryID:(uint64_t)registryID;
- (id<MTLCommandQueue>)commandQueueWithRegistryID:(uint64_t)registryID
                                      pixelFormat:(MTLPixelFormat)pixFormat;
- (void)returnCommandQueueToCache:(id<MTLCommandQueue>)commandQueue;

@end
