/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKSpatialCurve.h"
#import <math.h>

// Effective spatial handle offset (object space) for keypose `i` on its `isOut`
// side: the manual inHandle/outHandle if set, else the auto-derived Catmull-Rom
// tangent the curve uses (symmetric in/out interior, one-sided at the ends).
// Assumes >=2-component values on the keyposes involved.
static void _kkSpatialHandleOffset(NSArray<KKKeyPose *> *kps, NSUInteger i,
                                   BOOL isOut, double *dx, double *dy) {
  KKKeyPose *kp = kps[i];
  NSUInteger n = kps.count;
  // A side facing a hold-linked interval (two coincident keyposes the user sees
  // as one parked point) contributes no handle: the zero-length hold segment
  // must stay at the anchor instead of bulging into a loop the object travels
  // over the hold, and the twin then draws a single exterior handle like a path
  // endpoint. Overrides any manual handle a symmetric drag stored there.
  if (isOut && i + 1 < n && kp.outgoing.endpointsLinked) {
    *dx = 0;
    *dy = 0;
    return;
  }
  if (!isOut && i > 0 && kps[i - 1].outgoing.endpointsLinked) {
    *dx = 0;
    *dy = 0;
    return;
  }
  NSArray<NSNumber *> *manual = isOut ? kp.outHandle : kp.inHandle;
  if (manual.count >= 2) {
    *dx = manual[0].doubleValue;
    *dy = manual[1].doubleValue;
    return;
  }
  double px = kp.values[0].doubleValue, py = kp.values[1].doubleValue;
  if (i > 0 && i + 1 < n) {
    double ax = kps[i - 1].values[0].doubleValue;
    double ay = kps[i - 1].values[1].doubleValue;
    double cx = kps[i + 1].values[0].doubleValue;
    double cy = kps[i + 1].values[1].doubleValue;
    double tx = (cx - ax) / 6.0, ty = (cy - ay) / 6.0;
    *dx = isOut ? tx : -tx;
    *dy = isOut ? ty : -ty;
  } else if (isOut && i + 1 < n) {
    double cx = kps[i + 1].values[0].doubleValue;
    double cy = kps[i + 1].values[1].doubleValue;
    *dx = (cx - px) / 3.0;
    *dy = (cy - py) / 3.0;
  } else if (!isOut && i > 0) {
    double ax = kps[i - 1].values[0].doubleValue;
    double ay = kps[i - 1].values[1].doubleValue;
    *dx = (ax - px) / 3.0;
    *dy = (ay - py) / 3.0;
  } else {
    *dx = 0;
    *dy = 0;
  }
}

void KKLaneSpatialBezierXY(NSArray<KKKeyPose *> *kps, NSUInteger ia, double t,
                           double *outX, double *outY) {
  KKKeyPose *a = kps[ia];
  KKKeyPose *b = kps[ia + 1];
  double ax = a.values[0].doubleValue, ay = a.values[1].doubleValue;
  double bx = b.values[0].doubleValue, by = b.values[1].doubleValue;
  double aox = 0, aoy = 0, bix = 0, biy = 0;
  if (a.spatialSmooth)
    _kkSpatialHandleOffset(kps, ia, YES, &aox, &aoy);
  if (b.spatialSmooth)
    _kkSpatialHandleOffset(kps, ia + 1, NO, &bix, &biy);
  double c0x = ax + aox, c0y = ay + aoy;
  double c1x = bx + bix, c1y = by + biy;
  double mt = 1.0 - t;
  double w0 = mt * mt * mt, w1 = 3 * mt * mt * t, w2 = 3 * mt * t * t,
         w3 = t * t * t;
  *outX = w0 * ax + w1 * c0x + w2 * c1x + w3 * bx;
  *outY = w0 * ay + w1 * c0y + w2 * c1y + w3 * by;
}

double KKLaneSpatialArcParam(NSArray<KKKeyPose *> *kps, NSUInteger ia,
                             double s) {
  if (s <= 0.0)
    return 0.0;
  if (s >= 1.0)
    return 1.0;
  enum { kArcSamples = 24 };
  double dN = (double)kArcSamples;
  double px = 0, py = 0, cum[kArcSamples + 1];
  KKLaneSpatialBezierXY(kps, ia, 0.0, &px, &py);
  cum[0] = 0.0;
  for (NSUInteger i = 1; i <= kArcSamples; i++) {
    double x = 0, y = 0;
    KKLaneSpatialBezierXY(kps, ia, (double)i / dN, &x, &y);
    cum[i] = cum[i - 1] + hypot(x - px, y - py);
    px = x;
    py = y;
  }
  double total = cum[kArcSamples];
  if (total < 1e-12)
    return s; // degenerate (zero-length) curve: nothing to remap
  double target = s * total;
  for (NSUInteger i = 1; i <= kArcSamples; i++) {
    if (cum[i] >= target) {
      double seg = cum[i] - cum[i - 1];
      double f = (seg > 1e-12) ? (target - cum[i - 1]) / seg : 0.0;
      return ((double)(i - 1) + f) / dN;
    }
  }
  return 1.0;
}

