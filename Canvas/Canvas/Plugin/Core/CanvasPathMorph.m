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
  // The morph snapshot stores + reapplies `closed`, but that is a PATH-LEVEL
  // property (the snapshots were captured before the path was closed/opened),
  // so the base path's flag is authoritative - restore it after every apply,
  // else closing/opening an animated path wouldn't show until each keypose is
  // re-saved.
  if (frac <= kps.firstObject.time) {
    KKBezierPath *out = [path copy];
    KKMorphSnapshotApply(CanvasSnapshotForKeypose(kps.firstObject, path), out);
    out.closed = path.closed;
    return out;
  }
  if (frac >= kps.lastObject.time) {
    KKBezierPath *out = [path copy];
    KKMorphSnapshotApply(CanvasSnapshotForKeypose(kps.lastObject, path), out);
    out.closed = path.closed;
    return out;
  }
  for (NSUInteger i = 0; i + 1 < kps.count; i++) {
    KKKeyPose *a = kps[i], *b = kps[i + 1];
    if (frac < a.time || frac > b.time)
      continue;
    double span = b.time - a.time;
    double t = span > 1e-9 ? (frac - a.time) / span : 0.0;
    double e = a.outgoing
                   ? KKApplyEasing(t, (KKEasingCurve)a.outgoing.curve,
                                   a.outgoing.intensity, a.outgoing.frequency)
                   : t;
    KKBezierPath *out = [path copy];
    KKMorphInterpolateApply(CanvasSnapshotForKeypose(a, path),
                            CanvasSnapshotForKeypose(b, path), (float)e, out);
    out.closed = path.closed;
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

KKBezierPath *CanvasPathByWritingWorkingGeometry(KKBezierPath *base,
                                                 double frac,
                                                 KKBezierPath *editedWorking) {
  if (!base || !editedWorking)
    return base;
  NSInteger kp =
      CanvasPathActiveKeyposeAtFraction(base, frac, kCanvasPathKeyposeEps);
  return (kp >= 0) ? CanvasPathBySettingKeyposeGeometry(base, kp, editedWorking)
                   : editedWorking;
}

// One geometry's points reversed, with each anchor's in/out tangents swapped.
static KKBezierPath *CanvasGeometryReversed(KKBezierPath *src) {
  NSUInteger n = src.count;
  if (n < 2)
    return [src copy];
  KKBezierPath *out = [src copy];
  KKBezierPoint *pts = malloc(n * sizeof(KKBezierPoint));
  for (NSUInteger i = 0; i < n; i++) {
    KKBezierPoint p = [src pointAtIndex:(n - 1 - i)];
    KKBezierPoint r = p;
    r.inX = p.outX;
    r.inY = p.outY;
    r.outX = p.inX;
    r.outY = p.inY;
    pts[i] = r;
  }
  [out setBezierPoints:pts count:n closed:src.closed];
  free(pts);
  return out;
}

KKBezierPath *CanvasPathByRemovingKeypose(KKBezierPath *path,
                                          NSUInteger keyposeIndex) {
  if (path.animationJSON.length == 0)
    return path;
  KKTimeline *tl = [KKTimeline timelineFromJSON:path.animationJSON];
  NSMutableArray<KKLane *> *lanes = [tl.lanes mutableCopy];
  NSInteger pli = -1;
  for (NSUInteger i = 0; i < lanes.count; i++)
    if ([lanes[i].label isEqualToString:@"Points"]) {
      pli = (NSInteger)i;
      break;
    }
  if (pli < 0 || keyposeIndex >= lanes[pli].keyposes.count)
    return path;
  NSMutableArray<KKKeyPose *> *kps = [lanes[pli].keyposes mutableCopy];
  [kps removeObjectAtIndex:keyposeIndex];

  if (kps.count >= 2) { // still animated
    KKLane *nl = [lanes[pli] copy];
    nl.keyposes = kps;
    lanes[pli] = nl;
    tl.lanes = lanes;
    KKBezierPath *out = [path copy];
    out.animationJSON = [KKTimeline jsonFromTimeline:tl];
    return out;
  }
  if (kps.count == 0)
    return nil; // nothing left -> delete the layer

  // One keypose remains -> collapse to a constant path on the survivor's shape.
  KKBezierPath *out = [path copy];
  NSData *snap = kps[0].geometrySnapshot;
  if (snap)
    KKMorphSnapshotApply(snap, out);
  if (out.count < 2)
    return nil; // survivor not a viable path -> delete the layer
  out.closed =
      path.closed; // morph apply resets closed; base flag is authoritative
  KKLane *nl = [lanes[pli] copy];
  nl.enabled = NO; // constant again
  nl.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:@[]] ];
  lanes[pli] = nl;
  tl.lanes = lanes;
  out.animationJSON = [KKTimeline jsonFromTimeline:tl];
  return out;
}

KKBezierPath *CanvasPathByReversingGeometry(KKBezierPath *path) {
  if (path.count < 2)
    return path;
  KKBezierPath *out = CanvasGeometryReversed(path); // reverse the base points
  if (path.animationJSON.length == 0)
    return out; // constant: base reversal is the whole job
  // Reverse every Points keypose snapshot the SAME way so the morph still pairs
  // index i across keyposes (a keypose without its own snapshot follows the
  // base).
  KKTimeline *tl = [KKTimeline timelineFromJSON:path.animationJSON];
  NSMutableArray<KKLane *> *lanes = [tl.lanes mutableCopy];
  for (NSUInteger li = 0; li < lanes.count; li++) {
    if (![lanes[li].label isEqualToString:@"Points"])
      continue;
    NSMutableArray<KKKeyPose *> *kps = [lanes[li].keyposes mutableCopy];
    for (NSUInteger ki = 0; ki < kps.count; ki++) {
      if (!kps[ki].geometrySnapshot)
        continue; // no snapshot = follows the (already reversed) base
      KKBezierPath *tmp = [path copy];
      KKMorphSnapshotApply(kps[ki].geometrySnapshot, tmp);
      KKKeyPose *kp = [kps[ki] copy];
      kp.geometrySnapshot = KKMorphSnapshotCapture(CanvasGeometryReversed(tmp));
      kps[ki] = kp;
    }
    KKLane *nl = [lanes[li] copy];
    nl.keyposes = kps;
    lanes[li] = nl;
    break;
  }
  tl.lanes = lanes;
  out.animationJSON = [KKTimeline jsonFromTimeline:tl];
  return out;
}
