/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Stroke -> filled-outline tessellation: taper, dash, dot, and end-marker
// outline builders feeding the public KKPathStrokeToOutline.

#import "KKPathBoolean.h"

#import "KKCGPathBridge.h"
#import <CoreGraphics/CoreGraphics.h>

/// Douglas-Peucker polyline simplification.  Marks which indices to keep
/// in the `keep` array.  Tolerance is in the same units as the points.
static void douglasPeucker(const simd_float2 *pts, NSUInteger start,
                           NSUInteger end, float epsilon, BOOL *keep) {
  if (end <= start + 1)
    return;

  float maxDist = 0;
  NSUInteger maxIdx = start;

  simd_float2 a = pts[start];
  simd_float2 b = pts[end];
  simd_float2 ab = b - a;
  float abLen = simd_length(ab);

  for (NSUInteger i = start + 1; i < end; i++) {
    float dist;
    if (abLen < 1e-6f) {
      dist = simd_length(pts[i] - a);
    } else {
      simd_float2 ap = pts[i] - a;
      float cross = fabsf(ap.x * ab.y - ap.y * ab.x);
      dist = cross / abLen;
    }
    if (dist > maxDist) {
      maxDist = dist;
      maxIdx = i;
    }
  }

  if (maxDist > epsilon) {
    keep[maxIdx] = YES;
    douglasPeucker(pts, start, maxIdx, epsilon, keep);
    douglasPeucker(pts, maxIdx, end, epsilon, keep);
  }
}

/// Simplify a polyline using Douglas-Peucker, returning a new array of
/// kept points.  Caller must free the result.
static NSUInteger simplifyPolyline(const simd_float2 *pts, NSUInteger count,
                                   float epsilon, simd_float2 **outPts) {
  if (count < 3) {
    *outPts = malloc(count * sizeof(simd_float2));
    memcpy(*outPts, pts, count * sizeof(simd_float2));
    return count;
  }

  BOOL *keep = calloc(count, sizeof(BOOL));
  keep[0] = YES;
  keep[count - 1] = YES;
  douglasPeucker(pts, 0, count - 1, epsilon, keep);

  NSUInteger kept = 0;
  for (NSUInteger i = 0; i < count; i++) {
    if (keep[i])
      kept++;
  }

  simd_float2 *result = malloc(kept * sizeof(simd_float2));
  NSUInteger idx = 0;
  for (NSUInteger i = 0; i < count; i++) {
    if (keep[i])
      result[idx++] = pts[i];
  }

  free(keep);
  *outPts = result;
  return kept;
}

