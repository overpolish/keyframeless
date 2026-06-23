/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasPathMorph.h"
#import "CanvasLayerRender.h" // CanvasUnprojectLayerPointObj
#import "CanvasLayerTimeline.h" // CanvasLayerTimelineForPath / CanvasApplyTimelineToPath
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
  // setBezierPoints clears the corner radii - re-apply them in reversed order
  // so each radius stays with its anchor (else a pen prepend / reverse drops
  // them).
  if (src.hasCornerRadii)
    for (NSUInteger i = 0; i < n; i++)
      [out setCornerRadius:[src cornerRadiusAtIndex:(n - 1 - i)] atIndex:i];
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

// One geometry translated by `d` (local Y-up units): move every anchor; the
// in/out handles are relative offsets so they ride along untouched.
static KKBezierPath *CanvasGeometryTranslated(KKBezierPath *src,
                                              simd_float2 d) {
  KKBezierPath *out = [src copy];
  for (NSUInteger i = 0; i < src.count; i++) {
    KKBezierPoint p = [src pointAtIndex:i];
    [out moveAtIndex:i to:simd_make_float2(p.x + d.x, p.y + d.y)];
  }
  return out;
}

// A COPY of `path` (an image / group) with its Position lane shifted by the
// object-space delta on the ACTIVE keypose only (a constant Position -> its
// single value). Returns `path` unchanged when Position is animated and the
// playhead is BETWEEN keyposes - the same "constants OR on a keypose" gate the
// transform OSC follows. Position is Y-DOWN normalized, so the Y-up object
// delta is flipped; the lane is seeded from `templates` when absent.
static KKBezierPath *
CanvasPathByTranslatingPosition(KKBezierPath *path, simd_float2 objDelta,
                                double frac, NSArray<KKLane *> *templates) {
  simd_float2 d = simd_make_float2(objDelta.x, -objDelta.y);
  KKTimeline *tl = CanvasLayerTimelineForPath(path, templates);
  for (KKLane *l in tl.lanes) {
    if (![l.label isEqualToString:@"Position"])
      continue;
    NSArray<KKKeyPose *> *kps = l.keyposes;
    NSInteger idx = 0;
    if (l.enabled && kps.count >= 2) { // animated: only the parked keypose
      idx = -1;
      for (NSUInteger i = 0; i < kps.count; i++)
        if (fabs(kps[i].time - frac) <= kCanvasPathKeyposeEps) {
          idx = (NSInteger)i;
          break;
        }
      if (idx < 0)
        return path; // between keyposes: gated out, no move
    } else if (kps.count == 0) {
      return path;
    }
    NSMutableArray<KKKeyPose *> *mk = [kps mutableCopy];
    KKKeyPose *src = mk[idx];
    double x = (src.values.count > 0 ? src.values[0].doubleValue : 0.5) + d.x;
    double y = (src.values.count > 1 ? src.values[1].doubleValue : 0.5) + d.y;
    KKKeyPose *kp = [src copy]; // preserve time / spatial / interval state
    kp.values = @[ @(x), @(y) ];
    mk[idx] = kp;
    l.keyposes = mk;
    break;
  }
  KKBezierPath *out = [path copy];
  CanvasApplyTimelineToPath(tl, out);
  return out;
}

void CanvasTranslateSelection(NSMutableArray<KKBezierPath *> *paths,
                              NSArray<NSString *> *selectedLayerIDs,
                              simd_float2 objDelta, double frac, float aspect,
                              NSArray<KKLane *> *templates) {
  if (!selectedLayerIDs.count)
    return;
  NSSet<NSString *> *sel = [NSSet setWithArray:selectedLayerIDs];
  for (NSUInteger i = 0; i < paths.count; i++) {
    KKBezierPath *p = paths[i];
    if (!p.layerID.length || ![sel containsObject:p.layerID])
      continue;
    if (p.isImage || p.isGroup) {
      paths[i] = CanvasPathByTranslatingPosition(p, objDelta, frac, templates);
    } else {
      // Gated like the point OSC: a path moves only when constant or parked on
      // a Points keypose - never between keyposes (geometry isn't editable
      // there).
      if (!CanvasPathGeometryEditableAtFraction(p, frac))
        continue;
      // Object delta -> the path's LOCAL space (identity transform ->
      // unchanged).
      simd_float2 l0 =
          CanvasUnprojectLayerPointObj(paths, p, frac, aspect, 0.0f, 0.0f);
      simd_float2 l1 = CanvasUnprojectLayerPointObj(paths, p, frac, aspect,
                                                    objDelta.x, objDelta.y);
      simd_float2 ld = l1 - l0;
      // Translate the shape SHOWN at `frac` and write it back to the ACTIVE
      // keypose only (constant path -> the base). Editing the current point,
      // not every keypose - same persistence as dragging a single anchor.
      KKBezierPath *working = CanvasPathMorphedAtFraction(p, frac);
      KKBezierPath *moved = CanvasGeometryTranslated(working, ld);
      paths[i] = CanvasPathByWritingWorkingGeometry(p, frac, moved);
    }
  }
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
