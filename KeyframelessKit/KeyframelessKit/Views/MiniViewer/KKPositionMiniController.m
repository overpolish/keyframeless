/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPositionMiniController.h"

#import <KeyframelessKit/KKSnapEngine.h>
#import <KeyframelessKit/KKSpatialCurve.h>
#import <KeyframelessKit/KKTimingStage.h>
#import <simd/simd.h>

static const CGFloat kHandleHitTolPt = 12.0;

@implementation KKPositionMiniController {
  KKSnapEngine *_snapEngine;
  // Normalised press point captured at begin-drag; the Shift axis-lock anchor
  // so the locked axis stays pinned where it was, not wherever the cursor most
  // recently passed through.
  double _posPressNX;
  double _posPressNY;
  // Position value at grab, for delta dragging (move by the cursor's offset
  // from the press point) instead of snapping the handle to the cursor.
  double _posGrabValX;
  double _posGrabValY;
  // Motion-path drag: which keypose + which part (0=anchor, 1=out, 2=in).
  BOOL _pathGrabbed;
  NSInteger _pathIndex;
  NSInteger _pathPart;
  double _pathPressNX;
  double _pathPressNY;
  double _pathGrabValX; // keypose value at grab (delta-drag anchor)
  double _pathGrabValY;
}

- (instancetype)initWithRenderer:(KKMiniViewerRenderer *)renderer
                       laneLabel:(NSString *)laneLabel
                       pathLabel:(NSString *)pathLabel {
  if ((self = [super init])) {
    _renderer = renderer;
    _laneLabel = [laneLabel copy];
    _pathLabel = [pathLabel copy];
    _snapEngine = [[KKSnapEngine alloc] init];
    _pathIndex = -1;
  }
  return self;
}

- (KKSnapEngine *)snapEngine {
  return _snapEngine;
}

- (BOOL)isDragging {
  return _pathGrabbed; // the Position handle's grab lives in the base renderer
}

- (BOOL)pathGrabbed {
  return _pathGrabbed;
}

- (KKLane *)_lane {
  for (KKLane *lane in self.renderer.timeline.lanes)
    if ([lane.label isEqualToString:self.laneLabel])
      return lane;
  return nil;
}

- (BOOL)_pathActive {
  return [self.renderer labelVisibleOrRevealing:self.pathLabel] &&
         self.renderer.boundaryEditing;
}

#pragma mark Position point handle

- (BOOL)pointHandleCenter:(out CGPoint *)outCenter forContentRect:(CGRect)cr {
  if (outCenter)
    *outCenter = [self.renderer
        handlePointForContentRect:cr
                         position:[self.renderer
                                      valuesForLabel:self.laneLabel]];
  return YES;
}

- (BOOL)pointHandleCenter:(out CGPoint *)outCenter
                forValues:(NSArray<NSNumber *> *)values
           forContentRect:(CGRect)cr {
  // Map the 2D [x, y] to the handle's screen-space centre, the same path the
  // live handle uses - lets a guide place a "drag to here" destination point.
  if (values.count < 2 || cr.size.width <= 0 || cr.size.height <= 0)
    return NO;
  if (outCenter)
    *outCenter = [self.renderer handlePointForContentRect:cr position:values];
  return YES;
}

- (BOOL)pointHandleHitAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  // A hidden Position handle must not eat the hit, or the keypose anchor dot
  // underneath it becomes ungrabbable. labelVisibleOrRevealing keeps the
  // opt-hold reveal (click-to-reshow) working.
  if (![self.renderer labelVisibleOrRevealing:self.laneLabel])
    return NO;
  CGPoint hp = [self.renderer
      handlePointForContentRect:cr
                       position:[self.renderer valuesForLabel:self.laneLabel]];
  return hypot(p.x - hp.x, p.y - hp.y) <= kHandleHitTolPt;
}

