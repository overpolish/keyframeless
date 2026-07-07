/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasCornerFillet.h"   // CanvasPathByExpandingCorners
#import "CanvasFillProperties.h" // CanvasFillEnabledAtFraction (lane gate)
#import "CanvasFillRender.h" // CanvasBuildFillFan (same fan the render fills)
#import "CanvasHitTestGeometry.h" // CanvasInvBilinear + CanvasSampleImageAlpha
#import "CanvasLayerRender.h"     // CanvasHitTestLayerID (public decl)
#import "CanvasLayerTimeline.h"
#import "CanvasLayerTransform.h"
#import "CanvasMarkerTessellate.h" // marker triangle-list hit-test
#import "CanvasStrokeTessellate.h" // CanvasTessellateStroke (strip hit-test)
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKPluginHost.h>
#import <KeyframelessKit/KKShape.h>
#import <KeyframelessKit/KKTimingEvaluation.h>
#import <KeyframelessKit/KKTimingStage.h>
#import <simd/simd.h>

// The pixel scale every object-space projection feeds
// CanvasComposedModelMatrix: (aspect, 1). The pipeline is scale-invariant in
// object space, so only the canvas aspect matters, not the render's true pixel
// dims.
static inline simd_float2 CanvasHitScaleForAspect(float aspect) {
  return simd_make_float2(aspect > 0.0f ? aspect : 1.0f, 1.0f);
}

// The composed model matrix for one (transform, centre, groups) - INVARIANT
// across a layer's points. Build once, then project every point with
// CanvasProjectNormWithMatrix instead of recomposing the 4x4 per point.
// tileShift is 0 (the viewer OSC isn't tiled like the render).
static matrix_float4x4 CanvasComposedHitMatrix(CanvasLayerTransform t,
                                               simd_float2 c, float aspect,
                                               const CanvasGroupXform *groups,
                                               NSInteger ng) {
  return CanvasComposedModelMatrix(t, c, groups, ng,
                                   CanvasHitScaleForAspect(aspect),
                                   simd_make_float2(0, 0));
}

// Project a normalized layer-local point (Y-up [0,1]) through a PREBUILT model
// matrix + pixel scale - the per-vertex/anchor hot path. Same perspective
// divide the render uses.
static simd_float2 CanvasProjectNormWithMatrix(matrix_float4x4 m,
                                               simd_float2 scl, float nx,
                                               float ny) {
  simd_float2 half = simd_make_float2(0.5f, 0.5f);
  simd_float2 pPix = (simd_make_float2(nx, ny) - half) * scl;
  simd_float4 clip = simd_mul(m, simd_make_float4(pPix.x, pPix.y, 0.0f, 1.0f));
  if (clip.w == 0.0f)
    return simd_make_float2(nx, ny);
  simd_float2 screen = simd_make_float2(clip.x / clip.w, clip.y / clip.w);
  return screen / scl + half;
}

// A layer's on-screen quad corner in object space [0,1] (Y-up). One-off form
// (image corners, group compose): builds the matrix then projects. For many
// points of the same layer build the matrix once and call
// CanvasProjectNormWithMatrix directly.
static simd_float2 CanvasProjectedCornerObj(float nx, float ny,
                                            CanvasLayerTransform t, float cx,
                                            float cy, float aspect,
                                            const CanvasGroupXform *groups,
                                            NSInteger ng) {
  matrix_float4x4 m =
      CanvasComposedHitMatrix(t, simd_make_float2(cx, cy), aspect, groups, ng);
  return CanvasProjectNormWithMatrix(m, CanvasHitScaleForAspect(aspect), nx,
                                     ny);
}

