/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasStrokeTessellate.h"
#import "CanvasStrokeTessellateInternal.h"
#import <KeyframelessKit/KKBezierPath.h>
#import <simd/simd.h>

static const NSUInteger kStepsPerSegment = 32;
static const NSUInteger kMaxJoinSteps = 24; // max arc segments for a round join
static const float kMiterLimit = 4.0f; // clamp spikes at very sharp corners

// Segments in one contour: a closed contour wraps (cLen segments), an open one
// has cLen-1. A compound path's individual contours are each closed; a lone
// contour follows the path's own closed flag (an open pen path stays open).
static NSUInteger CanvasContourSegmentCount(NSUInteger cLen, BOOL closed) {
  if (cLen < 2)
    return 0;
  return closed ? cLen : cLen - 1;
}

BOOL CanvasContourClosed(KKBezierPath *path, NSUInteger contourCount) {
  return (contourCount > 1) ? YES : path.closed;
}

// The largest per-contour polyline vertex count across `path`, used to size the
// reused polyline buffer (each contour is rebuilt into it in turn).
NSUInteger CanvasMaxContourPolyCap(KKBezierPath *path, BOOL closed) {
  NSUInteger polyCap = 0;
  NSUInteger nc = path.contourCount;
  for (NSUInteger ci = 0; ci < nc; ci++) {
    NSRange r = [path contourRangeAtIndex:ci];
    NSUInteger segs = CanvasContourSegmentCount(r.length, closed);
    NSUInteger cap = segs * kStepsPerSegment + 2;
    if (cap > polyCap)
      polyCap = cap;
  }
  return polyCap;
}

// Total arc length (pixels) of a built contour polyline, including the closing
// edge back to pts[0] when `closed`.
float CanvasContourArcLength(const simd_float2 *pts, NSUInteger n,
                             BOOL closed) {
  float total = 0.0f;
  for (NSUInteger i = 1; i < n; i++)
    total += simd_distance(pts[i], pts[i - 1]);
  if (closed && n > 1)
    total += simd_distance(pts[0], pts[n - 1]);
  return total;
}

NSUInteger CanvasStrokeVertexCapacity(KKBezierPath *path) {
  if (path.count < 2)
    return 0;
  NSUInteger nc = path.contourCount;
  NSUInteger total = 0;
  for (NSUInteger ci = 0; ci < nc; ci++) {
    NSRange r = [path contourRangeAtIndex:ci];
    NSUInteger segs =
        CanvasContourSegmentCount(r.length, CanvasContourClosed(path, nc));
    if (segs == 0)
      continue;
    // One sample per step per segment, plus the open terminal + closing wrap.
    // Two strip verts each. Round/bevel joins emit extra cross-sections: budget
    // 2 pairs per sample (a small-angle round join emits two) plus a full
    // (kMaxJoinSteps+1)-pair fan per anchor corner. Over-budget truncates a
    // pathological all-sharp path gracefully (the emit loop guards maxVerts).
    NSUInteger samples = segs * kStepsPerSegment + 2;
    total += samples * 2 * 2 + (segs + 2) * (kMaxJoinSteps + 1) * 2;
  }
  if (total == 0)
    return 0;
  // Two degenerate bridge verts between each pair of contours, plus headroom,
  // plus a round-cap fan allowance at both ends of every contour (a fan is
  // (kCanvasCapSegs+1) rim+centre pairs + a 2-vert bridge; budget generously).
  NSUInteger capVerts = nc * 2 * ((kCanvasCapSegs + 1) * 2 + 2);
  return total + (nc > 1 ? (nc - 1) * 2 : 0) + capVerts + 8;
}