- (void)beginPointDragAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  // Capture the press normals + the grabbed value so the drag moves by delta
  // (Shift axis-lock anchors here too).
  if (cr.size.width > 0 && cr.size.height > 0) {
    _posPressNX = (p.x - CGRectGetMinX(cr)) / cr.size.width;
    _posPressNY = (p.y - CGRectGetMinY(cr)) / cr.size.height;
  }
  NSArray<NSNumber *> *pv = [self.renderer valuesForLabel:self.laneLabel];
  _posGrabValX = pv.count > 0 ? pv[0].doubleValue : 0.5;
  _posGrabValY = pv.count > 1 ? pv[1].doubleValue : 0.5;
}

// Snap is OFF by default, Cmd engages it; Shift locks to the dominant-travel
// axis (the other axis pins to the press point). Same modifier convention as
// the viewer's position drag.
- (void)applyPointDragToPoint:(CGPoint)p
                  contentRect:(CGRect)cr
                       canvas:(KKMiniViewerView *)canvas
                    modifiers:(NSEventModifierFlags)modifiers {
  if (cr.size.width <= 0 || cr.size.height <= 0)
    return;
  double nx = (p.x - CGRectGetMinX(cr)) / cr.size.width;
  double ny = (p.y - CGRectGetMinY(cr)) / cr.size.height;
  // Delta drag: move the grabbed value by the cursor's offset from the press
  // point, so grabbing off-centre doesn't snap the handle to the cursor.
  double newX = _posGrabValX + (nx - _posPressNX);
  double newY = _posGrabValY + (ny - _posPressNY);
  if (modifiers & NSEventModifierFlagShift) {
    if (fabs(nx - _posPressNX) >= fabs(ny - _posPressNY))
      newY = _posGrabValY;
    else
      newX = _posGrabValX;
  }
  if (modifiers & NSEventModifierFlagCommand)
    [self _snapPositionX:&newX Y:&newY contentRect:cr];
  else
    [_snapEngine reset];
  [self.renderer commitValues:@[ @(newX), @(newY) ]
                     forLabel:self.laneLabel
                       canvas:canvas];
}

#pragma mark Motion-path overlay

- (NSArray<NSValue *> *)motionPathPolylineForContentRect:(CGRect)cr {
  KKLane *lane = [self _lane];
  if (!lane || lane.keyposes.count < 2 || ![self _pathActive])
    return @[];
  NSArray<NSValue *> *pts = KKLanePositionPathPoints(lane, 24);
  NSMutableArray<NSValue *> *out = [NSMutableArray arrayWithCapacity:pts.count];
  for (NSValue *v in pts) {
    NSPoint o = v.pointValue;
    [out addObject:[NSValue valueWithPoint:[self.renderer
                                               handlePointForContentRect:cr
                                                                position:@[
                                                                  @(o.x), @(o.y)
                                                                ]]]];
  }
  return out;
}

- (NSArray<NSValue *> *)motionPathAnchorsForContentRect:(CGRect)cr {
  KKLane *lane = [self _lane];
  if (!lane || lane.keyposes.count < 2 || ![self _pathActive])
    return @[];
  // Skip the keypose under the position handle (nearest editFraction) and
  // coalesce its linked partners; KKLaneCoalescedAnchors dedups the rest.
  NSInteger active = [self _activeAnchorSkipIndexForLane:lane];
  NSMutableArray<NSValue *> *out = [NSMutableArray array];
  for (NSValue *pv in KKLaneCoalescedAnchors(lane, active)) {
    NSPoint v = pv.pointValue;
    [out addObject:[NSValue valueWithPoint:[self.renderer
                                               handlePointForContentRect:cr
                                                                position:@[
                                                                  @(v.x), @(v.y)
                                                                ]]]];
  }
  return out;
}

