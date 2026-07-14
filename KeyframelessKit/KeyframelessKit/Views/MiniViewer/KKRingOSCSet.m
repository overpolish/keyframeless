/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKRingOSCSet.h"
#import "KKRadialOSCSet_Protected.h"

#import <KeyframelessKit/KKResizeCursor.h> // KKResizeCursorForAngle, eye cursors
#import <KeyframelessKit/KKScaleGizmo.h>   // KKRingOSCExtentForNorm
#import <math.h>

@implementation KKRingOSCSet {
  // Drag press-anchor (cursor offset from centre + component values at press),
  // for an unlinked ellipse's cardinal-axis hold (Glow feel). The active label
  // itself lives in the base.
  double _dragStartDx, _dragStartDy, _dragStartDist;
  NSArray<NSNumber *> *_dragStartVals;
}

- (void)setRings:(NSArray<NSDictionary<NSString *, id> *> *)rings {
  self.specs = rings;
}

// A thin ring's ghost is barely visible at the base 0.3 dim; lift it to 0.6
// (peek mode returns 1.0, so it stays fully interactive there).
- (CGFloat)ghostAlphaForLabel:(NSString *)label {
  return [super ghostAlphaForLabel:label] < 1.0 ? 0.6 : 1.0;
}

// Ring centre (overlay points) + per-axis pixel radii for the current value. A
// vec2 #multi ring is an ellipse (rx=field0, ry=field1); a scalar is a circle.
- (BOOL)_geomForLabel:(NSString *)label
          contentRect:(CGRect)cr
               center:(out CGPoint *)outCenter
              radiusX:(out CGFloat *)outRx
              radiusY:(out CGFloat *)outRy {
  NSDictionary *s = [self specForLabel:label];
  if (!s)
    return NO;
  double minDim = MIN(cr.size.width, cr.size.height);
  NSArray<NSNumber *> *norms = [self normsForLabel:label];
  double nx = norms.count >= 1 ? norms[0].doubleValue : 0.0;
  double ny = norms.count >= 2 ? norms[1].doubleValue : nx;
  if (outCenter)
    *outCenter = [self centerForSpec:s contentRect:cr];
  if (outRx)
    *outRx = (CGFloat)KKRingOSCExtentForNorm(nx, minDim);
  if (outRy)
    *outRy = (CGFloat)KKRingOSCExtentForNorm(ny, minDim);
  return YES;
}

// The active ring whose (elliptical) stroke is within a few points of `p`, or
// nil.
- (nullable NSString *)_ringLabelAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  for (NSDictionary *s in self.specs) {
    NSString *label = s[@"label"];
    if (![self isActiveLabel:label forContentRect:cr])
      continue;
    CGPoint c = CGPointZero;
    CGFloat rx = 0, ry = 0;
    if (![self _geomForLabel:label
                 contentRect:cr
                      center:&c
                     radiusX:&rx
                     radiusY:&ry] ||
        (rx < 1.0 && ry < 1.0))
      continue;
    double nx = rx > 0 ? (p.x - c.x) / rx : 0;
    double ny = ry > 0 ? (p.y - c.y) / ry : 0;
    double ringDist = fabs(sqrt(nx * nx + ny * ny) - 1.0) * ((rx + ry) * 0.5);
    if (ringDist < 6.0)
      return label;
  }
  return nil;
}

- (NSArray<NSDictionary<NSString *, id> *> *)ringBundlesForContentRect:
    (CGRect)cr {
  NSMutableArray<NSDictionary<NSString *, id> *> *out = [NSMutableArray array];
  for (NSDictionary *s in self.specs) {
    NSString *label = s[@"label"];
    if (![self isActiveLabel:label forContentRect:cr])
      continue;
    CGPoint c = CGPointZero;
    CGFloat rx = 0, ry = 0;
    if (![self _geomForLabel:label
                 contentRect:cr
                      center:&c
                     radiusX:&rx
                     radiusY:&ry] ||
        (rx <= 0.5 && ry <= 0.5))
      continue;
    CGFloat alpha = [self ghostAlphaForLabel:label];
    BOOL ghost = alpha < 0.999;
    NSInteger emphasis =
        ghost ? 0 : ([self.activeLabel isEqualToString:label] ? 2 : 0);
    [out addObject:@{
      @"center" : [NSValue valueWithPoint:c],
      @"radiusX" : @(rx),
      @"radiusY" : @(ry),
      @"emphasis" : @(emphasis),
      @"alpha" : @(alpha),
    }];
  }
  return out;
}