// Sample ONE contour into a centered-pixel polyline matching the image-quad
// space: p_centered = (normalized - 0.5) * outputSize. Near-duplicate samples
// are dropped so adjacent edges yield stable normals.
NSUInteger CanvasBuildContourPolyline(KKBezierPath *path, NSRange r,
                                      BOOL closed, float outW, float outH,
                                      simd_float2 *pts, NSUInteger maxPts) {
  NSUInteger cLen = r.length;
  NSUInteger segs = CanvasContourSegmentCount(cLen, closed);
  if (segs == 0)
    return 0;
  simd_float2 scale = simd_make_float2(outW, outH);
  simd_float2 half = simd_make_float2(0.5f, 0.5f);
  NSUInteger n = 0;
  for (NSUInteger c = 0; c < segs; c++) {
    NSUInteger idx = r.location + c;
    NSUInteger nextIdx = r.location + ((c + 1) % cLen);
    for (NSUInteger i = 0; i < kStepsPerSegment; i++) {
      float t = (float)i / (float)kStepsPerSegment;
      simd_float2 norm = [path evaluatePointAtIndex:idx
                                          nextIndex:nextIdx
                                                atT:t];
      simd_float2 p = (norm - half) * scale;
      if (n > 0 && simd_distance_squared(p, pts[n - 1]) < 1e-6f)
        continue;
      if (n < maxPts)
        pts[n++] = p;
    }
  }
  if (!closed) {
    // Open contours need the final anchor (the segment loop stops before t=1).
    NSUInteger lastIdx = r.location + segs - 1;
    simd_float2 norm = [path evaluatePointAtIndex:lastIdx
                                        nextIndex:lastIdx + 1
                                              atT:1.0f];
    simd_float2 p = (norm - half) * scale;
    if (n == 0 || simd_distance_squared(p, pts[n - 1]) > 1e-6f) {
      if (n < maxPts)
        pts[n++] = p;
    }
  } else if (n > 1 && simd_distance_squared(pts[0], pts[n - 1]) < 1e-6f) {
    n--; // drop a closing sample that coincides with the start
  }
  return n;
}

static simd_float2 CanvasPerp(simd_float2 d) {
  return simd_make_float2(-d.y, d.x);
}

// Offset direction at polyline vertex i (pixel space), mitred between the
// incoming and outgoing edges. `hasPrev` / `hasNext` are NO at the ends of an
// open path, where the offset is the plain edge normal (butt end).
static simd_float2 CanvasMiterOffset(const simd_float2 *pts, NSUInteger n,
                                     NSUInteger i, BOOL closed, float hw) {
  simd_float2 prev = pts[(i + n - 1) % n];
  simd_float2 cur = pts[i];
  simd_float2 next = pts[(i + 1) % n];
  BOOL hasPrev = closed || i > 0;
  BOOL hasNext = closed || i + 1 < n;

  simd_float2 nIn = {0, 0}, nOut = {0, 0};
  if (hasPrev) {
    simd_float2 d = cur - prev;
    if (simd_length_squared(d) > 1e-12f)
      nIn = CanvasPerp(simd_normalize(d));
  }
  if (hasNext) {
    simd_float2 d = next - cur;
    if (simd_length_squared(d) > 1e-12f)
      nOut = CanvasPerp(simd_normalize(d));
  }
  if (!hasPrev)
    nIn = nOut;
  if (!hasNext)
    nOut = nIn;

  simd_float2 sum = nIn + nOut;
  if (simd_length_squared(sum) < 1e-12f)
    return nIn * hw; // 180deg reversal; fall back to one side
  simd_float2 miter = simd_normalize(sum);
  float cosHalf = simd_dot(miter, nIn);
  float scale = cosHalf > 0.001f ? 1.0f / cosHalf : kMiterLimit;
  if (scale > kMiterLimit)
    scale = kMiterLimit;
  return miter * (hw * scale);
}

// The incoming and outgoing edge normals at polyline vertex `i` (the per-edge
// perpendiculars CanvasMiterOffset bisects). At an open terminal the missing
// side mirrors the present one. Used by the bevel / round joins, which keep
// each edge at its own normal instead of bisecting to a single miter point.
static void CanvasEdgeNormals(const simd_float2 *pts, NSUInteger n,
                              NSUInteger i, BOOL closed, simd_float2 *outIn,
                              simd_float2 *outOut) {
  simd_float2 prev = pts[(i + n - 1) % n];
  simd_float2 cur = pts[i];
  simd_float2 next = pts[(i + 1) % n];
  BOOL hasPrev = closed || i > 0;
  BOOL hasNext = closed || i + 1 < n;
  simd_float2 nIn = {0, 0}, nOut = {0, 0};
  if (hasPrev) {
    simd_float2 d = cur - prev;
    if (simd_length_squared(d) > 1e-12f)
      nIn = CanvasPerp(simd_normalize(d));
  }
  if (hasNext) {
    simd_float2 d = next - cur;
    if (simd_length_squared(d) > 1e-12f)
      nOut = CanvasPerp(simd_normalize(d));
  }
  if (!hasPrev)
    nIn = nOut;
  if (!hasNext)
    nOut = nIn;
  *outIn = nIn;
  *outOut = nOut;
}

