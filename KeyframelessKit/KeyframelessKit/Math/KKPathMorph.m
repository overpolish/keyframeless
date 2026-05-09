/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPathMorph.h"
#import "KKShape.h"

// Cubic-bezier-based morph implementation. Mirrors the recipe shared across
// GSAP MorphSVG, Flubber, and KUTE.js Cubic Morph:
//   1. Promote every segment to a cubic bezier (linear segments become
//      degenerate cubics with handles at 1/3 and 2/3 along the chord).
//   2. Equalize segment counts by recursively splitting the shorter path's
//      longest segments via de Casteljau (lossless — no detail discarded).
//   3. Direction-match closed paths via signed area; reverse one if signs
//      differ to prevent inversions during interpolation.
//   4. For closed paths, cyclically rotate one path's segments to minimize
//      Σ‖A[i].P0 - B[i].P0‖² so corresponding anchors stay paired.
//   5. Lerp control points 1:1 across the matched segment lists.

typedef struct {
  simd_float2 p0, c0, c1, p1;
} KKMorphCubic;

static const NSUInteger kSubstepsPerSegment = 24;
static const NSUInteger kMinSampleCount = 8;

static simd_float2 evalCubic(simd_float2 p0, simd_float2 c0, simd_float2 c1,
                             simd_float2 p1, float t) {
  float u = 1.0f - t;
  return u * u * u * p0 + 3.0f * u * u * t * c0 + 3.0f * u * t * t * c1 +
         t * t * t * p1;
}

// Snapshot blob layout:
//   uint32 count
//   uint8 closed
//   KKBezierPoint × count
//   (optional) uint16 nContours
//   (optional) uint32 × nContours contourStarts (in order; first start is
//   always 0 implicitly and is included in the array)
//
// Older blobs written before the contour fields existed simply omit the
// trailing bytes — readHeader only consumes through the points array, and
// readContours treats missing trailing bytes as "single contour".

// Flags byte layout: bit 0 = closed, bit 1 = "shape tail follows points and
// contours". Tail is kind-tagged: per-kind payload then 1 byte KKShapeKind
// at the very end (reverse-readable so contour-block presence doesn't
// matter). Payload sizes live on KKShape +payloadByteCountForKind:.
#define KK_MORPH_FLAG_CLOSED (1u << 0)
#define KK_MORPH_FLAG_HAS_SHAPE_TAIL (1u << 1)

static BOOL readHeader(NSData *blob, const KKBezierPoint **outPts,
                       uint32_t *outCount, BOOL *outClosed) {
  if (!blob || blob.length < 5)
    return NO;
  const uint8_t *bytes = blob.bytes;
  uint32_t count;
  memcpy(&count, bytes, 4);
  uint8_t flags = bytes[4];
  size_t need = 5 + (size_t)count * sizeof(KKBezierPoint);
  if (blob.length < need)
    return NO;
  if (outPts)
    *outPts = (const KKBezierPoint *)(bytes + 5);
  if (outCount)
    *outCount = count;
  if (outClosed)
    *outClosed = (flags & KK_MORPH_FLAG_CLOSED) != 0;
  return YES;
}

// Reads the shape tail (payload + kind:u8 last byte). Returns the parsed
// shape (autoreleased), or nil if the tail isn't present, malformed, or
// of an unsupported kind. Tail is reverse-readable regardless of contour
// block presence.
static KKShape *readShapeTail(NSData *blob) {
  if (!blob || blob.length < 6)
    return nil;
  const uint8_t *bytes = blob.bytes;
  uint8_t flags = bytes[4];
  if (!(flags & KK_MORPH_FLAG_HAS_SHAPE_TAIL))
    return nil;
  uint8_t kind = bytes[blob.length - 1];
  size_t payload = [KKShape payloadByteCountForKind:kind];
  if (payload == 0 || blob.length < 5 + payload + 1)
    return nil;
  size_t off = blob.length - 1 - payload;
  return [KKShape shapeWithKind:kind bytes:bytes + off available:payload];
}

