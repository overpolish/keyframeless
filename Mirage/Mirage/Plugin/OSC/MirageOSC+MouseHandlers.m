/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "OSC_Internal.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>

@implementation MirageOSC (MouseHandlers)

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
  if (activePart == 9100) {
    [self _completeViewerPickAtX:positionX y:positionY];
    *forceUpdate = YES;
    return;
  }
  if (activePart == 9099) {
    *forceUpdate = YES;
    return;
  }
  if (activePart == 9004) {
    self.compareDividerDragging = YES;
    [self _setCompareDividerFromX:positionX];
    *forceUpdate = YES;
    return;
  }
  if (activePart >= 9001 && activePart <= 9003) {
    KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
    if (activePart == 9001) {
      state.mirageCompareBypassing = YES;
      self.compareBeforeMouseHeld = YES;
    } else if (activePart == 9002) {
      state.mirageCompareSplitEnabled = !state.mirageCompareSplitEnabled;
    } else {
      state.mirageCompareSelectionEnabled =
          !state.mirageCompareSelectionEnabled;
    }
    // All three modes now come from the effect render. The hidden nonce makes
    // Final Cut invalidate its cached frame instead of redrawing only the OSC.
    [self _invalidateCompareRender];
    [NSNotificationCenter.defaultCenter
        postNotificationName:kMirageCompareStateDidChangeNotification
                      object:nil];
    *forceUpdate = YES;
    return;
  }
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
  if (MirageSharedOSCGuideBridge().guideStep == 1) {
    MirageSharedOSCGuideBridge().guideStep = 2;
    *forceUpdate = YES;
  }
}

- (void)mouseDraggedAtPositionX:(double)positionX
                      positionY:(double)positionY
                     activePart:(NSInteger)activePart
                      modifiers:(NSUInteger)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time {
  if (self.compareDividerDragging) {
    [self _setCompareDividerFromX:positionX];
    *forceUpdate = YES;
    return;
  }
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
  if (self.compareBeforeMouseHeld) {
    self.compareBeforeMouseHeld = NO;
    KKInstanceStateForAPI(self.apiManager).mirageCompareBypassing = NO;
    [NSNotificationCenter.defaultCenter
        postNotificationName:kMirageCompareStateDidChangeNotification
                      object:nil];
    [self _invalidateCompareRender];
    *forceUpdate = YES;
    return;
  }
  if (self.compareDividerDragging) {
    self.compareDividerDragging = NO;
    [self _setCompareDividerFromX:positionX];
    id<FxOnScreenControlAPI_v4> api =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    [api setCursor:[NSCursor arrowCursor]];
    self.pointCursorSet = NO;
    *forceUpdate = YES;
    return;
  }
  [self oscMouseUp];
  if (MirageSharedOSCGuideBridge().guideStep == 2 && self.isDragging) {
    MirageSharedOSCGuideBridge().guideStep = 3;
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