// Set outArc[idx] = arcVal when an arc buffer is being filled (dashed stroke).
static inline void CanvasSetArc(float *outArc, NSUInteger idx, float arcVal) {
  if (outArc)
    outArc[idx] = arcVal;
}

// Emit one strip cross-section at `center` offset by ±normal*hw (the rail's two
// AA edges, textureCoordinate.y = ±1). `outArc`/`arcVal` record the arc length
// at this cross-section for the dash fragment (NULL = solid, no arc needed).
static NSUInteger CanvasEmitCross(KKVertex2D *v, NSUInteger vc, NSUInteger max,
                                  simd_float2 center, simd_float2 normal,
                                  float hw, float *outArc, float arcVal) {
  if (vc + 2 > max)
    return vc;
  CanvasSetArc(outArc, vc, arcVal);
  v[vc].position = center + normal * hw;
  v[vc].textureCoordinate = simd_make_float2(0.0f, 1.0f);
  vc++;
  CanvasSetArc(outArc, vc, arcVal);
  v[vc].position = center - normal * hw;
  v[vc].textureCoordinate = simd_make_float2(0.0f, -1.0f);
  vc++;
  return vc;
}

// Emit a cross-section with explicit + (ty +1) and - (ty -1) positions - used
// by the bevel / round joins, where one side is the shared inner miter point
// and the other is the outer bevel / arc point (so the + / - rail sides stay
// consistent with the straight segments and the strip joins seamlessly).
static NSUInteger CanvasEmitCrossPts(KKVertex2D *v, NSUInteger vc,
                                     NSUInteger max, simd_float2 plusPt,
                                     simd_float2 minusPt, float *outArc,
                                     float arcVal) {
  if (vc + 2 > max)
    return vc;
  CanvasSetArc(outArc, vc, arcVal);
  v[vc].position = plusPt;
  v[vc].textureCoordinate = simd_make_float2(0.0f, 1.0f);
  vc++;
  CanvasSetArc(outArc, vc, arcVal);
  v[vc].position = minusPt;
  v[vc].textureCoordinate = simd_make_float2(0.0f, -1.0f);
  vc++;
  return vc;
}

// Normalized cumulative arc length at each polyline vertex (frac[0] = 0, last
// vertex = 1), so a per-vertex width can be lerped Start -> End along the
// contour. A closed contour's total includes the closing edge back to pts[0].
// Degenerate (zero-length) contours collapse to all-zero (uniform Start).
static void CanvasContourArcFractions(const simd_float2 *pts, NSUInteger n,
                                      BOOL closed, float *outFrac) {
  if (n == 0)
    return;
  outFrac[0] = 0.0f;
  float cum = 0.0f;
  for (NSUInteger i = 1; i < n; i++) {
    cum += simd_distance(pts[i], pts[i - 1]);
    outFrac[i] = cum;
  }
  float total = cum;
  if (closed && n > 1)
    total += simd_distance(pts[0], pts[n - 1]);
  if (total < 1e-6f) {
    for (NSUInteger i = 0; i < n; i++)
      outFrac[i] = 0.0f;
    return;
  }
  for (NSUInteger i = 1; i < n; i++)
    outFrac[i] /= total;
}

