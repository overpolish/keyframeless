/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "MetalDeviceCache.h"
#import "Constants.h"
#import <KeyframelessKit/KeyframelessKit.h>

static RoundedMetalDeviceCache *gDeviceCache = nil;

@implementation RoundedMetalDeviceCache {
  KKLog *_log;
}

+ (RoundedMetalDeviceCache *)deviceCache;
{
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    gDeviceCache = [[RoundedMetalDeviceCache alloc] init];
  });
  return gDeviceCache;
}

- (id<MTLRenderPipelineState>)pipelineStateWithRegistryID:(uint64_t)registryID
                                              pixelFormat:
                                                  (MTLPixelFormat)pixelFormat {
  _log = [KKLog loggerForPlugin:@"co.overpolish.keyframeless"];
  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];

  id<MTLRenderPipelineState> ps = [cache pipelineStateForPluginID:kPluginID
                                                       registryID:registryID
                                                      pixelFormat:pixelFormat];
  if (ps)
    return ps;

  id<MTLDevice> device = [cache deviceWithRegistryID:registryID];
  id<MTLLibrary> library = [device newDefaultLibrary];

  id<MTLFunction> vertFn = [library newFunctionWithName:@"vertexShader"];
  id<MTLFunction> fragFn = [library newFunctionWithName:@"fragmentShader"];

  MTLRenderPipelineDescriptor *desc = [KKRenderPrimitives
      createPipelineDescriptorWithVertexFunction:vertFn
                                fragmentFunction:fragFn
                                     pixelFormat:pixelFormat
                                       blendMode:KKBlendModePremultipliedAlpha];
  NSError *error = nil;
  ps = [device newRenderPipelineStateWithDescriptor:desc error:&error];
  if (error) {
    [_log error:@"MetalDeviceCache: pipeline error: %@", error];
  }

  [cache registerPipelineState:ps
                   forPluginID:kPluginID
                    registryID:registryID
                   pixelFormat:pixelFormat];

  return ps;
}

- (id<MTLDevice>)deviceWithRegistryID:(uint64_t)registryID {
  return [[KKMetalDeviceCache sharedCache] deviceWithRegistryID:registryID];
}

- (id<MTLCommandQueue>)commandQueueWithRegistryID:(uint64_t)registryID
                                      pixelFormat:(MTLPixelFormat)pixFormat;
{
  return
      [[KKMetalDeviceCache sharedCache] commandQueueWithRegistryID:registryID
                                                       pixelFormat:pixFormat];
}

- (void)returnCommandQueueToCache:(id<MTLCommandQueue>)commandQueue;
{ [[KKMetalDeviceCache sharedCache] returnCommandQueueToCache:commandQueue]; }

@end
