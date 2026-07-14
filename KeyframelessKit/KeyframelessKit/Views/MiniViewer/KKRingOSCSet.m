/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKRingOSCSet.h"

#import <KeyframelessKit/KKResizeCursor.h> // KKResizeCursorForAngle, eye cursors
#import <KeyframelessKit/KKScaleGizmo.h>   // KKRingOSCExtentForNorm
#import <KeyframelessKit/KKTimingStage.h>  // KKLane / KKTimeline (aspectLinked)
#import <math.h>

@implementation KKRingOSCSet {
  __weak KKMiniViewerRenderer *_renderer;
  NSArray<NSDictionary<NSString *, id> *> *_specs;
  NSDictionary<NSString *, NSDictionary<NSString *, id> *> *_specByLabel;
  // The ring currently being dragged (nil = no drag). No hover state: like
  // KKPointOSCSet the hover only drives the cursor, not a stroke emphasis.
  NSString *_activeLabel;
  // Drag press-anchor (cursor offset from centre + component values at press),
  // for an unlinked ellipse's cardinal-axis hold (Glow feel).
  double _dragStartDx, _dragStartDy, _dragStartDist;
  NSArray<NSNumber *> *_dragStartVals;
}

- (instancetype)initWithRenderer:(KKMiniViewerRenderer *)renderer {
  self = [super init];
  if (self) {
    _renderer = renderer;
    _specs = @[];
    _specByLabel = @{};
  }
  return self;
}

- (void)setRings:(NSArray<NSDictionary<NSString *, id> *> *)rings {
  _specs = [rings copy] ?: @[];
  NSMutableDictionary *byLabel = [NSMutableDictionary dictionary];
  for (NSDictionary *s in _specs) {
    NSString *label = s[@"label"];
    if (label.length)
      byLabel[label] = s;
  }
  _specByLabel = byLabel;
  // Drop a drag whose ring vanished.
  if (_activeLabel && !_specByLabel[_activeLabel])
    _activeLabel = nil;
}

- (NSArray<NSString *> *)labels {
  NSMutableArray<NSString *> *out = [NSMutableArray array];
  for (NSDictionary *s in _specs)
    if (((NSString *)s[@"label"]).length)
      [out addObject:s[@"label"]];
  return out;
}

// A ring shows for a constant, visible (or Opt-revealed) lane whose element
// isn't suppressed - the same gate as the viewer ring and KKPointOSCSet.
- (BOOL)_active:(NSString *)label forContentRect:(CGRect)cr {
  return !CGRectIsEmpty(cr) && label.length &&
         ![_renderer.suppressedHandleLabels containsObject:label] &&
         [_renderer isConstantLabel:label] &&
         [_renderer labelVisibleOrRevealing:label];
}

// The ring lane's raw component values (per-component defaults when absent).
- (NSArray<NSNumber *> *)_valuesForLabel:(NSString *)label {
  NSArray<NSNumber *> *v = [_renderer valuesForLabel:label];
  if (v.count)
    return v;
  NSDictionary *s = _specByLabel[label];
  int fields = MAX(1, [s[@"fields"] intValue]);
  double mn = [s[@"min"] doubleValue];
  NSMutableArray<NSNumber *> *out = [NSMutableArray array];
  for (int k = 0; k < fields; k++)
    [out addObject:@(mn)];
  return out;
}

// Per-component normalized values (no upper clamp so an unbounded field grows).
- (NSArray<NSNumber *> *)_normsForLabel:(NSString *)label {
  NSDictionary *s = _specByLabel[label];
  double mn = [s[@"min"] doubleValue], mx = [s[@"max"] doubleValue];
  double span = mx - mn;
  NSMutableArray<NSNumber *> *out = [NSMutableArray array];
  for (NSNumber *n in [self _valuesForLabel:label])
    [out
        addObject:@(span > 0.0 ? fmax(0.0, (n.doubleValue - mn) / span) : 0.0)];
  return out;
}

