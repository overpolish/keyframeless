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

@implementation MagicMoveOSC (MouseHandlers)

- (void)mouseUpAtPositionX:(double)positionX
                 positionY:(double)positionY
                activePart:(NSInteger)activePart
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time {
  [self kkResetOptHideArming];
  [self.positionController mouseUp];
  [self.scaleControl mouseUp];
  [self.rotationOSC mouseUp];
  [self.anchorControl mouseUp];
  [super mouseUpAtPositionX:positionX
                  positionY:positionY
                 activePart:activePart
                  modifiers:modifiers
                forceUpdate:forceUpdate
                     atTime:time];
}

- (void)mouseMovedAtPositionX:(double)positionX
                    positionY:(double)positionY
                   activePart:(NSInteger)activePart
                    modifiers:(FxModifierKeys)modifiers
                  forceUpdate:(BOOL *)forceUpdate
                       atTime:(CMTime)time {
  [self kkUpdateOptRevealWithModifiers:modifiers forceUpdate:forceUpdate];
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  if ([self kkArmOptHideForActivePart:activePart modifiers:modifiers]) {
    if (forceUpdate)
      *forceUpdate = YES;
    return;
  }
  [super mouseDownAtPositionX:positionX
                    positionY:positionY
                   activePart:activePart
                    modifiers:modifiers
                  forceUpdate:forceUpdate
                       atTime:time];
  if (activePart == kOSCScalePart) {
    self.scaleControl.center = [self.anchorControl pivotCanvasAtTime:time];
    self.scaleControl.frameMin = [self _onScreenFrameMin];
    [self.scaleControl mouseDownAtX:positionX
                                  y:positionY
                          modifiers:modifiers
                        forceUpdate:forceUpdate
                             atTime:time];
    return;
  }
  if (activePart == kOSCAnchorPart) {
    [self.anchorControl mouseDownAtX:positionX
                                   y:positionY
                           modifiers:modifiers
                         forceUpdate:forceUpdate
                              atTime:time];
    return;
  }
  // Position handle / keypose anchor, and the motion-path tangent handles, are
  // owned by the Position controller (press capture, double-click smooth
  // toggle, grab-value capture all live in there). The hit-test already set
  // hoverTargetIsAnchor on the controller, so map the part to a KKPositionHit.
  if (activePart == kOSCPositionPart || activePart == kOSCPathHandlePart) {
    KKPositionHit hit = (activePart == kOSCPathHandlePart)
                            ? KKPositionHitTangentHandle
                            : (self.positionController.hoverTargetIsAnchor
                                   ? KKPositionHitAnchorDot
                                   : KKPositionHitHandle);
    [self.positionController mouseDownAtX:positionX
                                        y:positionY
                                      hit:hit
                                modifiers:modifiers
                              forceUpdate:forceUpdate
                                   atTime:time];
  }
  if (activePart == kOSCRotationPart) {
    // The shared KKRotationOSC owns press capture (nearest keypose), the
    // smoothed-pose tangent sync, compose/decompose and persistence.
    self.rotationOSC.center = [self.anchorControl pivotCanvasAtTime:time];
    self.rotationOSC.optRevealActive = self.optRevealActive;
    [self.rotationOSC mouseDownAtX:positionX
                                 y:positionY
                         modifiers:modifiers
                       forceUpdate:forceUpdate
                            atTime:time];
  }
}

- (void)mouseDraggedAtPositionX:(double)positionX
                      positionY:(double)positionY
                     activePart:(NSInteger)activePart
                      modifiers:(NSUInteger)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time {
  // First drag tick decides: opt held => hide-click (handled, no drag).
  if ([self kkArmOptHideForActivePart:activePart modifiers:modifiers]) {
    if (forceUpdate)
      *forceUpdate = YES;
    return;
  }
  if (activePart == kOSCPathHandlePart) {
    [self.positionController mouseDraggedAtX:positionX
                                           y:positionY
                                         hit:KKPositionHitTangentHandle
                                   modifiers:modifiers
                                 forceUpdate:forceUpdate
                                      atTime:time];
    return;
  }
  if (activePart == kOSCRotationPart) {
    [self.rotationOSC mouseDraggedAtX:positionX
                                    y:positionY
                            modifiers:modifiers
                          forceUpdate:forceUpdate
                               atTime:time];
    return;
  }
  if (activePart == kOSCScalePart) {
    self.scaleControl.center = [self.anchorControl pivotCanvasAtTime:time];
    self.scaleControl.frameMin = [self _onScreenFrameMin];
    [self.scaleControl mouseDraggedAtX:positionX
                                     y:positionY
                             modifiers:modifiers
                           forceUpdate:forceUpdate
                                atTime:time];
    return;
  }
  if (activePart == kOSCAnchorPart) {
    [self.anchorControl mouseDraggedAtX:positionX
                                      y:positionY
                              modifiers:modifiers
                            forceUpdate:forceUpdate
                                 atTime:time];
    return;
  }
  if (activePart != kOSCPositionPart)
    return;
  [self.positionController
      mouseDraggedAtX:positionX
                    y:positionY
                  hit:(self.positionController.hoverTargetIsAnchor
                           ? KKPositionHitAnchorDot
                           : KKPositionHitHandle)modifiers:modifiers
          forceUpdate:forceUpdate
               atTime:time];
}

@end
