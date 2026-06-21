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
  // them back). Auto-select still runs below, so you can click a different
  // layer to switch away from a locked one.
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
    // The controller gates hit-testing on visibility + ITS optRevealActive, so
    // a hidden handle isn't grabbable unless Opt-revealed - forward the reveal
    // flag so a revealed ghost becomes hittable (opt-click re-shows it).
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
      NSCursor *eye = [self kkVisibilityCursorForLabel:
                                [self oscElementKeyForActivePart:*activePart]];
      if (eye) {
        id<FxOnScreenControlAPI_v4> oscAPI =
            [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
        [oscAPI setCursor:eye];
      }
      return;
    }
    // Scale box handles, checked after the Position handle/path miss (the
    // control owns reachability + the opt-hover eye affordance + the resize
    // cursor).
    [self _syncScaleControlAtTime:time];
    if ([self.scale hitTestHandleAtX:positionX y:positionY atTime:time] >= 0) {
      *activePart = CanvasOSCPartScale;
      self.pointCursorSet = YES; // the control set a resize / eye cursor: reset
                                 // it on the next hover off
      return;
    }
    // Rotation rings, checked last (they sit inside the scale box). The control
    // owns reachability + the per-axis opt-hover eye + the rotate cursor.
    [self _syncRotationControlAtTime:time];
    if ([self.rotation hitTestRingAtX:positionX y:positionY atTime:time] >= 0) {
      *activePart = CanvasOSCPartRotation;
      self.pointCursorSet = YES; // the control set a rotate / eye cursor: reset
                                 // it on the next hover off
      return;
    }
  }

  // Path point editing: a click on the selected path's anchor / tangent handle
  // (cursor tool, Points OSC visible) grabs it. Checked before auto-select so a
  // click on an anchor edits the path instead of re-picking a layer beneath.
  // When Points is hidden, an Opt-peek still reveals + claims it (so an
  // Opt-click can re-show), mirroring the transform handles.
  BOOL pointsVisible = [self kkOSCElementVisible:@"Points"];
  BOOL pointsReveal = !pointsVisible && self.optRevealActive &&
                      [self kkOSCRevealEligible:@"Points"];
  if ([self _activeTool] == CanvasToolbarToolCursor &&
      (pointsVisible || pointsReveal) &&
      [self _pathEditHitAtX:positionX y:positionY] != CanvasPathEditHitNone) {
    *activePart = CanvasOSCPartPathEdit;
    id<FxOnScreenControlAPI_v4> peAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    // eye / eye.slash when an Opt-click would toggle visibility, else the move
    // cursor for a normal edit.
    [peAPI setCursor:[self kkVisibilityCursorForLabel:@"Points"]
                         ?: KKPointMoveCursor()];
    self.pointCursorSet = YES;
    return;
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
  // Empty area (no anchor/handle, nothing else claimed): a drag here marquees
  // the selected path's points. Claimed after layer-pick so clicking another
  // layer still selects it.
  if (*activePart == CanvasOSCPartNone &&
      [self _activeTool] == CanvasToolbarToolCursor &&
      [self kkOSCElementVisible:@"Points"] &&
      [self.pathEditController canMarqueeAtX:positionX y:positionY]) {
    *activePart = CanvasOSCPartPathEdit;
    id<FxOnScreenControlAPI_v4> mqAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    [mqAPI setCursor:[NSCursor crosshairCursor]];
    self.pointCursorSet = YES;
  }
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  // Drop any hover tooltip the moment a press starts (it must not linger
  // through a drag); mouse-moved re-establishes it afterwards.
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
  // Pen tool: clicks place anchor points / close the path instead of driving
  // the gizmo. Gated on the active tool, so the cursor tool keeps the gizmo.
  if ([self _penToolActive]) {
    [self _penMouseDownAtX:positionX
                         y:positionY
                 modifiers:modifiers
                    atTime:time];
    if (forceUpdate)
      *forceUpdate = YES;
    return;
  }
  // Path point editing: grab the anchor / handle the hover hit-test claimed.
  if (activePart == CanvasOSCPartPathEdit) {
    // Opt-click ON an anchor / handle toggles the Points OSC's visibility
    // (master on) - hides a visible one, re-shows a revealed ghost. Gated on an
    // actual element hit so Opt over EMPTY space stays the
    // subtract-from-marquee gesture.
    BOOL onElement =
        [self.pathEditController hitTestAtX:positionX
                                          y:positionY] != CanvasPathEditHitNone;
    if (onElement && [self kkArmOptHideForActivePart:activePart
                                           modifiers:modifiers]) {
      if (forceUpdate)
        *forceUpdate = YES;
      return;
    }
    // Master-ON + individually hidden: the ghost is revealed only for the
    // Opt-click re-show above, so a normal click on it is inert (don't edit a
    // hidden path). Master-OFF is "peek and use" - Opt revealed it, so a drag
    // proceeds to edit.
    if (![self kkOSCMasterOff] && ![self kkOSCElementVisible:@"Points"]) {
      if (forceUpdate)
        *forceUpdate = YES;
      return;
    }
    [self _pathEditMouseDownAtX:positionX y:positionY modifiers:modifiers];
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
  // Pen tool: a press-drag after placing an anchor pulls its bezier handles -
  // UNLESS a pen-insert just grabbed a new anchor, which the path-edit
  // controller now drags (press-insert-drag to adjust the inserted point).
  if ([self _penToolActive]) {
    if ([self _pathEditDragging])
      [self _pathEditMouseDraggedAtX:positionX y:positionY modifiers:modifiers];
    else
      [self _penMouseDraggedAtX:positionX y:positionY modifiers:modifiers];
    if (forceUpdate)
      *forceUpdate = YES;
    return;
  }
  // Path point editing: drag the grabbed anchor / handle.
  if ([self _pathEditDragging]) {
    [self _pathEditMouseDraggedAtX:positionX y:positionY modifiers:modifiers];
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
    // A pen-insert handed the drag to the path-edit controller; end it there so
    // the inserted point commits (one undo).
    if ([self _pathEditDragging])
      [self _pathEditMouseUp];
    else
      [self _penMouseUp];
    if (forceUpdate)
      *forceUpdate = YES;
    return;
  }
  if ([self _pathEditDragging]) {
    [self _pathEditMouseUp];
    [self kkResetOptHideArming]; // this branch returns before the shared reset
                                 // below
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
  if ([self _penToolActive] && [self _penKeyDown:asciiKey
                                       modifiers:modifiers
                                          atTime:time]) {
    if (forceUpdate)
      *forceUpdate = YES;
    if (didHandle)
      *didHandle = YES;
    return;
  }
  // Delete / Backspace removes the selected path anchors (with the auto-delete
  // cascade). Cursor tool only; no-op when nothing is selected.
  if ((asciiKey == 127 || asciiKey == 8) &&
      [self _activeTool] == CanvasToolbarToolCursor &&
      self.pathEditController.selectedAnchors.count > 0 &&
      [self.pathEditController
          removeAnchorsAtIndexes:self.pathEditController.selectedAnchors
                       breakPath:YES]) {
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
