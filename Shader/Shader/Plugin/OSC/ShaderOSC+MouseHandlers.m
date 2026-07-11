/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "OSC_Internal.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>

@implementation ShaderOSC (MouseHandlers)

// Track opt-reveal on hover (shared KKOnScreenControl machinery). Motion only
// reports the OPTION modifier while the hit-test claims a part; the hit-test's
// full-preview background-part fallback keeps that true over empty canvas too.
- (void)mouseMovedAtPositionX:(double)positionX
                    positionY:(double)positionY
                   activePart:(NSInteger)activePart
                    modifiers:(FxModifierKeys)modifiers
                  forceUpdate:(BOOL *)forceUpdate
                       atTime:(CMTime)time {
  [self kkUpdateOptRevealWithModifiers:modifiers forceUpdate:forceUpdate];
}

- (void)keyDownAtPositionX:(double)mousePositionX
                 positionY:(double)mousePositionY
                keyPressed:(unsigned short)asciiKey
                 modifiers:(FxModifierKeys)modifiers
               forceUpdate:(BOOL *)forceUpdate
                 didHandle:(BOOL *)didHandle
                    atTime:(CMTime)time {
  *didHandle = NO;
  *forceUpdate = NO;
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  // Opt-click an on-screen control to hide it (shared machinery on
  // KKOnScreenControl). Bails before any drag routing.
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
  // Origin handle / keypose anchor + the motion-path tangent handles are owned
  // by the Position controller (press capture, double-click smooth toggle,
  // grab-value capture all live there). The hit-test already set
  // hoverTargetIsAnchor, so map the part to a KKPositionHit.
  if (activePart == kOSCPositionPart || activePart == kOSCPathHandlePart) {
    KKPositionHit hit = (activePart == kOSCPathHandlePart)
                            ? KKPositionHitTangentHandle
                            : (self.originController.hoverTargetIsAnchor
                                   ? KKPositionHitAnchorDot
                                   : KKPositionHitHandle);
    [self.originController mouseDownAtX:positionX
                                      y:positionY
                                    hit:hit
                              modifiers:modifiers
                            forceUpdate:forceUpdate
                                 atTime:time];
  }
  // The Scale box owns its own press capture; centre it on the Origin pivot
  // first (mouseDown reads the hit handle from the preceding hit-test).
  if (activePart == kOSCScalePart) {
    self.scaleControl.center = [self oscPositionAtTime:time];
    self.scaleControl.frameMin = [self onScreenFrameMin];
    [self.scaleControl mouseDownAtX:positionX
                                  y:positionY
                          modifiers:modifiers
                        forceUpdate:forceUpdate
                             atTime:time];
  }
  if (activePart == kOSCRotationPart) {
    self.rotationControl.center = [self oscPositionAtTime:time];
    [self.rotationControl mouseDownAtX:positionX
                                     y:positionY
                             modifiers:modifiers
                           forceUpdate:forceUpdate
                                atTime:time];
  }
  // Advance the inspector timing guide (legacy plumbing, harmless when idle).
  if (ShaderSharedOSCGuideBridge().guideStep == 1) {
    ShaderSharedOSCGuideBridge().guideStep = 2;
    *forceUpdate = YES;
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
    [self.originController mouseDraggedAtX:positionX
                                         y:positionY
                                       hit:KKPositionHitTangentHandle
                                 modifiers:modifiers
                               forceUpdate:forceUpdate
                                    atTime:time];
    return;
  }
  if (activePart == kOSCScalePart) {
    self.scaleControl.center = [self oscPositionAtTime:time];
    self.scaleControl.frameMin = [self onScreenFrameMin];
    [self.scaleControl mouseDraggedAtX:positionX
                                     y:positionY
                             modifiers:modifiers
                           forceUpdate:forceUpdate
                                atTime:time];
    return;
  }
  if (activePart == kOSCRotationPart) {
    self.rotationControl.center = [self oscPositionAtTime:time];
    [self.rotationControl mouseDraggedAtX:positionX
                                        y:positionY
                                modifiers:modifiers
                              forceUpdate:forceUpdate
                                   atTime:time];
    return;
  }
  if (activePart != kOSCPositionPart)
    return;
  [self.originController
      mouseDraggedAtX:positionX
                    y:positionY
                  hit:(self.originController.hoverTargetIsAnchor
                           ? KKPositionHitAnchorDot
                           : KKPositionHitHandle)modifiers:modifiers
          forceUpdate:forceUpdate
               atTime:time];
}

- (void)mouseUpAtPositionX:(double)positionX
                 positionY:(double)positionY
                activePart:(NSInteger)activePart
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time {
  [self kkResetOptHideArming];
  [self.originController mouseUp];
  [self.scaleControl mouseUp];
  [self.rotationControl mouseUp];
  if (ShaderSharedOSCGuideBridge().guideStep == 2 && self.isDragging) {
    ShaderSharedOSCGuideBridge().guideStep = 3;
    *forceUpdate = YES;
  }
  [super mouseUpAtPositionX:positionX
                  positionY:positionY
                 activePart:activePart
                  modifiers:modifiers
                forceUpdate:forceUpdate
                     atTime:time];
}

@end
