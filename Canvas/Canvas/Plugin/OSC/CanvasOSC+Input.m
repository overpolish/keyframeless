/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerTimeline.h" // CanvasLayerBlobSnapshot
#import "CanvasOSC_Private.h"
#import "CanvasPathMorph.h" // CanvasTranslateSelection
#import "Plugin_Private.h"  // [CanvasPlugin availableLanes]
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKBezierPath.h>

// hitTest / mouse* / mouseMoved are FxOnScreenControl protocol methods; the
// primary @implementation handles draw + the element-key mapping, so these live
// in a category - which trips the protocol-method-in-category warning.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation CanvasOSC (Input)

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
    [self _toolbarMouseDownTag:activePart
                           atX:positionX
                             y:positionY
                        atTime:time];
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
  // Rect / ellipse tool: begin the drag-out box.
  if ([self _shapeToolActive]) {
    [self _shapeMouseDownAtX:positionX y:positionY modifiers:modifiers];
    if (forceUpdate)
      *forceUpdate = YES;
    return;
  }
  // Corner-radius widget: Opt-click (master on) toggles the "Corners" element's
  // visibility - hide a visible one, re-show an Opt-peeked ghost - exactly like a
  // point/handle Opt-click. Otherwise fall through to the radius drag (the
  // controller's mouseDown detects the corner). When the element is individually
  // hidden under the master, a plain click is inert (don't edit a hidden widget).
  if (activePart == CanvasOSCPartCorner) {
    if ([self kkArmOptHideForActivePart:activePart modifiers:modifiers]) {
      if (forceUpdate)
        *forceUpdate = YES;
      return;
    }
    if (![self kkOSCMasterOff] && ![self kkOSCElementVisible:@"Corners"]) {
      if (forceUpdate)
        *forceUpdate = YES;
      return;
    }
    [self _pathEditMouseDownAtX:positionX y:positionY modifiers:modifiers];
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
    // Opt-click re-show above, so a normal click ON the hidden path is inert
    // (don't edit a hidden path). Gate on `onElement` (a hit on the path's
    // anchor/handle) - NOT "any layer under the cursor", which wrongly
    // swallowed the marquee whenever a layer (esp. an image, whose Points are
    // always hidden) sat under the start point. A drag NOT on an element must
    // still start a marquee. Master-OFF is "peek and use" - a drag proceeds to
    // edit.
    if (onElement && ![self kkOSCMasterOff] &&
        ![self kkOSCElementVisible:@"Points"]) {
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
    [self _commitPickSelectionWithModifiers:modifiers];
    if (forceUpdate)
      *forceUpdate = YES;
    return;
  }
  // Body-drag move: press on a selected layer. Record the start (the per-tick
  // translate works from this pre-drag blob, not cumulatively); the drag /
  // up decide move-vs-select.
  if (activePart == CanvasOSCPartLayerMove) {
    self.layerMoveHitID = self.pendingPickLayerID;
    self.layerMoveStartObj = [self _objYUpAtCanvasX:positionX y:positionY];
    self.layerMoveStartBlob = CanvasLayerBlobSnapshot();
    self.layerMoveDidMove = NO;
    self.penLiveParamWritten = NO;
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
  if ([self _shapeToolActive]) {
    [self _shapeMouseDraggedAtX:positionX y:positionY modifiers:modifiers];
    if (forceUpdate)
      *forceUpdate = YES;
    return;
  }
  // Body-drag move: translate the whole selection live from the pre-drag blob.
  if (activePart == CanvasOSCPartLayerMove) {
    CGPoint cur = [self _objYUpAtCanvasX:positionX y:positionY];
    simd_float2 d = simd_make_float2((float)(cur.x - self.layerMoveStartObj.x),
                                     (float)(cur.y - self.layerMoveStartObj.y));
    // A small dead-zone so a click with sub-pixel jitter stays a click
    // (select), not a move. Once moving, keep moving.
    if (!self.layerMoveDidMove && simd_length(d) < 0.003f) {
      if (forceUpdate)
        *forceUpdate = YES;
      return;
    }
    self.layerMoveDidMove = YES;
    NSString *b64 = self.layerMoveStartBlob;
    NSMutableArray<KKBezierPath *> *paths =
        b64.length
            ? [KKBezierPath
                  pathsFromBlob:[[NSData alloc] initWithBase64EncodedString:b64
                                                                    options:0]]
            : [NSMutableArray array];
    CanvasTranslateSelection(
        paths, [self _selectedLayerIDs], d, [self fractionAtTime:time],
        (float)[self _canvasAspect], [CanvasPlugin availableLanes]);
    [self penSetLiveLayers:paths];
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
  if ([self _shapeToolActive]) {
    [self _shapeMouseUp];
    if (forceUpdate)
      *forceUpdate = YES;
    return;
  }
  // Body-drag move end: a real drag commits the move as one undo; a click (no
  // drag) just (re)selects the layer (plain replace; Shift/Cmd toggles).
  if (activePart == CanvasOSCPartLayerMove) {
    if (self.layerMoveDidMove) {
      [self penCommitLiveLayers];
    } else {
      self.pendingPickLayerID = self.layerMoveHitID;
      [self _commitPickSelectionWithModifiers:modifiers];
    }
    self.layerMoveStartBlob = nil;
    self.layerMoveHitID = nil;
    self.layerMoveDidMove = NO;
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
  // Delete / Backspace with a LAYER selected (no anchors) removes the selected
  // layer(s). Consumed even on success/failure paths below so the key never
  // reaches FCP, which would otherwise delete the whole effect.
  if ((asciiKey == 127 || asciiKey == 8) &&
      [self _activeTool] == CanvasToolbarToolCursor &&
      self.pathEditController.selectedAnchors.count == 0 &&
      [self _selectedLayerIDs].count > 0) {
    [self _deleteSelectedLayers];
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