// YES if `path` is editable at clip fraction `frac`: it has at least one
// constant param (per `templates`) OR an animated lane visible at `frac` (at a
// keypose or its lead-in/out hold). Gates the viewer auto-select so a
// fully-animated layer with no keypose at the playhead isn't pickable.
static BOOL CanvasLayerEditableAtFraction(KKBezierPath *path, double frac,
                                          NSArray<KKLane *> *templates) {
  if (CanvasLayerHasConstant(path, templates))
    return YES;
  if (path.animationJSON.length == 0)
    return YES;
  KKTimeline *tl = [KKTimeline timelineFromJSON:path.animationJSON];
  double frameDur = KKProcessFrameDurationSeconds();
  for (KKLane *l in tl.lanes)
    if (l.enabled && KKLaneVisibleAtFraction(l, frac, frameDur))
      return YES;
  return NO;
}

static NSUInteger CanvasLayerIndexOf(NSArray<KKBezierPath *> *layers,
                                     KKBezierPath *path) {
  NSUInteger idx = [layers indexOfObjectIdenticalTo:path];
  if (idx == NSNotFound)
    for (NSUInteger i = 0; i < layers.count; i++)
      if (layers[i].layerID.length &&
          [layers[i].layerID isEqualToString:path.layerID])
        return i;
  return idx;
}

CanvasProjCtx CanvasProjCtxMake(NSArray<KKBezierPath *> *layers,
                                KKBezierPath *path, double frac, float aspect) {
  CanvasProjCtx ctx = {0};
  ctx.aspect = aspect;
  if (!path)
    return ctx;
  ctx.t = (frac < 0.0) ? CanvasLayerTransformIdentity()
                       : CanvasLayerTransformAtFraction(path, frac);
  ctx.center = CanvasLayerObjectCenter(path);
  NSUInteger idx = CanvasLayerIndexOf(layers, path);
  if (idx == NSNotFound) {
    // Not in the layer stack (a transient path-op preview result), but if it
    // carries a parentGroupID resolve its ancestor groups by ID so it projects
    // through the SAME group transform its committed form will - otherwise the
    // green preview sits where the un-grouped geometry is, offset from the red
    // operand by the group transform.
    ctx.ng = path.parentGroupID.length
                 ? CanvasBuildGroupXformsForParentID(layers, path.parentGroupID,
                                                     frac, nil, nil, ctx.groups,
                                                     kCanvasGroupXformCap)
                 : 0;
  } else {
    ctx.ng = CanvasBuildGroupXforms(layers, idx, frac, nil, nil, ctx.groups,
                                    kCanvasGroupXformCap);
  }
  ctx.scl = CanvasHitScaleForAspect(aspect);
  ctx.m =
      CanvasComposedHitMatrix(ctx.t, ctx.center, aspect, ctx.groups, ctx.ng);
  return ctx;
}

simd_float2 CanvasProjectWithCtx(const CanvasProjCtx *ctx, float localX,
                                 float localY) {
  if (!ctx)
    return simd_make_float2(localX, localY);
  return CanvasProjectNormWithMatrix(ctx->m, ctx->scl, localX, localY);
}

void CanvasProjectLayerPointsObj(NSArray<KKBezierPath *> *layers,
                                 KKBezierPath *path, double frac, float aspect,
                                 const simd_float2 *localPts,
                                 simd_float2 *outProj, NSUInteger count) {
  if (!path || count == 0)
    return;
  CanvasProjCtx ctx = CanvasProjCtxMake(layers, path, frac, aspect);
  for (NSUInteger i = 0; i < count; i++)
    outProj[i] = CanvasProjectWithCtx(&ctx, localPts[i].x, localPts[i].y);
}

simd_float2 CanvasProjectLayerPointObj(NSArray<KKBezierPath *> *layers,
                                       KKBezierPath *path, double frac,
                                       float aspect, float localX,
                                       float localY) {
  simd_float2 in = simd_make_float2(localX, localY), out = in;
  CanvasProjectLayerPointsObj(layers, path, frac, aspect, &in, &out, 1);
  return out;
}

