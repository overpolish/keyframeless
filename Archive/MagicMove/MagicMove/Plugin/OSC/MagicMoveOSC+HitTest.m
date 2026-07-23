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
  // Clear any move cursor forced over a point last hover; the point branches
  // below re-set it, the scale box sets its own resize cursor, rotation none.
  if (self.pointCursorSet) {
    id<FxOnScreenControlAPI_v4> resetAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    [resetAPI setCursor:[NSCursor arrowCursor]];
    self.pointCursorSet = NO;
  }
  // Bootstrap the guide bridge's screen<->canvas reference (the only place a
  // valid canvas scale + screen point arrive together). Done before the early
  // returns so every hover feeds it.
  [self _ingestGuideHitTestAtCanvasX:positionX y:positionY];
  // Anchor pivot square is the topmost control: checked first so it is always
  // grabbable / opt-hideable. It is small, so the larger Position arc ring
  // around it stays clickable - the two coincide at the clip centre by default.
  // The shared kit control owns reachability + the move/eye cursor; remember we
  // set a point cursor so the next hover off it resets to the arrow.
  self.anchorControl.optRevealActive = self.optRevealActive;
  if ([self.anchorControl hitTestAtX:positionX y:positionY atTime:time] >= 0) {
    *activePart = kOSCAnchorPart;
    self.pointCursorSet = YES;
    return;
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
  // The gizmo cluster centres on the anchor pivot (where the render rotates /
  // scales), matching the draw.
  CGPoint pivot = [self.anchorControl pivotCanvasAtTime:time];
  // Scale box handles sit just outside the rotation rings; check them before
  // rotation so an edge handle near the ring radius wins over the ring. The
  // control owns reachability + the opt-hover eye affordance internally.
  self.scaleControl.center = pivot;
  self.scaleControl.frameMin = [self _onScreenFrameMin];
  self.scaleControl.optRevealActive = self.optRevealActive;
  if ([self.scaleControl hitTestHandleAtX:positionX y:positionY
                                   atTime:time] >= 0) {
    *activePart = kOSCScalePart;
    return;
  }
  // Rotation rings: the shared KKRotationOSC owns ring config + pose + hit-test
  // + the per-axis opt-hover eye cursor. Feed it this tick's centre + reveal.
  self.rotationOSC.center = pivot;
  self.rotationOSC.optRevealActive = self.optRevealActive;
  if ([self.rotationOSC hitTestRingAtX:positionX y:positionY atTime:time] >= 0)
    *activePart = kOSCRotationPart;
  // Motion full-preview Opt-reveal fallback (shared kit machinery): claim a
  // background part over empty canvas so Motion keeps reporting OPTION on
  // hover.
  *activePart = [self kkOSCBackgroundPartFallbackForActivePart:*activePart];
}

@end