/// Build an outline CGPath for a tapered stroke by sampling normals and
/// offsetting by the interpolated half-width.  Returns a closed path in
/// pixel space (caller must transform back to object space).
static CGPathRef createTaperedOutline(KKBezierPath *src, CGFloat sw, CGFloat ew,
                                      CGFloat refW, CGFloat refH,
                                      uint8_t lineCap) {
  NSUInteger segs = 64;
  if (src.count < 2)
    return CGPathCreateMutable();
  NSUInteger curveCount = src.count - 1;
  BOOL isClosed = src.closed;
  if (isClosed && src.count >= 2)
    curveCount = src.count;
  if (curveCount == 0)
    return CGPathCreateMutable();
  NSUInteger totalSamples = curveCount * segs + 1;
  float totalSteps = (float)(curveCount * segs);

  // Sample centre positions and half-widths along the path.
  simd_float2 *centres = malloc(totalSamples * sizeof(simd_float2));
  float *halfWidths = malloc(totalSamples * sizeof(float));
  NSUInteger sampleCount = 0;

  for (NSUInteger c = 0; c < curveCount; c++) {
    NSUInteger limit = (c == curveCount - 1) ? segs : segs - 1;
    for (NSUInteger i = 0; i <= limit; i++) {
      float t = (float)i / (float)segs;
      NSUInteger nextIdx = (c + 1) % src.count;
      simd_float2 pos = [src evaluatePointAtIndex:c nextIndex:nextIdx atT:t];
      simd_float2 pxPos = {pos.x * (float)refW, pos.y * (float)refH};

      float globalT =
          totalSteps > 0 ? (float)(c * segs + i) / totalSteps : 0.0f;
      float hw = (float)(sw + (ew - sw) * globalT) / 2.0f;

      centres[sampleCount] = pxPos;
      halfWidths[sampleCount] = hw;
      sampleCount++;
    }
  }

  // Compute normals from position finite differences to avoid tangent
  // discontinuities at segment boundaries.
  simd_float2 *normals = malloc(sampleCount * sizeof(simd_float2));
  for (NSUInteger i = 0; i < sampleCount; i++) {
    simd_float2 delta;
    if (i == 0)
      delta = centres[1] - centres[0];
    else if (i == sampleCount - 1)
      delta = centres[sampleCount - 1] - centres[sampleCount - 2];
    else
      delta = centres[i + 1] - centres[i - 1];
    float len = simd_length(delta);
    if (len < 1e-6f)
      delta = (simd_float2){1, 0};
    else
      delta /= len;
    normals[i] = (simd_float2){-delta.y, delta.x};
  }

  // Build offset polylines for both sides, then simplify.
  simd_float2 *plusSide = malloc(sampleCount * sizeof(simd_float2));
  simd_float2 *minusSide = malloc(sampleCount * sizeof(simd_float2));
  for (NSUInteger i = 0; i < sampleCount; i++) {
    plusSide[i] = centres[i] + normals[i] * halfWidths[i];
    minusSide[i] = centres[i] - normals[i] * halfWidths[i];
  }

  simd_float2 *simpPlus = NULL, *simpMinus = NULL;
  float epsilon = 1.5f;
  NSUInteger plusCount =
      simplifyPolyline(plusSide, sampleCount, epsilon, &simpPlus);
  NSUInteger minusCount =
      simplifyPolyline(minusSide, sampleCount, epsilon, &simpMinus);
  free(plusSide);
  free(minusSide);

  // Build CGPath: forward along +normal side, semicircular end cap,
  // backward along -normal side, semicircular start cap.
  CGMutablePathRef outline = CGPathCreateMutable();

  if (plusCount > 0 && minusCount > 0) {
    // Square cap extends the start outward by startHW along the tangent.
    simd_float2 startN = normals[0];
    simd_float2 startT = {startN.y, -startN.x}; // tangent (forward)
    float startHW = halfWidths[0];
    simd_float2 endN = normals[sampleCount - 1];
    simd_float2 endT = {endN.y, -endN.x};
    float endHW = halfWidths[sampleCount - 1];

    if (lineCap == 2) {
      // Square: extend start backward.
      simd_float2 sp = simpPlus[0] - startT * startHW;
      CGPathMoveToPoint(outline, NULL, sp.x, sp.y);
      simd_float2 sm = simpMinus[0] - startT * startHW;
      CGPathAddLineToPoint(outline, NULL, sm.x, sm.y);
      // Go forward to first minus, but we'll trace minus backward later,
      // so start with first plus instead. Restart approach:
    }

    // --- Start cap ---
    if (lineCap == 2) {
      // Square start: two corners extended backward.
      simd_float2 extPlus = simpPlus[0] - startT * startHW;
      CGPathMoveToPoint(outline, NULL, extPlus.x, extPlus.y);
      CGPathAddLineToPoint(outline, NULL, simpPlus[0].x, simpPlus[0].y);
    } else if (lineCap == 1) {
      // Round start: semicircle from minus[0] to plus[0].
      // We'll add this after tracing minus side backward. Start at plus[0].
      CGPathMoveToPoint(outline, NULL, simpPlus[0].x, simpPlus[0].y);
    } else {
      // Butt: start at plus[0].
      CGPathMoveToPoint(outline, NULL, simpPlus[0].x, simpPlus[0].y);
    }

    // --- Plus side (forward) ---
    for (NSUInteger i = 1; i < plusCount; i++)
      CGPathAddLineToPoint(outline, NULL, simpPlus[i].x, simpPlus[i].y);

    // --- End cap ---
    simd_float2 lastPlus = centres[sampleCount - 1] + endN * endHW;
    simd_float2 lastMinus = centres[sampleCount - 1] - endN * endHW;

    if (lineCap == 2) {
      // Square end: extend forward.
      simd_float2 extPlus = lastPlus + endT * endHW;
      simd_float2 extMinus = lastMinus + endT * endHW;
      CGPathAddLineToPoint(outline, NULL, extPlus.x, extPlus.y);
      CGPathAddLineToPoint(outline, NULL, extMinus.x, extMinus.y);
      CGPathAddLineToPoint(outline, NULL, lastMinus.x, lastMinus.y);
    } else if (lineCap == 1) {
      // Round end: semicircle from plus to minus via bezier arc.
      // Sweep CW from plus-side angle through tangent direction.
      float plusAngle = atan2f(endN.y, endN.x);
      CGPathAddArc(outline, NULL, centres[sampleCount - 1].x,
                   centres[sampleCount - 1].y, endHW, plusAngle,
                   plusAngle - (float)M_PI, true);
    } else {
      // Butt end: straight across.
      CGPathAddLineToPoint(outline, NULL, lastMinus.x, lastMinus.y);
    }

    // --- Minus side (backward) ---
    for (NSInteger i = (NSInteger)minusCount - 2; i >= 0; i--)
      CGPathAddLineToPoint(outline, NULL, simpMinus[i].x, simpMinus[i].y);

    // --- Start cap closing ---
    if (lineCap == 2) {
      // Square start: close via extended corners.
      simd_float2 extMinus = simpMinus[0] - startT * startHW;
      simd_float2 extPlus = simpPlus[0] - startT * startHW;
      CGPathAddLineToPoint(outline, NULL, extMinus.x, extMinus.y);
      CGPathAddLineToPoint(outline, NULL, extPlus.x, extPlus.y);
    } else if (lineCap == 1) {
      // Round start: semicircle from minus back to plus via bezier arc.
      // Sweep CW from minus-side angle through -tangent direction.
      float minusAngle = atan2f(-startN.y, -startN.x);
      CGPathAddArc(outline, NULL, centres[0].x, centres[0].y, startHW,
                   minusAngle, minusAngle - (float)M_PI, true);
    }

    CGPathCloseSubpath(outline);
  }

  free(simpPlus);
  free(simpMinus);

  free(centres);
  free(normals);
  free(halfWidths);
  return outline;
}

