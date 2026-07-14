/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMiniViewerRenderer.h"
#import "KKMiniViewerView_Private.h"
#import "KKOSCShaderTypes.h"
#import "KKTokens.h"
#import "NSColor+KKColors.h"
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKRenderPrimitives.h>
#import <KeyframelessKit/KKShaderTypes.h>
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
  NSNumber *savedFrac =
      (canProcess || canGenerate) && n > 1
          ? [(NSObject *)del valueForKey:@"editFraction"] // nil if absent
          : nil;
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
      if (n > 1) {
        @try {
          [(NSObject *)del setValue:@(slot.tag) forKey:@"editFraction"];
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

  // Alignment grid - drawn first (under the box borders + glyphs), tiled across
  // the whole view to match the in-viewer grid. Two-tone for legibility.
  if (_linePipeline && del &&
      [del respondsToSelector:
               @selector(miniViewer:gridSpacingX:spacingY:contentRect:)]) {
    CGFloat gnx = 0, gny = 0;
    CGRect gcr = [self contentRectInViewPoints];
    if ([del miniViewer:self gridSpacingX:&gnx spacingY:&gny contentRect:gcr] &&
        gnx > 0 && gny > 0) {
      [self _encodeGridWithSpacingX:gnx
                           spacingY:gny
                        contentRect:gcr
                            encoder:enc];
    }
  }

  // Box OSC borders (crop, scale, ...) - drawn here (before the glyphs) so the
  // handles sit on top of the line, not under it. Every box matches the in-
  // viewer KKRectBorderOSC default (white 0.6), dimmed by its ghost alpha.
  if (_linePipeline && del &&
      [del respondsToSelector:@selector(miniViewer:boxesForContentRect:)]) {
    CGRect cr = [self contentRectInViewPoints];
    for (KKMiniBox *box in [del miniViewer:self boxesForContentRect:cr]) {
      simd_float4 lineColor = {1.0f, 1.0f, 1.0f, 0.6f * (float)box.ghostAlpha};
      [self _encodeRectBorder:box.rect lineColor:lineColor encoder:enc];
    }
  }

  // Ring OSC (e.g. Glow's radius): the in-viewer KKRingOSC, rendered through
  // the SAME shader (_ringPipeline / KKRingOSCFragment) - a single-pass
  // elliptical fill+outline. No tessellation seams, no fill/outline bleed.
  if (_ringPipeline && del &&
      [del respondsToSelector:
               @selector(miniViewer:ringCenter:radiusX:radiusY:contentRect:)]) {
    CGPoint rc = CGPointZero;
    CGFloat rrx = 0, rry = 0;
    CGRect ringCR = [self contentRectInViewPoints];
    if ([del miniViewer:self
             ringCenter:&rc
                radiusX:&rrx
                radiusY:&rry
            contentRect:ringCR] &&
        rrx > 0.5 && rry > 0.5) {
      // Viewer KKRingOSC idle / hover / active, VERBATIM: same colors AND the
      // same fillWidth / outlineWidth (2.0/1.0, 2.5/1.5). The viewer's widths
      // are canvas pixels; the mini shows the source shrunk by crMin/srcMin
      // (preview pt over source px), so scaling the viewer widths by that
      // factor gives the identical stroke-to-ring proportion the viewer renders
      // (it normalizes fillWidth/outerRadiusPixels - we match that scale, not a
      // guessed point size).
      NSInteger emphasis =
          [del respondsToSelector:@selector(miniViewerRingEmphasis:)]
              ? [del miniViewerRingEmphasis:self]
              : 0;
      simd_float4 fillColor, strokeColor;
      CGFloat viewerFillPx, viewerOutlinePx;
      if (emphasis >= 2) { // active
        fillColor = (simd_float4){1.0f, 1.0f, 1.0f, 1.0f};
        strokeColor = (simd_float4){0.0f, 0.0f, 0.0f, 1.0f};
        viewerFillPx = 2.5;
        viewerOutlinePx = 1.5;
      } else if (emphasis >= 1) { // hover
        fillColor = (simd_float4){0xD0 / 255.0f, 0xCA / 255.0f, 0xCD / 255.0f,
                                  0xB2 / 255.0f};
        strokeColor = (simd_float4){0x09 / 255.0f, 0x07 / 255.0f, 0x0A / 255.0f,
                                    0xAD / 255.0f};
        viewerFillPx = 2.5;
        viewerOutlinePx = 1.5;
      } else { // idle
        fillColor = (simd_float4){0xCE / 255.0f, 0xCB / 255.0f, 0xCE / 255.0f,
                                  0xB1 / 255.0f};
        strokeColor = (simd_float4){0x1B / 255.0f, 0x18 / 255.0f, 0x1D / 255.0f,
                                    0x9F / 255.0f};
        viewerFillPx = 2.0;
        viewerOutlinePx = 1.0;
      }
      // Dim to a ghost when the ring is only shown because of an Opt-hold
      // reveal of a hidden ring (matches the point/box/rotation ghost handles).
      CGFloat ringGhostAlpha =
          [del respondsToSelector:@selector(miniViewerRingGhostAlpha:)]
              ? [del miniViewerRingGhostAlpha:self]
              : 1.0;
      fillColor.w *= (float)ringGhostAlpha;
      strokeColor.w *= (float)ringGhostAlpha;

      CGSize src = [self sourceMediaSize];
      CGFloat srcMin = MIN(src.width, src.height);
      CGFloat crMin = MIN(ringCR.size.width, ringCR.size.height);
      CGFloat srcScale = (srcMin > 0.5) ? crMin / srcMin : [self _canvasScale];
      // The viewer thickens BOTH fill + outline on hover/active, but at mini
      // scale its px deltas (x srcScale) are sub-perceptible. Add a flat point
      // boost so the hover/active outline visibly grows like the viewer. Fill
      // is also nudged +0.5pt in every state, plus a touch more (+0.1) at idle.
      CGFloat outlineBoostPt = (emphasis >= 1) ? 0.35 : 0.0;
      CGFloat fillBoostPt = (emphasis == 0) ? 0.6 : 0.5;
      [self _encodeRingOSCAt:rc
                   radiusXPt:rrx
                   radiusYPt:rry
                   fillColor:fillColor
                 strokeColor:strokeColor
                 fillWidthPt:viewerFillPx * srcScale + fillBoostPt
              outlineWidthPt:viewerOutlinePx * srcScale + outlineBoostPt
                     encoder:enc];
    }
  }

  // Motion path (Magic Move): red trajectory line + tangent connectors under
  // the dots, then anchor + handle dots. Drawn beneath the position handle.
  if (del &&
      [del respondsToSelector:
               @selector(miniViewer:motionPathPolylineForContentRect:)]) {
    CGRect cr = [self contentRectInViewPoints];
    NSArray<NSValue *> *poly = [del miniViewer:self
              motionPathPolylineForContentRect:cr];
    NSArray<NSValue *> *segs =
        [del respondsToSelector:
                 @selector(miniViewer:motionPathHandleSegmentsForContentRect:)]
            ? [del miniViewer:self motionPathHandleSegmentsForContentRect:cr]
            : nil;
    NSArray<NSValue *> *anchors =
        [del
            respondsToSelector:@selector(
                                   miniViewer:motionPathAnchorsForContentRect:)]
            ? [del miniViewer:self motionPathAnchorsForContentRect:cr]
            : nil;
    float pg = [del isKindOfClass:[KKMiniViewerRenderer class]]
                   ? (float)[(KKMiniViewerRenderer *)del motionPathGhostAlpha]
                   : 1.0f;
    if (_linePipeline && poly.count >= 2) {
      simd_float4 red = {1.0f, 0.25f, 0.25f, 0.9f * pg};
      [self _encodeMotionLineStrip:poly color:red halfWidthPt:1.0 encoder:enc];
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
                         sizeScale:0.6
                           encoder:enc];
      for (NSUInteger i = 1; i < segs.count; i += 2)
        [self _encodeHandleGlyphAt:segs[i].pointValue
                         fillColor:white
                         sizeScale:0.5
                           encoder:enc];
    }
  }

  // Extra motion paths (multi-point plugins, e.g. Shader): each additional
  // point OSC draws its OWN trajectory, so an animated point lane shows a path
  // whether or not it happens to be the first one. Same style as the primary
  // path above, drawn beneath the handles.
  if ((_linePipeline || _pointPipeline) && del &&
      [del
          respondsToSelector:@selector(
                                 miniViewer:extraMotionPathsForContentRect:)]) {
    CGRect cr = [self contentRectInViewPoints];
    for (NSDictionary<NSString *, id> *b in [del miniViewer:self
                             extraMotionPathsForContentRect:cr]) {
      NSArray<NSValue *> *poly = b[@"poly"];
      NSArray<NSValue *> *segs = b[@"segs"];
      NSArray<NSValue *> *anchors = b[@"anchors"];
      float pg = b[@"alpha"] ? [b[@"alpha"] floatValue] : 1.0f;
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
                           sizeScale:0.6
                             encoder:enc];
        for (NSUInteger i = 1; i < segs.count; i += 2)
          [self _encodeHandleGlyphAt:segs[i].pointValue
                           fillColor:white
                           sizeScale:0.5
                             encoder:enc];
      }
    }
  }

  if (_pointPipeline && del) {
    CGRect cr = [self contentRectInViewPoints];
    // Radius handle uses the host accent (same as Canvas's Rotate OSC) so
    // it's distinguishable from the white crop handles.
    NSColor *a =
        [[NSColor accent] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    CGFloat ar = 1, ag = 1, ab = 1, aa = 1;
    [a getRed:&ar green:&ag blue:&ab alpha:&aa];
    simd_float4 accentFill = {(float)ar, (float)ag, (float)ab, (float)aa};
    simd_float4 whiteFill = {1.0f, 1.0f, 1.0f, 1.0f};

    // Point-glyph size multiplier (radius handle + crop corners), so a plugin
    // can match a specific reference dot. Default 1.0.
    CGFloat pointSizeScale =
        [del isKindOfClass:[KKMiniViewerRenderer class]]
            ? [(KKMiniViewerRenderer *)del pointHandleSizeScale]
            : 1.0;

    // Layering matches the viewer (bottom -> top): boxes/rotation, then the
    // Position handle on top of the rings, then the anchor square topmost.
    // Box OSC handles (crop corners/edges, scale corners/edges, ...): white,
    // dimmed by each box's ghost alpha. One path for every box.
    if ([del respondsToSelector:@selector(miniViewer:boxesForContentRect:)]) {
      for (KKMiniBox *box in [del miniViewer:self boxesForContentRect:cr]) {
        simd_float4 fill = whiteFill;
        fill.w *= (float)box.ghostAlpha;
        for (NSValue *v in box.handleCenters)
          [self _encodeHandleGlyphAt:v.pointValue
                           fillColor:fill
                           sizeScale:pointSizeScale
                             encoder:enc];
      }
    }

    if (_rotationPipeline &&
        [del respondsToSelector:@selector(miniViewer:rotationOSCCenter:radiusPx:
                                          params:contentRect:)]) {
      CGPoint rotCenter = CGPointZero;
      CGFloat rotRadius = 0;
      KKRotationOSCParams rotParams = {0};
      if ([del miniViewer:self
              rotationOSCCenter:&rotCenter
                       radiusPx:&rotRadius
                         params:&rotParams
                    contentRect:cr]) {
        [self _encodeRotationOSCAt:rotCenter
                          radiusPx:rotRadius
                            params:rotParams
                           encoder:enc];
      }
    }

    // Position handle, drawn above the rotation rings + scale box so it stays
    // on top (matches the viewer's layering).
    CGPoint handleCenterPts;
    if ([del respondsToSelector:
                 @selector(miniViewer:pointHandleCenter:contentRect:)] &&
        [del miniViewer:self
            pointHandleCenter:&handleCenterPts
                  contentRect:cr]) {
      KKMiniHandleStyle style = KKMiniHandleStylePoint;
      BOOL isActive = NO;
      CGFloat ghostAlpha = 1.0;
      if ([del isKindOfClass:[KKMiniViewerRenderer class]]) {
        style = [(KKMiniViewerRenderer *)del pointHandleStyle];
        isActive = [(KKMiniViewerRenderer *)del pointHandleIsActive];
        ghostAlpha = [(KKMiniViewerRenderer *)del pointHandleGhostAlpha];
      }
      if (style == KKMiniHandleStyleNone) {
        // The renderer exposes a point-handle anchor (for guides / driven
        // drag) but paints its own control - draw no default glyph here.
      } else if (style == KKMiniHandleStyleArc) {
        [self _encodeArcHandleGlyphAt:handleCenterPts
                             isActive:isActive
                           ghostAlpha:ghostAlpha
                              encoder:enc];
      } else if (style == KKMiniHandleStyleRing) {
        // Haloed KKRingOSC ring (the shared radius-widget glyph). White fill +
        // dark outline for legibility on any background (matches Canvas's
        // corner ring), scaled with the OSC sizing ratio like the dot. Sizes
        // match Canvas's corner-radius ring (CanvasMiniViewerRenderer+Pen.m
        // penDrawRingAtObj:) so the two read identically in the mini-viewer,
        // as they already do in the main viewer.
        CGFloat cs = [self _canvasScale];
        simd_float4 f = whiteFill;
        f.w *= (float)ghostAlpha;
        simd_float4 outline = {0.0f, 0.0f, 0.0f, 0.75f * (float)ghostAlpha};
        [self _encodeRingOSCAt:handleCenterPts
                     radiusXPt:2.3 * cs
                     radiusYPt:2.3 * cs
                     fillColor:f
                   strokeColor:outline
                   fillWidthPt:1.0 * cs
                outlineWidthPt:0.5 * cs
                       encoder:enc];
      } else {
        // Point-style handles dim via the fill alpha (no ghostAlpha param).
        simd_float4 f = accentFill;
        f.w *= (float)ghostAlpha;
        [self _encodeHandleGlyphAt:handleCenterPts
                         fillColor:f
                         sizeScale:pointSizeScale
                           encoder:enc];
      }
    }

    // Additional point handles (a dynamic plugin with more than one point OSC,
    // e.g. Shader's multiple `#point osc` lanes). Each drawn with the same
    // glyph as the primary handle above; the delegate owns hit-test / drag.
    // Uses pointHandleCenter-style centres (fraction-based), so animatable
    // point lanes render their handle too, not only constant ones.
    if ([del respondsToSelector:
                 @selector(miniViewer:extraPointHandleGlyphsForContentRect:)]) {
      KKMiniHandleStyle exStyle =
          [del isKindOfClass:[KKMiniViewerRenderer class]]
              ? [(KKMiniViewerRenderer *)del pointHandleStyle]
              : KKMiniHandleStylePoint;
      for (NSDictionary<NSString *, id> *g in [del miniViewer:self
                         extraPointHandleGlyphsForContentRect:cr]) {
        CGPoint c = [g[@"center"] pointValue];
        CGFloat ga = g[@"alpha"] ? [g[@"alpha"] doubleValue] : 1.0;
        if (exStyle == KKMiniHandleStyleNone)
          continue;
        if (exStyle == KKMiniHandleStyleArc)
          [self _encodeArcHandleGlyphAt:c
                               isActive:NO
                             ghostAlpha:ga
                                encoder:enc];
        else {
          simd_float4 f = accentFill;
          f.w *= (float)ga;
          [self _encodeHandleGlyphAt:c
                           fillColor:f
                           sizeScale:pointSizeScale
                             encoder:enc];
        }
      }
    }

    // Anchor pivot square - topmost, mirroring the viewer's layering.
    CGPoint anchorCenterPts;
    if (_squarePipeline &&
        [del respondsToSelector:
                 @selector(miniViewer:anchorSquareCenter:contentRect:)] &&
        [del miniViewer:self
            anchorSquareCenter:&anchorCenterPts
                   contentRect:cr]) {
      CGFloat ghostAlpha =
          [del isKindOfClass:[KKMiniViewerRenderer class]]
              ? [(KKMiniViewerRenderer *)del anchorSquareGhostAlpha]
              : 1.0;
      [self _encodeSquareGlyphAt:anchorCenterPts
                      ghostAlpha:ghostAlpha
                       sizeScale:pointSizeScale
                         encoder:enc];
    }

    // Secondary Position arc handle (a plugin whose main point handle is
    // something else - e.g. Glow's radius ring - draws its Position here with
    // the same arc glyph the viewer uses).
    CGPoint posCenterPts;
    if ([del respondsToSelector:
                 @selector(miniViewer:positionHandleCenter:contentRect:)] &&
        [del miniViewer:self
            positionHandleCenter:&posCenterPts
                     contentRect:cr]) {
      BOOL posActive = NO;
      CGFloat posGhost = 1.0;
      if ([del isKindOfClass:[KKMiniViewerRenderer class]]) {
        posActive = [(KKMiniViewerRenderer *)del positionHandleIsActive];
        posGhost = [(KKMiniViewerRenderer *)del positionHandleGhostAlpha];
      }
      [self _encodeArcHandleGlyphAt:posCenterPts
                           isActive:posActive
                         ghostAlpha:posGhost
                            encoder:enc];
    }
  }

  // Toolbar chrome, drawn LAST (on top of the grid + handles), the same way the
  // Tool overlay (pen anchors / handles / curve / ghost), above the gizmo but
  // under the toolbar chrome. The delegate encodes via -encodeToolDotAtPoint: /
  // -encodeToolLineStrip:, which use this armed encoder + the glyph/line
  // pipelines (same look as the motion path).
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
  // this pass via the shared -drawInEncoder: path, using the toolbar pipeline.
  if (_toolbarPipeline && del &&
      [del respondsToSelector:@selector(miniViewer:drawToolbarInEncoder:device:
                                        pipeline:viewportWidth:height:)]) {
    CGSize d = self.drawableSize;
    [del miniViewer:self
        drawToolbarInEncoder:enc
                      device:self.device
                    pipeline:_toolbarPipeline
               viewportWidth:(float)d.width
                      height:(float)d.height];
  }

  [enc endEncoding];
  [cb presentDrawable:drawable];
  [cb commit];

  // Content rect may have shifted (pan/zoom/resolve) - keep handles aligned.
  [_overlay setNeedsDisplay:YES];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
  [self setNeedsDisplay:YES];
}

@end