- (NSArray<NSValue *> *)motionPathHandleSegmentsForContentRect:(CGRect)cr {
  KKLane *lane = [self _lane];
  if (!lane || lane.keyposes.count < 2 || ![self _pathActive])
    return @[];
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  NSMutableArray<NSValue *> *out = [NSMutableArray array];
  for (NSUInteger i = 0; i < kps.count; i++) {
    KKKeyPose *kp = kps[i];
    if (!kp.spatialSmooth || kp.values.count < 2)
      continue;
    double ax = kp.values[0].doubleValue, ay = kp.values[1].doubleValue;
    CGPoint anchorPt = [self.renderer handlePointForContentRect:cr
                                                       position:kp.values];
    CGPoint inH = CGPointZero, outH = CGPointZero;
    KKLaneSpatialHandlesForKeypose(lane, i, &inH, &outH);
    CGPoint sides[2] = {outH, inH};
    for (int s = 0; s < 2; s++) {
      if (hypot(sides[s].x, sides[s].y) < 1e-6)
        continue;
      CGPoint hp = [self.renderer
          handlePointForContentRect:cr
                           position:@[
                             @(ax + sides[s].x), @(ay + sides[s].y)
                           ]];
      [out addObject:[NSValue valueWithPoint:anchorPt]];
      [out addObject:[NSValue valueWithPoint:hp]];
    }
  }
  return out;
}

// The active keypose's dot is skipped only when the Position handle is actually
// drawn there (full opacity). When the Position OSC is hidden, return -1 so the
// path anchor shows / is grabbable - the active keypose stays editable.
- (NSInteger)_activeAnchorSkipIndexForLane:(KKLane *)lane {
  if ([self.renderer ghostAlphaForLabel:self.laneLabel] < 0.999)
    return -1;
  if (lane.keyposes.count == 0)
    return -1;
  return KKLaneNearestKeyposeIndex(lane, self.renderer.editFraction);
}

// The keypose anchor under `p` (excluding the active one, whose dot is hidden
// under the position handle), or -1.
- (NSInteger)_pathAnchorHitAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  KKLane *lane = [self _lane];
  if (!lane || lane.keyposes.count < 2 || CGRectIsEmpty(cr) ||
      ![self _pathActive])
    return -1;
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  NSInteger active = [self _activeAnchorSkipIndexForLane:lane];
  double bestD = kHandleHitTolPt;
  NSInteger best = -1;
  for (NSInteger i = 0; i < (NSInteger)kps.count; i++) {
    if (i == active || kps[i].values.count < 2)
      continue;
    CGPoint hp = [self.renderer handlePointForContentRect:cr
                                                 position:kps[i].values];
    double d = hypot(p.x - hp.x, p.y - hp.y);
    if (d <= bestD) {
      bestD = d;
      best = i;
    }
  }
  return best;
}

// A smooth keypose's tangent-handle dot under `p`: outputs the keypose index +
// which side (out vs in), or -1.
- (NSInteger)_pathHandleHitAtPoint:(CGPoint)p
                       contentRect:(CGRect)cr
                          outIsOut:(BOOL *)outIsOut {
  KKLane *lane = [self _lane];
  if (!lane || lane.keyposes.count < 2 || CGRectIsEmpty(cr) ||
      ![self _pathActive])
    return -1;
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  double bestD = kHandleHitTolPt;
  NSInteger bestI = -1;
  BOOL bestOut = NO;
  for (NSInteger i = 0; i < (NSInteger)kps.count; i++) {
    KKKeyPose *kp = kps[i];
    if (!kp.spatialSmooth || kp.values.count < 2)
      continue;
    double ax = kp.values[0].doubleValue, ay = kp.values[1].doubleValue;
    CGPoint inH = CGPointZero, outH = CGPointZero;
    KKLaneSpatialHandlesForKeypose(lane, i, &inH, &outH);
    CGPoint sides[2] = {outH, inH};
    BOOL sideOut[2] = {YES, NO};
    for (int s = 0; s < 2; s++) {
      if (hypot(sides[s].x, sides[s].y) < 1e-6)
        continue;
      CGPoint hp = [self.renderer
          handlePointForContentRect:cr
                           position:@[
                             @(ax + sides[s].x), @(ay + sides[s].y)
                           ]];
      double d = hypot(p.x - hp.x, p.y - hp.y);
      if (d <= bestD) {
        bestD = d;
        bestI = i;
        bestOut = sideOut[s];
      }
    }
  }
  if (outIsOut)
    *outIsOut = bestOut;
  return bestI;
}

