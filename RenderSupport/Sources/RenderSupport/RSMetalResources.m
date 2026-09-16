/* SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "RenderSupport.h"
#import <CoreVideo/CoreVideo.h>

MTLPixelFormat RSRenderPixelFormat(OSType ioSurfacePixelFormat) {
  switch (ioSurfacePixelFormat) {
  case kCVPixelFormatType_128RGBAFloat: return MTLPixelFormatRGBA32Float;
  case kCVPixelFormatType_32BGRA: return MTLPixelFormatBGRA8Unorm;
  default: return MTLPixelFormatRGBA16Float;
  }
}

id<MTLDevice> RSRenderDevice(uint64_t registryID) {
  static NSArray<id<MTLDevice>> *devices;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    devices = MTLCopyAllDevices();
  });
  for (id<MTLDevice> device in devices) {
    if (device.registryID == registryID)
      return device;
  }
  return nil;
}

id<MTLRenderPipelineState>
RSRenderPipeline(id<MTLDevice> device, NSBundle *bundle, MTLPixelFormat format,
                 NSString *vertex, NSString *fragment) {
  if (!device || !bundle || !vertex.length || !fragment.length)
    return nil;
  static NSMutableDictionary<NSArray *, id<MTLRenderPipelineState>> *pipelines;
  static NSLock *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    pipelines = [NSMutableDictionary dictionary];
    lock = [NSLock new];
  });
  NSArray *key =
      @[ @(device.registryID), bundle.bundlePath, @(format), vertex, fragment ];
  [lock lock];
  @try {
    id<MTLRenderPipelineState> cached = pipelines[key];
    if (cached)
      return cached;
    NSError *error = nil;
    id<MTLLibrary> library = [device newDefaultLibraryWithBundle:bundle
                                                           error:&error];
    if (!library)
      return nil;
    id<MTLFunction> v = [library newFunctionWithName:vertex];
    id<MTLFunction> f = [library newFunctionWithName:fragment];
    if (!v || !f)
      return nil;
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = v;
    descriptor.fragmentFunction = f;
    descriptor.colorAttachments[0].pixelFormat = format;
    // Colors are premultiplied; multiplying by source alpha again would darken edges.
    MTLRenderPipelineColorAttachmentDescriptor *color =
        descriptor.colorAttachments[0];
    color.blendingEnabled = YES;
    color.sourceRGBBlendFactor = MTLBlendFactorOne;
    color.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    color.sourceAlphaBlendFactor = MTLBlendFactorOne;
    color.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    id<MTLRenderPipelineState> pipeline =
        [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (pipeline)
      pipelines[key] = pipeline;
    return pipeline;
  } @finally {
    [lock unlock];
  }
}
