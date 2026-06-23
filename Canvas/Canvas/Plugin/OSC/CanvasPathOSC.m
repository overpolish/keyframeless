/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasPathOSC.h"
#import "CanvasCornerFillet.h" // corner widget geometry
#import "CanvasLayerRender.h"  // CanvasProjectLayerPointsObj
#import "CanvasPathEditController.h" // kCanvasMaxEditableAnchors
#import "CanvasPenController.h" // CanvasPenSurface draw primitives
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKShape.h> // KKRectShape (image extent)
#import <simd/simd.h>

// Coarser than the render tessellation - the OSC line only needs to read as the
// path's shape, not be pixel-exact.
static const NSUInteger kPathOSCSteps = 16;

// Draw EACH contour of `path` as its own projected polyline, so a compound path
// (SVG subpaths, a boolean result with several regions) isn't joined by a stray
// segment from one contour's end to the next's start. `colored` uses the
// surface's coloured primitive (path-op preview) vs the halo curve (path-edit
// OSC). A fresh result path with no layer transform projects to stored geometry.
static void CanvasDrawProjectedContours(id<CanvasPenSurface> surface,
                                        NSArray<KKBezierPath *> *layers,
                                        KKBezierPath *path, double frac,
                                        float aspect, BOOL colored,
                                        simd_float4 color) {
  if (!path || path.count < 2)
    return;
  KKBezierPath *cp =
      path.hasCornerRadii ? CanvasPathByExpandingCorners(path, aspect) : path;
  NSUInteger nc = cp.contourCount;
  NSUInteger steps = cp.count > kCanvasMaxEditableAnchors ? 2 : kPathOSCSteps;
  for (NSUInteger ci = 0; ci < nc; ci++) {
    NSRange r = [cp contourRangeAtIndex:ci];
    NSUInteger cLen = r.length;
    if (cLen < 2)
      continue;
    // A compound path's individual contours are each closed; a lone contour
    // follows the path's own closed flag (an open pen path stays open).
    BOOL closed = (nc > 1) ? YES : cp.closed;
    NSUInteger segs = closed ? cLen : cLen - 1;
    NSUInteger cap = segs * steps + 2;
    simd_float2 *local = malloc(sizeof(simd_float2) * cap);
    NSUInteger n = 0;
    for (NSUInteger c = 0; c < segs; c++) {
      NSUInteger idx = r.location + c;
      NSUInteger nextIdx = r.location + ((c + 1) % cLen);
      for (NSUInteger s = 0; s < steps; s++) {
        float t = (float)s / (float)steps;
        simd_float2 p = [cp evaluatePointAtIndex:idx nextIndex:nextIdx atT:t];
        if (n > 0 && simd_distance_squared(p, local[n - 1]) < 1e-9f)
          continue;
        if (n < cap)
          local[n++] = p;
      }
    }
    if (closed) {
      if (n > 0 && n < cap)
        local[n++] = local[0]; // close this contour back to its own start
    } else {
      simd_float2 p = [cp evaluatePointAtIndex:r.location + segs - 1
                                     nextIndex:r.location + segs
                                           atT:1.0f];
      if ((n == 0 || simd_distance_squared(p, local[n - 1]) > 1e-9f) && n < cap)
        local[n++] = p;
    }
    if (n >= 2) {
      simd_float2 *proj = malloc(sizeof(simd_float2) * n);
      CanvasProjectLayerPointsObj(layers, cp, frac, aspect, local, proj, n);
      CGPoint *cg = malloc(sizeof(CGPoint) * n);
      for (NSUInteger i = 0; i < n; i++)
        cg[i] = CGPointMake(proj[i].x, proj[i].y);
      if (colored)
        [surface penDrawColoredCurveObjPoints:cg count:n color:color];
      else
        [surface penDrawCurveObjPoints:cg count:n];
      free(proj);
      free(cg);
    }
    free(local);
  }
}