/// Sample the path into a pixel-space polyline with arc-length data.
/// Caller must free the returned arrays.
static NSUInteger samplePathForOutline(KKBezierPath *src, CGFloat refW,
                                       CGFloat refH, simd_float2 **outPositions,
                                       float **outArcLengths) {
  NSUInteger segsPerCurve = 128;
  NSUInteger curveCount = src.count - 1;
  if (src.closed && src.count >= 2)
    curveCount = src.count;

  NSUInteger totalSamples = curveCount * (segsPerCurve + 1);
  simd_float2 *positions = malloc(totalSamples * sizeof(simd_float2));
  float *arcLengths = calloc(totalSamples, sizeof(float));
  NSUInteger idx = 0;

  for (NSUInteger c = 0; c < curveCount; c++) {
    for (NSUInteger i = 0; i <= segsPerCurve; i++) {
      float t = (float)i / (float)segsPerCurve;
      NSUInteger nextIdx = (c + 1) % src.count;
      simd_float2 pos = [src evaluatePointAtIndex:c nextIndex:nextIdx atT:t];
      simd_float2 px = {(float)(pos.x * refW), (float)(pos.y * refH)};
      positions[idx] = px;
      if (idx > 0)
        arcLengths[idx] =
            arcLengths[idx - 1] + simd_length(px - positions[idx - 1]);
      idx++;
    }
  }

  *outPositions = positions;
  *outArcLengths = arcLengths;
  return idx;
}

/// Interpolate position in the sampled polyline at a given arc-length distance.
static simd_float2 positionAtArc(const simd_float2 *positions,
                                 const float *arcLengths, NSUInteger count,
                                 float arc, NSUInteger *hint) {
  NSUInteger lo = *hint;
  while (lo < count - 1 && arcLengths[lo + 1] < arc)
    lo++;
  *hint = lo;
  if (lo >= count - 1)
    return positions[count - 1];
  float segLen = arcLengths[lo + 1] - arcLengths[lo];
  float localT = (segLen > 1e-6f) ? (arc - arcLengths[lo]) / segLen : 0.0f;
  return simd_mix(positions[lo], positions[lo + 1],
                  (simd_float2){localT, localT});
}

/// Build a tapered outline for a single dash segment given its polyline points
/// and per-point half-widths. Returns a closed CGPath in pixel space.
static CGPathRef createTaperedDashOutline(const simd_float2 *pts,
                                          const float *halfWidths,
                                          NSUInteger count, uint8_t lineCap) {
  if (count < 2)
    return NULL;

  // Compute normals from finite differences.
  simd_float2 *normals = malloc(count * sizeof(simd_float2));
  for (NSUInteger i = 0; i < count; i++) {
    simd_float2 delta;
    if (i == 0)
      delta = pts[1] - pts[0];
    else if (i == count - 1)
      delta = pts[count - 1] - pts[count - 2];
    else
      delta = pts[i + 1] - pts[i - 1];
    float len = simd_length(delta);
    if (len < 1e-6f)
      delta = (simd_float2){1, 0};
    else
      delta /= len;
    normals[i] = (simd_float2){-delta.y, delta.x};
  }

  // Build offset polylines and simplify with Douglas-Peucker.
  simd_float2 *plusSide = malloc(count * sizeof(simd_float2));
  simd_float2 *minusSide = malloc(count * sizeof(simd_float2));
  for (NSUInteger i = 0; i < count; i++) {
    plusSide[i] = pts[i] + normals[i] * halfWidths[i];
    minusSide[i] = pts[i] - normals[i] * halfWidths[i];
  }

  float epsilon = 1.5f;
  simd_float2 *simpPlus = NULL, *simpMinus = NULL;
  NSUInteger plusCount = simplifyPolyline(plusSide, count, epsilon, &simpPlus);
  NSUInteger minusCount =
      simplifyPolyline(minusSide, count, epsilon, &simpMinus);
  free(plusSide);
  free(minusSide);

  // Build outline path.
  CGMutablePathRef outline = CGPathCreateMutable();

  simd_float2 startN = normals[0];
  simd_float2 startT = {startN.y, -startN.x};
  float startHW = halfWidths[0];
  simd_float2 endN = normals[count - 1];
  simd_float2 endT = {endN.y, -endN.x};
  float endHW = halfWidths[count - 1];

  if (plusCount > 0 && minusCount > 0) {
    // Start cap.
    if (lineCap == 2) {
      simd_float2 extPlus = simpPlus[0] - startT * startHW;
      CGPathMoveToPoint(outline, NULL, extPlus.x, extPlus.y);
      CGPathAddLineToPoint(outline, NULL, simpPlus[0].x, simpPlus[0].y);
    } else {
      CGPathMoveToPoint(outline, NULL, simpPlus[0].x, simpPlus[0].y);
    }

    // Plus side forward.
    for (NSUInteger i = 1; i < plusCount; i++)
      CGPathAddLineToPoint(outline, NULL, simpPlus[i].x, simpPlus[i].y);

    // End cap.
    if (lineCap == 2) {
      simd_float2 extPlus = simpPlus[plusCount - 1] + endT * endHW;
      simd_float2 extMinus = simpMinus[minusCount - 1] + endT * endHW;
      CGPathAddLineToPoint(outline, NULL, extPlus.x, extPlus.y);
      CGPathAddLineToPoint(outline, NULL, extMinus.x, extMinus.y);
      CGPathAddLineToPoint(outline, NULL, simpMinus[minusCount - 1].x,
                           simpMinus[minusCount - 1].y);
    } else if (lineCap == 1) {
      // Semicircle from plus to minus, sweep CW through tangent.
      float plusAngle = atan2f(endN.y, endN.x);
      CGPathAddArc(outline, NULL, pts[count - 1].x, pts[count - 1].y, endHW,
                   plusAngle, plusAngle - (float)M_PI, true);
    } else {
      CGPathAddLineToPoint(outline, NULL, simpMinus[minusCount - 1].x,
                           simpMinus[minusCount - 1].y);
    }

    // Minus side backward.
    for (NSInteger i = (NSInteger)minusCount - 2; i >= 0; i--)
      CGPathAddLineToPoint(outline, NULL, simpMinus[i].x, simpMinus[i].y);

    // Start cap closing.
    if (lineCap == 2) {
      simd_float2 extMinus = simpMinus[0] - startT * startHW;
      simd_float2 extPlus = simpPlus[0] - startT * startHW;
      CGPathAddLineToPoint(outline, NULL, extMinus.x, extMinus.y);
      CGPathAddLineToPoint(outline, NULL, extPlus.x, extPlus.y);
    } else if (lineCap == 1) {
      // Semicircle from minus back to plus, sweep CW through -tangent.
      float minusAngle = atan2f(-startN.y, -startN.x);
      CGPathAddArc(outline, NULL, pts[0].x, pts[0].y, startHW, minusAngle,
                   minusAngle - (float)M_PI, true);
    }

    CGPathCloseSubpath(outline);
  }

  free(simpPlus);
  free(simpMinus);
  free(normals);
  return outline;
}