- (BOOL)pathHandleHitAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  BOOL isOut;
  return [self _pathHandleHitAtPoint:p contentRect:cr outIsOut:&isOut] >= 0;
}

- (BOOL)pathAnchorHitAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  return [self _pathAnchorHitAtPoint:p contentRect:cr] >= 0;
}

- (BOOL)beginPathDragAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  BOOL isOut;
  NSInteger hi = [self _pathHandleHitAtPoint:p contentRect:cr outIsOut:&isOut];
  if (hi >= 0) {
    _pathGrabbed = YES;
    _pathIndex = hi;
    _pathPart = isOut ? 1 : 2;
    [self applyPathDragToPoint:p contentRect:cr modifiers:0];
    return YES;
  }
  NSInteger ai = [self _pathAnchorHitAtPoint:p contentRect:cr];
  if (ai >= 0) {
    _pathGrabbed = YES;
    _pathIndex = ai;
    _pathPart = 0;
    NSArray<NSNumber *> *gv = [self _lane].keyposes[ai].values;
    _pathGrabValX = gv.count > 0 ? gv[0].doubleValue : 0.5;
    _pathGrabValY = gv.count > 1 ? gv[1].doubleValue : 0.5;
    if (cr.size.width > 0 && cr.size.height > 0) {
      _pathPressNX = (p.x - CGRectGetMinX(cr)) / cr.size.width;
      _pathPressNY = (p.y - CGRectGetMinY(cr)) / cr.size.height;
    }
    [self applyPathDragToPoint:p contentRect:cr modifiers:0];
    return YES;
  }
  return NO;
}

