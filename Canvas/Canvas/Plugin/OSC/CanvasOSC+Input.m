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

  // Toolbar hover tooltip: show the localized bubble for the button under the
  // cursor (a real item tag > 0); clear it otherwise. Redraw only on a change.
  NSInteger tbHit = [self _toolbarHitTestAtX:positionX y:positionY];
  NSInteger newHover = (tbHit > 0 && !self.toolbarDragging) ? tbHit : 0;
  if (newHover != self.toolbar.hoveredTag) {
    self.toolbar.hoveredTag = newHover;
    if (forceUpdate)
      *forceUpdate = YES;
  }
  // Pen tool: track the cursor for the rubber-band + the grid-snap ghost (the
  // latter shows before the first point too).
  if ([self _penToolActive]) {
    [self _penMouseMovedAtX:positionX y:positionY];
    if (forceUpdate)
      *forceUpdate = YES;
  }
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
  // Toolbar (global chrome) sits on top: claim its hits before any handle or
  // layer pick. A tag > 0 is an item; < 0 is the toolbar body (swallow).
  NSInteger tbHit = [self _toolbarHitTestAtX:positionX y:positionY];
  if (tbHit != 0) {
    *activePart = (tbHit < 0) ? CanvasToolbarBackground : tbHit;
    id<FxOnScreenControlAPI_v4> tbAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    // Move cursor over the drag handle; plain arrow over the buttons / body.
    if (tbHit == CanvasToolbarDragHandle) {
      [tbAPI setCursor:KKPointMoveCursor()];
      self.pointCursorSet = YES; // reset to arrow on the next hover off it
    } else {
      [tbAPI setCursor:[NSCursor arrowCursor]];
    }
    return;
  }
  // Pen tool: claim the whole canvas (below the toolbar) so every click routes
  // to the OSC, and show the pen / close-shape cursor. Bypasses the gizmo
  // handles + auto-select entirely while drawing.
  if ([self _penToolActive]) {
    *activePart = CanvasOSCPartPen;
    id<FxOnScreenControlAPI_v4> penAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    [penAPI setCursor:[self _penCursorForCanvasX:positionX y:positionY]];
    self.pointCursorSet = YES;
    return;
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
  // Drop any hover tooltip the moment a press starts (it must not linger through
  // a drag); mouse-moved re-establishes it afterwards.
  self.toolbar.hoveredTag = 0;
  // Toolbar: the body swallows the click; an item toggles its flag or (the drag
  // handle) starts the bar move. None of these touch the gizmo / layer path.
  if (activePart == CanvasToolbarBackground) {
    if (forceUpdate)
      *forceUpdate = YES;
    return;
  }
  if (activePart >= CanvasToolbarDragHandle) {
    [self _toolbarMouseDownTag:activePart atX:positionX y:positionY];
    if (forceUpdate)
      *forceUpdate = YES;
    return;
  }
  // Pen tool: clicks place anchor points / close the path instead of driving the
  // gizmo. Gated on the active tool, so the cursor tool keeps the gizmo.
  if ([self _penToolActive]) {
    [self _penMouseDownAtX:positionX
                         y:positionY
                 modifiers:modifiers
                    atTime:time];
    if (forceUpdate)
      *forceUpdate = YES;
    return;
  }
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
  if (self.toolbarDragging) {
    [self _toolbarMouseDraggedAtX:positionX y:positionY];
    if (forceUpdate)
      *forceUpdate = YES;
    return;
  }
  // Pen tool: a press-drag after placing an anchor pulls its bezier handles.
  if ([self _penToolActive]) {
    [self _penMouseDraggedAtX:positionX y:positionY modifiers:modifiers];
    if (forceUpdate)
      *forceUpdate = YES;
    return;
  }
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
  if (self.toolbarDragging) {
    [self _toolbarMouseUp];
    if (forceUpdate)
      *forceUpdate = YES;
    return;
  }
  if ([self _penToolActive]) {
    [self _penMouseUp];
    if (forceUpdate)
      *forceUpdate = YES;
    return;
  }
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

- (void)keyDownAtPositionX:(double)positionX
                 positionY:(double)positionY
                keyPressed:(unsigned short)asciiKey
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                 didHandle:(BOOL *)didHandle
                    atTime:(CMTime)time {
  if ([self _handleToolbarKey:asciiKey modifiers:modifiers]) {
    if (forceUpdate)
      *forceUpdate = YES;
    if (didHandle)
      *didHandle = YES;
    return;
  }
  if ([self _penToolActive] &&
      [self _penKeyDown:asciiKey modifiers:modifiers atTime:time]) {
    if (forceUpdate)
      *forceUpdate = YES;
    if (didHandle)
      *didHandle = YES;
    return;
  }
  [super keyDownAtPositionX:positionX
                  positionY:positionY
                 keyPressed:asciiKey
                  modifiers:modifiers
                forceUpdate:forceUpdate
                  didHandle:didHandle
                     atTime:time];
}

@end

#pragma clang diagnostic pop
