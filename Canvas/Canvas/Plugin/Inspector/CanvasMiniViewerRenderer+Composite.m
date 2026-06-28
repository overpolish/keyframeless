/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The mini viewer's encode-effect render pass, split from
// CanvasMiniViewerRenderer.m: composites the source frame plus the image,
// vector-stroke, and filled layers into the preview dest - the inspector-process
// twin of the main render (Plugin+Render.m).

#import "CanvasMiniViewerRenderer_Internal.h"

#import "CanvasFillProperties.h" // CanvasFillEnabledAtFraction / StyleAtFraction
#import "CanvasFillRender.h"      // TEMP solid fill for closed paths
#import "CanvasLayerRender.h"
#import "CanvasLayerTimeline.h"
#import "CanvasLayerTree.h" // CanvasLayerPathWithAncestors
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

  [enc endEncoding]; // source base only; the layers overlay per layer below

  // 2) The layer stack PER LAYER, back-to-front (array[0] = topmost, drawn LAST),
  // each layer's image -> fill -> stroke together so z-order is correct ACROSS
  // layers (a higher layer covers a lower one) - the inspector twin of the main
  // render's runLayersOrdered. The mini dest is hazard-TRACKED, so sequential
  // render passes in this ONE command buffer serialize correctly; no separate
  // buffers / waits are needed (unlike the main render's untracked FCP dest).
  // editFraction is the keypose / boundary time when a popover edits one layer
  // (selectedLayerID + timeline override it) and 0 otherwise.
  CanvasFillPipelines fillPipes = {0};
  CanvasFillBuildPipelines(cb.device, cb.device.registryID, fmt, &fillPipes);
  BOOL miniCanFill =
      fillPipes.stencil && fillPipes.color && fillPipes.composite;
  double ef = self.editFraction < 0.0 ? 0.0 : self.editFraction;
  // Marching-ants phase: editFraction (live playhead) -> clip-local seconds, to
  // match the main render's CMTimeGetSeconds-based phase (lastKnownClipDuration
  // carries the duration into the timeline). 0 in the constants popover.
  double clipDur = self.clipDurationSeconds;
  if (clipDur <= 0.0)
    for (KKLane *l in self.timeline.lanes)
      clipDur = MAX(clipDur, l.lastKnownClipDuration);
  double miniElapsed = self.editFraction * clipDur;
  NSArray<KKBezierPath *> *mlayers = self.layers ?: @[];
  // A load-pass encoder over the dest, set up like the source pass (viewport +
  // viewport-size + the given pipeline). The mini renders the whole frame into
  // one dest (no tiling), so image dims = dest dims and the tile shift is zero.
  id<MTLRenderCommandEncoder> (^miniLoadEnc)(id<MTLRenderPipelineState>) =
      ^(id<MTLRenderPipelineState> ps) {
        MTLRenderPassDescriptor *lrpd =
            [MTLRenderPassDescriptor renderPassDescriptor];
        lrpd.colorAttachments[0].texture = dstSRGB;
        lrpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
        lrpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> e =
            [cb renderCommandEncoderWithDescriptor:lrpd];
        [e setViewport:vp];
        [e setVertexBytes:&viewportSize
                   length:sizeof(viewportSize)
                  atIndex:KKVertexInputIndex_ViewportSize];
        [e setRenderPipelineState:ps];
        return e;
      };
  // Order back-to-front (same as the main render's per-layer composite): real 3D
  // depth for separated layers, deck-facing flip for near-coincident ones.
  NSInteger miniTotal = (NSInteger)mlayers.count;
  NSInteger *miniIdx = malloc(sizeof(NSInteger) * (size_t)MAX(miniTotal, 1));
  CanvasLayerDrawKey *miniKeys =
      malloc(sizeof(CanvasLayerDrawKey) * (size_t)MAX(miniTotal, 1));
  NSInteger miniN = 0;
  for (NSInteger i = 0; i < miniTotal; i++) {
    KKBezierPath *lp = mlayers[i];
    if (lp.isGroup || lp.hidden)
      continue;
    miniIdx[miniN] = i;
    miniKeys[miniN] = CanvasLayerComposedDrawKey(
        mlayers, i, self.editFraction, w, h, 0.0f, 0.0f, self.selectedLayerID,
        self.timeline);
    miniN++;
  }
  NSInteger *miniOrdBuf = malloc(sizeof(NSInteger) * (size_t)MAX(miniN, 1));
  CanvasOrderDrawablesBackToFront(miniIdx, miniKeys, miniN,
                                  0.02f * fmaxf(w, h), miniOrdBuf);
  NSMutableArray<NSNumber *> *miniOrder =
      [NSMutableArray arrayWithCapacity:(NSUInteger)miniN];
  for (NSInteger k = 0; k < miniN; k++)
    [miniOrder addObject:@(miniOrdBuf[k])];
  free(miniIdx);
  free(miniKeys);
  free(miniOrdBuf);
  for (NSNumber *idxN in miniOrder) {
    NSInteger i = idxN.integerValue;
    KKBezierPath *p = mlayers[i];
    // Bundle p's ancestor groups so the per-layer encoders compose the group
    // transform (they skip group rows but read them); a bare @[p] drops it.
    NSArray<KKBezierPath *> *one = CanvasLayerPathWithAncestors(p, mlayers);
    if (p.isImage && _imagePipeline) {
      id<MTLRenderCommandEncoder> ienc = miniLoadEnc(_imagePipeline);
      CanvasEncodeImageLayers(one, ienc, cb.device, self.imageTextureCache, w, h,
                              0.0f, 0.0f, self.editFraction, self.selectedLayerID,
                              self.timeline, _imagePipeline, _imageTintPipeline,
                              _imageGradTintPipeline);
      [ienc endEncoding];
    }
    // A vector shape fills; an image contributes a fill only via a (non-Solid)
    // hachure overlay (Fill Style != 0).
    if (miniCanFill &&
        CanvasFillEnabledAtFraction(p, ef, self.selectedLayerID,
                                    self.timeline) &&
        (!p.isImage || CanvasFillStyleAtFraction(p, ef, self.selectedLayerID,
                                                 self.timeline)
                               .style != 0)) {
      CanvasEncodeFilledLayers(one, cb.device, self.imageTextureCache, cb,
                               dstSRGB, &fillPipes, w, h, w, h, 0.0f, 0.0f,
                               self.editFraction, self.selectedLayerID,
                               self.timeline);
    }
    if (!p.isImage && p.strokeEnabled && _strokePipeline) {
      id<MTLRenderCommandEncoder> senc = miniLoadEnc(_strokePipeline);
      CanvasEncodeVectorLayers(one, senc, cb.device, w, h, 0.0f, 0.0f,
                               self.editFraction, self.selectedLayerID,
                               self.timeline, 1.0f, miniElapsed, -1.0,
                               _strokePipeline, _strokeGradientPipeline,
                               _strokeDashPipeline);
      [senc endEncoding];
    }
  }
  return YES;
}

@end