// Append a round cap (outward semicircle) at an open contour's end, bridged
// into the running triangle strip. `center` is the terminal point, `railNormal`
// the unit perpendicular of the terminal edge (the rail's offset direction),
// and `outward` the unit tangent pointing away from the path. The arc rim
// carries textureCoordinate.y = ±1 (so KKLineFragment AAs it ~1px in); the
// centre is solid (y = 0) - same edge fade as the straight rail.
static NSUInteger CanvasAppendRoundCap(KKVertex2D *outVerts, NSUInteger vc,
                                       NSUInteger maxVerts, simd_float2 center,
                                       simd_float2 railNormal,
                                       simd_float2 outward, float hw,
                                       float *outArc, float arcVal) {
  if (vc + (kCanvasCapSegs + 1) * 2 + 2 > maxVerts)
    return vc;
  simd_float2 rim0 = center + railNormal * hw;
  if (vc > 0) {
    CanvasSetArc(outArc, vc, outArc ? outArc[vc - 1] : 0.0f);
    outVerts[vc] = outVerts[vc - 1]; // degenerate bridge from the strip
    vc++;
    CanvasSetArc(outArc, vc, arcVal);
    outVerts[vc].position = rim0;
    outVerts[vc].textureCoordinate = simd_make_float2(0.0f, 1.0f);
    vc++;
  }
  for (NSUInteger s = 0; s <= kCanvasCapSegs; s++) {
    float a = (float)s / (float)kCanvasCapSegs * (float)M_PI;
    simd_float2 dir = railNormal * cosf(a) + outward * sinf(a);
    CanvasSetArc(outArc, vc, arcVal);
    outVerts[vc].position = center + dir * hw;
    outVerts[vc].textureCoordinate = simd_make_float2(0.0f, 1.0f);
    vc++;
    CanvasSetArc(outArc, vc, arcVal);
    outVerts[vc].position = center;
    outVerts[vc].textureCoordinate = simd_make_float2(0.0f, 0.0f);
    vc++;
  }
  return vc;
}

void CanvasStrokeScratchFree(CanvasStrokeScratch *scratch) {
  if (!scratch)
    return;
  free(scratch->pts);
  free(scratch->frac);
  free(scratch->hw);
  scratch->pts = NULL;
  scratch->frac = NULL;
  scratch->hw = NULL;
  scratch->cap = 0;
}

