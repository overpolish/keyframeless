/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Metal pipeline-state creation for the mini viewer's composite pass, split
// from CanvasMiniViewerRenderer.m: the source-passthrough, image-overlay, and
// vector / gradient / dashed stroke pipelines, cached per pixel format.

#import "CanvasMiniViewerRenderer_Internal.h"

#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKRenderPrimitives.h>
#import <Metal/Metal.h>

@implementation CanvasMiniViewerRenderer (Pipeline)

// Source + image-overlay pipelines, built against `format` (the sRGB variant of
// the dest, so the shaders work in linear light). Both use the kit's shared
// shaders, which live in the KeyframelessKit framework bundle - Canvas ships no
// metallib of its own. Cached per format.
- (BOOL)_ensurePipelinesForDevice:(id<MTLDevice>)device
                      pixelFormat:(MTLPixelFormat)format {
  if (_pipeline && _imagePipeline && _imageTintPipeline &&
      _imageGradTintPipeline && _pipelineFormat == format)
    return YES;
  NSError *err = nil;
  id<MTLLibrary> lib = [device
      newDefaultLibraryWithBundle:[NSBundle bundleForClass:[KKMiniViewerRenderer
                                                               class]]
                            error:&err];
  if (!lib) {
    KKLogError(@"CanvasMiniViewerRenderer: no kit metallib: %@", err);
    return NO;
  }
  id<MTLFunction> vfn = [lib newFunctionWithName:@"KKVertexShader"];
  // Image layers use the transform-aware vertex shader (per-layer 4x4 model +
  // perspective for 3D tilt), matching the main render's image pipeline so the
  // preview shows X/Y rotation, not just Z.
  id<MTLFunction> tvfn = [lib newFunctionWithName:@"KKTransformVertexShader"];
  id<MTLFunction> ffn =
      [lib newFunctionWithName:@"KKTexturePassthroughFragment"];
  // Image layers fade by a per-layer Opacity uniform (premultiplied multiply).
  id<MTLFunction> offn = [lib newFunctionWithName:@"KKTextureOpacityFragment"];
  // Fill-tinted image layers: lerp the sampled image toward the fill colour /
  // (gradient variant) toward a UV-space gradient.
  id<MTLFunction> tffn = [lib newFunctionWithName:@"KKTextureTintFragment"];
  id<MTLFunction> gtffn =
      [lib newFunctionWithName:@"KKTextureGradientTintFragment"];
  // Vector strokes: transform vertex shader (compose like image layers) + the
  // antialiased line fragment, matching the main render's stroke pipeline.
  id<MTLFunction> lfn = [lib newFunctionWithName:@"KKLineFragment"];
  id<MTLFunction> glfn = [lib newFunctionWithName:@"KKGradientLineFragment"];
  // Dashed stroke: arc-threading vertex shader + the dash-mask fragment.
  id<MTLFunction> sdvfn = [lib newFunctionWithName:@"KKStrokeDashVertexShader"];
  id<MTLFunction> sdffn = [lib newFunctionWithName:@"KKStrokeDashFragment"];
  if (!vfn || !tvfn || !ffn || !offn || !tffn || !gtffn || !lfn || !glfn ||
      !sdvfn || !sdffn) {
    KKLogError(@"CanvasMiniViewerRenderer: missing passthrough shaders");
    return NO;
  }

  MTLRenderPipelineDescriptor *src = [KKRenderPrimitives
      createPipelineDescriptorWithVertexFunction:vfn
                                fragmentFunction:ffn
                                     pixelFormat:format
                                       blendMode:KKBlendModeNone];
  id<MTLRenderPipelineState> srcPS =
      [device newRenderPipelineStateWithDescriptor:src error:&err];
  if (!srcPS) {
    KKLogError(@"CanvasMiniViewerRenderer: source pipeline failed: %@", err);
    return NO;
  }

  MTLRenderPipelineDescriptor *img = [KKRenderPrimitives
      createPipelineDescriptorWithVertexFunction:tvfn
                                fragmentFunction:offn
                                     pixelFormat:format
                                       blendMode:KKBlendModePremultipliedAlpha];
  id<MTLRenderPipelineState> imgPS =
      [device newRenderPipelineStateWithDescriptor:img error:&err];
  if (!imgPS) {
    KKLogError(@"CanvasMiniViewerRenderer: image pipeline failed: %@", err);
    return NO;
  }

  MTLRenderPipelineDescriptor *imgTint = [KKRenderPrimitives
      createPipelineDescriptorWithVertexFunction:tvfn
                                fragmentFunction:tffn
                                     pixelFormat:format
                                       blendMode:KKBlendModePremultipliedAlpha];
  id<MTLRenderPipelineState> imgTintPS =
      [device newRenderPipelineStateWithDescriptor:imgTint error:&err];
  if (!imgTintPS) {
    KKLogError(@"CanvasMiniViewerRenderer: image-tint pipeline failed: %@", err);
    return NO;
  }

  MTLRenderPipelineDescriptor *imgGradTint = [KKRenderPrimitives
      createPipelineDescriptorWithVertexFunction:tvfn
                                fragmentFunction:gtffn
                                     pixelFormat:format
                                       blendMode:KKBlendModePremultipliedAlpha];
  id<MTLRenderPipelineState> imgGradTintPS =
      [device newRenderPipelineStateWithDescriptor:imgGradTint error:&err];
  if (!imgGradTintPS) {
    KKLogError(@"CanvasMiniViewerRenderer: image-grad-tint pipeline failed: %@",
               err);
    return NO;
  }

  MTLRenderPipelineDescriptor *stroke = [KKRenderPrimitives
      createPipelineDescriptorWithVertexFunction:tvfn
                                fragmentFunction:lfn
                                     pixelFormat:format
                                       blendMode:KKBlendModePremultipliedAlpha];
  id<MTLRenderPipelineState> strokePS =
      [device newRenderPipelineStateWithDescriptor:stroke error:&err];
  if (!strokePS) {
    KKLogError(@"CanvasMiniViewerRenderer: stroke pipeline failed: %@", err);
    return NO;
  }

  MTLRenderPipelineDescriptor *strokeGrad = [KKRenderPrimitives
      createPipelineDescriptorWithVertexFunction:tvfn
                                fragmentFunction:glfn
                                     pixelFormat:format
                                       blendMode:KKBlendModePremultipliedAlpha];
  id<MTLRenderPipelineState> strokeGradPS =
      [device newRenderPipelineStateWithDescriptor:strokeGrad error:&err];
  if (!strokeGradPS) {
    KKLogError(@"CanvasMiniViewerRenderer: gradient stroke pipeline failed: %@",
               err);
    return NO;
  }

  MTLRenderPipelineDescriptor *strokeDash = [KKRenderPrimitives
      createPipelineDescriptorWithVertexFunction:sdvfn
                                fragmentFunction:sdffn
                                     pixelFormat:format
                                       blendMode:KKBlendModePremultipliedAlpha];
  id<MTLRenderPipelineState> strokeDashPS =
      [device newRenderPipelineStateWithDescriptor:strokeDash error:&err];
  if (!strokeDashPS) {
    KKLogError(@"CanvasMiniViewerRenderer: dash stroke pipeline failed: %@", err);
    return NO;
  }

  _pipeline = srcPS;
  _imagePipeline = imgPS;
  _imageTintPipeline = imgTintPS;
  _imageGradTintPipeline = imgGradTintPS;
  _strokePipeline = strokePS;
  _strokeGradientPipeline = strokeGradPS;
  _strokeDashPipeline = strokeDashPS;
  _pipelineFormat = format;
  return YES;
}

@end