void CanvasDrawPathOpPreview(id<CanvasPenSurface> surface,
                             NSArray<KKBezierPath *> *layers,
                             NSArray<KKBezierPath *> *operands,
                             NSArray<KKBezierPath *> *results, double frac,
                             float aspect) {
  simd_float4 red = {1.0f, 0.25f, 0.25f, 0.95f};
  simd_float4 green = {0.2f, 0.95f, 0.3f, 0.95f};
  for (KKBezierPath *p in operands)
    CanvasDrawProjectedContours(surface, layers, p, frac, aspect, YES, red);
  for (KKBezierPath *p in results)
    CanvasDrawProjectedContours(surface, layers, p, frac, aspect, YES, green);
}

// A CG path (bitmap px via objToPx) for a path-op preview shape, sampling each
// contour like the stroke OSC so the FILL lands where the shape renders. Open
// contours stay open (no stray closing segment for a stroke pass).
static CGMutablePathRef CanvasOpFillCGPath(NSArray<KKBezierPath *> *layers,
                                           KKBezierPath *path, double frac,
                                           float aspect,
                                           CGPoint (^objToPx)(simd_float2))
    CF_RETURNS_RETAINED {
  CGMutablePathRef cgp = CGPathCreateMutable();
  if (!path || path.count < 2)
    return cgp;
  KKBezierPath *cp =
      path.hasCornerRadii ? CanvasPathByExpandingCorners(path, aspect) : path;
  NSUInteger nc = cp.contourCount;
  const NSUInteger steps = 16;
  for (NSUInteger ci = 0; ci < nc; ci++) {
    NSRange r = [cp contourRangeAtIndex:ci];
    NSUInteger cLen = r.length;
    if (cLen < 2)
      continue;
    BOOL closed = (nc > 1) ? YES : cp.closed;
    NSUInteger segs = closed ? cLen : cLen - 1;
    BOOL first = YES;
    for (NSUInteger c = 0; c < segs; c++) {
      NSUInteger idx = r.location + c;
      NSUInteger nextIdx = r.location + ((c + 1) % cLen);
      for (NSUInteger s = 0; s < steps; s++) {
        float t = (float)s / (float)steps;
        simd_float2 o = [cp evaluatePointAtIndex:idx nextIndex:nextIdx atT:t];
        simd_float2 pj =
            CanvasProjectLayerPointObj(layers, cp, frac, aspect, o.x, o.y);
        CGPoint cv = objToPx(pj);
        if (first) {
          CGPathMoveToPoint(cgp, NULL, cv.x, cv.y);
          first = NO;
        } else {
          CGPathAddLineToPoint(cgp, NULL, cv.x, cv.y);
        }
      }
    }
    if (closed) {
      CGPathCloseSubpath(cgp);
    } else {
      simd_float2 o = [cp evaluatePointAtIndex:r.location + segs - 1
                                     nextIndex:r.location + segs
                                           atT:1.0f];
      simd_float2 pj =
          CanvasProjectLayerPointObj(layers, cp, frac, aspect, o.x, o.y);
      CGPoint cv = objToPx(pj);
      CGPathAddLineToPoint(cgp, NULL, cv.x, cv.y);
    }
  }
  return cgp;
}

// Fill one preview shape's interior (even-odd, for holed boolean results) AND
// stroke its band at the shape's stroke width - composited at full opacity in a
// transparency layer, then the translucency applied once, so the fill + stroke
// don't double-alpha on the band's inner half.
static void CanvasFillOpShape(CGContextRef ctx, NSArray<KKBezierPath *> *layers,
                              KKBezierPath *p, double frac, float aspect,
                              CGFloat strokeScale, CGFloat r, CGFloat g,
                              CGFloat b, CGPoint (^objToPx)(simd_float2)) {
  CGMutablePathRef cgp = CanvasOpFillCGPath(layers, p, frac, aspect, objToPx);
  CGContextSetAlpha(ctx, 0.45);
  CGContextBeginTransparencyLayer(ctx, NULL);
  if (p.closed) {
    CGContextSetRGBFillColor(ctx, r, g, b, 1.0);
    CGContextAddPath(ctx, cgp);
    CGContextEOFillPath(ctx);
  }
  if (p.strokeEnabled && p.strokeWidth > 0.0f) {
    CGContextSetRGBStrokeColor(ctx, r, g, b, 1.0);
    CGContextSetLineWidth(ctx, p.strokeWidth * strokeScale);
    CGContextSetLineCap(ctx, (CGLineCap)p.lineCap);
    CGContextSetLineJoin(ctx, (CGLineJoin)p.lineJoin);
    CGContextAddPath(ctx, cgp);
    CGContextStrokePath(ctx);
  }
  CGContextEndTransparencyLayer(ctx);
  CGContextSetAlpha(ctx, 1.0);
  CGPathRelease(cgp);
}

