/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKBoxOSCSet.h"
#import "KKRadialOSCSet_Protected.h"

#import <KeyframelessKit/KKResizeCursor.h> // KKResizeCursorForBoxHandle, eye cursors
#import <KeyframelessKit/KKScaleGizmo.h> // KKRingOSCExtentForNorm, KKBoxOSCDragValues, KKBoxOSCReadoutString
#import <math.h>

static const CGFloat kBoxHandleHitTolPt = 12.0;
// Cmd-fine drag multiplier (matches the viewer KKBoxOSC / KKScaleOSC).
static const double kBoxMiniFineFactor = 0.2;

@implementation KKBoxOSCSet {
  // Box drag press-anchor (the grabbed handle 0-7 + the scale-box drag state).
  // The active label itself lives in the base.
  NSInteger _grabHandle;
  CGPoint _pressCenter;
  NSArray<NSNumber *> *_pressNorms;
  CGPoint _effCursor; // starts at the grabbed handle (no press snap)
  CGPoint _lastCursor;
}

- (instancetype)initWithRenderer:(KKMiniViewerRenderer *)renderer {
  self = [super initWithRenderer:renderer];
  if (self)
    _grabHandle = -1;
  return self;
}

- (void)setBoxes:(NSArray<NSDictionary<NSString *, id> *> *)boxes {
  self.specs = boxes;
  if (!self.activeLabel)
    _grabHandle = -1;
}

// Box centre + per-axis half-extents for the current value. A vec2 #multi box
// is a rectangle (halfW=field0, halfH=field1); a scalar box is a square.
- (BOOL)_geomForLabel:(NSString *)label
          contentRect:(CGRect)cr
               center:(out CGPoint *)outC
                halfW:(out CGFloat *)outHW
                halfH:(out CGFloat *)outHH {
  NSDictionary *s = [self specForLabel:label];
  if (!s)
    return NO;
  double minDim = MIN(cr.size.width, cr.size.height);
  NSArray<NSNumber *> *norms = [self normsForLabel:label];
  double nx = norms.count >= 1 ? norms[0].doubleValue : 0.0;
  double ny = norms.count >= 2 ? norms[1].doubleValue : nx;
  if (outC)
    *outC = [self centerForSpec:s contentRect:cr];
  if (outHW)
    *outHW = (CGFloat)KKRingOSCExtentForNorm(nx, minDim);
  if (outHH)
    *outHH = (CGFloat)KKRingOSCExtentForNorm(ny, minDim);
  return YES;
}

// The 8 handle centres (0-3 corners BL/BR/TR/TL, 4-7 edges bottom/right/top/
// left) for a box centred at `c` with the given half-extents.
static void kkBoxHandleCenters(CGPoint c, CGFloat hw, CGFloat hh,
                               CGPoint out[8]) {
  double l = c.x - hw, r = c.x + hw, b = c.y - hh, t = c.y + hh;
  out[0] = CGPointMake(l, b);
  out[1] = CGPointMake(r, b);
  out[2] = CGPointMake(r, t);
  out[3] = CGPointMake(l, t);
  out[4] = CGPointMake(c.x, b);
  out[5] = CGPointMake(r, c.y);
  out[6] = CGPointMake(c.x, t);
  out[7] = CGPointMake(l, c.y);
}

- (NSString *)_readoutForLabel:(NSString *)label {
  NSDictionary *s = [self specForLabel:label];
  return KKBoxOSCReadoutString([self valuesForLabel:label],
                               [s[@"isPercent"] boolValue],
                               [s[@"isInt"] boolValue]);
}

- (NSArray<KKMiniBox *> *)boxesForContentRect:(CGRect)cr {
  NSMutableArray<KKMiniBox *> *out = [NSMutableArray array];
  for (NSDictionary *s in self.specs) {
    NSString *label = s[@"label"];
    if (![self isActiveLabel:label forContentRect:cr])
      continue;
    CGPoint c = CGPointZero;
    CGFloat hw = 0, hh = 0;
    if (![self _geomForLabel:label
                 contentRect:cr
                      center:&c
                       halfW:&hw
                       halfH:&hh])
      continue;
    CGPoint h[8];
    kkBoxHandleCenters(c, hw, hh, h);
    NSMutableArray<NSValue *> *centers = [NSMutableArray arrayWithCapacity:8];
    for (int i = 0; i < 8; i++)
      [centers addObject:[NSValue valueWithPoint:NSPointFromCGPoint(h[i])]];
    [out addObject:[KKMiniBox boxWithRect:CGRectMake(c.x - hw, c.y - hh, 2 * hw,
                                                     2 * hh)
                            handleCenters:centers
                                  readout:[self _readoutForLabel:label]
                               ghostAlpha:[self ghostAlphaForLabel:label]]];
  }
  return out;
}