// Returns the array of contour start indices from a snapshot blob, or nil
// for single-contour / legacy blobs.
static NSArray<NSNumber *> *readContours(NSData *blob, uint32_t pointCount) {
  size_t pointsEnd = 5 + (size_t)pointCount * sizeof(KKBezierPoint);
  if (blob.length < pointsEnd + 2)
    return nil;
  const uint8_t *bytes = blob.bytes;
  uint16_t nContours;
  memcpy(&nContours, bytes + pointsEnd, 2);
  if (nContours <= 1)
    return nil;
  size_t need = pointsEnd + 2 + (size_t)nContours * 4;
  if (blob.length < need)
    return nil;
  NSMutableArray<NSNumber *> *out =
      [NSMutableArray arrayWithCapacity:nContours];
  for (uint16_t i = 0; i < nContours; i++) {
    uint32_t start;
    memcpy(&start, bytes + pointsEnd + 2 + i * 4, 4);
    [out addObject:@(start)];
  }
  return out;
}

NSData *KKMorphSnapshotCapture(KKBezierPath *path) {
  uint32_t count = (uint32_t)path.count;
  KKShape *shape = path.shape;
  NSData *shapePayload = shape.serializedPayload;
  uint8_t flags = 0;
  if (path.closed)
    flags |= KK_MORPH_FLAG_CLOSED;
  if (shapePayload)
    flags |= KK_MORPH_FLAG_HAS_SHAPE_TAIL;
  NSUInteger nContours = path.contourCount;
  size_t tailBytes = shapePayload ? shapePayload.length + 1 : 0;
  NSMutableData *data =
      [NSMutableData dataWithCapacity:5 + count * sizeof(KKBezierPoint) + 2 +
                                      nContours * 4 + tailBytes];
  [data appendBytes:&count length:4];
  [data appendBytes:&flags length:1];
  for (uint32_t i = 0; i < count; i++) {
    KKBezierPoint p = [path pointAtIndex:i];
    [data appendBytes:&p length:sizeof(KKBezierPoint)];
  }
  if (nContours > 1) {
    uint16_t nc = (uint16_t)MIN((NSUInteger)UINT16_MAX, nContours);
    [data appendBytes:&nc length:2];
    for (uint16_t i = 0; i < nc; i++) {
      uint32_t start = (uint32_t)[path contourRangeAtIndex:i].location;
      [data appendBytes:&start length:4];
    }
  }
  // Shape tail layout: payload, then kind:u8 as the very last byte. Reverse-
  // readable so it works whether or not a contour block precedes it.
  if (shapePayload) {
    [data appendData:shapePayload];
    uint8_t kind = (uint8_t)shape.kind;
    [data appendBytes:&kind length:1];
  }
  return data;
}

BOOL KKMorphSnapshotPeek(NSData *blob, uint32_t *outCount, BOOL *outClosed) {
  return readHeader(blob, NULL, outCount, outClosed);
}

void KKMorphSnapshotApply(NSData *blob, KKBezierPath *path) {
  const KKBezierPoint *pts = NULL;
  uint32_t count = 0;
  BOOL closed = NO;
  if (!readHeader(blob, &pts, &count, &closed))
    return;
  [path setBezierPoints:pts count:count closed:closed];
  [path setContourStarts:readContours(blob, count)];
  [path restoreShape:readShapeTail(blob)];
}

// --- Cubic helpers -----------------------------------------------------

