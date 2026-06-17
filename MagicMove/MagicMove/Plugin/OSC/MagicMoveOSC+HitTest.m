/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "OSC_Internal.h"
#import "Plugin_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>
#import <simd/simd.h>

@implementation MagicMoveOSC (HitTest)

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  *activePart = 0;
  self.anchorHovered = NO;
  // Clear any move cursor forced over a point last hover; the point branches
  // below re-set it, the scale box sets its own resize cursor, rotation none.
  if (self.pointCursorSet) {
    id<FxOnScreenControlAPI_v4> resetAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    [resetAPI setCursor:[NSCursor arrowCursor]];
    self.pointCursorSet = NO;
  }
  double frac = [self _fractionAtTime:time];
  // Bootstrap the guide bridge's screen<->canvas reference (the only place a
  // valid canvas scale + screen point arrive together). Done before the early
  // returns so every hover feeds it.
  [self _ingestGuideHitTestAtCanvasX:positionX y:positionY];
  // Anchor pivot square is the topmost control: checked first so it is always
  // grabbable / opt-hideable. It is small, so the larger Position arc ring
  // around it stays clickable - the two coincide at the clip centre by default.
  if (([self kkOSCElementVisible:@"Anchor"] ||
       (self.optRevealActive && [self kkOSCRevealEligible:@"Anchor"])) &&
      _anchorVisibleAtFraction(frac)) {
    CGPoint ac = [self _anchorCanvasAtFraction:frac];
    if (fmax(fabs(positionX - ac.x), fabs(positionY - ac.y)) <
        [self.anchorPointOSC hitRadius]) {
      self.anchorHovered = YES;
      *activePart = kOSCAnchorPart;
      [self _setViewerPointCursorForLabel:@"Anchor"];
      return;
    }
  }
  // The Position controller owns the tangent-handle / arc / anchor-dot hit
  // precedence (tangent > arc > anchor dot) and sets the move/eye cursor on a
  // hit. Map its result to our external activePart; remember we forced a point
  // cursor so the next hover off the point resets to the arrow.
  KKPositionHit ph = [self.positionController hitTestAtX:positionX
                                                       y:positionY
                                                  atTime:time];
  if (ph != KKPositionHitNone) {
    *activePart = (ph == KKPositionHitTangentHandle) ? kOSCPathHandlePart
                                                     : kOSCPositionPart;
    self.pointCursorSet = YES;
    return;
  }
  // Scale box handles sit just outside the rotation rings; check them before
  // rotation so an edge handle near the ring radius wins over the ring. The
  // control owns reachability + the opt-hover eye affordance internally.
  self.scaleControl.center = [self oscPositionAtTime:time];
  self.scaleControl.frameMin = [self _onScreenFrameMin];
  self.scaleControl.optRevealActive = self.optRevealActive;
  if ([self.scaleControl hitTestHandleAtX:positionX y:positionY
                                   atTime:time] >= 0) {
    *activePart = kOSCScalePart;
    return;
  }
  // Rotation rings: the shared KKRotationOSC owns ring config + pose + hit-test
  // + the per-axis opt-hover eye cursor. Feed it this tick's centre + reveal.
  self.rotationOSC.center = [self oscPositionAtTime:time];
  self.rotationOSC.optRevealActive = self.optRevealActive;
  if ([self.rotationOSC hitTestRingAtX:positionX y:positionY atTime:time] >= 0)
    *activePart = kOSCRotationPart;
}

// Force FCP's move cursor over a draggable point (anchor / position / path) and
// remember it so the next hover off the point resets to the arrow.
- (void)_setViewerPointCursorForLabel:(NSString *)label {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  // FCP's move cursor, or the Opt-hover eye/eye.slash when an Opt-click would
  // toggle this handle's visibility.
  [oscAPI setCursor:([self kkVisibilityCursorForLabel:label]
                         ?: KKPointMoveCursor())];
  self.pointCursorSet = YES;
}

@end
