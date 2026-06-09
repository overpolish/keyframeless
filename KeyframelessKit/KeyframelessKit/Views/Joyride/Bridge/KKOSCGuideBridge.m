/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKOSCGuideBridge.h"
#import "KKLog.h"
#import <QuartzCore/QuartzCore.h>

@implementation KKOSCGuideBridge {
  NSInteger _guideStep;

  NSPoint _handleScreenPos;
  BOOL _hasHandleScreenPos;
  NSPoint _targetScreenPos;
  BOOL _hasTargetScreenPos;
  NSRect _viewerImageScreenRect;

  // Screen↔canvas reference captured from the last hitTest / re-anchor.
  BOOL _hasCanvasRef;
  double _refMouseScreenX, _refMouseScreenY;
  double _refMouseCanvasX, _refMouseCanvasY;
  double _refSpC;

  // Live canvas scale refreshed every draw tick (survives zoom-to-fit even
  // when no hitTest runs; the hitTest ref above goes stale the moment the
  // guide overlay starts intercepting the mouse).
  double _freshSpC;
  BOOL _hasFreshSpC;

  // Previous hitTest screen sample + timestamp for the velocity gate.
  NSPoint _lastHitMouseScreen;
  CFTimeInterval _lastHitTs;

  CFTimeInterval _lastDrawTs;
  CFTimeInterval _lastNotifyTs;

  CGPoint _canvasTR, _canvasBL;
  BOOL _geometryValid;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _spotlightHandleRadius = 30.0;
    _targetVisibleAtStep = 2;
    _canvasRefStaleWindow = 15.0;
    _hitReanchorMaxVelocity = 200.0;
    _refSpC = 1.0;
    _freshSpC = 1.0;
  }
  return self;
}

- (NSNotificationName)guideStepNotificationName {
  return @"co.overpolish.kk.oscGuideStep";
}

- (NSNotificationName)guidePositionNotificationName {
  return @"co.overpolish.kk.oscGuidePosition";
}

- (NSInteger)guideStep {
  return _guideStep;
}

- (void)setGuideStep:(NSInteger)step {
  _guideStep = step;
  if (step == 0 || step == 1)
    _hasHandleScreenPos = NO;
  NSNotificationName name = self.guideStepNotificationName;
  dispatch_async(dispatch_get_main_queue(), ^{
    [[NSNotificationCenter defaultCenter] postNotificationName:name
                                                        object:nil
                                                      userInfo:@{
                                                        @"step" : @(step)
                                                      }];
  });
}

- (BOOL)hasCanvasReference {
  if (_lastDrawTs == 0.0)
    return NO;
  return (CACurrentMediaTime() - _lastDrawTs) < _canvasRefStaleWindow;
}

- (NSRect)estimatedHandleScreenRect {
  if (!_hasHandleScreenPos)
    return NSZeroRect;
  CGFloat r = _spotlightHandleRadius;
  return NSMakeRect(_handleScreenPos.x - r, _handleScreenPos.y - r, r * 2.0,
                    r * 2.0);
}

- (NSRect)estimatedViewerScreenRect {
  return _viewerImageScreenRect;
}

- (NSRect)estimatedTargetScreenRect {
  // The target only exists once the user has clicked (the drag step). Before
  // that the joyride pill must not draw a capsule to it.
  if (_guideStep != _targetVisibleAtStep || !_hasTargetScreenPos)
    return NSZeroRect;
  CGFloat r = _spotlightHandleRadius;
  return NSMakeRect(_targetScreenPos.x - r, _targetScreenPos.y - r, r * 2.0,
                    r * 2.0);
}

- (CGPoint)currentCanvasTopRight {
  return _canvasTR;
}
- (CGPoint)currentCanvasBottomLeft {
  return _canvasBL;
}
- (BOOL)geometryValid {
  return _geometryValid;
}

- (BOOL)screenToCanvas:(NSPoint)screenPt
                  outX:(double *)outX
                  outY:(double *)outY {
  if (!_hasCanvasRef) {
    KKLogWarn(@"[OSCGuide] screenToCanvas: no canvas ref");
    return NO;
  }
  *outX = _refMouseCanvasX + (screenPt.x - _refMouseScreenX) / _refSpC;
  *outY = _refMouseCanvasY + (screenPt.y - _refMouseScreenY) / _refSpC;
  return YES;
}