/// Create a dashed stroke outline. For uniform width uses CG's native dashing;
/// for tapered width manually splits into dash segments with arc-length
/// interpolated widths.
static CGPathRef createDashedOutline(KKBezierPath *src, CGFloat sw, CGFloat ew,
                                     CGFloat refW, CGFloat refH,
                                     uint8_t lineCap, uint8_t lineJoin) {
  BOOL tapers = !src.closed && fabsf((float)sw - (float)ew) > 0.001f;

  if (!tapers) {
    // Uniform width: let CoreGraphics handle dashing natively.
    // CG produces bezier arcs for round caps - minimal point count.
    CGMutablePathRef cgPath = CGPathCreateFromKKBezierPath(src);
    CGAffineTransform toPixel = CGAffineTransformMake(refW, 0, 0, refH, 0, 0);
    CGPathRef scaled = CGPathCreateCopyByTransformingPath(cgPath, &toPixel);
    CGPathRelease(cgPath);

    CGFloat lengths[] = {src.dashLength, src.dashGap};
    CGPathRef dashed =
        CGPathCreateCopyByDashingPath(scaled, NULL, 0, lengths, 2);
    CGPathRelease(scaled);
    if (!dashed)
      return NULL;

    CGPathRef stroked = CGPathCreateCopyByStrokingPath(
        dashed, NULL, sw, (CGLineCap)lineCap, (CGLineJoin)lineJoin, 4.0);
    CGPathRelease(dashed);
    if (!stroked)
      return NULL;

    CGMutablePathRef empty = CGPathCreateMutable();
    CGPathRef cleaned = CGPathCreateCopyByUnioningPath(stroked, empty, false);
    CGPathRelease(empty);
    CGPathRelease(stroked);
    return cleaned;
  }

  // Tapered: manually split into dash segments with per-point widths.
  simd_float2 *positions = NULL;
  float *arcLengths = NULL;
  NSUInteger count =
      samplePathForOutline(src, refW, refH, &positions, &arcLengths);
  if (count < 2) {
    free(positions);
    free(arcLengths);
    return NULL;
  }

  float totalArc = arcLengths[count - 1];
  float dashLen = src.dashLength;
  float dashGap = src.dashGap;
  float cycle = dashLen + dashGap;
  if (cycle < 1.0f)
    cycle = 1.0f;

  CGMutablePathRef combined = CGPathCreateMutable();
  NSUInteger hint = 0;
  float arc = 0.0f;

  while (arc < totalArc) {
    float dashStart = arc;
    float dashEnd = fminf(arc + dashLen, totalArc);

    NSUInteger maxPts = (NSUInteger)((dashEnd - dashStart) * 2.0f) + 4;
    simd_float2 *dashPts = malloc(maxPts * sizeof(simd_float2));
    float *dashHWs = malloc(maxPts * sizeof(float));
    NSUInteger dashPtCount = 0;

    // First point.
    dashPts[dashPtCount] =
        positionAtArc(positions, arcLengths, count, dashStart, &hint);
    float arcT = (totalArc > 0) ? dashStart / totalArc : 0.0f;
    float w = (float)sw + ((float)ew - (float)sw) * arcT;
    dashHWs[dashPtCount] = w / 2.0f;
    dashPtCount++;

    // Walk through polyline samples within this dash.
    for (NSUInteger i = hint + 1; i < count && arcLengths[i] < dashEnd; i++) {
      dashPts[dashPtCount] = positions[i];
      float t = (totalArc > 0) ? arcLengths[i] / totalArc : 0.0f;
      dashHWs[dashPtCount] = ((float)sw + ((float)ew - (float)sw) * t) / 2.0f;
      dashPtCount++;
      if (dashPtCount >= maxPts - 1) {
        maxPts *= 2;
        dashPts = realloc(dashPts, maxPts * sizeof(simd_float2));
        dashHWs = realloc(dashHWs, maxPts * sizeof(float));
      }
    }

    // Last point.
    dashPts[dashPtCount] =
        positionAtArc(positions, arcLengths, count, dashEnd, &hint);
    arcT = (totalArc > 0) ? dashEnd / totalArc : 0.0f;
    w = (float)sw + ((float)ew - (float)sw) * arcT;
    dashHWs[dashPtCount] = w / 2.0f;
    dashPtCount++;

    if (dashPtCount >= 2) {
      CGPathRef seg =
          createTaperedDashOutline(dashPts, dashHWs, dashPtCount, lineCap);
      if (seg) {
        CGPathAddPath(combined, NULL, seg);
        CGPathRelease(seg);
      }
    }

    free(dashPts);
    free(dashHWs);
    arc += cycle;
  }

  free(positions);
  free(arcLengths);

  CGMutablePathRef empty = CGPathCreateMutable();
  CGPathRef cleaned = CGPathCreateCopyByUnioningPath(combined, empty, false);
  CGPathRelease(empty);
  CGPathRelease(combined);
  return cleaned;
}