// Convert a snapshot blob into a flat cubic-segment list. `outSegs` is
// allocated with malloc (caller frees). Linear authored segments become
// degenerate cubics with control points at 1/3 and 2/3 along the chord.
static BOOL _kkSnapshotToCubics(NSData *blob, KKMorphCubic **outSegs,
                                NSUInteger *outCount, BOOL *outClosed) {
  const KKBezierPoint *pts = NULL;
  uint32_t n = 0;
  BOOL closed = NO;
  if (!readHeader(blob, &pts, &n, &closed) || n < 2)
    return NO;
  NSUInteger segCount = closed ? (NSUInteger)n : (NSUInteger)(n - 1);
  KKMorphCubic *segs = malloc(sizeof(KKMorphCubic) * segCount);
  if (!segs)
    return NO;
  for (NSUInteger i = 0; i < segCount; i++) {
    KKBezierPoint a = pts[i];
    KKBezierPoint b = pts[(i + 1) % n];
    BOOL isBezier =
        (a.type == KKBezierPointBezier || b.type == KKBezierPointBezier);
    simd_float2 p0 = {a.x, a.y};
    simd_float2 p1 = {b.x, b.y};
    simd_float2 c0, c1;
    if (isBezier) {
      c0 = (simd_float2){a.x + a.outX, a.y + a.outY};
      c1 = (simd_float2){b.x + b.inX, b.y + b.inY};
    } else {
      simd_float2 d = p1 - p0;
      c0 = p0 + d * (1.0f / 3.0f);
      c1 = p0 + d * (2.0f / 3.0f);
    }
    segs[i] = (KKMorphCubic){p0, c0, c1, p1};
  }
  *outSegs = segs;
  *outCount = segCount;
  *outClosed = closed;
  return YES;
}

// de Casteljau split at parameter t.
static void _kkCubicSplit(KKMorphCubic s, float t, KKMorphCubic *outL,
                          KKMorphCubic *outR) {
  simd_float2 q0 = s.p0 + (s.c0 - s.p0) * t;
  simd_float2 q1 = s.c0 + (s.c1 - s.c0) * t;
  simd_float2 q2 = s.c1 + (s.p1 - s.c1) * t;
  simd_float2 r0 = q0 + (q1 - q0) * t;
  simd_float2 r1 = q1 + (q2 - q1) * t;
  simd_float2 mid = r0 + (r1 - r0) * t;
  *outL = (KKMorphCubic){s.p0, q0, r0, mid};
  *outR = (KKMorphCubic){mid, r1, q2, s.p1};
}

// Chord length is enough for the "split the longest" heuristic — exact arc
// length isn't necessary and is much more expensive.
static float _kkCubicChord(KKMorphCubic s) { return simd_distance(s.p0, s.p1); }

// Subdivide `segs` (allocated with malloc, length `curCount`) until length
// reaches `target`. Each iteration splits the current longest segment in
// half. Returns a new buffer; the input is freed.
static KKMorphCubic *_kkEqualize(KKMorphCubic *segs, NSUInteger curCount,
                                 NSUInteger target) {
  if (curCount >= target)
    return segs;
  KKMorphCubic *buf = malloc(sizeof(KKMorphCubic) * target);
  if (!buf)
    return segs;
  memcpy(buf, segs, sizeof(KKMorphCubic) * curCount);
  free(segs);
  NSUInteger n = curCount;
  while (n < target) {
    NSUInteger pick = 0;
    float maxLen = -1.0f;
    for (NSUInteger i = 0; i < n; i++) {
      float len = _kkCubicChord(buf[i]);
      if (len > maxLen) {
        maxLen = len;
        pick = i;
      }
    }
    KKMorphCubic L, R;
    _kkCubicSplit(buf[pick], 0.5f, &L, &R);
    if (pick + 1 < n)
      memmove(&buf[pick + 2], &buf[pick + 1],
              (n - pick - 1) * sizeof(KKMorphCubic));
    buf[pick] = L;
    buf[pick + 1] = R;
    n++;
  }
  return buf;
}

// Signed polygon area from the cubic anchor points. Sign indicates winding;
// magnitude is unused.
static float _kkSignedArea(const KKMorphCubic *segs, NSUInteger count) {
  float a = 0;
  for (NSUInteger i = 0; i < count; i++) {
    simd_float2 p = segs[i].p0;
    simd_float2 q = segs[(i + 1) % count].p0;
    a += p.x * q.y - q.x * p.y;
  }
  return 0.5f * a;
}

