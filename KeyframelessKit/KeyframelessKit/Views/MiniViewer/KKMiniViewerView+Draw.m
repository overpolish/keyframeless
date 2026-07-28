/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMiniElement.h"
#import "KKMiniViewerRenderer.h"
#import "KKMiniViewerView_Private.h"
#import "KKOSCGlyphStyle.h"
#import "KKOSCShaderTypes.h"
#import "KKTokens.h"
#import "NSColor+KKColors.h"
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKRenderPrimitives.h>
#import <KeyframelessKit/KKShaderTypes.h>
#import <KeyframelessKit/KKWatermark.h>
#import <simd/simd.h>

// The per-frame render path: composes the active slot (plus any onion-skin /
// filmstrip slots) and draws the plugin handle overlay glyphs via the
// +Rendering encoders. MTKViewDelegate lives here.
@implementation KKMiniViewerView (Draw)

- (void)drawInMTKView:(MTKView *)view {
  id<CAMetalDrawable> drawable = self.currentDrawable;
  MTLRenderPassDescriptor *rpd = self.currentRenderPassDescriptor;
  if (!drawable || !rpd)
    return;

  id<MTLCommandBuffer> cb = [_queue commandBuffer];

  // Per-slot effect pass - the plugin's renderer reads its `editFraction`
  // property to pick which keypose's params to apply, so we mutate it
  // around each slot's process call. KVC because the view only knows the
  // canvasDelegate via its protocol (the renderer's concrete class lives in
  // the same KK module, so this stays cheap).
  id<KKMiniViewerDelegate> del = self.canvasDelegate;
  NSUInteger n = _filmstripSlots.count;
  BOOL canProcess =
      (del && [del respondsToSelector:@selector(miniViewer:processSourceTexture:
                                                intoTexture:commandBuffer:)]);
  // Source-less generator (no feed, produces its own pixels). Mutually
  // exclusive with the source path per slot: a slot with a source frame always
  // takes processSourceTexture:.
  BOOL canGenerate =
      (del && [del respondsToSelector:@selector(miniViewer:generateIntoTexture:
                                                commandBuffer:)]);
  // Live playback re-evaluates the effect at the moving playhead, so it
  // overrides editFraction even for a single slot; otherwise only the
  // multi-slot fan-out needs to save/restore it around the per-slot renders.
  BOOL liveOverride = self.livePlaybackActive && (canProcess || canGenerate);
  NSNumber *savedFrac =
      (canProcess || canGenerate) && (n > 1 || liveOverride)
          ? [(NSObject *)del valueForKey:@"editFraction"] // nil if absent
          : nil;
  // Feed-lock parameter-link time to the frame being rendered. Links resolve at
  // an absolute project time (`linkTimelineSec`), which the inspector normally
  // pushes from the playhead poller - but that poller only fires ~2/sec, so
  // during live playback linked values jumped while everything else stayed
  // 60fps. The feed frame's fraction (slot.tag) advances at the feed rate, and
  // the clip start is constant, so `start + tag*duration` gives a 60fps-smooth
  // project time. Saved/restored around the loop like editFraction. Renderers
  // that don't expose these keys (base mini renderer) leave savedLink nil and
  // are untouched.
  NSNumber *savedLink = nil;
  double linkClipStart = -1, linkClipDur = 0;
  if (savedFrac) {
    @try {
      NSNumber *cs = [(NSObject *)del valueForKey:@"clipTimelineStartSec"];
      NSNumber *cd = [(NSObject *)del valueForKey:@"clipDurationSeconds"];
      if (cs && cd && cs.doubleValue >= 0 && cd.doubleValue > 0) {
        linkClipStart = cs.doubleValue;
        linkClipDur = cd.doubleValue;
        savedLink = [(NSObject *)del valueForKey:@"linkTimelineSec"];
      }
    } @catch (...) {
    }
  }
  // Tell the renderer how many slots it's about to iterate so subclasses
  // can distinguish single-slot (source = plugin's published dest, blit it)
  // from multi-slot (source = raw frame at editFraction, re-render).
  if (canProcess) {
    @try {
      [(NSObject *)del setValue:@(n) forKey:@"currentSlotCount"];
    } @catch (...) {
    }
  }
  if (canProcess || canGenerate) {
    for (NSUInteger i = 0; i < n; i++) {
      _KKMiniFilmSlot *slot = _filmstripSlots[i];
      // A slot with a real source frame renders through the effect path; a
      // slot with no source, when the delegate is a generator, renders through
      // the source-less generate path.
      BOOL generating = (!slot.sourceTexture && canGenerate);
      if (!slot.sourceTexture && !generating)
        continue;
      BOOL recreatedTexture = [self _ensureProcessedTextureForSlot:slot];
      if (!slot.processedTexture)
        continue;
      // Interaction frame: the content can't have changed (only the view
      // transform), so skip the plugin effect re-render and reuse last frame's
      // processed texture. This is the big pan win - it nearly halves the frame
      // and lets macOS deliver scroll events at full rate. BUT if the texture
      // was just (re)created this frame (zoom changed the content-rect pixel
      // size, so the old texture was thrown away), the reused texture is blank
      // - it MUST be re-rendered or the slot flashes black on zoom. Pan keeps
      // the size, so it reuses intact.
      if (_reuseProcessedTexture && !recreatedTexture)
        continue;
      // Each slot renders its own keypose: point the renderer's editFraction at
      // this slot's tag before the per-slot render. Applies to BOTH the source
      // effect path and the generator path (a generator fans out its keyposes
      // the same way, just with no source frame).
      if (n > 1 || liveOverride) {
        // Render at the fraction THIS source frame represents (its feed tag),
        // so during live playback the effect transform stays locked to the
        // footage the feed just delivered rather than trailing a
        // separately-polled playhead. The multi-slot fan-out already keys off
        // the same tag.
        // During live playback prefer the publisher's PLAYHEAD fraction over the
        // frame's own tag. The tag is correct for its pixels, but FCP renders a
        // constant ~0.27s (16-20 frames at 60fps) ahead of the playhead, so
        // evaluating at the tag ran the animation that far early - a keypose
        // visibly started part-way in. Buffering the pixels to delay them
        // properly would cost ~20 surfaces at ~9MB, so the delivered frame is
        // drawn as-is and only the effect is pulled back into sync with the
        // viewer. Falls back to the tag when the publisher had no fresh sample
        // (< 0), which is also the whole multi-slot path.
        double evalFrac = slot.tag;
        if (liveOverride && _feedPlayheadFrac >= 0.0)
          evalFrac = _feedPlayheadFrac;
        @try {
          [(NSObject *)del setValue:@(evalFrac) forKey:@"editFraction"];
          if (savedLink)
            [(NSObject *)del setValue:@(linkClipStart + evalFrac * linkClipDur)
                               forKey:@"linkTimelineSec"];
        } @catch (...) {
        }
      }
      if (generating) {
        [del miniViewer:self
            generateIntoTexture:slot.processedTexture
                  commandBuffer:cb];
      } else {
        [del miniViewer:self
            processSourceTexture:slot.sourceTexture
                     intoTexture:slot.processedTexture
                   commandBuffer:cb];
      }
    }
    if (savedFrac) {
      @try {
        [(NSObject *)del setValue:savedFrac forKey:@"editFraction"];
        if (savedLink)
          [(NSObject *)del setValue:savedLink forKey:@"linkTimelineSec"];
      } @catch (...) {
      }
    }
  }
  // Slot 0 alias kept fresh for the OSC / handle / border code paths.
  _processedTexture = _filmstripSlots.firstObject.processedTexture;

  id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];

  if (_pipeline) {
    CGSize d = self.drawableSize;
    simd_uint2 vp = {(unsigned)d.width, (unsigned)d.height};
    BOOL onion = (self.renderMode == 2 && n > 1);
    NSUInteger activeIdx = onion ? [self _activeSlotIndex] : 0;

    // Helper: emit one textured quad for slot `i` at its cell rect, using
    // the currently-bound pipeline (texture / tint / alpha bound by caller).
    void (^drawSlotQuad)(NSUInteger, id<MTLTexture>) =
        ^(NSUInteger i, id<MTLTexture> tex) {
          CGRect r = [self _filmstripCellRectInDrawable:i ofTotal:n];
          float cx = (float)(CGRectGetMidX(r) - d.width / 2.0);
          float cy = (float)(CGRectGetMidY(r) - d.height / 2.0);
          float hw = (float)(r.size.width / 2.0);
          float hh = (float)(r.size.height / 2.0);
          KKVertex2D verts[4] = {
              {{cx - hw, cy + hh}, {0, 1}},
              {{cx - hw, cy - hh}, {0, 0}},
              {{cx + hw, cy + hh}, {1, 1}},
              {{cx + hw, cy - hh}, {1, 0}},
          };
          [enc setVertexBytes:verts
                       length:sizeof(verts)
                      atIndex:KKVertexInputIndex_Vertices];
          [enc setFragmentTexture:tex atIndex:KKTextureIndex_InputImage];
          [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip
                  vertexStart:0
                  vertexCount:4];
        };

    // Past a modest zoom, swap to NEAREST magnification so texels read as crisp
    // squares (pixel inspection) instead of bilinear blur; normal/zoomed-out
    // viewing keeps the smooth linear passthrough. Onion ghosts stay linear.
    id<MTLRenderPipelineState> passthrough =
        (_zoom > 3.0 && _pipelineNearest) ? _pipelineNearest : _pipeline;
    [enc setRenderPipelineState:passthrough];
    [enc setVertexBytes:&vp
                 length:sizeof(vp)
                atIndex:KKVertexInputIndex_ViewportSize];

    if (self.renderMode == 0) {
      // Off: only the active slot, even if the descriptor still has the
      // old multi-slot list - avoids a fan-out flash on a Filmstrip→Off
      // pill flip before the descriptor poll resyncs to a single slot.
      NSUInteger ai = (n > 1) ? [self _activeSlotIndex] : 0;
      _KKMiniFilmSlot *slot = _filmstripSlots[ai];
      id<MTLTexture> tex = slot.processedTexture ?: slot.sourceTexture;
      if (tex)
        drawSlotQuad(ai, tex);
    } else if (!onion) {
      // Filmstrip: passthrough for every slot, each in its own cell.
      for (NSUInteger i = 0; i < n; i++) {
        _KKMiniFilmSlot *slot = _filmstripSlots[i];
        id<MTLTexture> tex = slot.processedTexture ?: slot.sourceTexture;
        if (!tex)
          continue;
        drawSlotQuad(i, tex);
      }
    } else if (_onionPipeline) {
      // Onion: active frame opaque first, then prev (red) / next (blue)
      // ghosts on top with a low alpha so the active still reads through.
      // (Drawing active LAST would fully cover the ghosts - they paint
      // every pixel, not just outlines, so they'd be invisible.)
      _KKMiniFilmSlot *aSlot = _filmstripSlots[activeIdx];
      id<MTLTexture> aTex = aSlot.processedTexture ?: aSlot.sourceTexture;
      if (aTex)
        drawSlotQuad(activeIdx, aTex);

      [enc setRenderPipelineState:_onionPipeline];
      [enc setVertexBytes:&vp
                   length:sizeof(vp)
                  atIndex:KKVertexInputIndex_ViewportSize];
      for (NSInteger side = -1; side <= 1; side += 2) {
        NSInteger idx = (NSInteger)activeIdx + side;
        if (idx < 0 || idx >= (NSInteger)n)
          continue;
        _KKMiniFilmSlot *slot = _filmstripSlots[idx];
        id<MTLTexture> tex = slot.processedTexture ?: slot.sourceTexture;
        if (!tex)
          continue;
        simd_float4 tintRGBA = (side < 0)
                                   ? (simd_float4){1.0f, 0.2f, 0.2f, 0.7f}
                                   : (simd_float4){0.2f, 0.4f, 1.0f, 0.7f};
        float outAlpha = 0.35f;
        [enc setFragmentBytes:&tintRGBA length:sizeof(tintRGBA) atIndex:0];
        [enc setFragmentBytes:&outAlpha length:sizeof(outAlpha) atIndex:1];
        drawSlotQuad((NSUInteger)idx, tex);
      }
    }
  }

  // On-screen controls (grid, borders, rings, motion paths, handles, rotation,
  // anchor square, tool overlay, toolbar) are suppressed during live playback
  // so the moving preview reads as a clean frame - the whole overlay span is
  // gated.
  if (!self.livePlaybackActive) {
    // Alignment grid - drawn first (under the box borders + glyphs), tiled
    // across the whole view to match the in-viewer grid. Two-tone for
    // legibility.
    if (_linePipeline && del &&
        [del respondsToSelector:
                 @selector(miniViewer:gridSpacingX:spacingY:contentRect:)]) {
      CGFloat gnx = 0, gny = 0;
      CGRect gcr = [self contentRectInViewPoints];
      if ([del miniViewer:self
              gridSpacingX:&gnx
                  spacingY:&gny
               contentRect:gcr] &&
          gnx > 0 && gny > 0) {
        [self _encodeGridWithSpacingX:gnx
                             spacingY:gny
                          contentRect:gcr
                              encoder:enc];
      }
    }

    // === OSC elements: ONE generic dispatch ==============================
    // The delegate describes every element as a typed KKMiniElement
    // (KKMiniViewerRenderer assembles them from the legacy hooks; a
    // descriptor-native delegate returns them directly); the canvas encodes
    // each by kind. Two passes preserve the viewer layering: box BORDERS
    // under every glyph/ring/path, then the elements in array order.
    if (del &&
        [del
            respondsToSelector:@selector(miniViewer:elementsForContentRect:)]) {
      CGRect cr = [self contentRectInViewPoints];
      NSArray<KKMiniElement *> *els = [del miniViewer:self
                               elementsForContentRect:cr];

      if (_linePipeline) {
        for (KKMiniElement *e in els) {
          if (e.kind != KKMiniElementKindBox)
            continue;
          // Viewer KKRectBorderOSC default (white 0.6), dimmed by ghost.
          simd_float4 lineColor = {1.0f, 1.0f, 1.0f, 0.6f * (float)e.alpha};
          [self _encodeRectBorder:e.rect lineColor:lineColor encoder:enc];
        }
      }

      NSColor *a =
          [[NSColor accent] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
      CGFloat ar = 1, ag = 1, ab = 1, aa = 1;
      [a getRed:&ar green:&ag blue:&ab alpha:&aa];
      simd_float4 accentFill = {(float)ar, (float)ag, (float)ab, (float)aa};
      simd_float4 whiteFill = {1.0f, 1.0f, 1.0f, 1.0f};
      // Ring strokes scale the viewer's canvas-px widths by the mini's
      // preview-pt-over-source-px factor so the stroke-to-ring proportion
      // matches the viewer exactly.
      CGSize src = [self sourceMediaSize];
      CGFloat srcMin = MIN(src.width, src.height);
      CGFloat crMin = MIN(cr.size.width, cr.size.height);
      CGFloat srcScale = (srcMin > 0.5) ? crMin / srcMin : [self _canvasScale];

      for (KKMiniElement *e in els) {
        switch (e.kind) {
        case KKMiniElementKindBox: {
          if (!_pointPipeline)
            break;
          simd_float4 fill = whiteFill;
          fill.w *= (float)e.alpha;
          for (NSValue *v in e.handleCenters)
            [self _encodeHandleGlyphAt:v.pointValue
                             fillColor:fill
                             sizeScale:e.sizeScale
                               encoder:enc];
          break;
        }
        case KKMiniElementKindRing: {
          if (!_ringPipeline || e.radiusX <= 0.5 || e.radiusY <= 0.5)
            break;
          // THE shared ring palette (KKOSCGlyphStyle.h) - same table the
          // viewer's KKRingOSC reads, so the two can't drift.
          KKOSCRingStyle style = KKOSCRingStyleForEmphasis(e.emphasis);
          simd_float4 fillColor = style.fill;
          simd_float4 strokeColor = style.stroke;
          CGFloat viewerFillPx = style.fillWidthPx;
          CGFloat viewerOutlinePx = style.outlineWidthPx;
          fillColor.w *= (float)e.alpha;
          strokeColor.w *= (float)e.alpha;
          // Flat point boosts keep the hover/active growth perceptible at
          // mini scale (the viewer's px deltas x srcScale are sub-pixel).
          CGFloat outlineBoostPt = (e.emphasis >= 1) ? 0.35 : 0.0;
          CGFloat fillBoostPt = (e.emphasis == 0) ? 0.6 : 0.5;
          [self _encodeRingOSCAt:e.center
                       radiusXPt:e.radiusX
                       radiusYPt:e.radiusY
                       fillColor:fillColor
                     strokeColor:strokeColor
                     fillWidthPt:viewerFillPx * srcScale + fillBoostPt
                  outlineWidthPt:viewerOutlinePx * srcScale + outlineBoostPt
                         encoder:enc];
          break;
        }
        case KKMiniElementKindRotation:
          if (_rotationPipeline)
            [self _encodeRotationOSCAt:e.center
                              radiusPx:e.radiusPx
                                params:e.rotationParams
                               encoder:enc];
          break;
        case KKMiniElementKindMotionPath: {
          float pg = (float)e.alpha;
          NSArray<NSValue *> *poly = e.polyline;
          NSArray<NSValue *> *segs = e.handleSegments;
          NSArray<NSValue *> *anchors = e.anchors;
          if (_linePipeline && poly.count >= 2) {
            simd_float4 red = {1.0f, 0.25f, 0.25f, 0.9f * pg};
            [self _encodeMotionLineStrip:poly
                                   color:red
                             halfWidthPt:1.0
                                 encoder:enc];
          }
          if (_linePipeline) {
            simd_float4 white = {1.0f, 1.0f, 1.0f, 0.85f * pg};
            for (NSUInteger i = 0; i + 1 < segs.count; i += 2)
              [self _encodeMotionLineStrip:@[ segs[i], segs[i + 1] ]
                                     color:white
                               halfWidthPt:0.75
                                   encoder:enc];
          }
          if (_pointPipeline) {
            simd_float4 white = {1.0f, 1.0f, 1.0f, 1.0f * pg};
            for (NSValue *v in anchors)
              [self _encodeHandleGlyphAt:v.pointValue
                               fillColor:white
                               sizeScale:KKOSCAnchorDotScale
                                 encoder:enc];
            for (NSUInteger i = 1; i < segs.count; i += 2)
              [self _encodeHandleGlyphAt:segs[i].pointValue
                               fillColor:white
                               sizeScale:KKOSCTangentDotScale
                                 encoder:enc];
          }
          break;
        }
        case KKMiniElementKindGlyph: {
          switch ((KKMiniHandleStyle)e.style) {
          case KKMiniHandleStyleNone:
            // Anchoring-only element (guides / programmatic drag) - no glyph.
            break;
          case KKMiniHandleStyleArc:
            [self _encodeArcHandleGlyphAt:e.center
                                 isActive:e.active
                               ghostAlpha:e.alpha
                                  encoder:enc];
            break;
          case KKMiniHandleStyleRing: {
            // Haloed KKRingOSC ring (the shared radius-widget glyph), scaled
            // with the OSC sizing ratio. SOLID white (active style) to match
            // the viewer's radius widget, which sets solidStyle=YES (a small
            // handle reads unclear in the dim idle gray) - the two are
            // deliberately always-white for parity.
            // Radius widget = a ring at the shared small radius, drawn SOLID
            // (active style) to match the viewer's solidStyle radius widget.
            // Radius + stroke widths derive from the viewer's (KKOSCGlyphStyle)
            // times the mini ratio AND e.sizeScale (0.6, the point-dot shrink),
            // so the ring is the same size as the mini dots - matching the main
            // viewer where ring outer == dot outer.
            CGFloat cs = [self _canvasScale] * e.sizeScale;
            KKOSCRingStyle rs = KKOSCRingStyleForEmphasis(2);
            simd_float4 f = rs.fill;
            f.w *= (float)e.alpha;
            simd_float4 outline = rs.stroke;
            outline.w *= (float)e.alpha;
            [self _encodeRingOSCAt:e.center
                         radiusXPt:KKOSCMiniRadiusWidgetRadiusPt * cs
                         radiusYPt:KKOSCMiniRadiusWidgetRadiusPt * cs
                         fillColor:f
                       strokeColor:outline
                       fillWidthPt:rs.fillWidthPx * KKOSCMiniGlyphRatio * cs
                    outlineWidthPt:rs.outlineWidthPx * KKOSCMiniGlyphRatio * cs
                           encoder:enc];
            break;
          }
          case KKMiniHandleStyleSquare:
            if (_squarePipeline)
              [self _encodeSquareGlyphAt:e.center
                              ghostAlpha:e.alpha
                               sizeScale:e.sizeScale
                                 encoder:enc];
            break;
          default: { // Point dot: accent (or white on request), alpha-dimmed.
            if (!_pointPipeline)
              break;
            simd_float4 f = e.whiteFill ? whiteFill : accentFill;
            f.w *= (float)e.alpha;
            [self _encodeHandleGlyphAt:e.center
                             fillColor:f
                             sizeScale:e.sizeScale
                               encoder:enc];
            break;
          }
          }
          break;
        }
        }
      }
    }

    // Toolbar chrome, drawn LAST (on top of the grid + handles), the same way
    // the Tool overlay (pen anchors / handles / curve / ghost), above the gizmo
    // but under the toolbar chrome. The delegate encodes via
    // -encodeToolDotAtPoint: / -encodeToolLineStrip:, which use this armed
    // encoder + the glyph/line pipelines (same look as the motion path).
    if ((_pointPipeline || _linePipeline) && del &&
        [del respondsToSelector:@selector(
                                    miniViewerDrawToolOverlay:contentRect:)]) {
      _toolEncoder = enc;
      [self _beginToolBatch];
      [del miniViewerDrawToolOverlay:self
                         contentRect:[self contentRectInViewPoints]];
      [self _endToolBatch];
      _toolEncoder = nil;
    }

    // viewer draws it over the gizmo. The delegate renders its KKToolbar into
    // this pass via the shared -drawInEncoder: path, using the toolbar
    // pipeline.
    if (_toolbarPipeline && del &&
        [del
            respondsToSelector:@selector(miniViewer:drawToolbarInEncoder:device:
                                         pipeline:viewportWidth:height:)]) {
      CGSize d = self.drawableSize;
      [del miniViewer:self
          drawToolbarInEncoder:enc
                        device:self.device
                      pipeline:_toolbarPipeline
                 viewportWidth:(float)d.width
                        height:(float)d.height];
    }
  } // end live-playback overlay gate

  [enc endEncoding];

  // Trial mark goes on the COMPOSITED drawable, not on a slot's processed
  // texture: the template-save preview and the browser card thumbnails capture
  // that texture, and a watermark baked in there would ship with every template
  // a trial user authors. Stamping here keeps it on what's displayed and off
  // everything downstream, and being the last encode of the frame no effect
  // path can suppress it.
  if ([self.canvasDelegate isKindOfClass:[KKMiniViewerRenderer class]]) {
    NSString *wmProduct =
        ((KKMiniViewerRenderer *)self.canvasDelegate).watermarkProductID;
    if (wmProduct.length)
      KKWatermarkEncodeIfUnlicensed(wmProduct, cb, drawable.texture, NO);
  }

  [cb presentDrawable:drawable];
  [cb commit];

  // Content rect may have shifted (pan/zoom/resolve) - keep handles aligned.
  [_overlay setNeedsDisplay:YES];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
  [self setNeedsDisplay:YES];
}

@end
