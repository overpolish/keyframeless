/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasStrokeTessellate.h"
#import <KeyframelessKit/KKBezierPath.h>
#import <simd/simd.h>

static const NSUInteger kStepsPerSegment = 32;
static const float kAAPaddingPx = 0.75f; // solid core reaches the asked width
static const float kMiterLimit = 4.0f;   // clamp spikes at very sharp corners

static NSUInteger CanvasStrokeSegmentCount(KKBezierPath *path) {
  if (path.count < 2)
    return 0;
  return path.closed ? path.count : path.count - 1;
}

NSUInteger CanvasStrokeVertexCapacity(KKBezierPath *path) {
  NSUInteger segs = CanvasStrokeSegmentCount(path);
  if (segs == 0)
    return 0;
  // One polyline sample per step per segment, plus the open-path terminal
  // point, plus the closing wrap. Two strip verts each, with headroom.
  NSUInteger polyPts = segs * kStepsPerSegment + 2;
  return polyPts * 2 + 8;
}

// Sample the path into a centered-pixel polyline matching the image-quad space:
// p_centered = (normalized - 0.5) * outputSize. Near-duplicate samples are
// dropped so adjacent edges yield stable normals.
static NSUInteger CanvasBuildPolyline(KKBezierPath *path, float outW,
                                      float outH, simd_float2 *pts,
                                      NSUInteger maxPts) {
  NSUInteger segs = CanvasStrokeSegmentCount(path);
  simd_float2 scale = simd_make_float2(outW, outH);
  simd_float2 half = simd_make_float2(0.5f, 0.5f);
  NSUInteger n = 0;
  for (NSUInteger c = 0; c < segs; c++) {
    NSUInteger next = (c + 1) % path.count;
    for (NSUInteger i = 0; i < kStepsPerSegment; i++) {
      float t = (float)i / (float)kStepsPerSegment;
      simd_float2 norm = [path evaluatePointAtIndex:c nextIndex:next atT:t];
      simd_float2 p = (norm - half) * scale;
      if (n > 0 && simd_distance_squared(p, pts[n - 1]) < 1e-6f)
        continue;
      if (n < maxPts)
        pts[n++] = p;
    }
  }
  if (!path.closed) {
    // Open paths need the final anchor (the segment loop stops before t=1).
    NSUInteger lastSeg = segs - 1;
    simd_float2 norm = [path evaluatePointAtIndex:lastSeg
                                        nextIndex:lastSeg + 1
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

NSUInteger CanvasTessellateStroke(KKBezierPath *path, float strokeWidth,
                                  float outputWidth, float outputHeight,
                                  KKVertex2D *outVerts, NSUInteger maxVerts) {
  NSUInteger segs = CanvasStrokeSegmentCount(path);
  if (segs == 0 || !outVerts || maxVerts < 4)
    return 0;

  NSUInteger polyCap = segs * kStepsPerSegment + 2;
  simd_float2 *pts = malloc(sizeof(simd_float2) * polyCap);
  NSUInteger n =
      CanvasBuildPolyline(path, outputWidth, outputHeight, pts, polyCap);
  if (n < 2) {
    free(pts);
    return 0;
  }

  float hw = strokeWidth * 0.5f + kAAPaddingPx;
  NSUInteger vc = 0;
  NSUInteger stop = path.closed ? n + 1 : n; // +1 wraps the closed loop
  for (NSUInteger k = 0; k < stop && vc + 2 <= maxVerts; k++) {
    NSUInteger i = k % n;
    simd_float2 off = CanvasMiterOffset(pts, n, i, path.closed, hw);
    outVerts[vc].position = pts[i] + off;
    outVerts[vc].textureCoordinate = simd_make_float2(0.0f, 1.0f);
    vc++;
    outVerts[vc].position = pts[i] - off;
    outVerts[vc].textureCoordinate = simd_make_float2(0.0f, -1.0f);
    vc++;
  }

  free(pts);
  return vc;
}