// Emit ONE contour (or dash sub-polyline) as a triangle strip into outVerts,
// reusing the join (miter / bevel / round) + cap (butt / round / square)
// machinery for both the solid stroke and each dash. `pts` (mutable - a square
// cap pre-extends the terminals) is the centered-pixel polyline; `hw` holds the
// per-vertex half-width (length n, plus hw[n] = the closing width used only
// when `closed`). `bridgeFromPrev` stitches this strip onto whatever was
// emitted before with two degenerate verts (across a contour gap or between
// dashes). `arcv` (length n, plus arcv[n] = the closing arc) is the per-vertex
// arc length (pixels) recorded into `outArc` for the dash fragment; pass both
// NULL for a solid stroke (no arc needed).
NSUInteger CanvasEmitContourStrip(KKVertex2D *outVerts, NSUInteger vc,
                                  NSUInteger maxVerts, simd_float2 *pts,
                                  NSUInteger n, BOOL closed, const float *hw,
                                  const float *arcv, uint8_t lineCap,
                                  uint8_t lineJoin, BOOL bridgeFromPrev,
                                  float *outArc) {
  if (n < 2)
    return vc;
  float startHW = hw[0];
  float endHW = hw[n - 1];
  float startArc = arcv ? arcv[0] : 0.0f;

  // Square cap: push the open terminals out by their half-width along the end
  // tangent BEFORE stroking, so the butt rect extends into a square.
  if (!closed && lineCap == 2) {
    simd_float2 d0 = pts[0] - pts[1];
    if (simd_length_squared(d0) > 1e-12f)
      pts[0] += simd_normalize(d0) * startHW;
    simd_float2 d1 = pts[n - 1] - pts[n - 2];
    if (simd_length_squared(d1) > 1e-12f)
      pts[n - 1] += simd_normalize(d1) * endHW;
  }

  // Bridge from whatever was emitted before with two degenerate verts (repeat
  // the last emitted vertex, then this strip's first) so the single triangle
  // strip carries no visible span across the gap.
  if (bridgeFromPrev && vc > 0 && vc + 4 <= maxVerts) {
    simd_float2 firstOff;
    if (lineJoin == 0) {
      firstOff = CanvasMiterOffset(pts, n, 0, closed, startHW);
    } else {
      simd_float2 nIn0, nOut0;
      CanvasEdgeNormals(pts, n, 0, closed, &nIn0, &nOut0);
      firstOff = nIn0 * startHW;
    }
    CanvasSetArc(outArc, vc, outArc ? outArc[vc - 1] : 0.0f);
    outVerts[vc] = outVerts[vc - 1];
    vc++;
    CanvasSetArc(outArc, vc, startArc);
    outVerts[vc].position = pts[0] + firstOff;
    outVerts[vc].textureCoordinate = simd_make_float2(0.0f, 1.0f);
    vc++;
  }

  NSUInteger stop = closed ? n + 1 : n; // +1 wraps the closed loop
  for (NSUInteger k = 0; k < stop && vc + 2 <= maxVerts; k++) {
    NSUInteger i = k % n;
    float hwk = (closed && k == n) ? hw[n] : hw[i];
    float arck = arcv ? ((closed && k == n) ? arcv[n] : arcv[i]) : 0.0f;
    if (lineJoin == 0) {
      // Miter: one bisected cross-section (the original, clamped at the limit).
      simd_float2 off = CanvasMiterOffset(pts, n, i, closed, hwk);
      CanvasSetArc(outArc, vc, arck);
      outVerts[vc].position = pts[i] + off;
      outVerts[vc].textureCoordinate = simd_make_float2(0.0f, 1.0f);
      vc++;
      CanvasSetArc(outArc, vc, arck);
      outVerts[vc].position = pts[i] - off;
      outVerts[vc].textureCoordinate = simd_make_float2(0.0f, -1.0f);
      vc++;
      continue;
    }
    // Bevel / round join. The CONCAVE (inner) side converges to one shared
    // miter point so the two inner rails don't cross (that crossing left a
    // rogue sliver at the bevel tips). The CONVEX (outer) side bevels (a chord
    // between the two edge normals) or rounds (an even-angle arc). The +/- rail
    // sides keep their ty so the join stitches into the straight segments.
    simd_float2 nIn, nOut;
    CanvasEdgeNormals(pts, n, i, closed, &nIn, &nOut);
    float dn = simd_clamp(simd_dot(nIn, nOut), -1.0f, 1.0f);
    if (dn > 0.9999f) { // collinear / terminal
      vc = CanvasEmitCross(outVerts, vc, maxVerts, pts[i], nIn, hwk, outArc,
                           arck);
    } else {
      float ncross = nIn.x * nOut.y - nIn.y * nOut.x;
      BOOL innerIsPlus = ncross >= 0.0f; // concave side = + normals
      float outerSign = innerIsPlus ? -1.0f : 1.0f;
      simd_float2 bis = nIn + nOut;
      float bl = simd_length(bis);
      simd_float2 innerPt = pts[i];
      if (bl > 1e-4f) {
        simd_float2 bisN = bis / bl;
        float cosHalf = fmaxf(simd_dot(bisN, nIn), 0.1f);
        float d = fminf(hwk / cosHalf, hwk * kMiterLimit);
        innerPt = pts[i] + (innerIsPlus ? bisN : -bisN) * d;
      }
      float ang = acosf(dn);
      float dirSign = ncross >= 0.0f ? 1.0f : -1.0f;
      NSUInteger steps = 1; // bevel = 2 cross-sections (nIn, nOut)
      if (lineJoin == 1) {  // round: ~7.5 deg / step, capped
        steps = (NSUInteger)ceilf(ang / (float)(M_PI / 24.0));
        if (steps < 1)
          steps = 1;
        if (steps > kMaxJoinSteps)
          steps = kMaxJoinSteps;
      }
      for (NSUInteger s = 0; s <= steps && vc + 2 <= maxVerts; s++) {
        simd_float2 m;
        if (lineJoin == 1) {
          float a = dirSign * ang * ((float)s / (float)steps);
          float ca = cosf(a), sa = sinf(a);
          m = simd_make_float2(nIn.x * ca - nIn.y * sa,
                               nIn.x * sa + nIn.y * ca);
        } else {
          m = (s == 0) ? nIn : nOut;
        }
        simd_float2 outerPt = pts[i] + (outerSign * hwk) * m;
        if (innerIsPlus)
          vc = CanvasEmitCrossPts(outVerts, vc, maxVerts, innerPt, outerPt,
                                  outArc, arck);
        else
          vc = CanvasEmitCrossPts(outVerts, vc, maxVerts, outerPt, innerPt,
                                  outArc, arck);
      }
    }
  }

  // Round cap: append an outward semicircle fan at each open terminal (the
  // straight rail already covers up to the endpoint; the fan bulges past it).
  if (!closed && lineCap == 1) {
    float endArc = arcv ? arcv[n - 1] : 0.0f;
    simd_float2 d0 = pts[1] - pts[0];
    if (simd_length_squared(d0) > 1e-12f) {
      simd_float2 e = simd_normalize(d0);
      vc = CanvasAppendRoundCap(outVerts, vc, maxVerts, pts[0], CanvasPerp(e),
                                -e, startHW, outArc, startArc);
    }
    simd_float2 d1 = pts[n - 1] - pts[n - 2];
    if (simd_length_squared(d1) > 1e-12f) {
      simd_float2 e = simd_normalize(d1);
      vc = CanvasAppendRoundCap(outVerts, vc, maxVerts, pts[n - 1],
                                CanvasPerp(e), e, endHW, outArc, endArc);
    }
  }
  return vc;
}

