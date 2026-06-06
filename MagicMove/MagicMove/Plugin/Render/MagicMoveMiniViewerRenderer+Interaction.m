/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MagicMoveMiniViewerRenderer_Internal.h"
#import "MagicMoveParamsBuild.h"
#import "ShaderTypes.h"
#import <KeyframelessKit/KeyframelessKit.h>
#import <Metal/Metal.h>

static const CGFloat kHandleHitTolPt = 12.0;

// Scale box extent as a fraction of the content rect's min dimension (so it
// tracks the clip / scales with preview zoom). Mirrors the viewer's fractions.
static const double kMiniScaleE0Frac = 0.12;
static const double kMiniScaleSpanFrac = 0.057;
// Cmd-fine drag multiplier (matches the viewer).
static const double kMiniScaleFineFactor = 0.2;

@implementation MagicMoveMiniViewerRenderer (Interaction)

- (NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
    motionPathPolylineForContentRect:(CGRect)cr {
  KKLane *lane = MMMiniLaneNamed(self.timeline, @"Position");
  if (!lane || lane.keyposes.count < 2 ||
      ![self labelVisibleOrRevealing:@"Path"] || !self.boundaryEditing)
    return @[];
  NSArray<NSValue *> *pts = KKLanePositionPathPoints(lane, 24);
  NSMutableArray<NSValue *> *out = [NSMutableArray arrayWithCapacity:pts.count];
  for (NSValue *v in pts) {
    NSPoint o = v.pointValue;
    [out addObject:[NSValue
                       valueWithPoint:[self _handlePointForContentRect:cr
                                                              position:@[
                                                                @(o.x), @(o.y)
                                                              ]]]];
  }
  return out;
}

- (NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
    motionPathAnchorsForContentRect:(CGRect)cr {
  KKLane *lane = MMMiniLaneNamed(self.timeline, @"Position");
  if (!lane || lane.keyposes.count < 2 ||
      ![self labelVisibleOrRevealing:@"Path"] || !self.boundaryEditing)
    return @[];
  // Skip the keypose under the position handle (nearest editFraction) and
  // coalesce its linked partners; KKLaneCoalescedAnchors dedups the rest. Same
  // helper the viewer uses - returns object-space points to map into the rect.
  NSInteger active = [self _activeAnchorSkipIndexForLane:lane];
  NSMutableArray<NSValue *> *out = [NSMutableArray array];
  for (NSValue *pv in KKLaneCoalescedAnchors(lane, active)) {
    NSPoint v = pv.pointValue;
    [out addObject:[NSValue
                       valueWithPoint:[self _handlePointForContentRect:cr
                                                              position:@[
                                                                @(v.x), @(v.y)
                                                              ]]]];
  }
  return out;
}

- (NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
    motionPathHandleSegmentsForContentRect:(CGRect)cr {
  KKLane *lane = MMMiniLaneNamed(self.timeline, @"Position");
  if (!lane || lane.keyposes.count < 2 ||
      ![self labelVisibleOrRevealing:@"Path"] || !self.boundaryEditing)
    return @[];
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  NSMutableArray<NSValue *> *out = [NSMutableArray array];
  for (NSUInteger i = 0; i < kps.count; i++) {
    KKKeyPose *kp = kps[i];
    if (!kp.spatialSmooth || kp.values.count < 2)
      continue;
    double ax = kp.values[0].doubleValue, ay = kp.values[1].doubleValue;
    CGPoint anchorPt = [self _handlePointForContentRect:cr position:kp.values];
    CGPoint inH = CGPointZero, outH = CGPointZero;
    KKLaneSpatialHandlesForKeypose(lane, i, &inH, &outH);
    CGPoint sides[2] = {outH, inH};
    for (int s = 0; s < 2; s++) {
      if (hypot(sides[s].x, sides[s].y) < 1e-6)
        continue;
      CGPoint hp =
          [self _handlePointForContentRect:cr
                                  position:@[
                                    @(ax + sides[s].x), @(ay + sides[s].y)
                                  ]];
      [out addObject:[NSValue valueWithPoint:anchorPt]];
      [out addObject:[NSValue valueWithPoint:hp]];
    }
  }
  return out;
}

- (BOOL)pointHandleCenter:(out CGPoint *)outCenter forContentRect:(CGRect)cr {
  *outCenter =
      [self _handlePointForContentRect:cr
                              position:[self valuesForLabel:@"Position"]];
  return YES;
}

// Scale transform box (mini-viewer parity with the viewer). Concentric with the
// rotation gizmo (content-rect centre); the half-extents map the Scale percents
// through KKScaleGizmo, anchored to the mini rotation radius with the same
// proportions as the viewer (e0/span = 105/90, 50/90 of the radius).
- (BOOL)_scaleBoxShown {
  if (self.handlesHidden)
    return NO;
  if ([self.suppressedHandleLabels containsObject:@"Scale"])
    return NO;
  // Only when Scale is "active" in the current popover mode: a constant in the
  // constants popover, animated in the keypose popover. Without this, an
  // animated Scale's box wrongly shows in the constants popover.
  if (![self isConstantLabel:@"Scale"])
    return NO;
  return [self labelVisibleOrRevealing:@"Scale"];
}

- (CGFloat)scaleGhostAlpha {
  return [self ghostAlphaForLabel:@"Scale"];
}

- (NSString *)scaleReadoutText {
  if (![self _scaleBoxShown])
    return nil;
  NSArray<NSNumber *> *sv = [self valuesForLabel:@"Scale"];
  double sclX = sv.count > 0 ? fmax(0.0, sv[0].doubleValue) : 100.0;
  double sclY = sv.count > 1 ? fmax(0.0, sv[1].doubleValue) : 100.0;
  return [NSString stringWithFormat:@"%.0f%% x %.0f%%", sclX, sclY];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
      scaleBoxRect:(out CGRect *)outRect
    forContentRect:(CGRect)cr {
  if (![self _scaleBoxShown] || cr.size.width <= 0 || cr.size.height <= 0)
    return NO;
  CGPoint center = [self rotationCenterForContentRect:cr];
  // Size off the content rect (which scales with the preview's zoom/pan), not
  // the fixed popover radius - so the box grows/shrinks with the clip like the
  // viewer box does.
  double crMin = MIN(cr.size.width, cr.size.height);
  double e0 = crMin * kMiniScaleE0Frac, span = crMin * kMiniScaleSpanFrac;
  NSArray<NSNumber *> *sv = [self valuesForLabel:@"Scale"];
  double sclX = sv.count > 0 ? fmax(0.0, sv[0].doubleValue) : 100.0;
  double sclY = sv.count > 1 ? fmax(0.0, sv[1].doubleValue) : 100.0;
  double halfW = KKScaleGizmoExtentForPercent(sclX, e0, span);
  double halfH = KKScaleGizmoExtentForPercent(sclY, e0, span);
  *outRect =
      CGRectMake(center.x - halfW, center.y - halfH, 2 * halfW, 2 * halfH);
  return YES;
}

// Fills out[8] with the scale-box handle centres (0-3 corners BL/BR/TR/TL,
// 4-7 edges bottom/right/top/left) in overlay points. NO if the box isn't
// shown.
- (BOOL)_scaleHandlePositions:(CGPoint *)out forContentRect:(CGRect)cr {
  CGRect sb;
  if (![self miniViewer:self.canvas scaleBoxRect:&sb forContentRect:cr])
    return NO;
  double l = CGRectGetMinX(sb), r = CGRectGetMaxX(sb);
  double b = CGRectGetMinY(sb), t = CGRectGetMaxY(sb);
  double cx = CGRectGetMidX(sb), cy = CGRectGetMidY(sb);
  out[0] = CGPointMake(l, b);
  out[1] = CGPointMake(r, b);
  out[2] = CGPointMake(r, t);
  out[3] = CGPointMake(l, t);
  out[4] = CGPointMake(cx, b);
  out[5] = CGPointMake(r, cy);
  out[6] = CGPointMake(cx, t);
  out[7] = CGPointMake(l, cy);
  return YES;
}

- (NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
    scaleHandleCentersForContentRect:(CGRect)cr {
  CGPoint h[8];
  if (![self _scaleHandlePositions:h forContentRect:cr])
    return @[];
  NSMutableArray<NSValue *> *out = [NSMutableArray arrayWithCapacity:8];
  for (int i = 0; i < 8; i++)
    [out addObject:[NSValue valueWithPoint:NSPointFromCGPoint(h[i])]];
  return out;
}

// Scale-box handle centres the box *would* have at explicit scale percents -
// the guide's "drag the corner out to 200%" target. Mirrors the live geometry
// in -_scaleHandlePositions:forContentRect: but off passed-in values.
- (NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
       scaleHandleCentersForValues:(NSArray<NSNumber *> *)values
                       contentRect:(CGRect)cr {
  if (![self _scaleBoxShown] || cr.size.width <= 0 || cr.size.height <= 0)
    return nil;
  double sclX = values.count > 0 ? fmax(0.0, values[0].doubleValue) : 100.0;
  double sclY = values.count > 1 ? fmax(0.0, values[1].doubleValue) : sclX;
  CGPoint center = [self rotationCenterForContentRect:cr];
  double crMin = MIN(cr.size.width, cr.size.height);
  double e0 = crMin * kMiniScaleE0Frac, span = crMin * kMiniScaleSpanFrac;
  double halfW = KKScaleGizmoExtentForPercent(sclX, e0, span);
  double halfH = KKScaleGizmoExtentForPercent(sclY, e0, span);
  double l = center.x - halfW, r = center.x + halfW;
  double b = center.y - halfH, t = center.y + halfH;
  double cx = center.x, cy = center.y;
  CGPoint h[8] = {CGPointMake(l, b),  CGPointMake(r, b),  CGPointMake(r, t),
                  CGPointMake(l, t),  CGPointMake(cx, b), CGPointMake(r, cy),
                  CGPointMake(cx, t), CGPointMake(l, cy)};
  NSMutableArray<NSValue *> *out = [NSMutableArray arrayWithCapacity:8];
  for (int i = 0; i < 8; i++)
    [out addObject:[NSValue valueWithPoint:NSPointFromCGPoint(h[i])]];
  return out;
}

// The Scale transform box, appended to the base's boxes (Magic Move has no
// crop, so super returns none). The shared box path in KKMiniViewerView draws
// the border + 8 handles + readout uniformly with the crop box.
- (NSArray<KKMiniBox *> *)miniViewer:(KKMiniViewerView *)canvas
                 boxesForContentRect:(CGRect)cr {
  NSMutableArray<KKMiniBox *> *boxes = [[super miniViewer:canvas
                                      boxesForContentRect:cr] mutableCopy];
  CGRect sb;
  if ([self miniViewer:canvas scaleBoxRect:&sb forContentRect:cr]) {
    [boxes addObject:[KKMiniBox
                           boxWithRect:sb
                         handleCenters:[self miniViewer:canvas
                                           scaleHandleCentersForContentRect:cr]
                               readout:[self scaleReadoutText]
                            ghostAlpha:[self scaleGhostAlpha]]];
  }
  return boxes;
}

- (BOOL)_scaleHandleHitAtPoint:(CGPoint)p
                   contentRect:(CGRect)cr
                      outIndex:(NSInteger *)outIdx {
  CGPoint h[8];
  if (![self _scaleHandlePositions:h forContentRect:cr])
    return NO;
  NSInteger best = [self nearestHandleIndexToPoint:p
                                           centers:h
                                             count:8
                                         tolerance:kHandleHitTolPt];
  if (best == NSNotFound)
    return NO;
  if (outIdx)
    *outIdx = best;
  return YES;
}

// Absolute drag (effective cursor tracks the grabbed handle; Cmd = fine) with
// link-aware coupling (Shift inverts) and integer snapping - mirrors the
// viewer.
- (void)_applyScaleDragToPoint:(CGPoint)p
                   contentRect:(CGRect)cr
                     modifiers:(NSEventModifierFlags)modifiers {
  NSInteger h = _scaleGrabHandle;
  if (h < 0 || cr.size.width <= 0 || cr.size.height <= 0)
    return;
  double rawDx = p.x - _scaleLastCursor.x, rawDy = p.y - _scaleLastCursor.y;
  _scaleLastCursor = p;
  double fine =
      (modifiers & NSEventModifierFlagCommand) ? kMiniScaleFineFactor : 1.0;
  _scaleEffCursor = CGPointMake(_scaleEffCursor.x + rawDx * fine,
                                _scaleEffCursor.y + rawDy * fine);
  CGPoint c = _scalePressCenter;
  double crMin = MIN(cr.size.width, cr.size.height);
  double e0 = crMin * kMiniScaleE0Frac, span = crMin * kMiniScaleSpanFrac;
  double tX =
      KKScaleGizmoPercentForExtent(fabs(_scaleEffCursor.x - c.x), e0, span);
  double tY =
      KKScaleGizmoPercentForExtent(fabs(_scaleEffCursor.y - c.y), e0, span);
  BOOL shift = (modifiers & NSEventModifierFlagShift) != 0;
  KKLane *sl = MMMiniLaneNamed(self.timeline, @"Scale");
  BOOL effLinked = (sl.aspectLinked != 0) ^ shift;
  double pX = _scalePressSclX, pY = _scalePressSclY;
  BOOL haveRatio = (pX > 1e-6 && pY > 1e-6);
  double newX = pX, newY = pY;
  BOOL isCorner = (h <= 3);
  BOOL controlsX = isCorner || h == 5 || h == 7;
  if (isCorner) {
    if (effLinked && haveRatio) {
      double f = sqrt((tX / pX) * (tY / pY));
      newX = pX * f;
      newY = pY * f;
    } else {
      newX = tX;
      newY = tY;
    }
  } else if (controlsX) {
    newX = tX;
    newY = effLinked ? (haveRatio ? pY * (tX / pX) : tX) : pY;
  } else { // controls Y (h == 4 || h == 6)
    newY = tY;
    newX = effLinked ? (haveRatio ? pX * (tY / pY) : tY) : pX;
  }
  newX = fmax(0.0, round(newX));
  newY = fmax(0.0, round(newY));
  [self commitValues:@[ @(newX), @(newY) ]
            forLabel:@"Scale"
              canvas:self.canvas];
}

- (BOOL)pointHandleCenter:(out CGPoint *)outCenter
                 forValue:(double)value
           forContentRect:(CGRect)cr {
  // Position is 2D; no single-scalar guide target.
  return NO;
}

- (BOOL)pointHandleCenter:(out CGPoint *)outCenter
                forValues:(NSArray<NSNumber *> *)values
           forContentRect:(CGRect)cr {
  // Position target: map the 2D [x, y] to the handle's screen-space centre,
  // the same path the live handle uses - lets a guide place a "drag to here"
  // destination point.
  if (values.count < 2 || cr.size.width <= 0 || cr.size.height <= 0)
    return NO;
  if (outCenter)
    *outCenter = [self _handlePointForContentRect:cr position:values];
  return YES;
}

- (BOOL)pointHandleHitAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  CGPoint hp =
      [self _handlePointForContentRect:cr
                              position:[self valuesForLabel:@"Position"]];
  return hypot(p.x - hp.x, p.y - hp.y) <= kHandleHitTolPt;
}

- (void)applyPointDragToPoint:(CGPoint)p
                  contentRect:(CGRect)cr
                       canvas:(KKMiniViewerView *)canvas {
  // No-modifier path is only called on begin (kit's beginHandleDragAtPoint);
  // capture the press normals + the grabbed value here so the drag moves by
  // delta (Shift axis-lock anchors here too).
  if (cr.size.width > 0 && cr.size.height > 0) {
    _posPressNX = (p.x - CGRectGetMinX(cr)) / cr.size.width;
    _posPressNY = (p.y - CGRectGetMinY(cr)) / cr.size.height;
  }
  NSArray<NSNumber *> *pv = [self valuesForLabel:@"Position"];
  _posGrabValX = pv.count > 0 ? pv[0].doubleValue : 0.5;
  _posGrabValY = pv.count > 1 ? pv[1].doubleValue : 0.5;
  [self applyPointDragToPoint:p contentRect:cr canvas:canvas modifiers:0];
}

// Mirror of the viewer OSC: snap is OFF by default, Cmd engages it;
// Shift locks to the dominant-travel axis (the other axis pins to the
// press point). Same modifier convention as the viewer's position drag.
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
  if (modifiers & NSEventModifierFlagCommand) {
    [self _snapPositionX:&newX Y:&newY contentRect:cr];
  } else {
    [_snapEngine reset];
  }
  [self commitValues:@[ @(newX), @(newY) ] forLabel:@"Position" canvas:canvas];
}

// Mini-viewer drag is also called via the delegate dispatcher in
// KKMiniViewerView so the modifier variant takes precedence over the plain
// one.
- (void)miniViewer:(KKMiniViewerView *)canvas
    dragHandleToPoint:(CGPoint)p
          contentRect:(CGRect)cr
            modifiers:(NSEventModifierFlags)modifiers {
  if (_anchorGrabbed) {
    [self _applyAnchorDragToPoint:p contentRect:cr modifiers:modifiers];
    return;
  }
  if (_pathGrabbed) {
    [self _applyPathDragToPoint:p contentRect:cr modifiers:modifiers];
    return;
  }
  if (_scaleGrabbed) {
    [self _applyScaleDragToPoint:p contentRect:cr modifiers:modifiers];
    return;
  }
  // Rotation drag has to be routed here too - the override was only added
  // so Position could see modifiers, but it accidentally swallowed every
  // non-point drag (rotation rings, crop). Route rotation first, then fall
  // through to point. Crop goes via the base renderer's path on super.
  if ([self rotationIsActive]) {
    [self applyRotationDragToPoint:p
                       contentRect:cr
                            canvas:canvas
                         modifiers:modifiers];
    return;
  }
  if (![self pointHandleIsActive]) {
    [super miniViewer:canvas
        dragHandleToPoint:p
              contentRect:cr
                modifiers:modifiers];
    return;
  }
  [self applyPointDragToPoint:p
                  contentRect:cr
                       canvas:canvas
                    modifiers:modifiers];
}

// The active keypose's dot is skipped only when the Position handle is actually
// drawn there (full opacity). When the Position OSC is hidden, return -1 so the
// path anchor shows / is grabbable - the active keypose stays editable,
// matching the viewer.
- (NSInteger)_activeAnchorSkipIndexForLane:(KKLane *)lane {
  if ([self ghostAlphaForLabel:@"Position"] < 0.999)
    return -1;
  if (lane.keyposes.count == 0)
    return -1;
  return KKLaneNearestKeyposeIndex(lane, self.editFraction);
}

// The keypose anchor under `p` (excluding the active one, whose dot is hidden
// under the position handle), or NO. Mirrors the viewer's anchor hit-test.
- (BOOL)_pathAnchorHitAtPoint:(CGPoint)p
                  contentRect:(CGRect)cr
                     outIndex:(NSInteger *)outIdx {
  KKLane *lane = MMMiniLaneNamed(self.timeline, @"Position");
  if (!lane || lane.keyposes.count < 2 || CGRectIsEmpty(cr) ||
      ![self labelVisibleOrRevealing:@"Path"] || !self.boundaryEditing)
    return NO;
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  NSInteger active = [self _activeAnchorSkipIndexForLane:lane];
  double bestD = kHandleHitTolPt;
  NSInteger best = -1;
  for (NSInteger i = 0; i < (NSInteger)kps.count; i++) {
    if (i == active || kps[i].values.count < 2)
      continue;
    CGPoint hp = [self _handlePointForContentRect:cr position:kps[i].values];
    double d = hypot(p.x - hp.x, p.y - hp.y);
    if (d <= bestD) {
      bestD = d;
      best = i;
    }
  }
  if (best < 0)
    return NO;
  if (outIdx)
    *outIdx = best;
  return YES;
}

// A smooth keypose's tangent-handle dot under `p`: outputs the keypose index +
// which side (out vs in). Mirrors the viewer's handle hit-test.
- (BOOL)_pathHandleHitAtPoint:(CGPoint)p
                  contentRect:(CGRect)cr
                     outIndex:(NSInteger *)outIdx
                     outIsOut:(BOOL *)outIsOut {
  KKLane *lane = MMMiniLaneNamed(self.timeline, @"Position");
  if (!lane || lane.keyposes.count < 2 || CGRectIsEmpty(cr) ||
      ![self labelVisibleOrRevealing:@"Path"] || !self.boundaryEditing)
    return NO;
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
      CGPoint hp =
          [self _handlePointForContentRect:cr
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
  if (bestI < 0)
    return NO;
  if (outIdx)
    *outIdx = bestI;
  if (outIsOut)
    *outIsOut = bestOut;
  return YES;
}

// Live-update the dragged keypose's position in self.timeline (drives the
// preview); the full blob is persisted once on drag end.
- (void)_applyPathDragToPoint:(CGPoint)p
                  contentRect:(CGRect)cr
                    modifiers:(NSEventModifierFlags)modifiers {
  if (cr.size.width <= 0 || cr.size.height <= 0)
    return;
  KKLane *lane = MMMiniLaneNamed(self.timeline, @"Position");
  if (!lane || _pathIndex < 0 || _pathIndex >= (NSInteger)lane.keyposes.count)
    return;
  double curNX = (p.x - CGRectGetMinX(cr)) / cr.size.width;
  double curNY = (p.y - CGRectGetMinY(cr)) / cr.size.height;
  NSMutableArray<KKLane *> *lanes = [self.timeline.lanes mutableCopy];
  NSInteger li = [lanes indexOfObject:lane];
  if (li == NSNotFound)
    return;
  KKLane *nl = [lane copy];
  NSMutableArray<KKKeyPose *> *kps = [nl.keyposes mutableCopy];
  KKKeyPose *nk = [kps[_pathIndex] copy];
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
    nk.values = @[ @(nx), @(ny) ];
  } else {
    // Tangent handle: offset from the anchor; symmetric unless Shift breaks it.
    double ax = nk.values.count > 0 ? nk.values[0].doubleValue : 0.5;
    double ay = nk.values.count > 1 ? nk.values[1].doubleValue : 0.5;
    double offX = curNX - ax, offY = curNY - ay;
    NSArray<NSNumber *> *off = @[ @(offX), @(offY) ];
    NSArray<NSNumber *> *mir = @[ @(-offX), @(-offY) ];
    BOOL shift = (modifiers & NSEventModifierFlagShift) != 0;
    nk.spatialSmooth = YES;
    if (_pathPart == 1) {
      nk.outHandle = off;
      if (!shift)
        nk.inHandle = mir;
    } else {
      nk.inHandle = off;
      if (!shift)
        nk.outHandle = mir;
    }
  }
  kps[_pathIndex] = nk;
  nl.keyposes = kps;
  lanes[li] = nl;
  KKTimeline *t = [self.timeline copy];
  t.lanes = lanes;
  self.timeline = t;
  [self.canvas setNeedsDisplay:YES];
  [self.canvas setHandlesNeedDisplay];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    handleHitAtPoint:(CGPoint)p
         contentRect:(CGRect)cr {
  NSInteger idx;
  BOOL isOut;
  // Anchor pivot square is topmost (mirrors the viewer) so it is always
  // grabbable; the larger Position arc ring around it stays clickable.
  if ([self _anchorSquareHitAtPoint:p contentRect:cr])
    return YES;
  // The active keypose's position handle is next: when it coincides with a
  // path anchor or tangent handle, the handle wins. Handles are offset from the
  // anchor centre, so they stay grabbable away from it.
  if ([self pointHandleHitAtPoint:p contentRect:cr])
    return YES;
  if ([self _pathHandleHitAtPoint:p
                      contentRect:cr
                         outIndex:&idx
                         outIsOut:&isOut])
    return YES;
  if ([self _pathAnchorHitAtPoint:p contentRect:cr outIndex:&idx])
    return YES;
  if ([self _scaleHandleHitAtPoint:p contentRect:cr outIndex:&idx])
    return YES;
  return [super miniViewer:canvas handleHitAtPoint:p contentRect:cr];
}

- (void)miniViewer:(KKMiniViewerView *)canvas
    beginHandleDragAtPoint:(CGPoint)p
               contentRect:(CGRect)cr {
  _pathGrabbed = NO;
  _anchorGrabbed = NO;
  NSInteger idx;
  BOOL isOut;
  // Anchor square grabs first (topmost, matches the hit-test priority).
  if ([self _anchorSquareHitAtPoint:p contentRect:cr]) {
    self.canvas = canvas;
    _anchorGrabbed = YES;
    NSArray<NSNumber *> *av = [self valuesForLabel:@"Anchor"];
    _anchorGrabValX = av.count > 0 ? av[0].doubleValue : 0.5;
    _anchorGrabValY = av.count > 1 ? av[1].doubleValue : 0.5;
    if (cr.size.width > 0 && cr.size.height > 0) {
      _anchorPressNX = (p.x - CGRectGetMinX(cr)) / cr.size.width;
      _anchorPressNY = (p.y - CGRectGetMinY(cr)) / cr.size.height;
    }
    return;
  }
  // Active keypose's position handle takes the grab next (matches the hit-test
  // priority), so a coincident path anchor/handle doesn't steal it.
  if ([self pointHandleHitAtPoint:p contentRect:cr]) {
    [super miniViewer:canvas beginHandleDragAtPoint:p contentRect:cr];
    return;
  }
  if ([self _pathHandleHitAtPoint:p
                      contentRect:cr
                         outIndex:&idx
                         outIsOut:&isOut]) {
    self.canvas = canvas;
    _pathGrabbed = YES;
    _pathIndex = idx;
    _pathPart = isOut ? 1 : 2;
    [self _applyPathDragToPoint:p contentRect:cr modifiers:0];
    return;
  }
  if ([self _pathAnchorHitAtPoint:p contentRect:cr outIndex:&idx]) {
    self.canvas = canvas;
    _pathGrabbed = YES;
    _pathIndex = idx;
    _pathPart = 0;
    NSArray<NSNumber *> *gv =
        MMMiniLaneNamed(self.timeline, @"Position").keyposes[idx].values;
    _pathGrabValX = gv.count > 0 ? gv[0].doubleValue : 0.5;
    _pathGrabValY = gv.count > 1 ? gv[1].doubleValue : 0.5;
    if (cr.size.width > 0 && cr.size.height > 0) {
      _pathPressNX = (p.x - CGRectGetMinX(cr)) / cr.size.width;
      _pathPressNY = (p.y - CGRectGetMinY(cr)) / cr.size.height;
    }
    [self _applyPathDragToPoint:p contentRect:cr modifiers:0];
    return;
  }
  if ([self _scaleHandleHitAtPoint:p contentRect:cr outIndex:&idx]) {
    self.canvas = canvas;
    _scaleGrabbed = YES;
    _scaleGrabHandle = idx;
    _scalePressCenter = [self rotationCenterForContentRect:cr];
    NSArray<NSNumber *> *sv = [self valuesForLabel:@"Scale"];
    _scalePressSclX = sv.count > 0 ? fmax(0.0, sv[0].doubleValue) : 100.0;
    _scalePressSclY = sv.count > 1 ? fmax(0.0, sv[1].doubleValue) : 100.0;
    // Effective cursor starts at the grabbed handle (no press snap).
    CGPoint h[8];
    [self _scaleHandlePositions:h forContentRect:cr];
    _scaleEffCursor = h[idx];
    _scaleLastCursor = p;
    return;
  }
  [super miniViewer:canvas beginHandleDragAtPoint:p contentRect:cr];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    doubleClickAtPoint:(CGPoint)p
           contentRect:(CGRect)cr {
  KKLane *lane = MMMiniLaneNamed(self.timeline, @"Position");
  if (!lane || lane.keyposes.count < 2 || CGRectIsEmpty(cr) ||
      ![self labelVisibleOrRevealing:@"Path"] || !self.boundaryEditing)
    return NO;
  // Toggle the keypose under the click: an anchor dot, or the active keypose
  // under the position handle.
  NSInteger idx = -1;
  if (![self _pathAnchorHitAtPoint:p contentRect:cr outIndex:&idx]) {
    if ([self pointHandleHitAtPoint:p contentRect:cr]) {
      if (lane.keyposes.count)
        idx = KKLaneNearestKeyposeIndex(lane, self.editFraction);
    }
  }
  if (idx < 0)
    return NO;
  NSMutableArray<KKLane *> *lanes = [self.timeline.lanes mutableCopy];
  NSInteger li = [lanes indexOfObject:lane];
  if (li == NSNotFound)
    return NO;
  KKLane *nl = [lane copy];
  NSMutableArray<KKKeyPose *> *kps = [nl.keyposes mutableCopy];
  KKKeyPose *nk = [kps[idx] copy];
  nk.spatialSmooth = !nk.spatialSmooth;
  kps[idx] = nk;
  nl.keyposes = kps;
  lanes[li] = nl;
  KKTimeline *t = [self.timeline copy];
  t.lanes = lanes;
  self.timeline = t;
  if (self.onTimelinePersist)
    self.onTimelinePersist(self.timeline);
  [canvas setNeedsDisplay:YES];
  [canvas setHandlesNeedDisplay];
  return YES;
}

- (CGFloat)motionPathGhostAlpha {
  return [self ghostAlphaForLabel:@"Path"];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    optClickHandleAtPoint:(CGPoint)p
              contentRect:(CGRect)cr {
  // Anchor square is topmost, so it claims the opt-click first.
  if (self.onHandleVisibilityToggled && [self _anchorSquareHitAtPoint:p
                                                          contentRect:cr]) {
    self.onHandleVisibilityToggled(@"Anchor");
    [canvas setNeedsDisplay:YES];
    [canvas setHandlesNeedDisplay];
    return YES;
  }
  // Built-in handles (Position arc, rotation, crop) claim the opt-click next,
  // so at the active keypose the Position handle wins over the path anchor that
  // shares its spot when Position is revealed - matching the viewer. The path
  // then catches its own anchors/handles.
  if ([super miniViewer:canvas optClickHandleAtPoint:p contentRect:cr])
    return YES;
  NSInteger idx;
  BOOL isOut;
  if (self.onHandleVisibilityToggled && ([self _pathHandleHitAtPoint:p
                                                         contentRect:cr
                                                            outIndex:&idx
                                                            outIsOut:&isOut] ||
                                         [self _pathAnchorHitAtPoint:p
                                                         contentRect:cr
                                                            outIndex:&idx])) {
    self.onHandleVisibilityToggled(@"Path");
    [canvas setNeedsDisplay:YES];
    [canvas setHandlesNeedDisplay];
    return YES;
  }
  if (self.onHandleVisibilityToggled && [self _scaleHandleHitAtPoint:p
                                                         contentRect:cr
                                                            outIndex:&idx]) {
    self.onHandleVisibilityToggled(@"Scale");
    [canvas setNeedsDisplay:YES];
    [canvas setHandlesNeedDisplay];
    return YES;
  }
  return NO;
}

- (void)_snapPositionX:(double *)nx Y:(double *)ny contentRect:(CGRect)cr {
  // Position-handle drag edits the keypose nearest editFraction; exclude it.
  NSInteger edited = -1;
  for (KKLane *lane in self.timeline.lanes) {
    if (![lane.label isEqualToString:@"Position"])
      continue;
    if (lane.keyposes.count)
      edited = KKLaneNearestKeyposeIndex(lane, self.editFraction);
    break;
  }
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

  // Other keyposes on the Position lane. Identify the edited keypose by
  // closest-time match against editFraction (skipping by *value* would
  // unskip mid-drag the moment the edited keypose's value lines up with
  // another, producing a snap → unsnap → snap pingback).
  simd_float2 *objs = NULL;
  NSUInteger nObj = 0;
  for (KKLane *lane in self.timeline.lanes) {
    if (![lane.label isEqualToString:@"Position"])
      continue;
    NSArray<KKKeyPose *> *kps = lane.keyposes;
    if (kps.count > 0)
      objs = malloc(kps.count * sizeof(simd_float2));
    for (NSInteger k = 0; k < (NSInteger)kps.count; k++) {
      if (k == excludeIndex)
        continue;
      NSArray<NSNumber *> *v = kps[k].values;
      if (v.count < 2)
        continue;
      objs[nObj++] =
          (simd_float2){(float)v[0].doubleValue, (float)v[1].doubleValue};
    }
    break;
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

- (void)miniViewer:(KKMiniViewerView *)canvas
     snapGuideHasX:(out BOOL *)hasX
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

// Overlay-point centre of the anchor pivot: the clip centre (Position) shifted
// by the Anchor offset, in the same normalized clip space as the path anchors.
- (CGPoint)_anchorPointForContentRect:(CGRect)cr {
  NSArray<NSNumber *> *pos = [self valuesForLabel:@"Position"];
  NSArray<NSNumber *> *anc = [self valuesForLabel:@"Anchor"];
  double px = pos.count > 0 ? pos[0].doubleValue : 0.5;
  double py = pos.count > 1 ? pos[1].doubleValue : 0.5;
  double ax = anc.count > 0 ? anc[0].doubleValue : 0.5;
  double ay = anc.count > 1 ? anc[1].doubleValue : 0.5;
  return
      [self _handlePointForContentRect:cr
                              position:@[ @(px + ax - 0.5), @(py + ay - 0.5) ]];
}

// The anchor square shows when the Anchor lane is constant (a single fixed
// pivot) and not hidden - same convention as the other single-handle OSCs in
// the mini-viewer (animated lanes draw keypose dots instead).
- (BOOL)_anchorActiveForContentRect:(CGRect)cr {
  return !CGRectIsEmpty(cr) && [self isConstantLabel:@"Anchor"] &&
         [self labelVisibleOrRevealing:@"Anchor"];
}

- (BOOL)_anchorSquareHitAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  if (![self _anchorActiveForContentRect:cr])
    return NO;
  CGPoint c = [self _anchorPointForContentRect:cr];
  // Tight to the drawn square (Chebyshev, square hit region), and well under
  // the Position handle's 12pt grab so clicking the arc ring around the small
  // square still reaches Position - mirroring the viewer where the square is
  // physically smaller than the arc. Scales with the popover (canvas H / 230).
  CGFloat scale = self.canvas.bounds.size.height > 0
                      ? self.canvas.bounds.size.height / 230.0
                      : 1.0;
  CGFloat r = 5.0 * scale;
  return fmax(fabs(p.x - c.x), fabs(p.y - c.y)) < r;
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    anchorSquareCenter:(out CGPoint *)outCenter
           contentRect:(CGRect)cr {
  if (![self _anchorActiveForContentRect:cr])
    return NO;
  if (outCenter)
    *outCenter = [self _anchorPointForContentRect:cr];
  return YES;
}

- (CGFloat)anchorSquareGhostAlpha {
  return [self ghostAlphaForLabel:@"Anchor"];
}

// Delta drag like Position: the anchor value moves by the cursor's normalized
// offset from the grab point. Cmd snaps the PIVOT (Position + Anchor offset) to
// the clip's centre / corners / edge-midpoints / thirds, routed through the
// shared snap engine so the canvas strokes the yellow guide lines.
- (void)_applyAnchorDragToPoint:(CGPoint)p
                    contentRect:(CGRect)cr
                      modifiers:(NSEventModifierFlags)modifiers {
  if (cr.size.width <= 0 || cr.size.height <= 0)
    return;
  double nx = (p.x - CGRectGetMinX(cr)) / cr.size.width;
  double ny = (p.y - CGRectGetMinY(cr)) / cr.size.height;
  double newX = _anchorGrabValX + (nx - _anchorPressNX);
  double newY = _anchorGrabValY + (ny - _anchorPressNY);
  if (modifiers & NSEventModifierFlagCommand) {
    NSArray<NSNumber *> *pos = [self valuesForLabel:@"Position"];
    double posX = pos.count > 0 ? pos[0].doubleValue : 0.5;
    double posY = pos.count > 1 ? pos[1].doubleValue : 0.5;
    // Clip features in pivot-normalized content space (0/⅓/½/⅔/1 of the clip
    // offset from its centre by Position). Snapping the pivot here makes the
    // guide land on the clip's real edges/centre, not on a fixed value.
    static const double frac[] = {0.0, 1.0 / 3.0, 0.5, 2.0 / 3.0, 1.0};
    float ax[5], ay[5];
    for (int i = 0; i < 5; i++) {
      ax[i] = (float)(posX + frac[i] - 0.5);
      ay[i] = (float)(posY + frac[i] - 0.5);
    }
    float thrX = cr.size.width > 0 ? 6.0f / (float)cr.size.width : 0.02f;
    float thrY = cr.size.height > 0 ? 6.0f / (float)cr.size.height : 0.02f;
    simd_float2 pivot = {(float)(posX + newX - 0.5),
                         (float)(posY + newY - 0.5)};
    simd_float2 sn = [_snapEngine snapPoint:pivot
                             canvasAnchorsX:ax
                                     countX:5
                             canvasAnchorsY:ay
                                     countY:5
                              objectTargets:NULL
                                      count:0
                                 thresholdX:thrX
                                 thresholdY:thrY];
    newX = sn.x - posX + 0.5;
    newY = sn.y - posY + 0.5;
  } else {
    [_snapEngine reset];
  }
  [self commitValues:@[ @(newX), @(newY) ]
            forLabel:@"Anchor"
              canvas:self.canvas];
}

- (void)miniViewerEndHandleDrag:(KKMiniViewerView *)canvas {
  [_snapEngine reset];
  _anchorGrabbed = NO;
  _scaleGrabbed = NO;
  if (_pathGrabbed) {
    _pathGrabbed = NO;
    if (self.onTimelinePersist)
      self.onTimelinePersist(self.timeline);
    [canvas setNeedsDisplay:YES];
    [canvas setHandlesNeedDisplay];
    return;
  }
  [super miniViewerEndHandleDrag:canvas];
}

// Opting in to the base's 3-ring gizmo. The drag state machine, hit-test,
// compose × axis(dAngle) → decompose-near, and commit all live in the base
// (`KKMiniViewerRenderer`). The only thing MagicMove-specific is anchoring
// the sphere to the Position handle so the rings move with the translated
// image.

@end