CGContextRef CanvasRenderPathOpFillBitmap(NSArray<KKBezierPath *> *operands,
                                          NSArray<KKBezierPath *> *results,
                                          NSArray<KKBezierPath *> *layers,
                                          double frac, float aspect, NSInteger w,
                                          NSInteger h, CGFloat refW,
                                          CGPoint (^objToPx)(simd_float2)) {
  if (w <= 0 || h <= 0 || !objToPx)
    return NULL;
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(
      NULL, w, h, 8, w * 4, cs,
      (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(cs);
  if (!ctx)
    return NULL;
  // strokeWidth is OUTPUT px; convert to bitmap px via the projection (on-screen
  // px for one object-X unit / output width). Measured so it follows zoom + pan.
  CGPoint x0 = objToPx(simd_make_float2(0.0f, 0.5f));
  CGPoint x1 = objToPx(simd_make_float2(1.0f, 0.5f));
  CGFloat strokeScale = (refW > 0) ? (CGFloat)fabs(x1.x - x0.x) / refW : 1.0;
  for (KKBezierPath *p in operands)
    CanvasFillOpShape(ctx, layers, p, frac, aspect, strokeScale, 1.0, 0.20, 0.20,
                      objToPx);
  for (KKBezierPath *p in results)
    CanvasFillOpShape(ctx, layers, p, frac, aspect, strokeScale, 0.16, 0.85,
                      0.30, objToPx);
  return ctx;
}

id<MTLTexture> CanvasFillBitmapToTexture(CGContextRef ctx, id<MTLDevice> device,
                                         NSInteger width, NSInteger height) {
  if (!ctx || !device || width <= 0 || height <= 0)
    return nil;
  MTLTextureDescriptor *desc = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                   width:(NSUInteger)width
                                  height:(NSUInteger)height
                               mipmapped:NO];
  desc.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> tex = [device newTextureWithDescriptor:desc];
  [tex replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)width, (NSUInteger)height)
         mipmapLevel:0
           withBytes:CGBitmapContextGetData(ctx)
         bytesPerRow:(NSUInteger)width * 4];
  return tex;
}

void CanvasDrawLayerBoxOSC(id<CanvasPenSurface> surface,
                           NSArray<KKBezierPath *> *layers, KKBezierPath *layer,
                           double frac, float aspect) {
  if (!layer)
    return;
  simd_float2 local[4];
  if ([layer.shape isKindOfClass:[KKRectShape class]]) {
    KKRectShape *r = (KKRectShape *)layer.shape;
    local[0] = simd_make_float2(r.min.x, r.min.y);
    local[1] = simd_make_float2(r.max.x, r.min.y);
    local[2] = simd_make_float2(r.max.x, r.max.y);
    local[3] = simd_make_float2(r.min.x, r.max.y);
  } else {
    local[0] = simd_make_float2(0, 0);
    local[1] = simd_make_float2(1, 0);
    local[2] = simd_make_float2(1, 1);
    local[3] = simd_make_float2(0, 1);
  }
  simd_float2 proj[4];
  CanvasProjectLayerPointsObj(layers, layer, frac, aspect, local, proj, 4);
  CGPoint loop[5];
  for (int i = 0; i < 4; i++)
    loop[i] = CGPointMake(proj[i].x, proj[i].y);
  loop[4] = loop[0]; // close the box
  simd_float4 dim = {1.0f, 1.0f, 1.0f, 0.5f}; // dimmed white selection outline
  [surface penDrawSnappedLoopObjPoints:loop count:5 color:dim];
}