// Whether the lane is currently aspect-linked (the value popover's link glyph
// toggles it). Only meaningful when the field is `linked` (aspect-linkable).
- (BOOL)_laneLinkedForLabel:(NSString *)label {
  // Use the timeline lane's persisted lock ONLY when it carries aspect metadata
  // (a properly template-merged lane that reflects the user's toggle). The
  // mini's timeline is usually the raw blob-derived one where aspectLinkable
  // isn't serialized (=0) and aspectLinked is the un-materialized default (0)
  // rather than the directive's `linked`; there, fall back to the template's
  // aspectLinked so the ring honours the directive default and matches the main
  // viewer.
  for (KKLane *l in _renderer.timeline.lanes)
    if ([l.label isEqualToString:label]) {
      if (l.aspectLinkable)
        return l.aspectLinked;
      break;
    }
  KKLane *tmpl = [_renderer templateLaneForLabel:label];
  return tmpl ? tmpl.aspectLinked : YES;
}

// The ring centre (overlay points): the linked #point's live value when
// `linkLabel` is set, else the fixed `centerX`/`centerY`. Maps through the same
// clip-space helper the point handles use, so a ring and a point at the same
// object coords line up.
- (CGPoint)_centerForSpec:(NSDictionary *)s contentRect:(CGRect)cr {
  NSString *link = s[@"linkLabel"];
  double cx, cy;
  if ([link isKindOfClass:NSString.class] && link.length) {
    NSArray<NSNumber *> *pv = [_renderer valuesForLabel:link];
    cx = pv.count >= 1 ? pv[0].doubleValue : 0.5;
    cy = pv.count >= 2 ? pv[1].doubleValue : 0.5;
  } else {
    cx = [s[@"centerX"] doubleValue];
    cy = [s[@"centerY"] doubleValue];
  }
  return [_renderer handlePointForContentRect:cr position:@[ @(cx), @(cy) ]];
}

// Ring centre (overlay points) + per-axis pixel radii for the current value. A
// vec2 #multi ring is an ellipse (rx=field0, ry=field1); a scalar is a circle.
- (BOOL)_geomForLabel:(NSString *)label
          contentRect:(CGRect)cr
               center:(out CGPoint *)outCenter
              radiusX:(out CGFloat *)outRx
              radiusY:(out CGFloat *)outRy {
  NSDictionary *s = _specByLabel[label];
  if (!s)
    return NO;
  double minDim = MIN(cr.size.width, cr.size.height);
  NSArray<NSNumber *> *norms = [self _normsForLabel:label];
  double nx = norms.count >= 1 ? norms[0].doubleValue : 0.0;
  double ny = norms.count >= 2 ? norms[1].doubleValue : nx;
  if (outCenter)
    *outCenter = [self _centerForSpec:s contentRect:cr];
  if (outRx)
    *outRx = (CGFloat)KKRingOSCExtentForNorm(nx, minDim);
  if (outRy)
    *outRy = (CGFloat)KKRingOSCExtentForNorm(ny, minDim);
  return YES;
}