- (BOOL)reanchorAtScreen:(NSPoint)screenPt handleCanvasPos:(CGPoint)handle {
  if (!_hasFreshSpC)
    return NO;
  _refMouseScreenX = screenPt.x;
  _refMouseScreenY = screenPt.y;
  _refMouseCanvasX = handle.x;
  _refMouseCanvasY = handle.y;
  _refSpC = _freshSpC;
  _hasCanvasRef = YES;
  return YES;
}

// Recomputes _viewerImageScreenRect from the stored anchor and the given image
// corners (canvas space). Returns YES if the rect changed.
- (BOOL)_recomputeViewerRectWithTopRight:(CGPoint)tr
                              bottomLeft:(CGPoint)bl
                                    zoom:(double)zoom {
  if (!_hasCanvasRef)
    return NO;
  double trX = _refMouseScreenX + (tr.x - _refMouseCanvasX) * zoom;
  double trY = _refMouseScreenY + (tr.y - _refMouseCanvasY) * zoom;
  double blX = _refMouseScreenX + (bl.x - _refMouseCanvasX) * zoom;
  double blY = _refMouseScreenY + (bl.y - _refMouseCanvasY) * zoom;
  NSRect newRect = NSMakeRect(MIN(blX, trX), MIN(blY, trY), fabs(trX - blX),
                              fabs(trY - blY));
  if (NSEqualRects(newRect, _viewerImageScreenRect))
    return NO;
  _viewerImageScreenRect = newRect;
  return YES;
}

- (void)invalidateMapping {
  _hasCanvasRef = NO;
  _viewerImageScreenRect = NSZeroRect;
  _hasHandleScreenPos = NO;
  _hasTargetScreenPos = NO;
  _geometryValid = NO;
}

- (void)_postPositionNotification {
  NSNotificationName name = self.guidePositionNotificationName;
  dispatch_async(dispatch_get_main_queue(), ^{
    [[NSNotificationCenter defaultCenter] postNotificationName:name object:nil];
  });
}

- (void)ingestDrawTickWithCanvasTopRight:(CGPoint)trC
                              bottomLeft:(CGPoint)blC
                             canvasScale:(double)spC
                         handleCanvasPos:(CGPoint)handleCanvasPos
                         targetCanvasPos:(CGPoint)targetCanvasPos
                               hasTarget:(BOOL)hasTarget {
  CFTimeInterval now = CACurrentMediaTime();
  _lastDrawTs = now;

  if (spC > 0.0) {
    _freshSpC = spC;
    _hasFreshSpC = YES;
  }

  if (now - _lastNotifyTs >= 1.0) {
    _lastNotifyTs = now;
    [self _postPositionNotification];
  }

  BOOL haveCorners = fabs(trC.x - blC.x) > 1e-3 && fabs(trC.y - blC.y) > 1e-3;

  // The CANVAS→screen affine is zoom-invariant (only OBJECT→CANVAS rescales,
  // which the corners already capture), so the cached anchor + scale stay
  // valid; recompute the viewer rect here every tick from the fresh corners
  // so it can never be stale-vs-corners (the post-resize drift root cause:
  // hitTest doesn't fire after the guide's own zoom-to-fit).
  if (_hasCanvasRef && haveCorners)
    [self _recomputeViewerRectWithTopRight:trC bottomLeft:blC zoom:_refSpC];

  NSRect vr = _viewerImageScreenRect;
  BOOL canMapViaViewer = haveCorners && !NSIsEmptyRect(vr);
  if (canMapViaViewer) {
    _canvasTR = trC;
    _canvasBL = blC;
    _geometryValid = YES;
  }

  if (_guideStep > 0 && (canMapViaViewer || _hasCanvasRef)) {
    NSPoint handleScreen, targetScreen;
    if (canMapViaViewer) {
      double hfx = (handleCanvasPos.x - blC.x) / (trC.x - blC.x);
      double hfy = (handleCanvasPos.y - blC.y) / (trC.y - blC.y);
      handleScreen = NSMakePoint(NSMinX(vr) + hfx * NSWidth(vr),
                                 NSMinY(vr) + hfy * NSHeight(vr));
      double tfx = (targetCanvasPos.x - blC.x) / (trC.x - blC.x);
      double tfy = (targetCanvasPos.y - blC.y) / (trC.y - blC.y);
      targetScreen = NSMakePoint(NSMinX(vr) + tfx * NSWidth(vr),
                                 NSMinY(vr) + tfy * NSHeight(vr));
    } else {
      handleScreen = NSMakePoint(
          _refMouseScreenX + (handleCanvasPos.x - _refMouseCanvasX) * _refSpC,
          _refMouseScreenY + (handleCanvasPos.y - _refMouseCanvasY) * _refSpC);
      targetScreen = NSMakePoint(
          _refMouseScreenX + (targetCanvasPos.x - _refMouseCanvasX) * _refSpC,
          _refMouseScreenY + (targetCanvasPos.y - _refMouseCanvasY) * _refSpC);
    }
    BOOL changed = !_hasHandleScreenPos ||
                   fabs(handleScreen.x - _handleScreenPos.x) > 0.5 ||
                   fabs(handleScreen.y - _handleScreenPos.y) > 0.5 ||
                   !_hasTargetScreenPos ||
                   fabs(targetScreen.x - _targetScreenPos.x) > 0.5 ||
                   fabs(targetScreen.y - _targetScreenPos.y) > 0.5;
    _handleScreenPos = handleScreen;
    _hasHandleScreenPos = YES;
    if (hasTarget) {
      _targetScreenPos = targetScreen;
      _hasTargetScreenPos = YES;
    }
    if (changed)
      [self _postPositionNotification];
  }
}