// Reverse a cubic list in place: flips order, swaps p0/p1 and c0/c1 in each
// segment so the new direction is consistent.
static void _kkReverseCubics(KKMorphCubic *segs, NSUInteger count) {
  for (NSUInteger i = 0; i < count / 2; i++) {
    KKMorphCubic t = segs[i];
    segs[i] = segs[count - 1 - i];
    segs[count - 1 - i] = t;
  }
  for (NSUInteger i = 0; i < count; i++) {
    KKMorphCubic s = segs[i];
    segs[i] = (KKMorphCubic){s.p1, s.c1, s.c0, s.p0};
  }
}

// Pick the cyclic rotation k that minimizes Σ‖a[i].p0 - b[(i+k) % n].p0‖².
static NSUInteger _kkBestRotation(const KKMorphCubic *a, const KKMorphCubic *b,
                                  NSUInteger count) {
  NSUInteger bestK = 0;
  float bestSum = INFINITY;
  for (NSUInteger k = 0; k < count; k++) {
    float sum = 0;
    for (NSUInteger i = 0; i < count; i++) {
      simd_float2 diff = a[i].p0 - b[(i + k) % count].p0;
      sum += diff.x * diff.x + diff.y * diff.y;
    }
    if (sum < bestSum) {
      bestSum = sum;
      bestK = k;
    }
  }
  return bestK;
}

// Left-rotate the segment list by k (i.e. segs[k] becomes segs[0]).
static void _kkRotateCubics(KKMorphCubic *segs, NSUInteger count,
                            NSUInteger k) {
  k %= count;
  if (k == 0)
    return;
  KKMorphCubic *tmp = malloc(sizeof(KKMorphCubic) * count);
  if (!tmp)
    return;
  for (NSUInteger i = 0; i < count; i++)
    tmp[i] = segs[(i + k) % count];
  memcpy(segs, tmp, sizeof(KKMorphCubic) * count);
  free(tmp);
}

// Build a KKBezierPoint array from the morphed cubic segments. The output
// is always KKBezierPointBezier-typed since handles are now meaningful even
// for originally-linear segments (degenerate cubics still render straight).
static KKBezierPoint *_kkCubicsToPoints(const KKMorphCubic *segs,
                                        NSUInteger segCount, BOOL closed,
                                        NSUInteger *outCount) {
  NSUInteger n = closed ? segCount : segCount + 1;
  KKBezierPoint *pts = malloc(sizeof(KKBezierPoint) * n);
  if (!pts)
    return NULL;
  for (NSUInteger i = 0; i < n; i++) {
    simd_float2 anchor;
    simd_float2 inH = {0, 0}, outH = {0, 0};
    BOOL hasOut = closed ? YES : (i < segCount);
    BOOL hasIn = closed ? YES : (i > 0);
    if (hasOut) {
      KKMorphCubic s = segs[closed ? i : i];
      anchor = s.p0;
      outH = s.c0 - anchor;
    } else {
      // Tail anchor of an open path = previous segment's p1.
      anchor = segs[segCount - 1].p1;
    }
    if (hasIn) {
      NSUInteger inIdx = closed ? ((i + segCount - 1) % segCount) : (i - 1);
      simd_float2 c1 = segs[inIdx].c1;
      inH = c1 - anchor;
    }
    pts[i] = (KKBezierPoint){
        .x = anchor.x,
        .y = anchor.y,
        .inX = inH.x,
        .inY = inH.y,
        .outX = outH.x,
        .outY = outH.y,
        .type = KKBezierPointBezier,
    };
  }
  // Open-path endpoint tangent fix: the cubic-equalize step pairs cubics
  // strictly by index, with no spatial alignment for open paths. That can
  // leave the boundary cubics' handles dominated by whichever side had the
  // larger authored handle — pointing in a direction that disagrees with
  // the morphed visible chord. The stroke tessellator computes its end
  // normal from the analytic tangent (3·(c0-p0) at t=0, 3·(p1-c1) at t=1),
  // so a mis-directed boundary handle shows up as a V-notch at the cap.
  // Re-project the head's outH and tail's inH onto the chord toward the
  // neighboring anchor while preserving handle length.
  if (!closed && n >= 2) {
    simd_float2 a0 = {pts[0].x, pts[0].y};
    simd_float2 a1 = {pts[1].x, pts[1].y};
    simd_float2 chord0 = a1 - a0;
    float chord0Len = simd_length(chord0);
    if (chord0Len > 1e-6f) {
      simd_float2 outH0 = {pts[0].outX, pts[0].outY};
      float hLen = simd_length(outH0);
      simd_float2 dir = chord0 / chord0Len;
      pts[0].outX = dir.x * hLen;
      pts[0].outY = dir.y * hLen;
    }
    simd_float2 aN = {pts[n - 1].x, pts[n - 1].y};
    simd_float2 aP = {pts[n - 2].x, pts[n - 2].y};
    simd_float2 chordN = aP - aN;
    float chordNLen = simd_length(chordN);
    if (chordNLen > 1e-6f) {
      simd_float2 inHN = {pts[n - 1].inX, pts[n - 1].inY};
      float hLen = simd_length(inHN);
      simd_float2 dir = chordN / chordNLen;
      pts[n - 1].inX = dir.x * hLen;
      pts[n - 1].inY = dir.y * hLen;
    }
  }
  *outCount = n;
  return pts;
}

