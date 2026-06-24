/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasStrokeTessellate.h"
#import <KeyframelessKit/KKBezierPath.h>
#import <simd/simd.h>

static const NSUInteger kStepsPerSegment = 32;
static const NSUInteger kCapSegs = 24;     // semicircle segments for a round cap
static const NSUInteger kMaxJoinSteps = 24; // max arc segments for a round join
static const float kAAPaddingPx = 0.75f; // solid core reaches the asked width
static const float kMiterLimit = 4.0f;   // clamp spikes at very sharp corners

// Segments in one contour: a closed contour wraps (cLen segments), an open one
// has cLen-1. A compound path's individual contours are each closed; a lone
// contour follows the path's own closed flag (an open pen path stays open).
static NSUInteger CanvasContourSegmentCount(NSUInteger cLen, BOOL closed) {
  if (cLen < 2)
    return 0;
  return closed ? cLen : cLen - 1;
}

static BOOL CanvasContourClosed(KKBezierPath *path, NSUInteger contourCount) {
  return (contourCount > 1) ? YES : path.closed;
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
  // (kCapSegs+1) rim+centre pairs + a 2-vert bridge; budget generously).
  NSUInteger capVerts = nc * 2 * ((kCapSegs + 1) * 2 + 2);
  return total + (nc > 1 ? (nc - 1) * 2 : 0) + capVerts + 8;
}

