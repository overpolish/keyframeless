/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasPathOSC.h"
#import "CanvasCornerFillet.h"       // corner widget geometry
#import "CanvasLayerRender.h"        // CanvasProjectLayerPointsObj
#import "CanvasPenController.h"      // CanvasPenSurface draw primitives
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKShape.h> // KKRectShape (image extent)
#import <simd/simd.h>

// Coarser than the render tessellation - the OSC line only needs to read as the
// path's shape, not be pixel-exact.
static const NSUInteger kPathOSCSteps = 16;

// Above this anchor count the guide curve drops to 2 samples per segment: a
// dense path (e.g. a centerline trace) is already finely subdivided, so the halo
// reads fine while avoiding ~N*16 bezier re-evaluations per redraw. Purely a
// draw-cost knob - it gates nothing about editability.
static const NSUInteger kPathOSCDenseAnchors = 250;

// Draw EACH contour of `path` as its own projected polyline, so a compound path
// (SVG subpaths, a boolean result with several regions) isn't joined by a stray
// segment from one contour's end to the next's start. `colored` uses the
// surface's coloured primitive (path-op preview) vs the halo curve (path-edit
// OSC). A fresh result path with no layer transform projects to stored
// geometry.
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
  // Adaptive sampling: cap the TOTAL curve samples so a dense path (many short
  // segments, e.g. a centerline trace with hundreds of anchors) doesn't
  // re-evaluate ~N*16 bezier points every single redraw - that dominated the
  // mini's per-frame cost and made panning stutter. The halo only needs to read
  // as the shape, and dense paths are already finely subdivided, so a few steps
  // per segment is plenty. Sparse paths (few long curves) keep the full count
  // for smoothness.
  NSUInteger steps =
      cp.count > kPathOSCDenseAnchors
          ? 2
          : (NSUInteger)fmax(3.0,
                             fmin((double)kPathOSCSteps,
                                  round(1200.0 / fmax(1.0, (double)cp.count))));
  // Build the projection context ONCE for the whole path - it was rebuilt per
  // contour (each an O(N) object-centre bbox loop), so a multi-contour path was
  // O(contours*N) per frame regardless of sample count.
  CanvasProjCtx ctx = CanvasProjCtxMake(layers, cp, frac, aspect);
  for (NSUInteger ci = 0; ci < nc; ci++) {
    NSRange r = [cp contourRangeAtIndex:ci];
    NSUInteger cLen = r.length;
    if (cLen < 2)
      continue;
    // Per-contour open/closed must mirror the RENDER exactly
    // (CanvasContourClosed = path.closed for every contour) - else the guide
    // disagrees with what's drawn. Forcing closed whenever nc>1 looped each
    // contour of an OPEN multi-contour path (a multi-branch centerline: 77 open
    // contours, closed=NO) back on itself, adding stray connecting segments the
    // stroke never renders. A filled compound path carries closed=YES, so its
    // contours still close.
    BOOL closed = cp.closed;
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
      CGPoint *cg = malloc(sizeof(CGPoint) * n);
      for (NSUInteger i = 0; i < n; i++) {
        simd_float2 pj = CanvasProjectWithCtx(&ctx, local[i].x, local[i].y);
        cg[i] = CGPointMake(pj.x, pj.y);
      }
      if (colored)
        [surface penDrawColoredCurveObjPoints:cg count:n color:color];
      else
        [surface penDrawCurveObjPoints:cg count:n];
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
static CGMutablePathRef
CanvasOpFillCGPath(NSArray<KKBezierPath *> *layers, KKBezierPath *path,
                   double frac, float aspect,
                   CGPoint (^objToPx)(simd_float2)) CF_RETURNS_RETAINED {
  CGMutablePathRef cgp = CGPathCreateMutable();
  if (!path || path.count < 2)
    return cgp;
  KKBezierPath *cp =
      path.hasCornerRadii ? CanvasPathByExpandingCorners(path, aspect) : path;
  CanvasProjCtx ctx = CanvasProjCtxMake(layers, cp, frac, aspect);
  NSUInteger nc = cp.contourCount;
  const NSUInteger steps = 16;
  for (NSUInteger ci = 0; ci < nc; ci++) {
    NSRange r = [cp contourRangeAtIndex:ci];
    NSUInteger cLen = r.length;
    if (cLen < 2)
      continue;
    // Match the render's per-contour open/closed (path.closed for every
    // contour) so an open multi-contour stroke preview doesn't get a stray
    // closing segment per contour. The fill path is unaffected: CGContextEOFill
    // implicitly closes any open subpath.
    BOOL closed = cp.closed;
    NSUInteger segs = closed ? cLen : cLen - 1;
    BOOL first = YES;
    for (NSUInteger c = 0; c < segs; c++) {
      NSUInteger idx = r.location + c;
      NSUInteger nextIdx = r.location + ((c + 1) % cLen);
      for (NSUInteger s = 0; s < steps; s++) {
        float t = (float)s / (float)steps;
        simd_float2 o = [cp evaluatePointAtIndex:idx nextIndex:nextIdx atT:t];
        simd_float2 pj = CanvasProjectWithCtx(&ctx, o.x, o.y);
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
      simd_float2 pj = CanvasProjectWithCtx(&ctx, o.x, o.y);
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

// A fresh sRGB-premultiplied bitmap context of w x h px, or NULL. Shared by the
// path-op preview and the layer-hover highlight (both fill translucent shapes).
static CGContextRef CanvasNewFillBitmapContext(NSInteger w, NSInteger h)
    CF_RETURNS_RETAINED {
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(
      NULL, w, h, 8, w * 4, cs,
      (CGBitmapInfo)((uint32_t)kCGImageAlphaPremultipliedLast |
                     (uint32_t)kCGBitmapByteOrder32Big));
  CGColorSpaceRelease(cs);
  return ctx;
}

// strokeWidth is OUTPUT px; convert to bitmap px via the projection (on-screen
// px for one object-X unit / output width). Measured so it follows zoom + pan.
static CGFloat CanvasFillStrokeScale(CGFloat refW,
                                     CGPoint (^objToPx)(simd_float2)) {
  CGPoint x0 = objToPx(simd_make_float2(0.0f, 0.5f));
  CGPoint x1 = objToPx(simd_make_float2(1.0f, 0.5f));
  return (refW > 0) ? (CGFloat)fabs(x1.x - x0.x) / refW : 1.0;
}

CGContextRef CanvasRenderPathOpFillBitmap(
    NSArray<KKBezierPath *> *operands, NSArray<KKBezierPath *> *results,
    NSArray<KKBezierPath *> *layers, double frac, float aspect, NSInteger w,
    NSInteger h, CGFloat refW, CGPoint (^objToPx)(simd_float2)) {
  if (w <= 0 || h <= 0 || !objToPx)
    return NULL;
  CGContextRef ctx = CanvasNewFillBitmapContext(w, h);
  if (!ctx)
    return NULL;
  CGFloat strokeScale = CanvasFillStrokeScale(refW, objToPx);
  for (KKBezierPath *p in operands)
    CanvasFillOpShape(ctx, layers, p, frac, aspect, strokeScale, 1.0, 0.20,
                      0.20, objToPx);
  for (KKBezierPath *p in results)
    CanvasFillOpShape(ctx, layers, p, frac, aspect, strokeScale, 0.16, 0.85,
                      0.30, objToPx);
  return ctx;
}

CGContextRef CanvasRenderLayerHighlightBitmap(
    NSArray<KKBezierPath *> *highlight, NSArray<KKBezierPath *> *layers,
    double frac, float aspect, NSInteger w, NSInteger h, CGFloat refW, CGFloat r,
    CGFloat g, CGFloat b, CGPoint (^objToPx)(simd_float2)) {
  if (w <= 0 || h <= 0 || !objToPx)
    return NULL;
  CGContextRef ctx = CanvasNewFillBitmapContext(w, h);
  if (!ctx)
    return NULL;
  CGFloat strokeScale = CanvasFillStrokeScale(refW, objToPx);
  for (KKBezierPath *p in highlight)
    CanvasFillOpShape(ctx, layers, p, frac, aspect, strokeScale, r, g, b,
                      objToPx);
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
  [tex
      replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)width, (NSUInteger)height)
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
  loop[4] = loop[0];                          // close the box
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

  // Project the raw anchors once.
  simd_float2 *aLocal = malloc(sizeof(simd_float2) * count);
  for (NSUInteger i = 0; i < count; i++) {
    KKBezierPoint pt = [path pointAtIndex:i];
    aLocal[i] = simd_make_float2(pt.x, pt.y);
  }
  // Build the projection context ONCE and reuse it for every anchor, tangent
  // handle, and corner widget below. The per-point CanvasProjectLayerPointObj
  // rebuilt this context (object-centre bbox loop + group xforms) on each call,
  // and this function projects ~5N points/frame, so a busy path was O(N^2) and
  // spent hundreds of ms per redraw.
  CanvasProjCtx ctx = CanvasProjCtxMake(layers, path, frac, aspect);
  simd_float2 *aProj = malloc(sizeof(simd_float2) * count);
  for (NSUInteger i = 0; i < count; i++)
    aProj[i] = CanvasProjectWithCtx(&ctx, aLocal[i].x, aLocal[i].y);

  // Tangent handles (under the anchor dots): a line from the anchor to each
  // non-zero handle end, with the surface's handle endpoint dot. A corner with
  // a radius set hides its handles - the rounding owns that corner now, and the
  // stored (sharp) handles would read as a stale, contradictory control. They
  // come back when the radius is cleared (default).
  for (NSUInteger i = 0; i < count; i++) {
    if ([path cornerRadiusAtIndex:i] > 0.0f)
      continue;
    KKBezierPoint pt = [path pointAtIndex:i];
    CGPoint a = CGPointMake(aProj[i].x, aProj[i].y);
    if (fabsf(pt.outX) + fabsf(pt.outY) > 1e-6f) {
      simd_float2 b =
          CanvasProjectWithCtx(&ctx, pt.x + pt.outX, pt.y + pt.outY);
      [surface penDrawHandleFromObj:a toObj:CGPointMake(b.x, b.y)];
    }
    if (fabsf(pt.inX) + fabsf(pt.inY) > 1e-6f) {
      simd_float2 b = CanvasProjectWithCtx(&ctx, pt.x + pt.inX, pt.y + pt.inY);
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
      CanvasCornerWidget w = CanvasCornerWidgetObjCtx(path, i, &ctx);
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