NSUInteger CanvasTessellateStroke(KKBezierPath *path, float startWidth,
                                  float endWidth, float outputWidth,
                                  float outputHeight, uint8_t lineCap,
                                  uint8_t lineJoin, KKVertex2D *outVerts,
                                  NSUInteger maxVerts) {
  return CanvasTessellateStrokeArc(path, startWidth, endWidth, outputWidth,
                                   outputHeight, lineCap, lineJoin, outVerts,
                                   maxVerts, 0.0f, 0.0f, NULL, NULL);
}

NSUInteger CanvasTessellateStrokeScratch(KKBezierPath *path, float startWidth,
                                         float endWidth, float outputWidth,
                                         float outputHeight, uint8_t lineCap,
                                         uint8_t lineJoin, KKVertex2D *outVerts,
                                         NSUInteger maxVerts,
                                         CanvasStrokeScratch *scratch) {
  return CanvasTessellateStrokeArc(path, startWidth, endWidth, outputWidth,
                                   outputHeight, lineCap, lineJoin, outVerts,
                                   maxVerts, 0.0f, 0.0f, scratch, NULL);
}

// Trim `trimStart`/`trimEnd` px (arc length) off the ends of an OPEN polyline
// pts[0..n) in place, so an endpoint marker covers the stroke end (or rides a
// draw-on tip) instead of the stroke poking out past it. Walks in from each
// end, dropping fully-trimmed points and moving the boundary point to the trim
// distance. Returns the new vertex count (0 if trimmed away entirely). Declared
// in CanvasStrokeTessellateInternal.h - shared with the marker tessellator.
NSUInteger CanvasTrimOpenPolyline(simd_float2 *pts, NSUInteger n,
                                  float trimStart, float trimEnd) {
  if (n < 2)
    return n;
  if (trimEnd > 0.0f) {
    float rem = trimEnd;
    NSUInteger k = n - 1;
    while (k > 0) {
      float seg = simd_distance(pts[k], pts[k - 1]);
      if (seg >= rem) {
        float t = (seg > 1e-6f) ? rem / seg : 0.0f;
        pts[k] = pts[k] + (pts[k - 1] - pts[k]) * t;
        n = k + 1;
        break;
      }
      rem -= seg;
      k--;
    }
    if (k == 0)
      return 0;
  }
  if (trimStart > 0.0f) {
    float rem = trimStart;
    NSUInteger k = 0;
    while (k + 1 < n) {
      float seg = simd_distance(pts[k], pts[k + 1]);
      if (seg >= rem) {
        float t = (seg > 1e-6f) ? rem / seg : 0.0f;
        pts[k] = pts[k] + (pts[k + 1] - pts[k]) * t;
        if (k > 0) {
          for (NSUInteger j = 0; j + k < n; j++)
            pts[j] = pts[k + j];
          n -= k;
        }
        break;
      }
      rem -= seg;
      k++;
    }
    if (k + 1 >= n)
      return 0;
  }
  return n;
}