simd_float2 CanvasUnprojectLayerPointObj(NSArray<KKBezierPath *> *layers,
                                         KKBezierPath *path, double frac,
                                         float aspect, float screenX,
                                         float screenY) {
  simd_float2 unit[4] = {simd_make_float2(0, 0), simd_make_float2(1, 0),
                         simd_make_float2(1, 1), simd_make_float2(0, 1)};
  simd_float2 proj[4];
  CanvasProjectLayerPointsObj(layers, path, frac, aspect, unit, proj, 4);
  simd_float3x3 H = CanvasSquareToQuadHomography(
      CGPointMake(proj[0].x, proj[0].y), CGPointMake(proj[1].x, proj[1].y),
      CGPointMake(proj[2].x, proj[2].y), CGPointMake(proj[3].x, proj[3].y));
  simd_float3 v =
      simd_mul(simd_inverse(H), simd_make_float3(screenX, screenY, 1.0f));
  if (fabsf(v.z) < 1e-9f)
    return simd_make_float2(screenX, screenY);
  return simd_make_float2(v.x / v.z, v.y / v.z);
}

BOOL CanvasComposedGroupPointObj(NSArray<KKBezierPath *> *layers,
                                 KKBezierPath *member, double frac,
                                 float aspect, float inX, float inY,
                                 float *outX, float *outY) {
  if (outX)
    *outX = inX;
  if (outY)
    *outY = inY;
  if (!member || member.isGroup)
    return YES;
  NSUInteger idx = [layers indexOfObjectIdenticalTo:member];
  if (idx == NSNotFound)
    for (NSUInteger i = 0; i < layers.count; i++)
      if (layers[i].layerID.length &&
          [layers[i].layerID isEqualToString:member.layerID]) {
        idx = i;
        break;
      }
  if (idx == NSNotFound)
    return YES;
  CanvasGroupXform groups[kCanvasGroupXformCap];
  NSInteger ng = CanvasBuildGroupXforms(layers, idx, frac, nil, nil, groups,
                                        kCanvasGroupXformCap);
  if (ng == 0)
    return YES;
  // Identity member transform centred on the point: the member model becomes a
  // no-op, so the point (already in clip space) is transformed by the groups
  // alone, through the same perspective the render applies.
  simd_float2 c = CanvasProjectedCornerObj(
      inX, inY, CanvasLayerTransformIdentity(), inX, inY, aspect, groups, ng);
  if (outX)
    *outX = c.x;
  if (outY)
    *outY = c.y;
  return YES;
}

KKRotMatrix3 CanvasComposedGroupRotation(NSArray<KKBezierPath *> *layers,
                                         KKBezierPath *member, double frac) {
  KKRotMatrix3 base = KKRotMatrixIdentity();
  if (!member || member.isGroup)
    return base;
  NSUInteger idx = [layers indexOfObjectIdenticalTo:member];
  if (idx == NSNotFound)
    for (NSUInteger i = 0; i < layers.count; i++)
      if (layers[i].layerID.length &&
          [layers[i].layerID isEqualToString:member.layerID]) {
        idx = i;
        break;
      }
  if (idx == NSNotFound)
    return base;
  CanvasGroupXform groups[kCanvasGroupXformCap];
  NSInteger ng = CanvasBuildGroupXforms(layers, idx, frac, nil, nil, groups,
                                        kCanvasGroupXformCap);
  // groups[0] is the innermost parent; compose Rk · base each step so the
  // outermost ends up leftmost (matching the render's group·member order).
  for (NSInteger k = 0; k < ng; k++) {
    KKRotMatrix3 Rk = KKBuildRotationMatrix(groups[k].t.rotX, groups[k].t.rotY,
                                            groups[k].t.rotation);
    base = KKRotMatrixMul(Rk, base);
  }
  return base;
}

