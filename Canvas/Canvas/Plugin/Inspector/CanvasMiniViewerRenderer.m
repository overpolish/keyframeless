/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasMiniViewerRenderer.h"
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKShaderTypes.h>
#import <Metal/Metal.h>

NSString *const CanvasMiniViewerDescriptorPath = @"/tmp/canvas-miniviewer.json";
NSString *const CanvasMiniViewerRequestPath =
    @"/tmp/canvas-miniviewer-request.json";

@implementation CanvasMiniViewerRenderer {
  id<MTLRenderPipelineState> _pipeline;
  id<MTLDevice> _pipelineDevice;
  MTLPixelFormat _pipelineFormat;
}

// Canvas has no Crop lane, so suppress the base's default crop handles.
- (NSString *)cropLabel {
  return nil;
}

// Passthrough pipeline using the kit's shared shaders (they live in the
// KeyframelessKit framework bundle, not the plugin's - Canvas ships no
// metallib of its own). Cached per device/format.
- (id<MTLRenderPipelineState>)_pipelineForDevice:(id<MTLDevice>)device
                                     pixelFormat:(MTLPixelFormat)format {
  if (_pipeline && _pipelineDevice == device && _pipelineFormat == format)
    return _pipeline;
  NSError *err = nil;
  id<MTLLibrary> lib = [device
      newDefaultLibraryWithBundle:[NSBundle bundleForClass:[KKMiniViewerRenderer
                                                               class]]
                            error:&err];
  if (!lib) {
    KKLogError(@"CanvasMiniViewerRenderer: no kit metallib: %@", err);
    return nil;
  }
  id<MTLFunction> vfn = [lib newFunctionWithName:@"KKVertexShader"];
  id<MTLFunction> ffn = [lib newFunctionWithName:@"KKTexturePassthroughFragment"];
  if (!vfn || !ffn) {
    KKLogError(@"CanvasMiniViewerRenderer: missing passthrough shaders");
    return nil;
  }
  MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
  pd.vertexFunction = vfn;
  pd.fragmentFunction = ffn;
  pd.colorAttachments[0].pixelFormat = format;
  id<MTLRenderPipelineState> ps =
      [device newRenderPipelineStateWithDescriptor:pd error:&err];
  if (!ps) {
    KKLogError(@"CanvasMiniViewerRenderer: pipeline build failed: %@", err);
    return nil;
  }
  _pipeline = ps;
  _pipelineDevice = device;
  _pipelineFormat = format;
  return _pipeline;
}

// The base default returns NO and writes nothing, which leaves the (always
// allocated) processed texture black. Canvas is a passthrough for now, so copy
// source -> dest. A render-pass copy (not a blit) handles the source/dest pixel
// format mismatch (FCP source is float; the processed texture is BGRA8).
- (BOOL)encodeEffectFromSource:(id<MTLTexture>)source
                          into:(id<MTLTexture>)dest
                 commandBuffer:(id<MTLCommandBuffer>)cb {
  if (!source || !dest || !cb)
    return NO;
  if (source.width == 0 || source.height == 0 || dest.width == 0 ||
      dest.height == 0)
    return YES;

  id<MTLRenderPipelineState> pso = [self _pipelineForDevice:cb.device
                                                pixelFormat:dest.pixelFormat];
  if (!pso) {
    // Fallback blit (same-format only) so a transient PSO failure doesn't show
    // black.
    if (source.pixelFormat == dest.pixelFormat) {
      id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
      NSUInteger w = MIN(source.width, dest.width);
      NSUInteger h = MIN(source.height, dest.height);
      [blit copyFromTexture:source
                sourceSlice:0
                sourceLevel:0
               sourceOrigin:MTLOriginMake(0, 0, 0)
                 sourceSize:MTLSizeMake(w, h, 1)
                  toTexture:dest
           destinationSlice:0
           destinationLevel:0
          destinationOrigin:MTLOriginMake(0, 0, 0)];
      [blit endEncoding];
    }
    return YES;
  }

  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture = dest;
  rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
  rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
  float w = (float)dest.width, h = (float)dest.height;
  MTLViewport vp = {0, 0, w, h, -1.0, 1.0};
  [enc setViewport:vp];
  KKVertex2D vertices[4] = {
      {{w / 2.0f, -h / 2.0f}, {1, 1}},
      {{-w / 2.0f, -h / 2.0f}, {0, 1}},
      {{w / 2.0f, h / 2.0f}, {1, 0}},
      {{-w / 2.0f, h / 2.0f}, {0, 0}},
  };
  simd_uint2 viewportSize = {(unsigned)w, (unsigned)h};
  [enc setVertexBytes:vertices
               length:sizeof(vertices)
              atIndex:KKVertexInputIndex_Vertices];
  [enc setVertexBytes:&viewportSize
               length:sizeof(viewportSize)
              atIndex:KKVertexInputIndex_ViewportSize];
  [enc setRenderPipelineState:pso];
  [enc setFragmentTexture:source atIndex:KKTextureIndex_InputImage];
  [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  [enc endEncoding];
  return YES;
}

@end