- (void)ingestHitTestAtScreen:(NSPoint)mouse
                    canvasPos:(CGPoint)canvasPos
                  canvasScale:(double)spC
                     topRight:(CGPoint)tr
                   bottomLeft:(CGPoint)bl
                     onHandle:(BOOL)onHandle
              handleCanvasPos:(CGPoint)handleCanvasPos {
  // Re-anchor from any *slow* hitTest sample (cursor ~stationary anywhere over
  // the viewer), not just on-handle: the screen↔canvas pair + spC is given
  // directly by FCP every call and is always fresh, so a slow sample tracks
  // viewer resize/zoom. The only error source is temporal skew between FCP's
  // canvas coord and our async mouseLocation read, which scales with cursor
  // speed and translates the whole rect. Reject fast samples; accept
  // on-handle / first-ever samples regardless of speed.
  CFTimeInterval nowTs = CACurrentMediaTime();
  double vel = 0.0;
  if (_lastHitTs > 0.0) {
    double dt = nowTs - _lastHitTs;
    if (dt > 1e-4)
      vel = hypot(mouse.x - _lastHitMouseScreen.x,
                  mouse.y - _lastHitMouseScreen.y) /
            dt;
  }
  _lastHitMouseScreen = mouse;
  _lastHitTs = nowTs;
  BOOL trustworthy =
      onHandle || !_hasCanvasRef || vel < _hitReanchorMaxVelocity;
  if (_hasCanvasRef && !trustworthy)
    return;

  _refMouseScreenX = mouse.x;
  _refMouseScreenY = mouse.y;
  _refMouseCanvasX = canvasPos.x;
  _refMouseCanvasY = canvasPos.y;
  _refSpC = spC;
  _hasCanvasRef = YES;

  BOOL viewerMoved = [self _recomputeViewerRectWithTopRight:tr
                                                 bottomLeft:bl
                                                       zoom:spC];

  BOOL oscMoved = NO;
  if (_guideStep > 0) {
    NSPoint computed =
        NSMakePoint(mouse.x + (handleCanvasPos.x - canvasPos.x) * spC,
                    mouse.y + (handleCanvasPos.y - canvasPos.y) * spC);
    if (!_hasHandleScreenPos || fabs(computed.x - _handleScreenPos.x) > 1.0 ||
        fabs(computed.y - _handleScreenPos.y) > 1.0) {
      _handleScreenPos = computed;
      _hasHandleScreenPos = YES;
      oscMoved = YES;
    }
  }

  if (_guideStep > 0 && (viewerMoved || oscMoved))
    [self _postPositionNotification];
}

@end
