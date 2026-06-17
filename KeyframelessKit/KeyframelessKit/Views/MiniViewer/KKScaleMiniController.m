/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKScaleMiniController.h"
#import <KeyframelessKit/KKScaleGizmo.h>
#import <KeyframelessKit/KKTimingStage.h>

static const CGFloat kHandleHitTolPt = 12.0;
// Cmd-fine drag multiplier (matches the viewer KKScaleOSC).
static const double kMiniScaleFineFactor = 0.2;

@implementation KKScaleMiniController {
  BOOL _grabbed;
  NSInteger _grabHandle; // 0-7
  CGPoint _pressCenter;
  double _pressSclX, _pressSclY;
  CGPoint _effCursor; // starts at the grabbed handle (no press snap)
  CGPoint _lastCursor;
}

- (instancetype)initWithRenderer:(KKMiniViewerRenderer *)renderer
                       laneLabel:(NSString *)laneLabel {
  self = [super init];
  if (self) {
    _renderer = renderer;
    _laneLabel = [laneLabel copy];
    _grabHandle = -1;
  }
  return self;
}

- (BOOL)isDragging {
  return _grabbed;
}

- (nullable KKLane *)_liveLane {
  for (KKLane *lane in self.renderer.timeline.lanes)
    if ([lane.label isEqualToString:self.laneLabel])
      return lane;
  return nil;
}

// Aspect-link for a drag: the live lane if present, else the plugin template.
// An untouched default constant has no lane in the renderer's sparse timeline,
// so a bare read would drop the lock; a present lane wins so a user-unlinked
// scale stays unlinked. Mirrors KKScaleOSC.
- (BOOL)_aspectLinked {
  KKLane *lane = [self _liveLane];
  return (lane ? lane.aspectLinked
               : [self.renderer templateLaneForLabel:self.laneLabel]
                     .aspectLinked) != 0;
}

- (BOOL)boxShown {
  KKMiniViewerRenderer *r = self.renderer;
  if ([r.suppressedHandleLabels containsObject:self.laneLabel])
    return NO;
  // Only when Scale is "active" in the current popover mode: a constant in the
  // constants popover, animated in the keypose popover. Without this an
  // animated Scale's box wrongly shows in the constants popover.
  if (![r isConstantLabel:self.laneLabel])
    return NO;
  // `labelVisibleOrRevealing:` already handles the master tick AND the
  // master-off Opt "peek and use" reveal (mirrors how the base gates Position /
  // rotation). A separate `handlesHidden` short-circuit here would defeat the
  // peek, hiding the scale box when every other OSC reveals.
  return [r labelVisibleOrRevealing:self.laneLabel];
}

- (CGFloat)ghostAlpha {
  return [self.renderer ghostAlphaForLabel:self.laneLabel];
}

- (nullable NSString *)readoutText {
  if (![self boxShown])
    return nil;
  NSArray<NSNumber *> *sv = [self.renderer valuesForLabel:self.laneLabel];
  double sclX = sv.count > 0 ? fmax(0.0, sv[0].doubleValue) : 100.0;
  double sclY = sv.count > 1 ? fmax(0.0, sv[1].doubleValue) : 100.0;
  return [NSString stringWithFormat:@"%.0f%% x %.0f%%", sclX, sclY];
}

- (BOOL)boxRect:(out CGRect *)outRect forContentRect:(CGRect)cr {
  if (![self boxShown] || cr.size.width <= 0 || cr.size.height <= 0)
    return NO;
  CGPoint center = [self.renderer rotationCenterForContentRect:cr];
  // Size off the content rect (which scales with the preview's zoom/pan) so the
  // box grows/shrinks with the clip like the viewer box does.
  double crMin = MIN(cr.size.width, cr.size.height);
  double e0 = crMin * KKScaleGizmoE0Frac, span = crMin * KKScaleGizmoSpanFrac;
  NSArray<NSNumber *> *sv = [self.renderer valuesForLabel:self.laneLabel];
  double sclX = sv.count > 0 ? fmax(0.0, sv[0].doubleValue) : 100.0;
  double sclY = sv.count > 1 ? fmax(0.0, sv[1].doubleValue) : 100.0;
  double halfW = KKScaleGizmoExtentForPercent(sclX, e0, span);
  double halfH = KKScaleGizmoExtentForPercent(sclY, e0, span);
  if (outRect)
    *outRect =
        CGRectMake(center.x - halfW, center.y - halfH, 2 * halfW, 2 * halfH);
  return YES;
}