/// Create a dotted stroke outline by placing circles at regular intervals.
/// Supports tapering (start/end width).
static CGPathRef createDottedOutline(KKBezierPath *src, CGFloat sw, CGFloat ew,
                                     CGFloat refW, CGFloat refH) {
  simd_float2 *positions = NULL;
  float *arcLengths = NULL;
  NSUInteger count =
      samplePathForOutline(src, refW, refH, &positions, &arcLengths);
  if (count < 2) {
    free(positions);
    free(arcLengths);
    return NULL;
  }

  float totalArc = arcLengths[count - 1];
  BOOL tapers = !src.closed && fabsf((float)sw - (float)ew) > 0.001f;
  float spacing = (float)sw + src.dotGap;
  if (spacing < 1.0f)
    spacing = 1.0f;

  CGMutablePathRef combined = CGPathCreateMutable();
  NSUInteger hint = 0;
  float arc = 0.0f;

  while (arc <= totalArc) {
    simd_float2 center =
        positionAtArc(positions, arcLengths, count, arc, &hint);

    float arcT = (totalArc > 0) ? arc / totalArc : 0.0f;
    float localW =
        tapers ? ((float)sw + ((float)ew - (float)sw) * arcT) : (float)sw;
    float radius = localW / 2.0f;

    CGRect circleRect = CGRectMake(center.x - radius, center.y - radius,
                                   radius * 2.0f, radius * 2.0f);
    CGPathAddEllipseInRect(combined, NULL, circleRect);
    arc += spacing;
  }

  free(positions);
  free(arcLengths);

  // Union to merge touching dots.
  CGMutablePathRef empty = CGPathCreateMutable();
  CGPathRef cleaned = CGPathCreateCopyByUnioningPath(combined, empty, false);
  CGPathRelease(empty);
  CGPathRelease(combined);
  return cleaned;
}

