/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKAnchorMiniController.h"
#import <KeyframelessKit/KKSnapEngine.h>
#import <simd/simd.h>

@implementation KKAnchorMiniController {
  KKSnapEngine *_snap;
  BOOL _grabbed;
  double _grabValX, _grabValY; // anchor value at mouseDown
  double _pressNX, _pressNY;   // cursor's normalised content position at press
}

- (instancetype)initWithRenderer:(KKMiniViewerRenderer *)renderer
                       laneLabel:(NSString *)laneLabel
               positionLaneLabel:(NSString *)positionLaneLabel
                      snapEngine:(KKSnapEngine *)snapEngine {
  self = [super init];
  if (self) {
    _renderer = renderer;
    _laneLabel = [laneLabel copy];
    _positionLaneLabel = [positionLaneLabel copy];
    _snap = snapEngine;
    _hitRadiusPt = 5.0;
  }
  return self;
}

- (BOOL)isDragging {
  return _grabbed;
}

- (void)_anchorX:(double *)outAX y:(double *)outAY {
  NSArray<NSNumber *> *anc = [self.renderer valuesForLabel:self.laneLabel];
  *outAX = anc.count > 0 ? anc[0].doubleValue : 0.5;
  *outAY = anc.count > 1 ? anc[1].doubleValue : 0.5;
}

- (void)_positionX:(double *)outPX y:(double *)outPY {
  NSArray<NSNumber *> *pos = [self.renderer valuesForLabel:self.positionLaneLabel];
  *outPX = pos.count > 0 ? pos[0].doubleValue : 0.5;
  *outPY = pos.count > 1 ? pos[1].doubleValue : 0.5;
}

// The square shows when the Anchor lane is a constant (a single fixed pivot) and
// not hidden - same convention as the other single-handle mini OSCs (animated
// lanes draw keypose dots instead).
- (BOOL)squareShown {
  return [self.renderer isConstantLabel:self.laneLabel] &&
         [self.renderer labelVisibleOrRevealing:self.laneLabel];
}

- (CGFloat)ghostAlpha {
  return [self.renderer ghostAlphaForLabel:self.laneLabel];
}

- (BOOL)squareCenter:(out CGPoint *)outCenter forContentRect:(CGRect)cr {
  if (CGRectIsEmpty(cr) || ![self squareShown])
    return NO;
  if (self.centerOverride) {
    if (outCenter)
      *outCenter = self.centerOverride(cr);
    return YES;
  }
  double px = 0.5, py = 0.5, ax = 0.5, ay = 0.5;
  [self _positionX:&px y:&py];
  [self _anchorX:&ax y:&ay];
  // Pivot = content centre (Position) + Anchor offset, in the same normalised
  // clip space as the path anchors.
  CGPoint c = [self.renderer handlePointForContentRect:cr
                                              position:@[ @(px + ax - 0.5),
                                                          @(py + ay - 0.5) ]];
  if (outCenter)
    *outCenter = c;
  return YES;
}

- (BOOL)squareHitAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  CGPoint c;
  if (![self squareCenter:&c forContentRect:cr])
    return NO;
  // Tight to the drawn square (Chebyshev), well under the Position handle's grab
  // so the arc ring around the small square still reaches Position - mirroring
  // the viewer. Scale by the OSC SIZING height (the constant-screen-size metric
  // the square's DRAW + the Position arc use), NOT the live bounds: on an
  // enlarged popover the live bounds grow but the drawn square stays a constant
  // screen size, so a bounds-scaled hit zone would balloon past the square and
  // into the Position ring - the intermittent "anchor steals Position" clash.
  CGFloat h = self.renderer.canvas.oscSizingHeight;
  CGFloat scale = h > 0 ? h / 230.0 : 1.0;
  CGFloat r = self.hitRadiusPt * scale;
  return fmax(fabs(p.x - c.x), fabs(p.y - c.y)) < r;
}

- (BOOL)beginDragAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  _grabbed = NO;
  if (![self squareHitAtPoint:p contentRect:cr])
    return NO;
  _grabbed = YES;
  [self _anchorX:&_grabValX y:&_grabValY];
  if (self.viewToValue && cr.size.width > 0 && cr.size.height > 0) {
    simd_float2 v = self.viewToValue(p, cr);
    _pressNX = v.x;
    _pressNY = v.y;
  } else {
    if (cr.size.width > 0)
      _pressNX = (p.x - CGRectGetMinX(cr)) / cr.size.width;
    if (cr.size.height > 0)
      _pressNY = (p.y - CGRectGetMinY(cr)) / cr.size.height;
  }
  return YES;
}

// Delta drag: the anchor value moves by the cursor's normalised offset from the
// grab point. Cmd snaps the PIVOT (Position + Anchor offset) to the clip's
// centre / corners / edge-midpoints / thirds, routed through the shared snap
// engine so the canvas strokes the yellow guide lines.
- (void)applyDragToPoint:(CGPoint)p
             contentRect:(CGRect)cr
               modifiers:(NSEventModifierFlags)modifiers
                  canvas:(KKMiniViewerView *)canvas {
  if (!_grabbed || cr.size.width <= 0 || cr.size.height <= 0)
    return;
  double nx, ny;
  if (self.viewToValue) {
    simd_float2 v = self.viewToValue(p, cr);
    nx = v.x;
    ny = v.y;
  } else {
    nx = (p.x - CGRectGetMinX(cr)) / cr.size.width;
    ny = (p.y - CGRectGetMinY(cr)) / cr.size.height;
  }
  double newX = _grabValX + (nx - _pressNX);
  double newY = _grabValY + (ny - _pressNY);
  if (modifiers & NSEventModifierFlagCommand) {
    double posX = 0.5, posY = 0.5;
    [self _positionX:&posX y:&posY];
    static const double frac[] = {0.0, 1.0 / 3.0, 0.5, 2.0 / 3.0, 1.0};
    float ax[5], ay[5];
    for (int i = 0; i < 5; i++) {
      ax[i] = (float)(posX + frac[i] - 0.5);
      ay[i] = (float)(posY + frac[i] - 0.5);
    }
    float thrX = 6.0f / (float)cr.size.width;
    float thrY = 6.0f / (float)cr.size.height;
    simd_float2 pivot = {(float)(posX + newX - 0.5), (float)(posY + newY - 0.5)};
    simd_float2 sn = [_snap snapPoint:pivot
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
  } else if (self.gridSnapPivot) {
    double posX = 0.5, posY = 0.5;
    [self _positionX:&posX y:&posY];
    simd_float2 pivot = {(float)(posX + newX - 0.5), (float)(posY + newY - 0.5)};
    simd_float2 sn = self.gridSnapPivot(pivot, cr);
    newX = sn.x - posX + 0.5;
    newY = sn.y - posY + 0.5;
    [_snap reset];
  } else {
    [_snap reset];
  }
  [self.renderer commitValues:@[ @(newX), @(newY) ]
                     forLabel:self.laneLabel
                       canvas:canvas];
}

- (void)endDrag {
  _grabbed = NO;
  [_snap reset];
}

@end