// When both blobs carry the same shape kind, restore the path's shape ivar
// with t-lerped parameters. When kinds differ (or either is missing),
// leave the shape as `setBezierPoints` left it (cleared) — mid-transition
// across kinds is genuinely "not a rect/ellipse anymore."
static void restoreLerpedShapeTail(NSData *fromBlob, NSData *toBlob, float t,
                                   KKBezierPath *path) {
  KKShape *lerped = [KKShape lerpFrom:readShapeTail(fromBlob)
                                   to:readShapeTail(toBlob)
                                    t:t];
  if (lerped)
    [path restoreShape:lerped];
}

// --- Public: cubic-based morph apply -----------------------------------

void KKMorphInterpolateApply(NSData *fromBlob, NSData *toBlob, float t,
                             KKBezierPath *path) {
  uint32_t aN = 0, bN = 0;
  BOOL aClosed = NO, bClosed = NO;
  if (!KKMorphSnapshotPeek(fromBlob, &aN, &aClosed) ||
      !KKMorphSnapshotPeek(toBlob, &bN, &bClosed))
    return;
  if (aN < 2 || bN < 2)
    return;
  // Open vs closed mismatch is ambiguous — bail rather than guess.
  if (aClosed != bClosed)
    return;

  // Don't clamp t — overshoot easing curves (Elastic/Bounce/Back) carry
  // values outside [0, 1], and clamping them flattens the overshoot. Linear
  // extrapolation past either endpoint is the desired behavior here.

  // Topology match: lerp authored control points 1:1. Faster, and preserves
  // linear-segment types when both authored shapes are linear.
  if (aN == bN) {
    const KKBezierPoint *aPts = NULL, *bPts = NULL;
    BOOL ac, bc;
    readHeader(fromBlob, &aPts, &aN, &ac);
    readHeader(toBlob, &bPts, &bN, &bc);
    if (!aPts || !bPts)
      return;
    KKBezierPoint *out = malloc(sizeof(KKBezierPoint) * aN);
    if (!out)
      return;
    for (uint32_t i = 0; i < aN; i++) {
      out[i].x = aPts[i].x + (bPts[i].x - aPts[i].x) * t;
      out[i].y = aPts[i].y + (bPts[i].y - aPts[i].y) * t;
      out[i].inX = aPts[i].inX + (bPts[i].inX - aPts[i].inX) * t;
      out[i].inY = aPts[i].inY + (bPts[i].inY - aPts[i].inY) * t;
      out[i].outX = aPts[i].outX + (bPts[i].outX - aPts[i].outX) * t;
      out[i].outY = aPts[i].outY + (bPts[i].outY - aPts[i].outY) * t;
      out[i].type = (aPts[i].type == KKBezierPointBezier ||
                     bPts[i].type == KKBezierPointBezier)
                        ? KKBezierPointBezier
                        : KKBezierPointLinear;
    }
    [path setBezierPoints:out count:aN closed:aClosed];
    // Matching topology means contour structure also matches — pick from's
    // contour starts (they're authoritative since user edits don't change
    // topology when the count matches).
    [path setContourStarts:readContours(fromBlob, aN)];
    restoreLerpedShapeTail(fromBlob, toBlob, t, path);
    free(out);
    return;
  }

  // Mismatched counts: cubic-promote, equalize via subdivision, direction
  // match, cyclic align, lerp.
  KKMorphCubic *aSegs = NULL, *bSegs = NULL;
  NSUInteger aSegCount = 0, bSegCount = 0;
  BOOL aC = NO, bC = NO;
  if (!_kkSnapshotToCubics(fromBlob, &aSegs, &aSegCount, &aC))
    return;
  if (!_kkSnapshotToCubics(toBlob, &bSegs, &bSegCount, &bC)) {
    free(aSegs);
    return;
  }
  NSUInteger target = MAX(aSegCount, bSegCount);
  aSegs = _kkEqualize(aSegs, aSegCount, target);
  bSegs = _kkEqualize(bSegs, bSegCount, target);

  if (aClosed) {
    float areaA = _kkSignedArea(aSegs, target);
    float areaB = _kkSignedArea(bSegs, target);
    if ((areaA >= 0) != (areaB >= 0))
      _kkReverseCubics(bSegs, target);
    NSUInteger k = _kkBestRotation(aSegs, bSegs, target);
    _kkRotateCubics(bSegs, target, k);
  }

  KKMorphCubic *out = malloc(sizeof(KKMorphCubic) * target);
  if (!out) {
    free(aSegs);
    free(bSegs);
    return;
  }
  for (NSUInteger i = 0; i < target; i++) {
    out[i].p0 = aSegs[i].p0 + (bSegs[i].p0 - aSegs[i].p0) * t;
    out[i].c0 = aSegs[i].c0 + (bSegs[i].c0 - aSegs[i].c0) * t;
    out[i].c1 = aSegs[i].c1 + (bSegs[i].c1 - aSegs[i].c1) * t;
    out[i].p1 = aSegs[i].p1 + (bSegs[i].p1 - aSegs[i].p1) * t;
  }

  NSUInteger outPtCount = 0;
  KKBezierPoint *outPts = _kkCubicsToPoints(out, target, aClosed, &outPtCount);
  if (outPts) {
    [path setBezierPoints:outPts count:outPtCount closed:aClosed];
    // Subdivision invalidates the original contour-start indices; collapse
    // to a single contour. (Compound-path morph between mismatched
    // topologies is a known limitation.)
    [path setContourStarts:nil];
    restoreLerpedShapeTail(fromBlob, toBlob, t, path);
    free(outPts);
  }
  free(aSegs);
  free(bSegs);
  free(out);
}