// Sample ONE contour into a centered-pixel polyline matching the image-quad
// space: p_centered = (normalized - 0.5) * outputSize. Near-duplicate samples
// are dropped so adjacent edges yield stable normals.
static NSUInteger CanvasBuildContourPolyline(KKBezierPath *path, NSRange r,
                                             BOOL closed, float outW,
                                             float outH, simd_float2 *pts,
                                             NSUInteger maxPts) {
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
// side mirrors the present one. Used by the bevel / round joins, which keep each
// edge at its own normal instead of bisecting to a single miter point.
static void CanvasEdgeNormals(const simd_float2 *pts, NSUInteger n, NSUInteger i,
                              BOOL closed, simd_float2 *outIn,
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

// Emit one strip cross-section at `center` offset by ±normal*hw (the rail's two
// AA edges, textureCoordinate.y = ±1).
static NSUInteger CanvasEmitCross(KKVertex2D *v, NSUInteger vc, NSUInteger max,
                                  simd_float2 center, simd_float2 normal,
                                  float hw) {
  if (vc + 2 > max)
    return vc;
  v[vc].position = center + normal * hw;
  v[vc].textureCoordinate = simd_make_float2(0.0f, 1.0f);
  vc++;
  v[vc].position = center - normal * hw;
  v[vc].textureCoordinate = simd_make_float2(0.0f, -1.0f);
  vc++;
  return vc;
}

// Emit a cross-section with explicit + (ty +1) and - (ty -1) positions - used by
// the bevel / round joins, where one side is the shared inner miter point and
// the other is the outer bevel / arc point (so the + / - rail sides stay
// consistent with the straight segments and the strip joins seamlessly).
static NSUInteger CanvasEmitCrossPts(KKVertex2D *v, NSUInteger vc,
                                     NSUInteger max, simd_float2 plusPt,
                                     simd_float2 minusPt) {
  if (vc + 2 > max)
    return vc;
  v[vc].position = plusPt;
  v[vc].textureCoordinate = simd_make_float2(0.0f, 1.0f);
  vc++;
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

// Append a round cap (outward semicircle) at an open contour's end, bridged into
// the running triangle strip. `center` is the terminal point, `railNormal` the
// unit perpendicular of the terminal edge (the rail's offset direction), and
// `outward` the unit tangent pointing away from the path. The arc rim carries
// textureCoordinate.y = ±1 (so KKLineFragment AAs it ~1px in); the centre is
// solid (y = 0) - same edge fade as the straight rail.
static NSUInteger CanvasAppendRoundCap(KKVertex2D *outVerts, NSUInteger vc,
                                       NSUInteger maxVerts, simd_float2 center,
                                       simd_float2 railNormal,
                                       simd_float2 outward, float hw) {
  if (vc + (kCapSegs + 1) * 2 + 2 > maxVerts)
    return vc;
  simd_float2 rim0 = center + railNormal * hw;
  if (vc > 0) {
    outVerts[vc] = outVerts[vc - 1]; // degenerate bridge from the strip
    vc++;
    outVerts[vc].position = rim0;
    outVerts[vc].textureCoordinate = simd_make_float2(0.0f, 1.0f);
    vc++;
  }
  for (NSUInteger s = 0; s <= kCapSegs; s++) {
    float a = (float)s / (float)kCapSegs * (float)M_PI;
    simd_float2 dir = railNormal * cosf(a) + outward * sinf(a);
    outVerts[vc].position = center + dir * hw;
    outVerts[vc].textureCoordinate = simd_make_float2(0.0f, 1.0f);
    vc++;
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
  scratch->pts = NULL;
  scratch->frac = NULL;
  scratch->cap = 0;
}

NSUInteger CanvasTessellateStroke(KKBezierPath *path, float startWidth,
                                  float endWidth, float outputWidth,
                                  float outputHeight, uint8_t lineCap,
                                  uint8_t lineJoin, KKVertex2D *outVerts,
                                  NSUInteger maxVerts) {
  return CanvasTessellateStrokeScratch(path, startWidth, endWidth, outputWidth,
                                       outputHeight, lineCap, lineJoin, outVerts,
                                       maxVerts, NULL);
}

NSUInteger CanvasTessellateStrokeScratch(KKBezierPath *path, float startWidth,
                                         float endWidth, float outputWidth,
                                         float outputHeight, uint8_t lineCap,
                                         uint8_t lineJoin, KKVertex2D *outVerts,
                                         NSUInteger maxVerts,
                                         CanvasStrokeScratch *scratch) {
  if (path.count < 2 || !outVerts || maxVerts < 4)
    return 0;

  NSUInteger nc = path.contourCount;
  BOOL closed = CanvasContourClosed(path, nc);

  // The polyline buffer is reused per contour, so size it for the largest one.
  NSUInteger polyCap = 0;
  for (NSUInteger ci = 0; ci < nc; ci++) {
    NSRange r = [path contourRangeAtIndex:ci];
    NSUInteger segs = CanvasContourSegmentCount(r.length, closed);
    NSUInteger cap = segs * kStepsPerSegment + 2;
    if (cap > polyCap)
      polyCap = cap;
  }
  if (polyCap == 0)
    return 0;
  // Caller-provided scratch (grown on demand) on a hot single-threaded path, or
  // a local malloc/free otherwise.
  simd_float2 *pts;
  float *frac;
  if (scratch) {
    if (scratch->cap < polyCap) {
      free(scratch->pts);
      free(scratch->frac);
      scratch->pts = malloc(sizeof(simd_float2) * polyCap);
      scratch->frac = malloc(sizeof(float) * polyCap);
      scratch->cap = polyCap;
    }
    pts = scratch->pts;
    frac = scratch->frac;
  } else {
    pts = malloc(sizeof(simd_float2) * polyCap);
    frac = malloc(sizeof(float) * polyCap);
  }

  float startHW = startWidth * 0.5f + kAAPaddingPx;
  float endHW = endWidth * 0.5f + kAAPaddingPx;
  NSUInteger vc = 0;
  BOOL anyEmitted = NO;
  for (NSUInteger ci = 0; ci < nc; ci++) {
    NSRange r = [path contourRangeAtIndex:ci];
    NSUInteger n = CanvasBuildContourPolyline(path, r, closed, outputWidth,
                                              outputHeight, pts, polyCap);
    if (n < 2)
      continue;
    // Per-vertex half-width: Start at the contour's first vertex, End at its
    // last, lerped by normalized arc length (taper renders per contour).
    CanvasContourArcFractions(pts, n, closed, frac);

    // Square cap: push the open terminals out by their half-width along the end
    // tangent BEFORE stroking, so the butt rect extends into a square. (frac is
    // already computed, so the taper distribution is unaffected.)
    if (!closed && lineCap == 2) {
      simd_float2 d0 = pts[0] - pts[1];
      if (simd_length_squared(d0) > 1e-12f)
        pts[0] += simd_normalize(d0) * startHW;
      simd_float2 d1 = pts[n - 1] - pts[n - 2];
      if (simd_length_squared(d1) > 1e-12f)
        pts[n - 1] += simd_normalize(d1) * endHW;
    }

    // Bridge from the previous contour with two degenerate verts (repeat the
    // last emitted vertex, then this contour's first) so the single triangle
    // strip carries no visible span across the gap.
    if (anyEmitted && vc > 0 && vc + 4 <= maxVerts) {
      simd_float2 firstOff;
      if (lineJoin == 0) {
        firstOff = CanvasMiterOffset(pts, n, 0, closed, startHW);
      } else {
        simd_float2 nIn0, nOut0;
        CanvasEdgeNormals(pts, n, 0, closed, &nIn0, &nOut0);
        firstOff = nIn0 * startHW;
      }
      outVerts[vc] = outVerts[vc - 1];
      vc++;
      outVerts[vc].position = pts[0] + firstOff;
      outVerts[vc].textureCoordinate = simd_make_float2(0.0f, 1.0f);
      vc++;
    }

    NSUInteger stop = closed ? n + 1 : n; // +1 wraps the closed loop
    for (NSUInteger k = 0; k < stop && vc + 2 <= maxVerts; k++) {
      NSUInteger i = k % n;
      // The closing wrap (k == n) sits at arc fraction 1 even though i == 0.
      float f = (closed && k == n) ? 1.0f : frac[i];
      float hw = startHW + (endHW - startHW) * f;
      if (lineJoin == 0) {
        // Miter: one bisected cross-section (the original, clamped at the limit).
        simd_float2 off = CanvasMiterOffset(pts, n, i, closed, hw);
        outVerts[vc].position = pts[i] + off;
        outVerts[vc].textureCoordinate = simd_make_float2(0.0f, 1.0f);
        vc++;
        outVerts[vc].position = pts[i] - off;
        outVerts[vc].textureCoordinate = simd_make_float2(0.0f, -1.0f);
        vc++;
        continue;
      }
      // Bevel / round join. The CONCAVE (inner) side converges to one shared
      // miter point so the two inner rails don't cross (that crossing left a
      // rogue sliver at the bevel tips). The CONVEX (outer) side bevels (a chord
      // between the two edge normals) or rounds (an even-angle arc). The +/-
      // rail sides keep their ty so the join stitches into the straight segments.
      simd_float2 nIn, nOut;
      CanvasEdgeNormals(pts, n, i, closed, &nIn, &nOut);
      float dn = simd_clamp(simd_dot(nIn, nOut), -1.0f, 1.0f);
      if (dn > 0.9999f) { // collinear / terminal
        vc = CanvasEmitCross(outVerts, vc, maxVerts, pts[i], nIn, hw);
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
          float d = fminf(hw / cosHalf, hw * kMiterLimit);
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
          simd_float2 outerPt = pts[i] + (outerSign * hw) * m;
          if (innerIsPlus)
            vc = CanvasEmitCrossPts(outVerts, vc, maxVerts, innerPt, outerPt);
          else
            vc = CanvasEmitCrossPts(outVerts, vc, maxVerts, outerPt, innerPt);
        }
      }
    }

    // Round cap: append an outward semicircle fan at each open terminal (the
    // straight rail already covers up to the endpoint; the fan bulges past it).
    if (!closed && lineCap == 1) {
      simd_float2 d0 = pts[1] - pts[0];
      if (simd_length_squared(d0) > 1e-12f) {
        simd_float2 e = simd_normalize(d0);
        vc = CanvasAppendRoundCap(outVerts, vc, maxVerts, pts[0], CanvasPerp(e),
                                  -e, startHW);
      }
      simd_float2 d1 = pts[n - 1] - pts[n - 2];
      if (simd_length_squared(d1) > 1e-12f) {
        simd_float2 e = simd_normalize(d1);
        vc = CanvasAppendRoundCap(outVerts, vc, maxVerts, pts[n - 1],
                                  CanvasPerp(e), e, endHW);
      }
    }
    anyEmitted = YES;
  }

  if (!scratch) {
    free(pts);
    free(frac);
  }
  return vc;
}