// Point in triangle (aspect-corrected screen space) via consistent edge signs.
// A point on an edge counts as inside. Callers must skip degenerate (zero-area)
// triangles first - those report every point as inside.
static BOOL CanvasPointInTri(simd_float2 p, simd_float2 a, simd_float2 b,
                             simd_float2 c) {
  float d1 = (p.x - b.x) * (a.y - b.y) - (a.x - b.x) * (p.y - b.y);
  float d2 = (p.x - c.x) * (b.y - c.y) - (b.x - c.x) * (p.y - c.y);
  float d3 = (p.x - a.x) * (c.y - a.y) - (c.x - a.x) * (p.y - a.y);
  BOOL neg = (d1 < 0.0f) || (d2 < 0.0f) || (d3 < 0.0f);
  BOOL pos = (d1 > 0.0f) || (d2 > 0.0f) || (d3 > 0.0f);
  return !(neg && pos);
}

// Project a tessellated stroke / marker vertex (centered-pixel object space) to
// the aspect-corrected space the hit-test compares in: pixel -> path-normalized
// (inverse of the tessellator's (norm-0.5)*outputSize) -> the same pipeline as
// the centerline -> x scaled by aspect. `inv` = 1/outputSize. `m`/`scl` are the
// layer's prebuilt model matrix + pixel scale (CanvasComposedHitMatrix), so a
// dense stroke's thousands of strip vertices reuse one matrix instead of
// recomposing the 4x4 per vertex - the dense-path hit-test cost.
static simd_float2 CanvasHitProjectVert(KKVertex2D v, simd_float2 inv,
                                        matrix_float4x4 m, simd_float2 scl,
                                        float aspect) {
  simd_float2 nm = v.position * inv + simd_make_float2(0.5f, 0.5f);
  simd_float2 pr = CanvasProjectNormWithMatrix(m, scl, nm.x, nm.y);
  return simd_make_float2(pr.x * aspect, pr.y);
}

// Hit a stroke by testing the point against the SAME tessellated triangle-strip
// the render draws (not a centerline + tolerance). This is the general stroke
// hit primitive: it follows whatever geometry the tessellator emits, so it
// already handles the taper and will extend to wavy / multi-stroke sketch and
// arrow markers (they just add triangles) with no hit-test change. Each strip
// vertex is converted pixel -> path-normalized (the inverse of the
// tessellator's (norm-0.5)*outputSize) and projected through the same pipeline
// as the centerline; every consecutive vertex triple is one triangle.
// Degenerate bridge / collinear triangles are skipped so they can't false-hit.
// `startW` / `endW` are canvas px, already floored to a minimum grab width by
// the caller.
static BOOL CanvasStrokeStripHit(KKBezierPath *geom, float startW, float endW,
                                 float outW, float outH, uint8_t lineCap,
                                 uint8_t lineJoin, matrix_float4x4 m,
                                 simd_float2 scl, float aspect, simd_float2 q) {
  NSUInteger cap = CanvasStrokeVertexCapacity(geom);
  if (cap < 3)
    return NO;
  // Per-process scratch reused across the mouse-move hit-test so hover doesn't
  // malloc per layer per move. Safe as a static here: the hit-test runs only on
  // the main/event thread (viewer OSC + mini interaction), and each FxPlug
  // instance is its own XPC process, so this is effectively per-instance and
  // never shared/concurrent (unlike the render path, which passes NULL
  // scratch).
  static KKVertex2D *sVerts = NULL;
  static NSUInteger sVertsCap = 0;
  static CanvasStrokeScratch sScratch;
  if (sVertsCap < cap) {
    free(sVerts);
    sVerts = malloc(sizeof(KKVertex2D) * cap);
    sVertsCap = cap;
  }
  KKVertex2D *verts = sVerts;
  NSUInteger vc = CanvasTessellateStrokeScratch(
      geom, startW, endW, outW, outH, lineCap, lineJoin, verts, cap, &sScratch);
  BOOL hit = NO;
  if (vc >= 3) {
    simd_float2 qa = simd_make_float2(q.x * aspect, q.y);
    simd_float2 inv = simd_make_float2(outW != 0.0f ? 1.0f / outW : 0.0f,
                                       outH != 0.0f ? 1.0f / outH : 0.0f);
    simd_float2 p0 = {0, 0}, p1 = {0, 0};
    for (NSUInteger i = 0; i < vc; i++) {
      simd_float2 pa = CanvasHitProjectVert(verts[i], inv, m, scl, aspect);
      if (i >= 2) {
        float area2 =
            (p1.x - p0.x) * (pa.y - p0.y) - (pa.x - p0.x) * (p1.y - p0.y);
        if (fabsf(area2) > 1e-9f && CanvasPointInTri(qa, p0, p1, pa)) {
          hit = YES;
          break;
        }
      }
      p0 = p1;
      p1 = pa;
    }
  }
  return hit;
}