// Live-update the dragged keypose's position in the timeline (drives the
// preview); the full blob is persisted once on drag end.
- (void)applyPathDragToPoint:(CGPoint)p
                 contentRect:(CGRect)cr
                   modifiers:(NSEventModifierFlags)modifiers {
  if (cr.size.width <= 0 || cr.size.height <= 0)
    return;
  KKLane *lane = [self _lane];
  if (!lane || _pathIndex < 0 || _pathIndex >= (NSInteger)lane.keyposes.count)
    return;
  double curNX = (p.x - CGRectGetMinX(cr)) / cr.size.width;
  double curNY = (p.y - CGRectGetMinY(cr)) / cr.size.height;
  NSMutableArray<KKLane *> *lanes = [self.renderer.timeline.lanes mutableCopy];
  NSInteger li = [lanes indexOfObject:lane];
  if (li == NSNotFound)
    return;
  KKLane *nl;
  if (_pathPart == 0) {
    // Anchor: delta-based move (no jump) + Shift axis-lock + Cmd-snap.
    double nx = _pathGrabValX + (curNX - _pathPressNX);
    double ny = _pathGrabValY + (curNY - _pathPressNY);
    if (modifiers & NSEventModifierFlagShift) {
      double dx = curNX - _pathPressNX, dy = curNY - _pathPressNY;
      if (fabs(dx) >= fabs(dy))
        ny = _pathGrabValY;
      else
        nx = _pathGrabValX;
    }
    if (modifiers & NSEventModifierFlagCommand)
      [self _snapPositionX:&nx Y:&ny contentRect:cr excludeIndex:_pathIndex];
    else
      [_snapEngine reset];
    // Propagate the value to any hold-linked twin (a coincident keypose joined
    // by a linked interval) - otherwise dragging one anchor of a linked pair
    // leaves the other behind, diverging an intended Hold into an invalid
    // state.
    nl = KKLaneBySettingValuesAtIndex(lane, _pathIndex, @[ @(nx), @(ny) ]);
  } else {
    // Tangent handle: offset from the anchor. Shift axis-locks the handle to
    // H/V; Cmd snaps its angle to 45-degree steps; Ctrl breaks it into a cusp
    // (in/out independent) - otherwise the opposite side mirrors. Per-keypose
    // curve shape is NOT shared by a hold-link, so write it alone.
    nl = [lane copy];
    NSMutableArray<KKKeyPose *> *kps = [nl.keyposes mutableCopy];
    KKKeyPose *nk = [kps[_pathIndex] copy];
    double ax = nk.values.count > 0 ? nk.values[0].doubleValue : 0.5;
    double ay = nk.values.count > 1 ? nk.values[1].doubleValue : 0.5;
    double offX = curNX - ax, offY = curNY - ay;
    if (modifiers & NSEventModifierFlagShift) {
      if (fabs(offX) >= fabs(offY))
        offY = 0.0;
      else
        offX = 0.0;
    }
    if (modifiers & NSEventModifierFlagCommand) {
      double len = hypot(offX, offY);
      if (len > 1e-9) {
        double step = M_PI / 4.0;
        double ang = round(atan2(offY, offX) / step) * step;
        offX = cos(ang) * len;
        offY = sin(ang) * len;
      }
    }
    NSArray<NSNumber *> *off = @[ @(offX), @(offY) ];
    NSArray<NSNumber *> *mir = @[ @(-offX), @(-offY) ];
    BOOL cusp = (modifiers & NSEventModifierFlagControl) != 0;
    nk.spatialSmooth = YES;
    if (_pathPart == 1) {
      nk.outHandle = off;
      if (!cusp)
        nk.inHandle = mir;
    } else {
      nk.inHandle = off;
      if (!cusp)
        nk.outHandle = mir;
    }
    kps[_pathIndex] = nk;
    nl.keyposes = kps;
  }
  lanes[li] = nl;
  KKTimeline *t = [self.renderer.timeline copy];
  t.lanes = lanes;
  self.renderer.timeline = t;
  [self.renderer.canvas setNeedsDisplay:YES];
  [self.renderer.canvas setHandlesNeedDisplay];
}

- (BOOL)toggleSmoothAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  KKLane *lane = [self _lane];
  if (!lane || lane.keyposes.count < 2 || CGRectIsEmpty(cr) ||
      ![self _pathActive])
    return NO;
  // Toggle the keypose under the click: an anchor dot, or the active keypose
  // under the position handle.
  NSInteger idx = [self _pathAnchorHitAtPoint:p contentRect:cr];
  if (idx < 0 && [self pointHandleHitAtPoint:p contentRect:cr] &&
      lane.keyposes.count)
    idx = KKLaneNearestKeyposeIndex(lane, self.renderer.editFraction);
  if (idx < 0)
    return NO;
  NSMutableArray<KKLane *> *lanes = [self.renderer.timeline.lanes mutableCopy];
  NSInteger li = [lanes indexOfObject:lane];
  if (li == NSNotFound)
    return NO;
  KKLane *nl = [lane copy];
  NSMutableArray<KKKeyPose *> *kps = [nl.keyposes mutableCopy];
  BOOL newSmooth = !kps[idx].spatialSmooth;
  // A hold-linked pair is two coincident keyposes the user sees as one; toggle
  // the smooth flag on the whole linked run (idx + its twins) so clicking
  // either half updates the curve - otherwise the un-toggled outgoing twin
  // keeps the boundary a corner and the click looks like it did nothing.
  NSMutableIndexSet *run =
      [NSMutableIndexSet indexSetWithIndex:(NSUInteger)idx];
  for (NSInteger i = idx;
       i + 1 < (NSInteger)kps.count && kps[i].outgoing.endpointsLinked; i++)
    [run addIndex:(NSUInteger)(i + 1)];
  for (NSInteger i = idx; i > 0 && kps[i - 1].outgoing.endpointsLinked; i--)
    [run addIndex:(NSUInteger)(i - 1)];
  [run enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
    KKKeyPose *nk = [kps[i] copy];
    nk.spatialSmooth = newSmooth;
    kps[i] = nk;
  }];
  nl.keyposes = kps;
  lanes[li] = nl;
  KKTimeline *t = [self.renderer.timeline copy];
  t.lanes = lanes;
  self.renderer.timeline = t;
  if (self.renderer.onTimelinePersist)
    self.renderer.onTimelinePersist(self.renderer.timeline);
  [self.renderer.canvas setNeedsDisplay:YES];
  [self.renderer.canvas setHandlesNeedDisplay];
  return YES;
}

