/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPointOSCSet.h"

#import <KeyframelessKit/KKPluginHost.h> // KKProcessFrameDurationSeconds
#import <KeyframelessKit/KKPositionMiniController.h>
#import <KeyframelessKit/KKResizeCursor.h> // KKPointMoveCursor
#import <KeyframelessKit/KKTimeline.h>
#import <KeyframelessKit/KKTimingEvaluation.h> // KKLaneKeyedAtFraction

@implementation KKPointOSCSet {
  __weak KKMiniViewerRenderer *_renderer;
  NSArray<KKPositionMiniController *> *_controllers;
  NSString *_signature; // newline-joined labels, so setLaneLabels: is a no-op
                        // when the set is unchanged
  // The controller currently being dragged (handle or path anchor/tangent).
  KKPositionMiniController *_active;
}

- (instancetype)initWithRenderer:(KKMiniViewerRenderer *)renderer {
  self = [super init];
  if (self) {
    _renderer = renderer;
    _controllers = @[];
    _signature = @"";
  }
  return self;
}

- (NSArray<KKPositionMiniController *> *)controllers {
  return _controllers;
}

- (void)setLaneLabels:(NSArray<NSString *> *)laneLabels {
  NSString *sig = [laneLabels componentsJoinedByString:@"\n"];
  if ([sig isEqualToString:_signature])
    return; // same set - keep the controllers + any in-flight drag
  _signature = [sig copy];
  NSMutableDictionary<NSString *, KKPositionMiniController *> *byLabel =
      [NSMutableDictionary dictionary];
  for (KKPositionMiniController *c in _controllers)
    byLabel[c.laneLabel] = c;
  NSMutableArray<KKPositionMiniController *> *next = [NSMutableArray array];
  for (NSString *label in laneLabels) {
    KKPositionMiniController *c =
        byLabel[label]
            ?: [[KKPositionMiniController alloc]
                   initWithRenderer:_renderer
                          laneLabel:label
                          pathLabel:[label stringByAppendingString:@" Path"]];
    [next addObject:c];
  }
  _controllers = next;
}

#pragma mark - Per-point visibility gates (mirror KKPositionOSC)

// Editing-context (mode) gate: constant lanes in the Constants popover,
// animated lanes in a keypose/boundary popover.
- (BOOL)_contextActive:(NSString *)label {
  return label.length && [_renderer isConstantLabel:label];
}

// The PATH (line + anchor dots) shows whenever the lane matches the context and
// its "<lane> Path" element isn't hidden - at EVERY fraction, independent of
// the handle (so hiding Path keeps the handle and vice versa).
- (BOOL)_pathActive:(NSString *)label {
  return [self _contextActive:label] &&
         [_renderer
             labelVisibleOrRevealing:[label stringByAppendingString:@" Path"]];
}

// The ARC HANDLE also needs the lane's own visibility AND the lane sitting
// exactly ON a keypose at editFraction - so a lane between/past its keyposes
// (incl. its flat lead-out) shows just its path + anchors, no arc.
- (BOOL)_handleActive:(NSString *)label {
  if (![self _contextActive:label] ||
      ![_renderer labelVisibleOrRevealing:label])
    return NO;
  KKLane *lane = nil;
  for (KKLane *l in _renderer.timeline.lanes)
    if ([l.key isEqualToString:label]) {
      lane = l;
      break;
    }
  return KKLaneKeyedAtFraction(lane, _renderer.editFraction,
                               KKProcessFrameDurationSeconds());
}

// The controller whose ARC handle is under `p` (only ones active this frame),
// or nil.
- (KKPositionMiniController *)_handleHitAtPoint:(CGPoint)p
                                    contentRect:(CGRect)cr {
  for (KKPositionMiniController *c in _controllers)
    if ([self _handleActive:c.laneLabel] && [c pointHandleHitAtPoint:p
                                                         contentRect:cr])
      return c;
  return nil;
}

// The controller whose motion-path anchor / tangent is under `p`, or nil.
- (KKPositionMiniController *)_pathHitAtPoint:(CGPoint)p
                                  contentRect:(CGRect)cr {
  for (KKPositionMiniController *c in _controllers)
    if ([self _pathActive:c.laneLabel] &&
        ([c pathHandleHitAtPoint:p contentRect:cr] ||
         [c pathAnchorHitAtPoint:p contentRect:cr]))
      return c;
  return nil;
}

#pragma mark - Draw geometry

- (NSArray<NSDictionary<NSString *, id> *> *)handleGlyphsForContentRect:
    (CGRect)cr {
  NSMutableArray<NSDictionary<NSString *, id> *> *out = [NSMutableArray array];
  for (KKPositionMiniController *c in _controllers) {
    CGPoint centre = CGPointZero;
    if ([self _handleActive:c.laneLabel] && [c pointHandleCenter:&centre
                                                  forContentRect:cr])
      [out addObject:@{
        @"center" : [NSValue valueWithPoint:centre],
        // ghostAlphaForLabel dims an Opt-revealed hidden handle to a ghost, the
        // same as the base's pointHandleGhostAlpha did for the old primary.
        @"alpha" : @([_renderer ghostAlphaForLabel:c.laneLabel]),
      }];
  }
  return out;
}

- (BOOL)activeHandleCenter:(out CGPoint *)outCenter forContentRect:(CGRect)cr {
  for (KKPositionMiniController *c in _controllers)
    if ([self _handleActive:c.laneLabel] && [c pointHandleCenter:outCenter
                                                  forContentRect:cr])
      return YES;
  return NO;
}