// --- Legacy linear-resample helpers (kept for back-compat) -------------

// Densely sample one snapshot along arc length, producing `nSamples`
// evenly-spaced positions. Closed paths sample the wrap segment too.
// Returns NO if the snapshot is degenerate (count < 2).
static BOOL densePolyline(const KKBezierPoint *pts, NSUInteger count,
                          BOOL closed, NSUInteger nSamples, simd_float2 *out) {
  if (count < 2 || nSamples == 0)
    return NO;
  NSUInteger segCount = closed ? count : count - 1;

  NSUInteger total = segCount * kSubstepsPerSegment + 1;
  simd_float2 *dense = malloc(sizeof(simd_float2) * total);
  float *cum = malloc(sizeof(float) * total);
  if (!dense || !cum) {
    free(dense);
    free(cum);
    return NO;
  }
  NSUInteger w = 0;
  cum[0] = 0.0f;
  for (NSUInteger s = 0; s < segCount; s++) {
    NSUInteger ai = s;
    NSUInteger bi = (s + 1) % count;
    KKBezierPoint a = pts[ai];
    KKBezierPoint b = pts[bi];
    simd_float2 p0 = (simd_float2){a.x, a.y};
    simd_float2 p1 = (simd_float2){b.x, b.y};
    BOOL bezier =
        (a.type == KKBezierPointBezier || b.type == KKBezierPointBezier);
    simd_float2 c0 = bezier ? (simd_float2){a.x + a.outX, a.y + a.outY} : p0;
    simd_float2 c1 = bezier ? (simd_float2){b.x + b.inX, b.y + b.inY} : p1;
    for (NSUInteger k = 0; k < kSubstepsPerSegment; k++) {
      float t = (float)k / (float)kSubstepsPerSegment;
      simd_float2 q =
          bezier ? evalCubic(p0, c0, c1, p1, t) : p0 + (p1 - p0) * t;
      if (s == 0 && k == 0) {
        dense[w++] = q;
      } else {
        simd_float2 prev = dense[w - 1];
        cum[w] = cum[w - 1] + simd_distance(prev, q);
        dense[w++] = q;
      }
    }
  }
  KKBezierPoint last = pts[closed ? 0 : count - 1];
  simd_float2 endP = (simd_float2){last.x, last.y};
  simd_float2 prev = dense[w - 1];
  cum[w] = cum[w - 1] + simd_distance(prev, endP);
  dense[w++] = endP;

  float totalLen = cum[w - 1];

  for (NSUInteger i = 0; i < nSamples; i++) {
    float target;
    if (closed) {
      target = totalLen * ((float)i / (float)nSamples);
    } else {
      target = (nSamples == 1) ? 0.0f
                               : totalLen * ((float)i / (float)(nSamples - 1));
    }
    if (totalLen <= 1e-6f) {
      out[i] = dense[0];
      continue;
    }
    NSUInteger lo = 0, hi = w - 1;
    while (lo + 1 < hi) {
      NSUInteger mid = (lo + hi) / 2;
      if (cum[mid] <= target)
        lo = mid;
      else
        hi = mid;
    }
    float span = cum[hi] - cum[lo];
    float f = (span > 1e-6f) ? (target - cum[lo]) / span : 0.0f;
    out[i] = dense[lo] + (dense[hi] - dense[lo]) * f;
  }

  free(dense);
  free(cum);
  return YES;
}