// The active box + handle under `p`, or nil. Sets `*outIdx` to the handle.
- (nullable NSString *)_handleAtPoint:(CGPoint)p
                          contentRect:(CGRect)cr
                             outIndex:(NSInteger *)outIdx {
  for (NSDictionary *s in self.specs) {
    NSString *label = s[@"label"];
    if (![self isActiveLabel:label forContentRect:cr])
      continue;
    CGPoint c = CGPointZero;
    CGFloat hw = 0, hh = 0;
    if (![self _geomForLabel:label
                 contentRect:cr
                      center:&c
                       halfW:&hw
                       halfH:&hh])
      continue;
    CGPoint h[8];
    kkBoxHandleCenters(c, hw, hh, h);
    NSInteger best =
        [self.renderer nearestHandleIndexToPoint:p
                                         centers:h
                                           count:8
                                       tolerance:kBoxHandleHitTolPt];
    if (best != NSNotFound) {
      if (outIdx)
        *outIdx = best;
      return label;
    }
  }
  return nil;
}

- (BOOL)handleHitAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  return [self cursorAtPoint:p contentRect:cr] != nil;
}

- (NSCursor *)cursorAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  NSInteger idx = -1;
  NSString *hit = [self _handleAtPoint:p contentRect:cr outIndex:&idx];
  if (!hit)
    return nil;
  BOOL ghost = [self.renderer ghostAlphaForLabel:hit] < 1.0;
  BOOL optToggle = self.renderer.revealHidden && !self.renderer.handlesHidden &&
                   self.renderer.onHandleVisibilityToggled != nil;
  if (optToggle)
    return ghost ? KKVisibilityShowCursor() : KKVisibilityHideCursor();
  if (ghost)
    return [NSCursor arrowCursor];
  return KKResizeCursorForBoxHandle(idx);
}

- (BOOL)beginDragAtPoint:(CGPoint)p
             contentRect:(CGRect)cr
                  canvas:(KKMiniViewerView *)canvas {
  NSInteger idx = -1;
  NSString *hit = [self _handleAtPoint:p contentRect:cr outIndex:&idx];
  if (!hit)
    return NO;
  self.activeLabel = hit;
  _grabHandle = idx;
  CGPoint c = CGPointZero;
  CGFloat hw = 0, hh = 0;
  [self _geomForLabel:hit contentRect:cr center:&c halfW:&hw halfH:&hh];
  _pressCenter = c;
  _pressNorms = [self normsForLabel:hit];
  CGPoint h[8];
  kkBoxHandleCenters(c, hw, hh, h);
  // Effective cursor starts at the grabbed handle so the value begins where it
  // is (no press snap); the drag advances it by the raw cursor delta.
  _effCursor = (idx >= 0 && idx < 8) ? h[idx] : p;
  _lastCursor = p;
  [canvas setNeedsDisplay:YES];
  return YES;
}

- (BOOL)dragToPoint:(CGPoint)p
        contentRect:(CGRect)cr
             canvas:(KKMiniViewerView *)canvas
          modifiers:(NSEventModifierFlags)modifiers {
  NSString *active = self.activeLabel;
  if (!active || _grabHandle < 0)
    return NO;
  NSDictionary *s = [self specForLabel:active];
  if (!s)
    return YES;
  double rawDx = p.x - _lastCursor.x, rawDy = p.y - _lastCursor.y;
  _lastCursor = p;
  double fine =
      (modifiers & NSEventModifierFlagCommand) ? kBoxMiniFineFactor : 1.0;
  _effCursor =
      CGPointMake(_effCursor.x + rawDx * fine, _effCursor.y + rawDy * fine);
  double minDim = MIN(cr.size.width, cr.size.height);
  double candNX =
      KKRingOSCNormForExtent(fabs(_effCursor.x - _pressCenter.x), minDim);
  double candNY =
      KKRingOSCNormForExtent(fabs(_effCursor.y - _pressCenter.y), minDim);
  double pNX = _pressNorms.count >= 1 ? _pressNorms[0].doubleValue : 0;
  double pNY = _pressNorms.count >= 2 ? _pressNorms[1].doubleValue : pNX;
  BOOL shift = (modifiers & NSEventModifierFlagShift) != 0;
  BOOL laneLinked =
      [s[@"linked"] boolValue] && [self laneLinkedForLabel:active];
  BOOL effLinked = [s[@"linked"] boolValue] ? (laneLinked ^ shift) : NO;
  NSArray<NSNumber *> *newValues = KKBoxOSCDragValues(
      _grabHandle, [s[@"fields"] intValue], effLinked, pNX, pNY, candNX, candNY,
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
  _grabHandle = -1;
  [canvas setNeedsDisplay:YES];
  return YES;
}

- (BOOL)optClickAtPoint:(CGPoint)p
            contentRect:(CGRect)cr
                 canvas:(KKMiniViewerView *)canvas {
  // Claim any handle hit (return YES) even without a visibility callback, so a
  // hit box never falls through to a drag. Hide when the callback is wired.
  NSString *hit = [self _handleAtPoint:p contentRect:cr outIndex:NULL];
  if (!hit)
    return NO;
  if (self.renderer.onHandleVisibilityToggled)
    self.renderer.onHandleVisibilityToggled(hit);
  [canvas setNeedsDisplay:YES];
  return YES;
}

@end