// The active ring whose (elliptical) stroke is within a few points of `p`, or
// nil.
- (nullable NSString *)_ringLabelAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  for (NSDictionary *s in _specs) {
    NSString *label = s[@"label"];
    if (![self _active:label forContentRect:cr])
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

- (CGFloat)_ghostAlphaForLabel:(NSString *)label {
  // The base ghost dim (0.3) is barely visible for a thin ring; use 0.6 (peek
  // mode returns 1.0, so it stays fully interactive there).
  return [_renderer ghostAlphaForLabel:label] < 1.0 ? 0.6 : 1.0;
}

- (NSArray<NSDictionary<NSString *, id> *> *)ringBundlesForContentRect:
    (CGRect)cr {
  NSMutableArray<NSDictionary<NSString *, id> *> *out = [NSMutableArray array];
  for (NSDictionary *s in _specs) {
    NSString *label = s[@"label"];
    if (![self _active:label forContentRect:cr])
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
    CGFloat alpha = [self _ghostAlphaForLabel:label];
    BOOL ghost = alpha < 0.999;
    NSInteger emphasis =
        ghost ? 0 : ([_activeLabel isEqualToString:label] ? 2 : 0);
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
  BOOL ghost = [_renderer ghostAlphaForLabel:hit] < 1.0;
  // Opt-hover hide/show affordance: only when an Opt-click would actually
  // toggle (Opt held + master on). eye.slash over a visible ring, eye over a
  // ghost.
  BOOL optToggle = _renderer.revealHidden && !_renderer.handlesHidden &&
                   _renderer.onHandleVisibilityToggled != nil;
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
  _activeLabel = hit;
  CGPoint c = [self _centerForSpec:_specByLabel[hit] contentRect:cr];
  _dragStartDx = p.x - c.x;
  _dragStartDy = p.y - c.y;
  _dragStartDist = hypot(_dragStartDx, _dragStartDy);
  _dragStartVals = [self _valuesForLabel:hit];
  [canvas setNeedsDisplay:YES]; // idle -> active stroke
  return YES;
}

- (BOOL)dragToPoint:(CGPoint)p
        contentRect:(CGRect)cr
             canvas:(KKMiniViewerView *)canvas
          modifiers:(NSEventModifierFlags)modifiers {
  if (!_activeLabel)
    return NO;
  NSDictionary *s = _specByLabel[_activeLabel];
  if (!s)
    return YES;
  CGPoint c = [self _centerForSpec:s contentRect:cr];
  double minDim = MIN(cr.size.width, cr.size.height);
  double dx = p.x - c.x, dy = p.y - c.y;
  // Effective aspect lock (lane's persisted lock, Shift-inverted for this
  // drag); the shared math matches the viewer ring exactly.
  BOOL shift = (modifiers & NSEventModifierFlagShift) != 0;
  BOOL laneLinked =
      [s[@"linked"] boolValue] && [self _laneLinkedForLabel:_activeLabel];
  BOOL effLinked = [s[@"linked"] boolValue] ? (laneLinked ^ shift) : NO;
  NSArray<NSNumber *> *newValues = KKRingOSCDragValues(
      [s[@"fields"] intValue], effLinked,
      _dragStartVals.count >= 1 ? _dragStartVals[0].doubleValue : 0,
      _dragStartVals.count >= 2 ? _dragStartVals[1].doubleValue : 0,
      _dragStartDx, _dragStartDy, _dragStartDist, dx, dy, minDim,
      [s[@"min"] doubleValue], [s[@"max"] doubleValue],
      [s[@"bounded"] boolValue], [s[@"isInt"] boolValue]);
  [_renderer commitValues:newValues forLabel:_activeLabel canvas:canvas];
  [canvas setNeedsDisplay:YES];
  return YES;
}

- (BOOL)endDragOnCanvas:(KKMiniViewerView *)canvas {
  if (!_activeLabel)
    return NO;
  _activeLabel = nil;
  [canvas setNeedsDisplay:YES]; // active -> idle stroke
  return YES;
}

- (BOOL)optClickAtPoint:(CGPoint)p
            contentRect:(CGRect)cr
                 canvas:(KKMiniViewerView *)canvas {
  // Hit-test FIRST and CLAIM any ring hit (return YES) even if the visibility
  // callback is missing - otherwise a hit ring falls through to a drag (the
  // overlay drags when optClickHandleAtPoint returns NO). Hide when the
  // callback is wired.
  NSString *hit = [self _ringLabelAtPoint:p contentRect:cr];
  if (!hit)
    return NO;
  if (_renderer.onHandleVisibilityToggled)
    _renderer.onHandleVisibilityToggled(hit);
  [canvas setNeedsDisplay:YES];
  return YES;
}

@end