NSUInteger KKMorphInterpolateSampleCount(NSData *fromBlob, NSData *toBlob) {
  uint32_t a = 0, b = 0;
  KKMorphSnapshotPeek(fromBlob, &a, NULL);
  KKMorphSnapshotPeek(toBlob, &b, NULL);
  NSUInteger n = MAX((NSUInteger)a, (NSUInteger)b) * 4;
  if (n < kMinSampleCount)
    n = kMinSampleCount;
  return n;
}

NSUInteger KKMorphInterpolate(NSData *fromBlob, NSData *toBlob, float t,
                              simd_float2 *outPositions, BOOL *outClosed) {
  const KKBezierPoint *aPts = NULL, *bPts = NULL;
  uint32_t aCount = 0, bCount = 0;
  BOOL aClosed = NO, bClosed = NO;
  if (!readHeader(fromBlob, &aPts, &aCount, &aClosed))
    return 0;
  if (!readHeader(toBlob, &bPts, &bCount, &bClosed))
    return 0;
  if (aCount < 2 || bCount < 2)
    return 0;

  NSUInteger n = KKMorphInterpolateSampleCount(fromBlob, toBlob);
  simd_float2 *aSamp = malloc(sizeof(simd_float2) * n);
  simd_float2 *bSamp = malloc(sizeof(simd_float2) * n);
  if (!aSamp || !bSamp) {
    free(aSamp);
    free(bSamp);
    return 0;
  }
  if (!densePolyline(aPts, aCount, aClosed, n, aSamp) ||
      !densePolyline(bPts, bCount, bClosed, n, bSamp)) {
    free(aSamp);
    free(bSamp);
    return 0;
  }

  float clampT = MAX(0.0f, MIN(1.0f, t));
  for (NSUInteger i = 0; i < n; i++) {
    outPositions[i] = aSamp[i] + (bSamp[i] - aSamp[i]) * clampT;
  }
  if (outClosed)
    *outClosed = (clampT < 0.5f) ? aClosed : bClosed;

  free(aSamp);
  free(bSamp);
  return n;
}
