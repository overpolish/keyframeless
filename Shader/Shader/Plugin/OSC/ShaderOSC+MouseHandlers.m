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
  // Option-click an OSC element to hide just it. Arm FIRST (before super), or
  // the base arms the interaction as a normal drag and this becomes a cached
  // no-op - so the toggle never fires and visibility never persists.
  BOOL optHide = [self kkArmOptHideForActivePart:activePart
                                       modifiers:modifiers];
  if (optHide) {
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
  [self oscMouseDownAtX:positionX
                      y:positionY
             activePart:activePart
              modifiers:modifiers
            forceUpdate:forceUpdate
                 atTime:time];
  // Advance the (dormant) inspector timing-guide step machine. Harmless when no
  // guide is running; re-activates once shader-exposed OSCs are wired.
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
  if ([self oscMouseDraggedAtX:positionX
                             y:positionY
                     modifiers:modifiers
                   forceUpdate:forceUpdate
                        atTime:time])
    return;
  [super mouseDraggedAtPositionX:positionX
                       positionY:positionY
                      activePart:activePart
                       modifiers:modifiers
                     forceUpdate:forceUpdate
                          atTime:time];
}

- (void)mouseUpAtPositionX:(double)positionX
                 positionY:(double)positionY
                activePart:(NSInteger)activePart
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time {
  [self oscMouseUp];
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