/// Create a CGPath outline for a marker shape in pixel space.
/// markerType: 1=arrow, 2=circle, 3=square, 4=arrowhead, 5=line.
/// endpoint: pixel-space position. tangent: unit vector pointing outward.
/// normal: unit perpendicular to tangent.
static CGPathRef createMarkerOutline(uint8_t markerType, simd_float2 endpoint,
                                     simd_float2 tangent, simd_float2 normal,
                                     float markerSize, float strokeWidth) {
  if (markerType == 0)
    return NULL;

  CGMutablePathRef path = CGPathCreateMutable();

  switch (markerType) {
  case 1: { // Arrow - filled triangle.
    float wingSpread = markerSize * 0.5f;
    simd_float2 base = endpoint - tangent * markerSize;
    simd_float2 left = base + normal * wingSpread;
    simd_float2 right = base - normal * wingSpread;
    CGPathMoveToPoint(path, NULL, left.x, left.y);
    CGPathAddLineToPoint(path, NULL, endpoint.x, endpoint.y);
    CGPathAddLineToPoint(path, NULL, right.x, right.y);
    CGPathCloseSubpath(path);
    break;
  }
  case 2: { // Circle.
    float radius = markerSize * 0.5f;
    CGRect rect = CGRectMake(endpoint.x - radius, endpoint.y - radius,
                             radius * 2.0f, radius * 2.0f);
    CGPathAddEllipseInRect(path, NULL, rect);
    break;
  }
  case 3: { // Square.
    float halfSide = markerSize * 0.5f;
    simd_float2 fwd = tangent * halfSide;
    simd_float2 side = normal * halfSide;
    simd_float2 a = endpoint - fwd + side;
    simd_float2 b = endpoint + fwd + side;
    simd_float2 c = endpoint + fwd - side;
    simd_float2 d = endpoint - fwd - side;
    CGPathMoveToPoint(path, NULL, a.x, a.y);
    CGPathAddLineToPoint(path, NULL, b.x, b.y);
    CGPathAddLineToPoint(path, NULL, c.x, c.y);
    CGPathAddLineToPoint(path, NULL, d.x, d.y);
    CGPathCloseSubpath(path);
    break;
  }
  case 4: { // Arrowhead - open chevron (two thick arms).
    float wingSpread = markerSize * 0.5f;
    float halfThick = strokeWidth * 0.5f;
    simd_float2 base = endpoint - tangent * markerSize;
    simd_float2 left = base + normal * wingSpread;
    simd_float2 right = base - normal * wingSpread;

    simd_float2 leftEdge = endpoint - left;
    float leftLen = simd_length(leftEdge);
    simd_float2 leftDir = leftLen > 0.001f ? leftEdge / leftLen : tangent;
    simd_float2 leftPerp = (simd_float2){-leftDir.y, leftDir.x};

    simd_float2 rightEdge = endpoint - right;
    float rightLen = simd_length(rightEdge);
    simd_float2 rightDir = rightLen > 0.001f ? rightEdge / rightLen : tangent;
    simd_float2 rightPerp = (simd_float2){-rightDir.y, rightDir.x};

    // Left arm quad.
    simd_float2 la = left + leftPerp * halfThick;
    simd_float2 lb = left - leftPerp * halfThick;
    simd_float2 lc = endpoint + leftPerp * halfThick;
    simd_float2 ld = endpoint - leftPerp * halfThick;
    CGPathMoveToPoint(path, NULL, la.x, la.y);
    CGPathAddLineToPoint(path, NULL, lc.x, lc.y);
    CGPathAddLineToPoint(path, NULL, ld.x, ld.y);
    CGPathAddLineToPoint(path, NULL, lb.x, lb.y);
    CGPathCloseSubpath(path);

    // Right arm quad.
    simd_float2 ra = endpoint + rightPerp * halfThick;
    simd_float2 rb = endpoint - rightPerp * halfThick;
    simd_float2 rc = right + rightPerp * halfThick;
    simd_float2 rd = right - rightPerp * halfThick;
    CGPathMoveToPoint(path, NULL, ra.x, ra.y);
    CGPathAddLineToPoint(path, NULL, rc.x, rc.y);
    CGPathAddLineToPoint(path, NULL, rd.x, rd.y);
    CGPathAddLineToPoint(path, NULL, rb.x, rb.y);
    CGPathCloseSubpath(path);
    break;
  }
  case 5: { // Line - perpendicular bar.
    float halfSpread = markerSize * 0.5f;
    float halfThick = strokeWidth * 0.5f;
    simd_float2 top = endpoint + normal * halfSpread;
    simd_float2 bottom = endpoint - normal * halfSpread;
    CGPathMoveToPoint(path, NULL, top.x + tangent.x * halfThick,
                      top.y + tangent.y * halfThick);
    CGPathAddLineToPoint(path, NULL, top.x - tangent.x * halfThick,
                         top.y - tangent.y * halfThick);
    CGPathAddLineToPoint(path, NULL, bottom.x - tangent.x * halfThick,
                         bottom.y - tangent.y * halfThick);
    CGPathAddLineToPoint(path, NULL, bottom.x + tangent.x * halfThick,
                         bottom.y + tangent.y * halfThick);
    CGPathCloseSubpath(path);
    break;
  }
  default:
    CGPathRelease(path);
    return NULL;
  }

  return path;
}

/// Stroke pullback distance for a marker type - matches KKMarkerPullback
/// in MarkerTessellation. Duplicated here because KeyframelessKit cannot
/// import Canvas plugin headers.
static float outlineMarkerPullback(uint8_t markerType, float markerSize) {
  switch (markerType) {
  case 1:
    return markerSize * 0.7f; // arrow
  default:
    return 0.0f; // circle, square, arrowhead, line
  }
}

