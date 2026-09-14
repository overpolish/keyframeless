/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasOSC_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKBezierPath.h>

// mouseMoved / hitTest are FxOnScreenControl protocol methods; the primary
// @implementation handles draw + the element-key mapping, so the cursor-tool
// gesture CLASSIFICATION (hover cursor + which part is hit, in priority order:
// toolbar > pen/shape tools > transform gizmo > path points > body-move >
// auto-select pick > empty-canvas marquee) lives here. Splitting it from the
// event HANDLING (CanvasOSC+Input.m) keeps both readable. The category trips
// the protocol-method-in-category warning.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation CanvasOSC (HitTest)

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
  // Bootstrap the guide bridge's screen<->canvas reference (the only place a
  // valid canvas scale + screen point arrive together). Before the early
  // returns so every hover feeds it.
  [self _ingestGuideHitTestAtCanvasX:positionX y:positionY];
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
  // Rect / ellipse tool: claim the whole canvas (below the toolbar) so the box
  // drag routes to the OSC, and show the crosshair. Bypasses the gizmo +
  // auto-select while drawing, like the pen.
  if ([self _shapeToolActive]) {
    *activePart = CanvasOSCPartShape;
    id<FxOnScreenControlAPI_v4> shAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    [shAPI setCursor:[NSCursor crosshairCursor]];
    self.pointCursorSet = YES;
    return;
  }
  // Locked SELECTED layer: its own handles aren't grabbable (and Opt can't peek
  // them back). Auto-select still runs below, so you can click a different
  // layer to switch away from a locked one.
  [self _applyGroupComposeOffsetAtTime:time];
  // The transform-gizmo handles are hittable only when the gizmo is shown (a
  // lone image / group) - matching the draw gate, so a lone path / multi /
  // empty selection never grabs an invisible handle.
  if (![self _selectedLayerLocked] && [self _showsTransformGizmo]) {
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
  // Point editing needs EXACTLY one selected layer: off while a multi-selection
  // is active (layer-level - the points show dimmed, non-editable), and off
  // with nothing selected (count 0) - else the hit-test resolves the topmost
  // path via the fallback and the unselected top layer's anchors become
  // grabbable though none are drawn.
  BOOL singleSel = [self _selectedLayerIDs].count == 1;
  // Corner-radius widgets are their own "Corners" element: claim a hover over
  // one as CanvasOSCPartCorner so an Opt-click toggles "Corners" (not "Points")
  // and the eye cursor reads the right element. Checked before the
  // anchor/handle claim (the widgets sit in the empty area inside a corner,
  // clear of anchors).
  BOOL cornersVisible = [self kkOSCElementVisible:@"Corners"];
  BOOL cornersReveal = !cornersVisible && self.optRevealActive &&
                       [self kkOSCRevealEligible:@"Corners"];
  if (singleSel && [self _activeTool] == CanvasToolbarToolCursor) {
    self.pathEditController.cornerWidgetsActive =
        cornersVisible || cornersReveal;
    if ((cornersVisible || cornersReveal) &&
        [self.pathEditController cornerWidgetHitAtX:positionX y:positionY]) {
      *activePart = CanvasOSCPartCorner;
      id<FxOnScreenControlAPI_v4> cAPI =
          [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
      [cAPI setCursor:[self kkVisibilityCursorForLabel:@"Corners"]
                          ?: KKPointMoveCursor()];
      self.pointCursorSet = YES;
      return;
    }
  }
  if (singleSel && [self _activeTool] == CanvasToolbarToolCursor &&
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
  // Body of an ALREADY-selected layer (cursor tool): claim it so a drag moves
  // the whole selection (paths shift points, images shift Position). Checked
  // after the gizmo + point handles (they win) and before auto-select /
  // marquee. Click vs drag is resolved on mouseUp (a click just (re)selects).
  if (*activePart == CanvasOSCPartNone &&
      [self _activeTool] == CanvasToolbarToolCursor) {
    NSString *hit = [self _pickLayerIDAtX:positionX y:positionY atTime:time];
    if (hit.length && [[self _selectedLayerIDs] containsObject:hit]) {
      self.pendingPickLayerID = hit;
      *activePart = CanvasOSCPartLayerMove;
      id<FxOnScreenControlAPI_v4> mvAPI =
          [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
      [mvAPI setCursor:[NSCursor openHandCursor]];
      self.pointCursorSet = YES;
      return;
    }
  }
  // Auto-select: no handle was grabbed, so if the toggle is on, claim a click
  // over the topmost layer to select it. A plain click over an already-selected
  // layer is a no-op (leave it to FCP); but Shift / Cmd makes the click
  // additive (toggle into / out of the multi-selection), so claim it even when
  // the layer is already selected so the toggle-off can register.
  self.pendingPickLayerID = nil;
  if ([self _autoSelectEnabled]) {
    NSString *hit = [self _pickLayerIDAtX:positionX y:positionY atTime:time];
    BOOL additive = (NSEvent.modifierFlags & (NSEventModifierFlagShift |
                                              NSEventModifierFlagCommand)) != 0;
    NSArray<NSString *> *curSel = [self _selectedLayerIDs];
    BOOL alreadySelected = [curSel containsObject:(hit ?: @"")];
    // Claim the click to (re)select when: a modifier makes it additive
    // (toggle), the hit isn't already selected, OR a multi-selection is active
    // - a plain click on any layer then collapses the selection to just that
    // one.
    if (hit.length && (additive || !alreadySelected || curSel.count > 1)) {
      self.pendingPickLayerID = hit;
      *activePart = CanvasOSCPartLayerPick;
      id<FxOnScreenControlAPI_v4> oscAPI =
          [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
      [oscAPI setCursor:[NSCursor pointingHandCursor]];
      self.pointCursorSet = YES;
    }
  }
  // Empty canvas (cursor tool, nothing else claimed): a drag marquees whole
  // layers; a click (no drag) deselects. Over a layer the pick / body-drag
  // branches above own it (when auto-select is ON), so the marquee stays the
  // empty-area fallback there. But with auto-select OFF nothing claims an
  // unselected layer body - so a drag over it must still marquee (else you
  // can't rubber-band over an image with auto-select off).
  if (*activePart == CanvasOSCPartNone &&
      [self _activeTool] == CanvasToolbarToolCursor &&
      [self.pathEditController canMarqueeAtX:positionX y:positionY] &&
      (![self _autoSelectEnabled] || [self _pickLayerIDAtX:positionX
                                                         y:positionY
                                                    atTime:time] == nil)) {
    *activePart = CanvasOSCPartPathEdit;
    id<FxOnScreenControlAPI_v4> mqAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    [mqAPI setCursor:[NSCursor crosshairCursor]];
    self.pointCursorSet = YES;
  }
  // Motion full-preview Opt-reveal fallback (shared kit machinery): claim a
  // background part over empty canvas so Motion keeps reporting OPTION on
  // hover. Last resort - only when nothing else (controls, layer pick, marquee)
  // claimed.
  *activePart = [self kkOSCBackgroundPartFallbackForActivePart:*activePart];
}

@end

#pragma clang diagnostic pop