// Fills out[8] with the handle centres (0-3 corners BL/BR/TR/TL, 4-7 edges
// bottom/right/top/left) in overlay points. NO if the box isn't shown.
- (BOOL)_handlePositions:(CGPoint *)out forContentRect:(CGRect)cr {
  CGRect sb;
  if (![self boxRect:&sb forContentRect:cr])
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

- (NSArray<NSValue *> *)handleCentersForContentRect:(CGRect)cr {
  CGPoint h[8];
  if (![self _handlePositions:h forContentRect:cr])
    return @[];
  NSMutableArray<NSValue *> *out = [NSMutableArray arrayWithCapacity:8];
  for (int i = 0; i < 8; i++)
    [out addObject:[NSValue valueWithPoint:NSPointFromCGPoint(h[i])]];
  return out;
}

- (nullable NSArray<NSValue *> *)handleCentersForValues:
                                     (NSArray<NSNumber *> *)values
                                            contentRect:(CGRect)cr {
  if (![self boxShown] || cr.size.width <= 0 || cr.size.height <= 0)
    return nil;
  double sclX = values.count > 0 ? fmax(0.0, values[0].doubleValue) : 100.0;
  double sclY = values.count > 1 ? fmax(0.0, values[1].doubleValue) : sclX;
  CGPoint center = [self.renderer rotationCenterForContentRect:cr];
  double crMin = MIN(cr.size.width, cr.size.height);
  double e0 = crMin * KKScaleGizmoE0Frac, span = crMin * KKScaleGizmoSpanFrac;
  CGPoint h[8];
  KKScaleHandlePositions(center, sclX, sclY, e0, span, h);
  NSMutableArray<NSValue *> *out = [NSMutableArray arrayWithCapacity:8];
  for (int i = 0; i < 8; i++)
    [out addObject:[NSValue valueWithPoint:NSPointFromCGPoint(h[i])]];
  return out;
}

- (BOOL)handleHitAtPoint:(CGPoint)p
             contentRect:(CGRect)cr
                outIndex:(nullable NSInteger *)outIdx {
  CGPoint h[8];
  if (![self _handlePositions:h forContentRect:cr])
    return NO;
  NSInteger best = [self.renderer nearestHandleIndexToPoint:p
                                                    centers:h
                                                      count:8
                                                  tolerance:kHandleHitTolPt];
  if (best == NSNotFound)
    return NO;
  if (outIdx)
    *outIdx = best;
  return YES;
}

- (BOOL)beginDragAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  NSInteger idx;
  if (![self handleHitAtPoint:p contentRect:cr outIndex:&idx])
    return NO;
  _grabbed = YES;
  _grabHandle = idx;
  _pressCenter = [self.renderer rotationCenterForContentRect:cr];
  NSArray<NSNumber *> *sv = [self.renderer valuesForLabel:self.laneLabel];
  _pressSclX = sv.count > 0 ? fmax(0.0, sv[0].doubleValue) : 100.0;
  _pressSclY = sv.count > 1 ? fmax(0.0, sv[1].doubleValue) : 100.0;
  // Effective cursor starts at the grabbed handle (no press snap).
  CGPoint h[8];
  [self _handlePositions:h forContentRect:cr];
  _effCursor = h[idx];
  _lastCursor = p;
  return YES;
}

// Absolute drag (effective cursor tracks the grabbed handle; Cmd = fine) with
// link-aware coupling (Shift inverts) and integer snapping - mirrors the
// viewer.
- (void)applyDragToPoint:(CGPoint)p
             contentRect:(CGRect)cr
               modifiers:(NSEventModifierFlags)modifiers
                  canvas:(KKMiniViewerView *)canvas {
  NSInteger h = _grabHandle;
  if (h < 0 || cr.size.width <= 0 || cr.size.height <= 0)
    return;
  double rawDx = p.x - _lastCursor.x, rawDy = p.y - _lastCursor.y;
  _lastCursor = p;
  double fine =
      (modifiers & NSEventModifierFlagCommand) ? kMiniScaleFineFactor : 1.0;
  _effCursor =
      CGPointMake(_effCursor.x + rawDx * fine, _effCursor.y + rawDy * fine);
  CGPoint c = _pressCenter;
  double crMin = MIN(cr.size.width, cr.size.height);
  double e0 = crMin * KKScaleGizmoE0Frac, span = crMin * KKScaleGizmoSpanFrac;
  double tX = KKScaleGizmoPercentForExtent(fabs(_effCursor.x - c.x), e0, span);
  double tY = KKScaleGizmoPercentForExtent(fabs(_effCursor.y - c.y), e0, span);
  BOOL shift = (modifiers & NSEventModifierFlagShift) != 0;
  BOOL effLinked = [self _aspectLinked] ^ shift;
  double newX = 0, newY = 0;
  KKScaleValuesForHandleDrag(h, _pressSclX, _pressSclY, tX, tY, effLinked,
                             &newX, &newY);
  [self.renderer commitValues:@[ @(newX), @(newY) ]
                     forLabel:self.laneLabel
                       canvas:canvas];
}

- (void)endDrag {
  _grabbed = NO;
  _grabHandle = -1;
}

@end