/// Compute marker tangent/normal by sampling the polyline at a pullback arc
/// position - matches the rendering pipeline. The tangent points outward from
/// the path at the endpoint.
static void endpointFromPolyline(const simd_float2 *positions,
                                 const float *arcLengths, NSUInteger count,
                                 BOOL atEnd, float markerSize,
                                 simd_float2 *outPosition,
                                 simd_float2 *outTangent,
                                 simd_float2 *outNormal) {
  float totalArc = arcLengths[count - 1];
  // Match rendering: sample tangent at max(pullback, markerSize * 0.3) from
  // the endpoint, clamped to path length.
  float minPull = markerSize * 0.3f;
  if (minPull < 1.0f)
    minPull = 1.0f;

  NSUInteger hint = 0;
  simd_float2 pullbackPos;
  if (atEnd) {
    float pullArc = totalArc - minPull;
    if (pullArc < 0.0f)
      pullArc = 0.0f;
    pullbackPos = positionAtArc(positions, arcLengths, count, pullArc, &hint);
  } else {
    float pullArc = minPull;
    if (pullArc > totalArc)
      pullArc = totalArc;
    pullbackPos = positionAtArc(positions, arcLengths, count, pullArc, &hint);
  }

  simd_float2 pos = atEnd ? positions[count - 1] : positions[0];
  simd_float2 dir;
  if (atEnd) {
    dir = pos - pullbackPos; // outward = forward along path at end
  } else {
    dir = pos - pullbackPos; // outward = backward from path at start
  }
  float len = simd_length(dir);
  if (len < 1e-6f)
    dir = (simd_float2){1, 0};
  else
    dir /= len;

  *outPosition = pos;
  *outTangent = dir;
  *outNormal = (simd_float2){-dir.y, dir.x};
}