NSUInteger CanvasTessellateStrokeArc(
    KKBezierPath *path, float startWidth, float endWidth, float outputWidth,
    float outputHeight, uint8_t lineCap, uint8_t lineJoin, KKVertex2D *outVerts,
    NSUInteger maxVerts, float trimStartPx, float trimEndPx,
    CanvasStrokeScratch *scratch, float *outArc) {
  if (path.count < 2 || !outVerts || maxVerts < 4)
    return 0;

  NSUInteger nc = path.contourCount;
  BOOL closed = CanvasContourClosed(path, nc);

  // The polyline buffer is reused per contour, so size it for the largest one.
  NSUInteger polyCap = CanvasMaxContourPolyCap(path, closed);
  if (polyCap == 0)
    return 0;
  // Caller-provided scratch (grown on demand) on a hot single-threaded path, or
  // a local malloc/free otherwise. `hw` holds n+1 entries (the closing width).
  simd_float2 *pts;
  float *frac;
  float *hw;
  if (scratch) {
    if (scratch->cap < polyCap) {
      free(scratch->pts);
      free(scratch->frac);
      free(scratch->hw);
      scratch->pts = malloc(sizeof(simd_float2) * polyCap);
      scratch->frac = malloc(sizeof(float) * polyCap);
      scratch->hw = malloc(sizeof(float) * (polyCap + 1));
      scratch->cap = polyCap;
    }
    pts = scratch->pts;
    frac = scratch->frac;
    hw = scratch->hw;
  } else {
    pts = malloc(sizeof(simd_float2) * polyCap);
    frac = malloc(sizeof(float) * polyCap);
    hw = malloc(sizeof(float) * (polyCap + 1));
  }
  // Absolute per-vertex arc length (pixels) for the dash fragment - only when
  // an arc buffer is requested (the render's dashed path; the hit-test passes
  // NULL).
  float *arcv = outArc ? malloc(sizeof(float) * (polyCap + 1)) : NULL;

  float startHW = startWidth * 0.5f + kCanvasAAPaddingPx;
  float endHW = endWidth * 0.5f + kCanvasAAPaddingPx;
  NSUInteger vc = 0;
  BOOL anyEmitted = NO;
  for (NSUInteger ci = 0; ci < nc; ci++) {
    NSRange r = [path contourRangeAtIndex:ci];
    NSUInteger n = CanvasBuildContourPolyline(path, r, closed, outputWidth,
                                              outputHeight, pts, polyCap);
    if (n < 2)
      continue;
    // An open single contour with an endpoint marker: trim the ends back so the
    // marker covers the stroke end (no poke-through).
    if (!closed && nc == 1 && (trimStartPx > 0.0f || trimEndPx > 0.0f)) {
      n = CanvasTrimOpenPolyline(pts, n, trimStartPx, trimEndPx);
      if (n < 2)
        continue;
    }
    // Per-vertex half-width: Start at the contour's first vertex, End at its
    // last, lerped by normalized arc length (taper renders per contour). The
    // closing wrap (hw[n], closed only) sits at arc fraction 1.
    CanvasContourArcFractions(pts, n, closed, frac);
    for (NSUInteger i = 0; i < n; i++)
      hw[i] = startHW + (endHW - startHW) * frac[i];
    hw[n] = endHW;
    if (arcv) {
      // Absolute arc = normalized fraction x total contour length. Each contour
      // restarts at 0 so the dash pattern tiles per contour.
      float total = CanvasContourArcLength(pts, n, closed);
      for (NSUInteger i = 0; i < n; i++)
        arcv[i] = frac[i] * total;
      arcv[n] = total;
    }

    vc = CanvasEmitContourStrip(outVerts, vc, maxVerts, pts, n, closed, hw,
                                arcv, lineCap, lineJoin, anyEmitted, outArc);
    anyEmitted = YES;
  }

  if (!scratch) {
    free(pts);
    free(frac);
    free(hw);
  }
  free(arcv);
  return vc;
}

