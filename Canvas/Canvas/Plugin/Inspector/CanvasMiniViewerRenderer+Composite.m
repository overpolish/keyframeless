/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The mini viewer's encode-effect render pass, split from
// CanvasMiniViewerRenderer.m: composites the source frame plus the image,
// vector-stroke, and filled layers into the preview dest - the inspector-process
// twin of the main render (Plugin+Render.m).

#import "CanvasMiniViewerRenderer_Internal.h"

#import "CanvasFillRender.h" // TEMP solid fill for closed paths
#import "CanvasLayerRender.h"
#import "CanvasLayerTimeline.h"
#import <KeyframelessKit/KKShaderTypes.h>
#import <Metal/Metal.h>

// The sRGB sibling of an 8-bit format, so a texture view of it gamma-decodes on
// read / encodes on write (a linear-light working pass). Mirrors the main
// render, which composites in FCP's float/linear space; without it the 8-bit
// mini dest would composite in gamma space and the image would read too dark.
// Returns the input unchanged when there's no sRGB sibling (float formats).
static MTLPixelFormat CanvasSRGBVariant(MTLPixelFormat f) {
  switch (f) {
  case MTLPixelFormatBGRA8Unorm:
    return MTLPixelFormatBGRA8Unorm_sRGB;
  case MTLPixelFormatRGBA8Unorm:
    return MTLPixelFormatRGBA8Unorm_sRGB;
  default:
    return f;
  }
}

@implementation CanvasMiniViewerRenderer (Composite)

// Runs the same compositing as the main render (Plugin+Render.m) in the
// inspector process: draw the source frame, then composite every visible image
// layer over it (shared CanvasEncodeImageLayers). Works in linear light through
// sRGB texture views so the preview matches the viewer.
- (BOOL)encodeEffectFromSource:(id<MTLTexture>)source
                          into:(id<MTLTexture>)dest
                 commandBuffer:(id<MTLCommandBuffer>)cb {
  if (!source || !dest || !cb)
    return NO;
  if (source.width == 0 || source.height == 0 || dest.width == 0 ||
      dest.height == 0)
    return YES;

  MTLPixelFormat fmt = CanvasSRGBVariant(dest.pixelFormat);
  if (![self _ensurePipelinesForDevice:cb.device pixelFormat:fmt]) {
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

  // Read source as linear (sRGB-decode on sample), write dest as linear
  // (sRGB-encode on store); fall back to the plain textures if no view applies.
  id<MTLTexture> srcLin =
      [source
          newTextureViewWithPixelFormat:CanvasSRGBVariant(source.pixelFormat)]
          ?: source;
  id<MTLTexture> dstSRGB = [dest newTextureViewWithPixelFormat:fmt] ?: dest;

  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture = dstSRGB;
  rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
  rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];

  float w = (float)dest.width, h = (float)dest.height;
  self.renderWidth = w;
  self.renderHeight = h;
  // The feed source is the full project frame (render requests the full source
  // tile), so its dims are the TRUE output px the outline op needs.
  self.outputWidth = (CGFloat)source.width;
  self.outputHeight = (CGFloat)source.height;
  MTLViewport vp = {0, 0, w, h, -1.0, 1.0};
  [enc setViewport:vp];
  simd_uint2 viewportSize = {(unsigned)w, (unsigned)h};
  [enc setVertexBytes:&viewportSize
               length:sizeof(viewportSize)
              atIndex:KKVertexInputIndex_ViewportSize];

  // 1) Source frame, full-screen.
  KKVertex2D srcQuad[4] = {
      {{w / 2.0f, -h / 2.0f}, {1, 1}},
      {{-w / 2.0f, -h / 2.0f}, {0, 1}},
      {{w / 2.0f, h / 2.0f}, {1, 0}},
      {{-w / 2.0f, h / 2.0f}, {0, 0}},
  };
  [enc setVertexBytes:srcQuad
               length:sizeof(srcQuad)
              atIndex:KKVertexInputIndex_Vertices];
  [enc setRenderPipelineState:_pipeline];
  [enc setFragmentTexture:srcLin atIndex:KKTextureIndex_InputImage];
  [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip
          vertexStart:0
          vertexCount:4];

  // 2) Image layers over the source (shared with the main render), each
  // transformed at the renderer's current time. editFraction is the keypose /
  // boundary time when a popover is editing one (so the preview matches the
  // edited pose) and 0 otherwise (constants resolve correctly there).
  [enc setRenderPipelineState:_imagePipeline];
  // The mini renders the whole frame into one dest (no tiling), so image dims =
  // dest dims and the tile shift is zero.
  CanvasEncodeImageLayers(
      self.layers ?: @[], enc, cb.device, self.imageTextureCache, w, h, 0.0f,
      0.0f, self.editFraction, self.selectedLayerID, self.timeline,
      _imagePipeline, _imageTintPipeline, _imageGradTintPipeline);

  [enc endEncoding];

  // 3) TEMP solid fill for closed filled paths, mirroring the main render. The
  // stencil even-odd needs its own passes (this MTKView pass has no stencil
  // attachment), so run them after the encoder ends, over the same dest. Drawn
  // BEFORE the strokes so a fill sits under its stroke.
  CanvasFillPipelines fillPipes = {0};
  CanvasFillBuildPipelines(cb.device, cb.device.registryID, fmt, &fillPipes);
  if (fillPipes.stencil && fillPipes.color && fillPipes.composite)
    CanvasEncodeFilledLayers(self.layers ?: @[], cb.device,
                             self.imageTextureCache, cb, dstSRGB, &fillPipes, w, h,
                             w, h, 0.0f, 0.0f, self.editFraction,
                             self.selectedLayerID, self.timeline);

  // 4) Vector strokes LAST, in their own LOAD pass over the same dest, so a fill
  // sits UNDER its stroke (mirrors the main render's stroke-after-fill order).
  // Same viewport / viewport-size as the source + image pass.
  if (_strokePipeline) {
    MTLRenderPassDescriptor *srpd =
        [MTLRenderPassDescriptor renderPassDescriptor];
    srpd.colorAttachments[0].texture = dstSRGB;
    srpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
    srpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> senc =
        [cb renderCommandEncoderWithDescriptor:srpd];
    [senc setViewport:vp];
    [senc setVertexBytes:&viewportSize
                  length:sizeof(viewportSize)
                 atIndex:KKVertexInputIndex_ViewportSize];
    [senc setRenderPipelineState:_strokePipeline];
    // strokeScale 1.0: the mini already renders at the dest size. Marching-ants
    // phase at the previewed frame: editFraction is the live playhead time, so
    // map it to clip-local seconds (editFraction x clip duration) to match the
    // main render's CMTimeGetSeconds-based phase (KKLane.lastKnownClipDuration
    // carries the duration into the timeline). 0 in the constants popover.
    double clipDur = self.clipDurationSeconds;
    if (clipDur <= 0.0) // fall back to whatever the timeline carries
      for (KKLane *l in self.timeline.lanes)
        clipDur = MAX(clipDur, l.lastKnownClipDuration);
    double miniElapsed = self.editFraction * clipDur;
    CanvasEncodeVectorLayers(self.layers ?: @[], senc, cb.device, w, h, 0.0f,
                             0.0f, self.editFraction, self.selectedLayerID,
                             self.timeline, 1.0f, miniElapsed, _strokePipeline,
                             _strokeGradientPipeline, _strokeDashPipeline);
    [senc endEncoding];
  }
  return YES;
}

@end