NSArray<KKBezierPath *> *KKPathStrokeToOutline(NSArray<KKBezierPath *> *paths,
                                               CGFloat referenceWidth,
                                               CGFloat referenceHeight) {
  if (paths.count == 0 || referenceWidth <= 0 || referenceHeight <= 0)
    return nil;

  NSMutableArray<KKBezierPath *> *results = [NSMutableArray array];

  for (KKBezierPath *src in paths) {
    if (src.count < 2 || !src.strokeEnabled) {
      continue;
    }

    float sw = src.strokeWidth;
    float ew = (src.endWidth > 0) ? src.endWidth : sw;
    BOOL tapers = !src.closed && fabsf(sw - ew) > 0.001f;

    CGPathRef cleaned = NULL;

    if (src.strokeStyle == 1) {
      // Dashed stroke.
      cleaned = createDashedOutline(src, sw, ew, referenceWidth,
                                    referenceHeight, src.lineCap, src.lineJoin);
    } else if (src.strokeStyle == 2) {
      // Dotted stroke.
      cleaned =
          createDottedOutline(src, sw, ew, referenceWidth, referenceHeight);
    } else if (tapers) {
      // Variable-width stroke: build outline manually.
      CGPathRef tapered = createTaperedOutline(src, sw, ew, referenceWidth,
                                               referenceHeight, src.lineCap);
      CGMutablePathRef empty = CGPathCreateMutable();
      cleaned = CGPathCreateCopyByUnioningPath(tapered, empty, false);
      CGPathRelease(empty);
      CGPathRelease(tapered);
    } else {
      // Uniform stroke: use CG stroking.
      CGMutablePathRef cgPath = CGPathCreateFromKKBezierPath(src);
      CGAffineTransform toPixel =
          CGAffineTransformMake(referenceWidth, 0, 0, referenceHeight, 0, 0);
      CGPathRef scaled = CGPathCreateCopyByTransformingPath(cgPath, &toPixel);
      CGPathRelease(cgPath);

      CGPathRef stroked = CGPathCreateCopyByStrokingPath(
          scaled, NULL, sw, (CGLineCap)src.lineCap, (CGLineJoin)src.lineJoin,
          4.0);
      CGPathRelease(scaled);

      if (!stroked)
        continue;

      CGMutablePathRef empty = CGPathCreateMutable();
      cleaned = CGPathCreateCopyByUnioningPath(stroked, empty, false);
      CGPathRelease(empty);
      CGPathRelease(stroked);
    }

    if (!cleaned)
      continue;

    // Union markers with the stroke outline (open paths only).
    if (!src.closed && (src.startMarker > 0 || src.endMarker > 0)) {
      // Sample polyline in the same pixel space as the stroke outline.
      simd_float2 *markerPositions = NULL;
      float *markerArcLengths = NULL;
      NSUInteger markerSampleCount =
          samplePathForOutline(src, referenceWidth, referenceHeight,
                               &markerPositions, &markerArcLengths);

      if (markerSampleCount >= 2) {
        float totalArc = markerArcLengths[markerSampleCount - 1];
        float startMarkerSz = sw * src.startMarkerSize;
        float endSw = tapers ? ew : sw;
        float endMarkerSz = endSw * src.endMarkerSize;
        float startPB = outlineMarkerPullback(src.startMarker, startMarkerSz);
        float endPB = outlineMarkerPullback(src.endMarker, endMarkerSz);

        // Re-generate the stroke outline from the trimmed polyline so
        // the stroke doesn't extend past the marker base.
        if (startPB > 0.0f || endPB > 0.0f) {
          float trimStart = startPB;
          float trimEnd = totalArc - endPB;
          if (trimStart >= trimEnd)
            trimStart = trimEnd = totalArc * 0.5f;

          // Collect trimmed polyline points with per-point half-widths.
          NSUInteger hint = 0;
          NSUInteger maxPts = markerSampleCount + 2;
          simd_float2 *trimPts = malloc(maxPts * sizeof(simd_float2));
          float *trimHWs = malloc(maxPts * sizeof(float));
          NSUInteger trimCount = 0;

          trimPts[trimCount] =
              positionAtArc(markerPositions, markerArcLengths,
                            markerSampleCount, trimStart, &hint);
          float arcT = (totalArc > 0) ? trimStart / totalArc : 0.0f;
          trimHWs[trimCount] = (sw + (ew - sw) * arcT) / 2.0f;
          trimCount++;

          for (NSUInteger i = hint + 1; i < markerSampleCount; i++) {
            if (markerArcLengths[i] > trimEnd)
              break;
            trimPts[trimCount] = markerPositions[i];
            float t = (totalArc > 0) ? markerArcLengths[i] / totalArc : 0.0f;
            trimHWs[trimCount] = (sw + (ew - sw) * t) / 2.0f;
            trimCount++;
          }

          hint = 0;
          trimPts[trimCount] = positionAtArc(markerPositions, markerArcLengths,
                                             markerSampleCount, trimEnd, &hint);
          arcT = (totalArc > 0) ? trimEnd / totalArc : 0.0f;
          trimHWs[trimCount] = (sw + (ew - sw) * arcT) / 2.0f;
          trimCount++;

          if (trimCount >= 2) {
            CGPathRef trimOutline = NULL;

            if (tapers) {
              // Variable width: build tapered outline with per-point widths.
              trimOutline = createTaperedDashOutline(trimPts, trimHWs,
                                                     trimCount, src.lineCap);
            } else {
              // Uniform width: simplify and stroke.
              simd_float2 *simpPts = NULL;
              NSUInteger simpCount =
                  simplifyPolyline(trimPts, trimCount, 1.5f, &simpPts);
              CGMutablePathRef trimPath = CGPathCreateMutable();
              CGPathMoveToPoint(trimPath, NULL, simpPts[0].x, simpPts[0].y);
              for (NSUInteger i = 1; i < simpCount; i++)
                CGPathAddLineToPoint(trimPath, NULL, simpPts[i].x,
                                     simpPts[i].y);
              free(simpPts);

              trimOutline = CGPathCreateCopyByStrokingPath(
                  trimPath, NULL, sw, (CGLineCap)src.lineCap,
                  (CGLineJoin)src.lineJoin, 4.0);
              CGPathRelease(trimPath);
            }

            if (trimOutline) {
              CGMutablePathRef empty = CGPathCreateMutable();
              CGPathRef trimCleaned =
                  CGPathCreateCopyByUnioningPath(trimOutline, empty, false);
              CGPathRelease(empty);
              CGPathRelease(trimOutline);
              CGPathRelease(cleaned);
              cleaned = trimCleaned;
            }
          }

          free(trimPts);
          free(trimHWs);
        }

        // Create and union marker outlines.
        if (src.startMarker > 0) {
          simd_float2 pos, tang, norm;
          endpointFromPolyline(markerPositions, markerArcLengths,
                               markerSampleCount, NO, startMarkerSz, &pos,
                               &tang, &norm);
          CGPathRef marker = createMarkerOutline(src.startMarker, pos, tang,
                                                 norm, startMarkerSz, sw);
          if (marker) {
            CGPathRef merged =
                CGPathCreateCopyByUnioningPath(cleaned, marker, false);
            CGPathRelease(marker);
            CGPathRelease(cleaned);
            cleaned = merged;
          }
        }

        if (src.endMarker > 0) {
          simd_float2 pos, tang, norm;
          endpointFromPolyline(markerPositions, markerArcLengths,
                               markerSampleCount, YES, endMarkerSz, &pos, &tang,
                               &norm);
          CGPathRef marker = createMarkerOutline(src.endMarker, pos, tang, norm,
                                                 endMarkerSz, endSw);
          if (marker) {
            CGPathRef merged =
                CGPathCreateCopyByUnioningPath(cleaned, marker, false);
            CGPathRelease(marker);
            CGPathRelease(cleaned);
            cleaned = merged;
          }
        }
      }

      free(markerPositions);
      free(markerArcLengths);

      if (!cleaned)
        continue;
    }

    // Scale back to object space.
    CGAffineTransform toObject = CGAffineTransformMake(
        1.0 / referenceWidth, 0, 0, 1.0 / referenceHeight, 0, 0);
    CGPathRef unscaled = CGPathCreateCopyByTransformingPath(cleaned, &toObject);
    CGPathRelease(cleaned);

    KKBezierPath *outline = KKBezierPathFromCGPath(unscaled);
    CGPathRelease(unscaled);

    if (outline.count == 0)
      continue;

    // The outline becomes a filled path using the source stroke color.
    outline.fillEnabled = YES;
    outline.fillR = src.strokeR;
    outline.fillG = src.strokeG;
    outline.fillB = src.strokeB;
    outline.strokeEnabled = NO;
    outline.opacity = src.opacity;
    outline.name = src.name;
    KKPathCopyPlacementProperties(outline,
                                  src); // stay in the source's group + place

    [results addObject:outline];
  }

  return results.count > 0 ? results : nil;
}