- (BOOL)activeHandleCenter:(out CGPoint *)outCenter
                 forValues:(NSArray<NSNumber *> *)values
            forContentRect:(CGRect)cr {
  for (KKPositionMiniController *c in _controllers)
    if ([self _handleActive:c.laneLabel] && [c pointHandleCenter:outCenter
                                                       forValues:values
                                                  forContentRect:cr])
      return YES;
  return NO;
}

- (NSArray<NSDictionary<NSString *, id> *> *)motionPathBundlesForContentRect:
    (CGRect)cr {
  NSMutableArray<NSDictionary<NSString *, id> *> *out = [NSMutableArray array];
  for (KKPositionMiniController *c in _controllers) {
    if (![self _pathActive:c.laneLabel])
      continue;
    [out addObject:@{
      @"poly" : [c motionPathPolylineForContentRect:cr] ?: @[],
      @"segs" : [c motionPathHandleSegmentsForContentRect:cr] ?: @[],
      @"anchors" : [c motionPathAnchorsForContentRect:cr] ?: @[],
      @"alpha" : @([_renderer ghostAlphaForLabel:c.pathLabel]),
    }];
  }
  return out;
}

#pragma mark - Interaction

- (BOOL)handleHitAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  return [self cursorAtPoint:p contentRect:cr] != nil;
}

- (NSCursor *)cursorAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  KKPositionMiniController *handle = [self _handleHitAtPoint:p contentRect:cr];
  if (handle)
    return [_renderer kkVisibilityCursorForLabel:handle.laneLabel]
               ?: KKPointMoveCursor();
  KKPositionMiniController *path = [self _pathHitAtPoint:p contentRect:cr];
  if (path)
    return [_renderer kkVisibilityCursorForLabel:path.pathLabel]
               ?: KKPointMoveCursor();
  return nil;
}

- (BOOL)beginDragAtPoint:(CGPoint)p
             contentRect:(CGRect)cr
                  canvas:(KKMiniViewerView *)canvas {
  // Handle grabs first (matches the hit-test priority) so a coincident path
  // anchor doesn't steal it; then the motion-path anchors / tangents.
  KKPositionMiniController *handle = [self _handleHitAtPoint:p contentRect:cr];
  if (handle) {
    _active = handle;
    // Grab ONLY - deliberately no apply on mouse-down. The drag is delta-based,
    // so applying at the press point is a no-op for the grabbed keypose, but
    // the commit still runs KKLaneBySettingValuesAtIndex's HOLD-LINK
    // propagation, which stamps this keypose's value onto its linked
    // neighbours. A mere click therefore collapsed a linked pair onto one
    // point, flattening the segment between them - which read as a
    // just-smoothed arc snapping back to linear (spatialSmooth stayed set the
    // whole time, the geometry was what got destroyed).
    [handle beginPointDragAtPoint:p contentRect:cr];
    return YES;
  }
  KKPositionMiniController *path = [self _pathHitAtPoint:p contentRect:cr];
  if (path && [path beginPathDragAtPoint:p contentRect:cr]) {
    _active = path;
    return YES;
  }
  return NO;
}

- (BOOL)dragToPoint:(CGPoint)p
        contentRect:(CGRect)cr
             canvas:(KKMiniViewerView *)canvas
          modifiers:(NSEventModifierFlags)modifiers {
  if (!_active)
    return NO;
  if (_active.pathGrabbed)
    [_active applyPathDragToPoint:p contentRect:cr modifiers:modifiers];
  else
    [_active applyPointDragToPoint:p
                       contentRect:cr
                            canvas:canvas
                         modifiers:modifiers];
  return YES;
}

- (BOOL)endDragOnCanvas:(KKMiniViewerView *)canvas {
  if (!_active)
    return NO;
  // A point-handle drag already committed each value per-tick; a path drag
  // needs the whole blob persisted, which endDrag signals by returning YES.
  BOOL wasPathDrag = [_active endDrag];
  _active = nil;
  if (wasPathDrag && _renderer.onTimelinePersist)
    _renderer.onTimelinePersist(_renderer.timeline);
  [canvas setNeedsDisplay:YES];
  [canvas setHandlesNeedDisplay];
  return YES;
}

- (BOOL)doubleClickAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  KKPositionMiniController *c = [self _handleHitAtPoint:p contentRect:cr]
                                    ?: [self _pathHitAtPoint:p contentRect:cr];
  return [c toggleSmoothAtPoint:p contentRect:cr];
}

- (BOOL)optClickAtPoint:(CGPoint)p
            contentRect:(CGRect)cr
                 canvas:(KKMiniViewerView *)canvas {
  if (!_renderer.onHandleVisibilityToggled)
    return NO;
  // The handle claims the opt-click first (matches the viewer, where the handle
  // wins over a coincident path anchor); then the path toggles its own element.
  KKPositionMiniController *handle = [self _handleHitAtPoint:p contentRect:cr];
  NSString *key = handle.laneLabel;
  if (!key) {
    KKPositionMiniController *path = [self _pathHitAtPoint:p contentRect:cr];
    key = path.pathLabel;
  }
  if (!key)
    return NO;
  _renderer.onHandleVisibilityToggled(key);
  [canvas setNeedsDisplay:YES];
  [canvas setHandlesNeedDisplay];
  return YES;
}

- (void)snapGuideHasX:(out BOOL *)hasX
                    X:(out CGFloat *)outX
         fromKeyposeX:(out BOOL *)fromKeyposeX
                 hasY:(out BOOL *)hasY
                    Y:(out CGFloat *)outY
         fromKeyposeY:(out BOOL *)fromKeyposeY {
  [(_active ?: _controllers.firstObject) snapGuideHasX:hasX
                                                     X:outX
                                          fromKeyposeX:fromKeyposeX
                                                  hasY:hasY
                                                     Y:outY
                                          fromKeyposeY:fromKeyposeY];
}

@end