- (BOOL)endDrag {
  [_snapEngine reset];
  if (_pathGrabbed) {
    _pathGrabbed = NO;
    return YES;
  }
  return NO;
}

- (void)_snapPositionX:(double *)nx Y:(double *)ny contentRect:(CGRect)cr {
  // Position-handle drag edits the keypose nearest editFraction; exclude it.
  KKLane *lane = [self _lane];
  NSInteger edited =
      (lane.keyposes.count)
          ? KKLaneNearestKeyposeIndex(lane, self.renderer.editFraction)
          : -1;
  [self _snapPositionX:nx Y:ny contentRect:cr excludeIndex:edited];
}

- (void)_snapPositionX:(double *)nx
                     Y:(double *)ny
           contentRect:(CGRect)cr
          excludeIndex:(NSInteger)excludeIndex {
  static const float anchors[] = {0.0f, 0.25f, 0.5f, 0.75f, 1.0f};
  // Snap threshold in mini-viewer view points; convert to normalized units
  // (per-axis since the mini may not be square).
  static const float kThreshPt = 6.0f;
  float thrX = cr.size.width > 0 ? kThreshPt / (float)cr.size.width : 0.01f;
  float thrY = cr.size.height > 0 ? kThreshPt / (float)cr.size.height : 0.01f;

  KKLane *lane = [self _lane];
  simd_float2 *objs = NULL;
  NSUInteger nObj = 0;
  if (lane) {
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
      for (NSInteger i = excludeIndex;
           i > 0 && kps[i - 1].outgoing.endpointsLinked; i--)
        [skip addIndex:(NSUInteger)(i - 1)];
    }
    if (kps.count > 0)
      objs = malloc(kps.count * sizeof(simd_float2));
    for (NSInteger k = 0; k < (NSInteger)kps.count; k++) {
      if ([skip containsIndex:(NSUInteger)k])
        continue;
      NSArray<NSNumber *> *v = kps[k].values;
      if (v.count < 2)
        continue;
      objs[nObj++] =
          (simd_float2){(float)v[0].doubleValue, (float)v[1].doubleValue};
    }
  }
  simd_float2 snapped =
      [_snapEngine snapPoint:(simd_float2){(float)*nx, (float)*ny}
              canvasAnchorsX:anchors
                      countX:5
              canvasAnchorsY:anchors
                      countY:5
               objectTargets:objs
                       count:nObj
                  thresholdX:thrX
                  thresholdY:thrY];
  if (objs)
    free(objs);
  *nx = snapped.x;
  *ny = snapped.y;
}

- (void)snapGuideHasX:(out BOOL *)hasX
                    X:(out CGFloat *)outX
         fromKeyposeX:(out BOOL *)fromKeyposeX
                 hasY:(out BOOL *)hasY
                    Y:(out CGFloat *)outY
         fromKeyposeY:(out BOOL *)fromKeyposeY {
  *hasX = _snapEngine.snappedX;
  *outX = (CGFloat)_snapEngine.snapValueX;
  *fromKeyposeX = _snapEngine.snapXFromObject;
  *hasY = _snapEngine.snappedY;
  *outY = (CGFloat)_snapEngine.snapValueY;
  *fromKeyposeY = _snapEngine.snapYFromObject;
}

@end