void KKLaneSpatialHandlesForKeypose(KKLane *lane, NSUInteger index,
                                    CGPoint *inHandle, CGPoint *outHandle) {
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  if (index >= kps.count || kps[index].values.count < 2) {
    if (inHandle)
      *inHandle = CGPointZero;
    if (outHandle)
      *outHandle = CGPointZero;
    return;
  }
  // Endpoints have only one meaningful side: the first keypose has no incoming
  // segment (no in handle), the last has no outgoing segment (no out handle).
  // Report the meaningless side as zero even if a manual handle was stored
  // there by a symmetric drag, so it isn't drawn or grabbed. The evaluator
  // never reads these sides, so this is purely about what the OSC shows.
  BOOL isFirst = (index == 0);
  BOOL isLast = (index + 1 == kps.count);
  double dx = 0, dy = 0;
  if (outHandle) {
    if (isLast) {
      *outHandle = CGPointZero;
    } else {
      _kkSpatialHandleOffset(kps, index, YES, &dx, &dy);
      *outHandle = CGPointMake(dx, dy);
    }
  }
  if (inHandle) {
    if (isFirst) {
      *inHandle = CGPointZero;
    } else {
      _kkSpatialHandleOffset(kps, index, NO, &dx, &dy);
      *inHandle = CGPointMake(dx, dy);
    }
  }
}

NSArray<NSValue *> *KKLaneCoalescedAnchors(KKLane *lane, NSInteger skipIndex) {
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  const double eps = 1.0e-4;
  NSArray<NSNumber *> *skipVal =
      (skipIndex >= 0 && skipIndex < (NSInteger)kps.count &&
       kps[skipIndex].values.count >= 2)
          ? kps[skipIndex].values
          : nil;
  NSMutableArray<NSValue *> *out = [NSMutableArray array];
  for (NSInteger i = 0; i < (NSInteger)kps.count; i++) {
    if (i == skipIndex || kps[i].values.count < 2)
      continue;
    double vx = kps[i].values[0].doubleValue, vy = kps[i].values[1].doubleValue;
    if (skipVal && fabs(vx - skipVal[0].doubleValue) < eps &&
        fabs(vy - skipVal[1].doubleValue) < eps)
      continue; // coincident with the active keypose - hidden under the handle
    BOOL dup = NO;
    for (NSValue *pv in out) {
      NSPoint dp = pv.pointValue;
      if (fabs(vx - dp.x) < eps && fabs(vy - dp.y) < eps) {
        dup = YES;
        break;
      }
    }
    if (!dup)
      [out addObject:[NSValue valueWithPoint:NSMakePoint(vx, vy)]];
  }
  return out;
}

NSArray<NSValue *> *KKLanePositionPathPoints(KKLane *lane,
                                             NSUInteger samplesPerSegment) {
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  NSMutableArray<NSValue *> *out = [NSMutableArray array];
  if (kps.count == 0 || kps.firstObject.values.count < 2)
    return out;
  if (kps.count == 1) {
    [out addObject:[NSValue valueWithPoint:NSMakePoint(
                                               kps[0].values[0].doubleValue,
                                               kps[0].values[1].doubleValue)]];
    return out;
  }
  NSUInteger perSeg = MAX((NSUInteger)1, samplesPerSegment);
  for (NSUInteger i = 0; i + 1 < kps.count; i++) {
    KKKeyPose *a = kps[i], *b = kps[i + 1];
    if (a.values.count < 2 || b.values.count < 2)
      continue;
    if (!(a.spatialSmooth || b.spatialSmooth)) {
      // Straight segment: just the start anchor (the final endpoint is added
      // once after the loop, and each next segment contributes its own start).
      [out addObject:[NSValue
                         valueWithPoint:NSMakePoint(a.values[0].doubleValue,
                                                    a.values[1].doubleValue)]];
      continue;
    }
    // Curved segment: tessellate the geometric bezier at uniform parameter
    // (no easing), so overshooting easing curves don't loop the path.
    for (NSUInteger j = 0; j < perSeg; j++) {
      double tt = (double)j / (double)perSeg;
      double x = 0, y = 0;
      KKLaneSpatialBezierXY(kps, i, tt, &x, &y);
      [out addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
    }
  }
  KKKeyPose *last = kps.lastObject;
  [out addObject:[NSValue
                     valueWithPoint:NSMakePoint(last.values[0].doubleValue,
                                                last.values[1].doubleValue)]];
  return out;
}
