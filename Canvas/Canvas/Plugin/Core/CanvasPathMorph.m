/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasPathMorph.h"
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKEasing.h>
#import <KeyframelessKit/KKPathMorph.h>
#import <KeyframelessKit/KeyframelessKit.h>

// The enabled "Points" lane's keyposes (>=2 = animated), else nil.
static NSArray<KKKeyPose *> *CanvasPointsKeyposes(KKBezierPath *path) {
  if (path.animationJSON.length == 0)
    return nil;
  KKTimeline *tl = [KKTimeline timelineFromJSON:path.animationJSON];
  for (KKLane *l in tl.lanes)
    if ([l.label isEqualToString:@"Points"])
      return (l.enabled && l.keyposes.count >= 2) ? l.keyposes : nil;
  return nil;
}

// Snapshot for a keypose: its own geometry, or the base path's as a fallback
// (a keypose not yet edited holds no snapshot and reads the base shape).
static NSData *CanvasSnapshotForKeypose(KKKeyPose *kp, KKBezierPath *base) {
  return kp.geometrySnapshot ?: KKMorphSnapshotCapture(base);
}

KKBezierPath *CanvasPathMorphedAtFraction(KKBezierPath *path, double frac) {
  NSArray<KKKeyPose *> *kps = CanvasPointsKeyposes(path);
  if (!kps)
    return path; // constant: edit / render the base geometry directly
  if (frac <= kps.firstObject.time) {
    KKBezierPath *out = [path copy];
    KKMorphSnapshotApply(CanvasSnapshotForKeypose(kps.firstObject, path), out);
    return out;
  }
  if (frac >= kps.lastObject.time) {
    KKBezierPath *out = [path copy];
    KKMorphSnapshotApply(CanvasSnapshotForKeypose(kps.lastObject, path), out);
    return out;
  }
  for (NSUInteger i = 0; i + 1 < kps.count; i++) {
    KKKeyPose *a = kps[i], *b = kps[i + 1];
    if (frac < a.time || frac > b.time)
      continue;
    double span = b.time - a.time;
    double t = span > 1e-9 ? (frac - a.time) / span : 0.0;
    double e = a.outgoing ? KKApplyEasing(t, (KKEasingCurve)a.outgoing.curve,
                                          a.outgoing.intensity,
                                          a.outgoing.frequency)
                          : t;
    KKBezierPath *out = [path copy];
    KKMorphInterpolateApply(CanvasSnapshotForKeypose(a, path),
                            CanvasSnapshotForKeypose(b, path), (float)e, out);
    return out;
  }
  return path;
}

// Parked-at-a-keypose tolerance (clip fraction), shared by the editable gate +
// the controller's edit routing.
const double kCanvasPathKeyposeEps = 0.01;

BOOL CanvasPathGeometryEditableAtFraction(KKBezierPath *path, double frac) {
  if (CanvasPathMorphedAtFraction(path, frac) == path)
    return YES; // constant path: always editable
  return CanvasPathActiveKeyposeAtFraction(path, frac, kCanvasPathKeyposeEps) >=
         0;
}

NSInteger CanvasPathActiveKeyposeAtFraction(KKBezierPath *path, double frac,
                                            double eps) {
  NSArray<KKKeyPose *> *kps = CanvasPointsKeyposes(path);
  if (!kps)
    return -1;
  for (NSUInteger i = 0; i < kps.count; i++)
    if (fabs(kps[i].time - frac) <= eps)
      return (NSInteger)i;
  return -1;
}

KKBezierPath *CanvasPathBySettingKeyposeGeometry(KKBezierPath *path,
                                                 NSInteger keyposeIndex,
                                                 KKBezierPath *geometry) {
  if (path.animationJSON.length == 0 || !geometry)
    return path;
  KKTimeline *tl = [KKTimeline timelineFromJSON:path.animationJSON];
  NSMutableArray<KKLane *> *lanes = [tl.lanes mutableCopy];
  // Any keypose without its own snapshot is currently displaying the base
  // geometry. Freeze those at the base BEFORE we repoint base at the edited
  // shape, else they'd follow base and the edit would "copy" across every
  // keypose instead of staying on the one being edited.
  NSData *baseSnapshot = KKMorphSnapshotCapture(path);
  BOOL changed = NO;
  for (NSUInteger li = 0; li < lanes.count; li++) {
    KKLane *l = lanes[li];
    if (![l.label isEqualToString:@"Points"])
      continue;
    if (keyposeIndex < 0 || keyposeIndex >= (NSInteger)l.keyposes.count)
      break;
    NSMutableArray<KKKeyPose *> *kps = [l.keyposes mutableCopy];
    for (NSUInteger ki = 0; ki < kps.count; ki++) {
      BOOL isTarget = ((NSInteger)ki == keyposeIndex);
      if (!isTarget && kps[ki].geometrySnapshot)
        continue; // already has its own shape - don't disturb it
      KKKeyPose *kp = [kps[ki] copy];
      kp.geometrySnapshot =
          isTarget ? KKMorphSnapshotCapture(geometry) : baseSnapshot;
      kps[ki] = kp;
    }
    KKLane *nl = [l copy];
    nl.keyposes = kps;
    lanes[li] = nl;
    changed = YES;
    break;
  }
  if (!changed)
    return path;
  tl.lanes = lanes;
  KKBezierPath *out = [path copy];
  out.animationJSON = [KKTimeline jsonFromTimeline:tl];
  // Base points follow the latest edit: keeps the constant fallback + the OSC's
  // base view in step, and seeds snapshot-less keyposes from this shape.
  KKMorphSnapshotApply(KKMorphSnapshotCapture(geometry), out);
  return out;
}