// Hit the endpoint markers (arrow / circle / square / arrowhead / tick) the
// same way as the stroke - test the point against the SAME tessellated geometry
// the render draws, so a click anywhere on a marker selects the path. Markers
// are a triangle LIST (independent triples), unlike the stroke strip.
// `startW`/`endW` are the effective stroke widths (px) - the marker size is
// width x the lane multiplier, matching CanvasTessellateMarkers in the render.
static BOOL CanvasStrokeMarkersHit(KKBezierPath *geom, float startW, float endW,
                                   uint8_t startMarker, uint8_t endMarker,
                                   float startMul, float endMul, float outW,
                                   float outH, matrix_float4x4 m,
                                   simd_float2 scl, float aspect,
                                   simd_float2 q) {
  if (startMarker == 0 && endMarker == 0)
    return NO;
  NSUInteger cap = CanvasMarkerVertexCapacity();
  static KKVertex2D *sMVerts = NULL;
  static NSUInteger sMCap = 0;
  if (sMCap < cap) {
    free(sMVerts);
    sMVerts = malloc(sizeof(KKVertex2D) * cap);
    sMCap = cap;
  }
  // The hit-test selects the whole layer from its full stroke + markers
  // (CanvasStrokeStripHit likewise ignores draw-on), so a partly-revealed
  // draw-on path stays grabbable where it's drawn (no draw-on trim, 0/0).
  NSUInteger vc = CanvasTessellateMarkers(
      geom, outW, outH, startMarker, endMarker, startW * startMul,
      endW * endMul, startW, endW, /*trimStartPx=*/0.0f, /*trimEndPx=*/0.0f,
      sMVerts, cap);
  if (vc < 3)
    return NO;
  simd_float2 qa = simd_make_float2(q.x * aspect, q.y);
  simd_float2 inv = simd_make_float2(outW != 0.0f ? 1.0f / outW : 0.0f,
                                     outH != 0.0f ? 1.0f / outH : 0.0f);
  for (NSUInteger i = 0; i + 2 < vc; i += 3) { // triangle LIST: triples
    simd_float2 p[3];
    for (int k = 0; k < 3; k++)
      p[k] = CanvasHitProjectVert(sMVerts[i + k], inv, m, scl, aspect);
    float area2 = (p[1].x - p[0].x) * (p[2].y - p[0].y) -
                  (p[2].x - p[0].x) * (p[1].y - p[0].y);
    if (fabsf(area2) > 1e-9f && CanvasPointInTri(qa, p[0], p[1], p[2]))
      return YES;
  }
  return NO;
}