- (BOOL)handleHitAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  return [self _ringLabelAtPoint:p contentRect:cr] != nil;
}

- (NSCursor *)cursorAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  NSString *hit = [self _ringLabelAtPoint:p contentRect:cr];
  if (!hit)
    return nil;
  BOOL ghost = [self.renderer ghostAlphaForLabel:hit] < 1.0;
  // Opt-hover hide/show affordance: only when an Opt-click would actually
  // toggle (Opt held + master on). eye.slash over a visible ring, eye over a
  // ghost.
  BOOL optToggle = self.renderer.revealHidden && !self.renderer.handlesHidden &&
                   self.renderer.onHandleVisibilityToggled != nil;
  if (optToggle)
    return ghost ? KKVisibilityShowCursor() : KKVisibilityHideCursor();
  if (ghost)
    return nil; // a re-enable ghost keeps the arrow, not a resize cursor
  CGPoint c = CGPointZero;
  CGFloat rx = 0, ry = 0;
  [self _geomForLabel:hit contentRect:cr center:&c radiusX:&rx radiusY:&ry];
  return KKResizeCursorForAngle(atan2(p.y - c.y, p.x - c.x));
}

- (BOOL)beginDragAtPoint:(CGPoint)p
             contentRect:(CGRect)cr
                  canvas:(KKMiniViewerView *)canvas {
  NSString *hit = [self _ringLabelAtPoint:p contentRect:cr];
  if (!hit)
    return NO;
  self.activeLabel = hit;
  CGPoint c = [self centerForSpec:[self specForLabel:hit] contentRect:cr];
  _dragStartDx = p.x - c.x;
  _dragStartDy = p.y - c.y;
  _dragStartDist = hypot(_dragStartDx, _dragStartDy);
  _dragStartVals = [self valuesForLabel:hit];
  [canvas setNeedsDisplay:YES]; // idle -> active stroke
  return YES;
}

- (BOOL)dragToPoint:(CGPoint)p
        contentRect:(CGRect)cr
             canvas:(KKMiniViewerView *)canvas
          modifiers:(NSEventModifierFlags)modifiers {
  NSString *active = self.activeLabel;
  if (!active)
    return NO;
  NSDictionary *s = [self specForLabel:active];
  if (!s)
    return YES;
  CGPoint c = [self centerForSpec:s contentRect:cr];
  double minDim = MIN(cr.size.width, cr.size.height);
  double dx = p.x - c.x, dy = p.y - c.y;
  // Effective aspect lock (lane's persisted lock, Shift-inverted for this
  // drag); the shared math matches the viewer ring exactly.
  BOOL shift = (modifiers & NSEventModifierFlagShift) != 0;
  BOOL laneLinked =
      [s[@"linked"] boolValue] && [self laneLinkedForLabel:active];
  BOOL effLinked = [s[@"linked"] boolValue] ? (laneLinked ^ shift) : NO;
  NSArray<NSNumber *> *newValues = KKRingOSCDragValues(
      [s[@"fields"] intValue], effLinked,
      _dragStartVals.count >= 1 ? _dragStartVals[0].doubleValue : 0,
      _dragStartVals.count >= 2 ? _dragStartVals[1].doubleValue : 0,
      _dragStartDx, _dragStartDy, _dragStartDist, dx, dy, minDim,
      [s[@"min"] doubleValue], [s[@"max"] doubleValue],
      [s[@"bounded"] boolValue], [s[@"isInt"] boolValue]);
  [self.renderer commitValues:newValues forLabel:active canvas:canvas];
  [canvas setNeedsDisplay:YES];
  return YES;
}

- (BOOL)endDragOnCanvas:(KKMiniViewerView *)canvas {
  if (!self.activeLabel)
    return NO;
  self.activeLabel = nil;
  [canvas setNeedsDisplay:YES]; // active -> idle stroke
  return YES;
}

- (BOOL)optClickAtPoint:(CGPoint)p
            contentRect:(CGRect)cr
                 canvas:(KKMiniViewerView *)canvas {
  // Hit-test FIRST and CLAIM any ring hit (return YES) even if the visibility
  // callback is missing - otherwise a hit ring falls through to a drag. Hide
  // when the callback is wired.
  NSString *hit = [self _ringLabelAtPoint:p contentRect:cr];
  if (!hit)
    return NO;
  if (self.renderer.onHandleVisibilityToggled)
    self.renderer.onHandleVisibilityToggled(hit);
  [canvas setNeedsDisplay:YES];
  return YES;
}

@end
