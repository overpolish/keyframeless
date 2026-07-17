/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin+Render_Internal.h"

#import <KeyframelessKit/KKMetalDeviceCache.h>
#import <KeyframelessKit/KKRenderPrimitives.h>

@implementation ShaderPlugin (RenderPipeline)

- (id<MTLRenderPipelineState>)customPipelineForSource:(NSString *)userSource
                                     destinationImage:
                                         (FxImageTile *)destinationImage {
  return [self
      customPipelineForSource:userSource
                  pixelFormat:[KKMetalDeviceCache
                                  pixelFormatForImageTile:destinationImage]
                   registryID:destinationImage.deviceRegistryID
                   bufferMode:NO];
}

- (id<MTLRenderPipelineState>)customPipelineForSource:(NSString *)userSource
                                          pixelFormat:(MTLPixelFormat)pf
                                           registryID:(uint64_t)registryID
                                           bufferMode:(BOOL)bufferMode {
  KKGLSLTranspileResult *tr = bufferMode ? KKTranspileGLSLBuffer(userSource)
                                         : KKTranspileGLSL(userSource);
  if (!tr.msl) {
    KKLogError(@"[Custom] GLSL transpile failed: %@", tr.errorLog);
    return nil;
  }
  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  NSString *pluginID = [NSString
      stringWithFormat:@"%@.custom.%lu", kPluginID, (unsigned long)tr.msl.hash];
  id<MTLRenderPipelineState> existing =
      [cache pipelineStateForPluginID:pluginID
                           registryID:registryID
                          pixelFormat:pf];
  if (existing)
    return existing;

  id<MTLDevice> device = [cache deviceWithRegistryID:registryID];
  if (!device)
    return nil;
  NSError *err = nil;
  id<MTLLibrary> lib = [device newLibraryWithSource:tr.msl
                                            options:nil
                                              error:&err];
  if (!lib) {
    KKLogError(@"[Custom] MSL compile failed: %@", err);
    return nil;
  }
  id<MTLFunction> vfn = [lib newFunctionWithName:tr.vertexName];
  id<MTLFunction> ffn = [lib newFunctionWithName:tr.fragmentName];
  if (!vfn || !ffn)
    return nil;
  MTLRenderPipelineDescriptor *desc = [KKRenderPrimitives
      createPipelineDescriptorWithVertexFunction:vfn
                                fragmentFunction:ffn
                                     pixelFormat:pf
                                       blendMode:KKBlendModePremultipliedAlpha];
  id<MTLRenderPipelineState> ps =
      [device newRenderPipelineStateWithDescriptor:desc error:&err];
  if (!ps) {
    KKLogError(@"[Custom] pipeline build failed: %@", err);
    return nil;
  }
  [cache registerPipelineState:ps
                   forPluginID:pluginID
                    registryID:registryID
                   pixelFormat:pf];
  return ps;
}

@end