// Hit the FILL the same way as the stroke: test the point against the SAME
// triangle fan the render fills (CanvasBuildFillFan), projected through the
// layer transform. The render's stencil INVERTS per fan triangle, so a pixel
// covered by an ODD number of triangles is filled - so we count containing
// triangles and report inside on odd parity. That matches the rendered fill
// exactly, including holes / compound paths (one fan per contour).
static BOOL CanvasFillFanHit(KKBezierPath *geom, float outW, float outH,
                             matrix_float4x4 m, simd_float2 scl, float aspect,
                             simd_float2 q) {
  KKVertex2D *fan = NULL;
  simd_float2 bbMin, bbMax;
  NSUInteger triCount =
      CanvasBuildFillFan(geom, outW, outH, &fan, &bbMin, &bbMax);
  if (triCount == 0) {
    free(fan);
    return NO;
  }
  simd_float2 qa = simd_make_float2(q.x * aspect, q.y);
  simd_float2 inv = simd_make_float2(outW != 0.0f ? 1.0f / outW : 0.0f,
                                     outH != 0.0f ? 1.0f / outH : 0.0f);
  NSUInteger covered = 0;
  for (NSUInteger ti = 0; ti < triCount; ti++) {
    simd_float2 p[3];
    for (int k = 0; k < 3; k++)
      p[k] = CanvasHitProjectVert(fan[ti * 3 + k], inv, m, scl, aspect);
    float area2 = (p[1].x - p[0].x) * (p[2].y - p[0].y) -
                  (p[2].x - p[0].x) * (p[1].y - p[0].y);
    if (fabsf(area2) > 1e-9f && CanvasPointInTri(qa, p[0], p[1], p[2]))
      covered++;
  }
  free(fan);
  return (covered & 1) != 0; // even-odd: odd coverage = inside (stencil invert)
}

// YES if the query hits a vector layer: within its (transformed) stroke, OR -
// for a fill-enabled path - anywhere inside the filled region. Stroke tol is
// the half-width in object-Y units plus a screen-slop floor so a thin stroke is
// still grabbable.
static const float kHitStrokeSlopObj = 0.012f; // ~1.2% of canvas height
static BOOL CanvasVectorLayerHit(KKBezierPath *path, double frac, float aspect,
                                 simd_float2 q, float canvasHeightPx,
                                 const CanvasGroupXform *groups, NSInteger ng) {
  // Hit-test the rounded geometry (what's actually rendered), not the stored
  // sharp corners - else a click near a rounded-off corner misses.
  KKBezierPath *geom =
      path.hasCornerRadii ? CanvasPathByExpandingCorners(path, aspect) : path;
  if (geom.count < 2)
    return NO;
  CanvasLayerTransform t = (frac < 0.0)
                               ? CanvasLayerTransformIdentity()
                               : CanvasLayerTransformAtFraction(path, frac);
  simd_float2 c = CanvasLayerObjectCenter(path);
  // Build the composed model matrix ONCE - every tessellated vertex of the
  // stroke strip / markers / fill fan reuses it instead of recomposing the 4x4
  // per vertex (a dense path emits thousands of verts, so the per-vertex
  // rebuild was the bulk of the busy-path hit-test cost).
  simd_float2 scl = CanvasHitScaleForAspect(aspect);
  matrix_float4x4 m = CanvasComposedHitMatrix(t, c, aspect, groups, ng);
  // Shared pixel space for every tessellation-derived test (stroke strip,
  // markers, fill fan): the aspect-corrected canvas height. The scale cancels
  // in the project-back, so any consistent value works.
  float h = canvasHeightPx > 1.0f ? canvasHeightPx : 1000.0f;
  float a = aspect > 0.0f ? aspect : 1.0f;
  double efrac = frac < 0.0 ? 0.0 : frac;
  if (CanvasStrokeEnabledAtFraction(path, efrac, nil, nil)) {
    // Effective Start/End widths from the Stroke Width lane (the flat
    // strokeWidth is stale once the lane drives the render). Test against the
    // actual tessellated strip so a tapered (and later wavy / multi) stroke is
    // clickable exactly where it's drawn.
    float swStart = path.strokeWidth, swEnd = path.strokeWidth;
    CanvasStrokeWidthAtFraction(path, efrac, nil, nil, &swStart, &swEnd);
    // Floor the clickable width to the screen slop so a hairline stays
    // grabbable (a 2*slop-wide strip = slop half-width in object-Y, matching
    // the old tol).
    float minPx = 2.0f * kHitStrokeSlopObj * h;
    uint8_t lineCap = path.lineCap, lineJoin = path.lineJoin;
    CanvasStrokeCapJoinAtFraction(path, efrac, nil, nil, &lineCap, &lineJoin);
    if (CanvasStrokeStripHit(geom, fmaxf(swStart, minPx), fmaxf(swEnd, minPx),
                             a * h, h, lineCap, lineJoin, m, scl, aspect, q))
      return YES;
    // Endpoint markers are drawn on top of the stroke, so they're clickable too
    // (use the real stroke widths so the marker size matches what's drawn).
    uint8_t startMarker = 0, endMarker = 0;
    float startMul = path.startMarkerSize, endMul = path.endMarkerSize;
    CanvasStrokeMarkersAtFraction(path, efrac, nil, nil, &startMarker,
                                  &endMarker, &startMul, &endMul);
    if (CanvasStrokeMarkersHit(geom, swStart, swEnd, startMarker, endMarker,
                               startMul, endMul, a * h, h, m, scl, aspect, q))
      return YES;
  }
  // Fill: test the SAME triangle fan the render fills (odd coverage = inside),
  // lane-gated like the render so a lane-toggled fill is clickable even when
  // the flat fillEnabled is NO.
  if (CanvasFillEnabledAtFraction(path, efrac, nil, nil) &&
      CanvasFillFanHit(geom, a * h, h, m, scl, aspect, q))
    return YES;
  return NO;
}

