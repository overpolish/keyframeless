/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPositionElementModel.h"

#import <KeyframelessKit/KKSnapEngine.h>
#import <KeyframelessKit/KKSpatialCurve.h>
#import <KeyframelessKit/KKTimeline.h>

double KKPositionHitTolPt(double dotRadiusPt) { return dotRadiusPt + 6.0; }

NSInteger KKPositionAnchorHitIndex(KKLane *lane, CGPoint pt, double hitTolPt,
                                   NSInteger skipIndex,
                                   NS_NOESCAPE KKPositionProjection project) {
  if (!lane || lane.keyposes.count < 2)
    return -1;
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  double bestD = hitTolPt;
  NSInteger best = -1;
  for (NSInteger i = 0; i < (NSInteger)kps.count; i++) {
    if (i == skipIndex || kps[i].values.count < 2)
      continue;
    CGPoint c = project(kps[i].values[0].doubleValue,
                        kps[i].values[1].doubleValue, kps[i].time);
    double d = hypot(pt.x - c.x, pt.y - c.y);
    if (d <= bestD) {
      bestD = d;
      best = i;
    }
  }
  return best;
}

NSInteger KKPositionTangentHitIndex(KKLane *lane, CGPoint pt, double hitTolPt,
                                    BOOL *outIsOut,
                                    NS_NOESCAPE KKPositionProjection project) {
  if (!lane || lane.keyposes.count < 2)
    return -1;
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  double bestD = hitTolPt;
  NSInteger best = -1;
  BOOL bestOut = NO;
  for (NSInteger i = 0; i < (NSInteger)kps.count; i++) {
    KKKeyPose *kp = kps[i];
    if (!kp.spatialSmooth || kp.values.count < 2)
      continue;
    double ax = kp.values[0].doubleValue, ay = kp.values[1].doubleValue;
    CGPoint inH = CGPointZero, outH = CGPointZero;
    KKLaneSpatialHandlesForKeypose(lane, (NSUInteger)i, &inH, &outH);
    CGPoint sides[2] = {outH, inH};
    BOOL sideOut[2] = {YES, NO};
    for (int s = 0; s < 2; s++) {
      if (hypot(sides[s].x, sides[s].y) < 1e-6)
        continue;
      CGPoint c = project(ax + sides[s].x, ay + sides[s].y, kp.time);
      double d = hypot(pt.x - c.x, pt.y - c.y);
      if (d <= bestD) {
        bestD = d;
        best = i;
        bestOut = sideOut[s];
      }
    }
  }
  if (best >= 0 && outIsOut)
    *outIsOut = bestOut;
  return best;
}

void KKPositionShapeAnchorDrag(double grabX, double grabY, double dx,
                               double dy, BOOL shiftAxisLock, double *outX,
                               double *outY) {
  double nx = grabX + dx, ny = grabY + dy;
  if (shiftAxisLock) {
    if (fabs(dx) >= fabs(dy))
      ny = grabY;
    else
      nx = grabX;
  }
  if (outX)
    *outX = nx;
  if (outY)
    *outY = ny;
}

void KKPositionApplyTangentDrag(KKKeyPose *kp, BOOL isOut, double offX,
                                double offY, BOOL shiftAxisLock,
                                BOOL cmdAngleSnap, BOOL ctrlCusp) {
  if (shiftAxisLock) {
    if (fabs(offX) >= fabs(offY))
      offY = 0.0;
    else
      offX = 0.0;
  }
  if (cmdAngleSnap) {
    double len = hypot(offX, offY);
    if (len > 1e-9) {
      double step = M_PI / 4.0;
      double ang = round(atan2(offY, offX) / step) * step;
      offX = cos(ang) * len;
      offY = sin(ang) * len;
    }
  }
  NSArray<NSNumber *> *off = @[ @(offX), @(offY) ];
  NSArray<NSNumber *> *mirror = @[ @(-offX), @(-offY) ];
  kp.spatialSmooth = YES;
  if (isOut) {
    kp.outHandle = off;
    if (!ctrlCusp)
      kp.inHandle = mirror;
  } else {
    kp.inHandle = off;
    if (!ctrlCusp)
      kp.outHandle = mirror;
  }
}

simd_float2 KKPositionSnapPoint(KKSnapEngine *engine, simd_float2 p,
                                KKLane *lane, NSInteger excludeIndex,
                                NSArray<NSValue *> *externalTargets,
                                float thresholdX, float thresholdY) {
  static const float anchors[] = {0.0f, 0.25f, 0.5f, 0.75f, 1.0f};
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  // Skip the edited keypose AND its hold-linked twins: a coincident keypose
  // joined by a linked interval moves WITH the drag, so it's the same point -
  // leaving it in would snap the anchor to itself (a phantom accent guide).
  NSMutableIndexSet *skip = [NSMutableIndexSet indexSet];
  if (excludeIndex >= 0 && excludeIndex < (NSInteger)kps.count) {
    [skip addIndex:(NSUInteger)excludeIndex];
    for (NSInteger i = excludeIndex;
         i + 1 < (NSInteger)kps.count && kps[i].outgoing.endpointsLinked; i++)
      [skip addIndex:(NSUInteger)(i + 1)];
    for (NSInteger i = excludeIndex; i > 0 && kps[i - 1].outgoing.endpointsLinked;
         i--)
      [skip addIndex:(NSUInteger)(i - 1)];
  }
  NSUInteger cap = kps.count + externalTargets.count;
  simd_float2 *objs = cap ? malloc(cap * sizeof(simd_float2)) : NULL;
  NSUInteger nObj = 0;
  for (NSInteger k = 0; k < (NSInteger)kps.count; k++) {
    if ([skip containsIndex:(NSUInteger)k])
      continue;
    NSArray<NSNumber *> *v = kps[k].values;
    if (v.count < 2)
      continue;
    objs[nObj++] =
        (simd_float2){(float)v[0].doubleValue, (float)v[1].doubleValue};
  }
  // Host-supplied targets (other handles / point OSCs) share this space.
  for (NSValue *t in externalTargets) {
    CGPoint ep = t.pointValue;
    objs[nObj++] = (simd_float2){(float)ep.x, (float)ep.y};
  }
  simd_float2 snapped = [engine snapPoint:p
                           canvasAnchorsX:anchors
                                   countX:5
                           canvasAnchorsY:anchors
                                   countY:5
                            objectTargets:objs
                                    count:nObj
                               thresholdX:thresholdX
                               thresholdY:thresholdY];
  if (objs)
    free(objs);
  return snapped;
}
