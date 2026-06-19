/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasOSC_Private.h"
#import <FxPlug/FxPlugSDK.h>

// hitTest / mouse* / mouseMoved are FxOnScreenControl protocol methods; the
// primary @implementation handles draw + the element-key mapping, so these live
// in a category - which trips the protocol-method-in-category warning.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation CanvasOSC (Input)

// Track Option-hold (reveal) - local, modifier-only (no param read, which the
// OSC context can't do anyway). On change it requests a redraw so the handle
// appears/disappears as Option is pressed/released.
- (void)mouseMovedAtPositionX:(double)positionX
                    positionY:(double)positionY
                   activePart:(NSInteger)activePart
                    modifiers:(FxModifierKeys)modifiers
                  forceUpdate:(BOOL *)forceUpdate
                       atTime:(CMTime)time {
  // FCP doesn't surface the held Option flag in mouseMoved for a hidden OSC
  // (it draws nothing), so the passed `modifiers` come through as 0. Read the
  // LIVE modifier state directly and OR it in (the bit constants differ:
  // NSEventModifierFlagOption vs kFxModifierKey_OPTION) so opt-reveal works
  // with the cursor anywhere, like the other plugins.
  FxModifierKeys eff = modifiers;
  if ([NSEvent modifierFlags] & NSEventModifierFlagOption)
    eff |= kFxModifierKey_OPTION;
  [self kkUpdateOptRevealWithModifiers:eff forceUpdate:forceUpdate];
}

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  *activePart = CanvasOSCPartNone;
  // Clear a move cursor forced on the previous hover; the hit branch re-sets
  // it.
  if (self.pointCursorSet) {
    id<FxOnScreenControlAPI_v4> resetAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    [resetAPI setCursor:[NSCursor arrowCursor]];
    self.pointCursorSet = NO;
  }
  // Locked SELECTED layer: its own handles aren't grabbable (and Opt can't peek
  // them back). Auto-select still runs below, so you can click a different layer
  // to switch away from a locked one.
  [self _applyGroupComposeOffsetAtTime:time];
  if (![self _selectedLayerLocked]) {
    // Anchor pivot square is the topmost control: checked first so it stays
    // grabbable / opt-hideable even when it coincides with the Position handle.
    // The control owns reachability + the move/eye cursor.
    self.anchor.optRevealActive = self.optRevealActive;
    if ([self.anchor hitTestAtX:positionX y:positionY atTime:time] >= 0) {
      *activePart = CanvasOSCPartAnchor;
      self.pointCursorSet = YES;
      return;
    }
    // The controller gates hit-testing on visibility + ITS optRevealActive, so a
    // hidden handle isn't grabbable unless Opt-revealed - forward the reveal flag
    // so a revealed ghost becomes hittable (opt-click re-shows it).
    self.position.optRevealActive = self.optRevealActive;
    KKPositionHit ph = [self.position hitTestAtX:positionX
                                               y:positionY
                                          atTime:time];
    if (ph != KKPositionHitNone) {
      *activePart = (ph == KKPositionHitTangentHandle) ? CanvasOSCPartPath
                                                       : CanvasOSCPartPosition;
      self.pointCursorSet = YES; // the controller set the move/eye cursor
      // When an opt-click would toggle this element's visibility (master on),
      // show the eye / eye.slash affordance over its handle instead.
      NSCursor *eye = [self
          kkVisibilityCursorForLabel:[self oscElementKeyForActivePart:
                                               *activePart]];
      if (eye) {
        id<FxOnScreenControlAPI_v4> oscAPI =
            [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
        [oscAPI setCursor:eye];
      }
      return;
    }
    // Scale box handles, checked after the Position handle/path miss (the control
    // owns reachability + the opt-hover eye affordance + the resize cursor).
    [self _syncScaleControlAtTime:time];
    if ([self.scale hitTestHandleAtX:positionX y:positionY atTime:time] >= 0) {
      *activePart = CanvasOSCPartScale;
      return;
    }
    // Rotation rings, checked last (they sit inside the scale box). The control
    // owns reachability + the per-axis opt-hover eye + the rotate cursor.
    [self _syncRotationControlAtTime:time];
    if ([self.rotation hitTestRingAtX:positionX y:positionY atTime:time] >= 0) {
      *activePart = CanvasOSCPartRotation;
      return;
    }
  }

  // Auto-select: no handle was grabbed, so if the toggle is on, claim a click
  // over the topmost (unselected) image layer to select it. Clicking the
  // already-selected layer is a no-op (don't claim - leave the click to FCP).
  self.pendingPickLayerID = nil;
  if ([self _autoSelectEnabled]) {
    NSString *hit = [self _pickLayerIDAtX:positionX y:positionY atTime:time];
    if (hit.length && ![hit isEqualToString:[self _resolvedSelectedLayerID]]) {
      self.pendingPickLayerID = hit;
      *activePart = CanvasOSCPartLayerPick;
      id<FxOnScreenControlAPI_v4> oscAPI =
          [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
      [oscAPI setCursor:[NSCursor pointingHandCursor]];
      self.pointCursorSet = YES;
    }
  }
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  // Auto-select pick: the hover hit-test claimed a click over an unselected
  // image layer - commit the selection and consume the click (no drag).
  if (activePart == CanvasOSCPartLayerPick) {
    [self _commitPickSelection];
    if (forceUpdate)
      *forceUpdate = YES;
    return;
  }
  // Opt-click over the handle (master on) toggles this element's visibility
  // instead of dragging; master off leaves it a normal drag (peek-and-use).
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
  [self _applyGroupComposeOffsetAtTime:time];
  if (activePart == CanvasOSCPartScale) {
    [self _syncScaleControlAtTime:time];
    [self.scale mouseDownAtX:positionX
                           y:positionY
                   modifiers:modifiers
                 forceUpdate:forceUpdate
                      atTime:time];
    return;
  }
  if (activePart == CanvasOSCPartRotation) {
    [self _syncRotationControlAtTime:time];
    [self.rotation mouseDownAtX:positionX
                              y:positionY
                      modifiers:modifiers
                    forceUpdate:forceUpdate
                         atTime:time];
    return;
  }
  if (activePart == CanvasOSCPartAnchor) {
    [self.anchor mouseDownAtX:positionX
                            y:positionY
                    modifiers:modifiers
                  forceUpdate:forceUpdate
                       atTime:time];
    return;
  }
  if (activePart != CanvasOSCPartPosition && activePart != CanvasOSCPartPath)
    return;
  KKPositionHit hit =
      (activePart == CanvasOSCPartPath)
          ? KKPositionHitTangentHandle
          : (self.position.hoverTargetIsAnchor ? KKPositionHitAnchorDot
                                               : KKPositionHitHandle);
  [self.position mouseDownAtX:positionX
                            y:positionY
                          hit:hit
                    modifiers:modifiers
                  forceUpdate:forceUpdate
                       atTime:time];
}

- (void)mouseDraggedAtPositionX:(double)positionX
                      positionY:(double)positionY
                     activePart:(NSInteger)activePart
                      modifiers:(NSUInteger)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time {
  // Opt-hide latched on the first event sticks for the rest of the interaction
  // (so an opt-click doesn't half-drag).
  if ([self kkArmOptHideForActivePart:activePart modifiers:modifiers])
    return;
  [self _applyGroupComposeOffsetAtTime:time];
  if (activePart == CanvasOSCPartScale) {
    [self _syncScaleControlAtTime:time];
    [self.scale mouseDraggedAtX:positionX
                              y:positionY
                      modifiers:modifiers
                    forceUpdate:forceUpdate
                         atTime:time];
    return;
  }
  if (activePart == CanvasOSCPartRotation) {
    [self _syncRotationControlAtTime:time];
    [self.rotation mouseDraggedAtX:positionX
                                 y:positionY
                         modifiers:modifiers
                       forceUpdate:forceUpdate
                            atTime:time];
    return;
  }
  if (activePart == CanvasOSCPartAnchor) {
    [self.anchor mouseDraggedAtX:positionX
                               y:positionY
                       modifiers:modifiers
                     forceUpdate:forceUpdate
                          atTime:time];
    return;
  }
  if (activePart != CanvasOSCPartPosition && activePart != CanvasOSCPartPath)
    return;
  KKPositionHit hit =
      (activePart == CanvasOSCPartPath)
          ? KKPositionHitTangentHandle
          : (self.position.hoverTargetIsAnchor ? KKPositionHitAnchorDot
                                               : KKPositionHitHandle);
  [self.position mouseDraggedAtX:positionX
                               y:positionY
                             hit:hit
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
  [self kkResetOptHideArming];
  [self.position mouseUp];
  [self.scale mouseUp];
  [self.rotation mouseUp];
  [self.anchor mouseUp];
  [super mouseUpAtPositionX:positionX
                  positionY:positionY
                 activePart:activePart
                  modifiers:modifiers
                forceUpdate:forceUpdate
                     atTime:time];
}

@end

#pragma clang diagnostic pop