void CanvasDrawPathEditOSC(id<CanvasPenSurface> surface,
                           NSArray<KKBezierPath *> *layers, KKBezierPath *path,
                           double frac, float aspect, NSIndexSet *selected,
                           BOOL marqueeActive, CGRect marqueeSurfaceRect,
                           BOOL ghost, BOOL showCornerWidgets) {
  NSUInteger count = path.count;
  if (!surface || count < 1)
    return;

  // The guide curve traces the corner-expanded geometry (so it follows the
  // rounded stroke; the anchors below stay at the stored sharp corners), drawn
  // per contour so a compound path's subpaths aren't joined by a stray segment.
  CanvasDrawProjectedContours(surface, layers, path, frac, aspect, NO,
                              simd_make_float4(0, 0, 0, 0));

  // A path too large to edit per-anchor draws only its outline (above): drawing
  // a dot + handles + corner ring for each of thousands of anchors would be
  // thousands of draw calls every frame. The marquee still draws (selection is
  // disabled for such a path, so it won't actually be active, but be safe).
  if (count > kCanvasMaxEditableAnchors) {
    if (marqueeActive)
      [surface penDrawMarqueeRect:marqueeSurfaceRect];
    return;
  }

  // Project the raw anchors once.
  simd_float2 *aLocal = malloc(sizeof(simd_float2) * count);
  for (NSUInteger i = 0; i < count; i++) {
    KKBezierPoint pt = [path pointAtIndex:i];
    aLocal[i] = simd_make_float2(pt.x, pt.y);
  }
  simd_float2 *aProj = malloc(sizeof(simd_float2) * count);
  CanvasProjectLayerPointsObj(layers, path, frac, aspect, aLocal, aProj, count);

  // Tangent handles (under the anchor dots): a line from the anchor to each
  // non-zero handle end, with the surface's handle endpoint dot. A corner with a
  // radius set hides its handles - the rounding owns that corner now, and the
  // stored (sharp) handles would read as a stale, contradictory control. They
  // come back when the radius is cleared (default).
  for (NSUInteger i = 0; i < count; i++) {
    if ([path cornerRadiusAtIndex:i] > 0.0f)
      continue;
    KKBezierPoint pt = [path pointAtIndex:i];
    CGPoint a = CGPointMake(aProj[i].x, aProj[i].y);
    if (fabsf(pt.outX) + fabsf(pt.outY) > 1e-6f) {
      simd_float2 b = CanvasProjectLayerPointObj(
          layers, path, frac, aspect, pt.x + pt.outX, pt.y + pt.outY);
      [surface penDrawHandleFromObj:a toObj:CGPointMake(b.x, b.y)];
    }
    if (fabsf(pt.inX) + fabsf(pt.inY) > 1e-6f) {
      simd_float2 b = CanvasProjectLayerPointObj(layers, path, frac, aspect,
                                                 pt.x + pt.inX, pt.y + pt.inY);
      [surface penDrawHandleFromObj:a toObj:CGPointMake(b.x, b.y)];
    }
  }

  // Anchor dots on top - selected ones draw active (host accent); all dimmed
  // when this is a hidden-Points reveal ghost.
  for (NSUInteger i = 0; i < count; i++)
    [surface penDrawDotAtObj:CGPointMake(aProj[i].x, aProj[i].y)
                       ghost:ghost
                     hovered:NO
                      active:[selected containsIndex:i]];
  free(aLocal);
  free(aProj);

  // Live-corner widgets: an accent handle just inside each interior corner
  // (along the bisector), drawn on top of the anchors. Click-drag rounds that
  // corner (CanvasPathEditController). Cursor tool only (not interactive while
  // pen-drawing); hidden while this is a reveal ghost.
  if (showCornerWidgets && !ghost) {
    for (NSUInteger i = 0; i < count; i++) {
      CanvasCornerWidget w =
          CanvasCornerWidgetObj(layers, path, frac, aspect, i);
      if (!w.valid)
        continue;
      [surface penDrawRingAtObj:CGPointMake(w.widgetObj.x, w.widgetObj.y)
                          maxed:w.atMax];
    }
  }

  // Rubber-band on top of everything (surface points - no projection).
  if (marqueeActive)
    [surface penDrawMarqueeRect:marqueeSurfaceRect];
}