typedef struct {
  NSInteger index;          // original layer-stack index (0 = topmost)
  CanvasLayerDrawKey key;   // depth + facing, the SAME key the render sorts by
} CanvasHitCandidate;

NSString *CanvasHitTestLayerID(NSArray<KKBezierPath *> *layers, double frac,
                               float aspect, float objX, float objY,
                               BOOL alphaAware,
                               NSSet<NSString *> *excludedLayerIDs,
                               BOOL requireEditableAtFrac,
                               NSArray<KKLane *> *templates,
                               float canvasHeightPx) {
  simd_float2 q = simd_make_float2(objX, objY);
  // Pass 1: collect pickable candidates with their 3D depth, then test them
  // front-to-back in the SAME order the render draws (nearer depth first, layer
  // stack as the tiebreak). Without this a layer pushed visually in front by a
  // 3D group tilt drew on top but couldn't be clicked - the old loop walked
  // plain stack order, which no longer matches what you see.
  NSUInteger n = layers.count;
  CanvasHitCandidate *cand =
      malloc(sizeof(CanvasHitCandidate) * MAX(n, (NSUInteger)1));
  NSInteger candCount = 0;
  for (NSInteger i = 0; i < (NSInteger)n; i++) {
    KKBezierPath *path = layers[i];
    if (path.hidden || path.isGroup || path.locked)
      continue;
    if (path.layerID && [excludedLayerIDs containsObject:path.layerID])
      continue; // non-selectable (mirrors the layer list's gating)
    if (requireEditableAtFrac && frac >= 0.0 &&
        !CanvasLayerEditableAtFraction(path, frac, templates))
      continue; // viewer: nothing to edit here (animated, off-keypose)
    BOOL isImage = path.isImage && path.imagePath.length &&
                   [path.shape isKindOfClass:[KKRectShape class]];
    // Candidate if it draws anything pickable at this frac: stroke OR fill,
    // read from the lanes (not the flat props) so a lane-toggled
    // stroke/fill-only shape is selectable - matching what the render draws.
    double efrac = frac < 0.0 ? 0.0 : frac;
    BOOL isVector = !path.isImage && path.count >= 2 &&
                    (CanvasStrokeEnabledAtFraction(path, efrac, nil, nil) ||
                     CanvasFillEnabledAtFraction(path, efrac, nil, nil));
    if (!isImage && !isVector)
      continue;
    cand[candCount].index = i;
    // Object-space dims (aspect, 1) - the pipeline is scale-invariant, so this
    // yields the SAME order the render's (W, H) key does.
    cand[candCount].key = CanvasLayerComposedDrawKey(
        layers, i, frac, aspect > 0.0f ? aspect : 1.0f, 1.0f, 0.0f, 0.0f, nil,
        nil);
    candCount++;
  }
  // Order back-to-front with the SAME key + ordering as the render (incl. the
  // deck-facing flip for coincident layers), then walk it REVERSED below so the
  // layer drawn on top is hit first.
  float hitTol = 0.02f * fmaxf(aspect > 0.0f ? aspect : 1.0f, 1.0f);
  NSInteger *hitIdx = malloc(sizeof(NSInteger) * (size_t)MAX(candCount, 1));
  CanvasLayerDrawKey *hitKeys =
      malloc(sizeof(CanvasLayerDrawKey) * (size_t)MAX(candCount, 1));
  for (NSInteger c = 0; c < candCount; c++) {
    hitIdx[c] = cand[c].index;
    hitKeys[c] = cand[c].key;
  }
  NSInteger *hitOrder = malloc(sizeof(NSInteger) * (size_t)MAX(candCount, 1));
  CanvasOrderDrawablesBackToFront(hitIdx, hitKeys, candCount, hitTol, hitOrder);
  free(hitIdx);
  free(hitKeys);

  NSString *result = nil;
  for (NSInteger c = 0; c < candCount; c++) {
    NSInteger i = hitOrder[candCount - 1 - c]; // front-to-back
    KKBezierPath *path = layers[i];
    BOOL isImage = path.isImage && path.imagePath.length &&
                   [path.shape isKindOfClass:[KKRectShape class]];
    BOOL isVector = !isImage; // candidates are only image or vector (pass 1)

    // Compose ancestor group transforms so a member moved by its group is
    // hit-tested where it's actually drawn. ng==0 for an ungrouped layer.
    CanvasGroupXform groups[kCanvasGroupXformCap];
    NSInteger ng = CanvasBuildGroupXforms(layers, (NSUInteger)i, frac, nil, nil,
                                          groups, kCanvasGroupXformCap);

    if (isVector) {
      // "What you see" hit test: inside a filled region, or within a stroke.
      // A click in a stroke-only path's hollow interior misses and falls
      // through to the layer beneath (alphaAware doesn't apply to vectors).
      if (CanvasVectorLayerHit(path, frac, aspect, q, canvasHeightPx, groups,
                               ng)) {
        result = path.layerID;
        break;
      }
      continue;
    }

    KKRectShape *rect = (KKRectShape *)path.shape;
    CanvasLayerTransform t = (frac < 0.0)
                                 ? CanvasLayerTransformIdentity()
                                 : CanvasLayerTransformAtFraction(path, frac);
    float cx = (rect.min.x + rect.max.x) * 0.5f;
    float cy = (rect.min.y + rect.max.y) * 0.5f;
    // Corner -> UV: tl=(0,0) tr=(1,0) br=(1,1) bl=(0,1). Object Y-up, so the
    // image TOP is at max.y (v=0) and the bottom at min.y (v=1).
    simd_float2 tl = CanvasProjectedCornerObj(rect.min.x, rect.max.y, t, cx, cy,
                                              aspect, groups, ng);
    simd_float2 tr = CanvasProjectedCornerObj(rect.max.x, rect.max.y, t, cx, cy,
                                              aspect, groups, ng);
    simd_float2 br = CanvasProjectedCornerObj(rect.max.x, rect.min.y, t, cx, cy,
                                              aspect, groups, ng);
    simd_float2 bl = CanvasProjectedCornerObj(rect.min.x, rect.min.y, t, cx, cy,
                                              aspect, groups, ng);
    simd_float2 uv;
    if (!CanvasInvBilinear(q, tl, tr, br, bl, &uv))
      continue; // outside the transformed quad
    if (alphaAware &&
        CanvasSampleImageAlpha(path.imagePath, uv.x, uv.y) <= 0.04f)
      continue; // transparent here -> fall through to the layer beneath
    result = path.layerID;
    break;
  }
  free(cand);
  free(hitOrder);
  return result;
}
