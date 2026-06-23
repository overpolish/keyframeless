/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerRender.h"
#import "CanvasLayerTimeline.h" // CanvasLayerTimelineForPath (override resync)
#import "CanvasMiniViewerRenderer_Internal.h"
#import "CanvasPathMorph.h" // CanvasTranslateSelection (body-drag move)
#import "CanvasToolbar.h"   // CanvasToolbarToolCursor
#import <KeyframelessKit/KeyframelessKit.h>

// The cursor-tool GESTURE LIFECYCLE for the mini surface: hit ordering
// (handleHitAtPoint:), and the press/drag/release that drives point editing,
// body-drag move of the selection, and the empty-canvas marquee. Split from the
// hover/cursor policy + helpers (CanvasMiniViewerRenderer+Interaction.m), which
// declares the shared gesture helpers used here.
@implementation CanvasMiniViewerRenderer (Gesture)

// NS modifiers -> the shared controller's surface-neutral flags.
static CanvasPenModifiers CanvasEditModsFromNS(NSEventModifierFlags m) {
  CanvasPenModifiers o = CanvasPenModNone;
  if (m & NSEventModifierFlagShift)
    o |= CanvasPenModShift;
  if (m & NSEventModifierFlagCommand)
    o |= CanvasPenModCmd;
  if (m & NSEventModifierFlagControl)
    o |= CanvasPenModCtrl;
  if (m & NSEventModifierFlagOption)
    o |= CanvasPenModOpt;
  return o;
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    handleHitAtPoint:(CGPoint)p
         contentRect:(CGRect)cr {
  // Anchor square is topmost so its TIGHT central grab zone (hitRadiusPt = 3)
  // wins, but the larger Position handle around it stays clickable - so
  // clicking the centre square grabs the anchor while the Position arc/ring
  // grabs Position. The anchor is also grabbable wherever it's offset (e.g. a
  // group, whose pivot is its content centre).
  self.canvas = canvas;
  self.penContentRect = cr;
  // Path point editing claims first (so the overlay grabs the click for an
  // anchor/handle instead of letting it fall through to a view pan).
  // A marquee is only claimed INSIDE the active content rect: in filmstrip mode
  // the active cell == cr and the inactive cells fan out beyond it, so a click
  // on an inactive cell stays unclaimed here and falls through to the view's
  // mouseDown filmstrip cell-switch.
  if ([self _pathEditContext]) {
    if ([self.pathEditController hitTestAtX:p.x y:p.y] != CanvasPathEditHitNone)
      return YES;
    if ([self.pathEditController cornerWidgetHitAtX:p.x y:p.y])
      return YES; // the corner widget claims the click (sits in empty area)
  }
  if ([self.anchorMini squareHitAtPoint:p contentRect:cr])
    return YES;
  // The active keypose's Position handle wins where it coincides with a path
  // anchor/tangent (handles sit offset from the anchor, so they stay
  // grabbable).
  if ([self pointHandleHitAtPoint:p contentRect:cr])
    return YES;
  if ([self.positionMini pathHandleHitAtPoint:p contentRect:cr])
    return YES;
  if ([self.positionMini pathAnchorHitAtPoint:p contentRect:cr])
    return YES;
  if ([self.scaleMini handleHitAtPoint:p contentRect:cr outIndex:NULL])
    return YES;
  // Base transform handles (the 3-axis rotation rings, drawn + hit-tested by
  // KKMiniViewerRenderer via the rotationLabel opt-in) must be claimed BEFORE
  // the body-move / marquee fallbacks, else a click on a ring is stolen by a
  // layer move or a marquee. The OSC always wins over move/select.
  if ([super miniViewer:canvas handleHitAtPoint:p contentRect:cr])
    return YES;
  // Body of a SELECTED layer: a drag moves the whole selection (after every
  // handle, so handles keep priority; the path body is a move, not a marquee).
  if ([self _selectedLayerUnderPoint:p contentRect:cr].length)
    return YES;
  // Empty-canvas layer marquee: claimed last so every handle keeps priority.
  if ([self _layerMarqueeAllowedAtPoint:p contentRect:cr])
    return YES;
  return NO;
}

- (void)miniViewer:(KKMiniViewerView *)canvas
    beginHandleDragAtPoint:(CGPoint)p
               contentRect:(CGRect)cr {
  self.canvas = canvas;
  self.penContentRect = cr;
  CanvasPenModifiers em = CanvasEditModsFromNS(NSEvent.modifierFlags);
  // Path point editing: ONLY on an anchor / handle / corner of the selected
  // path - NOT its body (the body is a move, below). Pass the live modifiers so
  // Shift/Opt at selection START is seen.
  if ([self _pathEditContext] &&
      ([self.pathEditController hitTestAtX:p.x
                                         y:p.y] != CanvasPathEditHitNone ||
       [self.pathEditController cornerWidgetHitAtX:p.x y:p.y]) &&
      [self.pathEditController mouseDownAtX:p.x y:p.y modifiers:em])
    return;
  // Anchor square grabs first (tight central zone, matches the hit-test
  // priority).
  if ([self.anchorMini beginDragAtPoint:p contentRect:cr])
    return;
  // Position handle next (the base re-checks it and drives the point grab
  // lifecycle), then the motion-path anchors / tangent handles (the controller
  // owns those; the base doesn't know about them).
  if ([self pointHandleHitAtPoint:p contentRect:cr]) {
    [super miniViewer:canvas beginHandleDragAtPoint:p contentRect:cr];
    return;
  }
  self.canvas = canvas;
  if ([self.positionMini beginPathDragAtPoint:p contentRect:cr])
    return;
  if ([self.scaleMini beginDragAtPoint:p contentRect:cr]) {
    self.canvas = canvas;
    return;
  }
  // Base transform handles (rotation rings): if the base claims this point,
  // delegate the drag to it before the body-move / marquee fallbacks so a ring
  // grabs rotation. The point handle above already returned, so this resolves
  // to a rotation-ring hit; the base's dragHandleToPoint / endDrag (reached via
  // the !pointHandleIsActive branch below) then drive and commit the rotation.
  if ([super miniViewer:canvas handleHitAtPoint:p contentRect:cr]) {
    [super miniViewer:canvas beginHandleDragAtPoint:p contentRect:cr];
    return;
  }
  // Body of a selected layer: begin a move (translate from this pre-drag
  // stack).
  NSString *moveHit = [self _selectedLayerUnderPoint:p contentRect:cr];
  if (moveHit.length) {
    self.layerMoveActive = YES;
    self.layerMoveHitID = moveHit;
    self.layerMoveStartObj = [self penObjFromSurfaceX:p.x y:p.y];
    self.layerMoveStartLayers = [self.layers copy];
    self.layerMoveDidMove = NO;
    return;
  }
  // Empty-canvas marquee: LAST, so every transform handle (incl. the rotation
  // rings, which sit in empty space beyond a group's small content body) keeps
  // priority. Mirrors the hit-test order; otherwise a click on a group's ring
  // out over the empty canvas would start a marquee instead of rotating.
  if ([self _layerMarqueeAllowedAtPoint:p contentRect:cr] &&
      [self.pathEditController mouseDownAtX:p.x y:p.y modifiers:em])
    return;
  [super miniViewer:canvas beginHandleDragAtPoint:p contentRect:cr];
}

- (void)miniViewer:(KKMiniViewerView *)canvas
    dragHandleToPoint:(CGPoint)p
          contentRect:(CGRect)cr
            modifiers:(NSEventModifierFlags)modifiers {
  self.penContentRect = cr;
  // Body-drag move: translate the whole selection live from the pre-drag stack.
  if (self.layerMoveActive) {
    CGPoint cur = [self penObjFromSurfaceX:p.x y:p.y];
    simd_float2 d = simd_make_float2((float)(cur.x - self.layerMoveStartObj.x),
                                     (float)(cur.y - self.layerMoveStartObj.y));
    // Nothing in the selection is movable in this scope (all excluded, e.g.
    // constants move-lane-animated): stay a click, never a no-op move/persist.
    NSArray<NSString *> *movable = [self _miniMovableSelectedIDs];
    if (movable.count == 0)
      return;
    if (!self.layerMoveDidMove && simd_length(d) < 0.003f)
      return; // dead-zone: a click with jitter stays a click (select)
    self.layerMoveDidMove = YES;
    NSMutableArray<KKBezierPath *> *paths =
        [self.layerMoveStartLayers mutableCopy] ?: [NSMutableArray array];
    CanvasTranslateSelection(paths, movable, d, self.editFraction,
                             (float)[self penCanvasAspect], self.laneTemplates);
    self.layers = paths;
    // The PRIMARY (selected) image reads its transform from the override
    // timeline (self.timeline) in CanvasEncodeImageLayers, NOT from its path -
    // so a body move that only rewrote the paths leaves the primary visually
    // stuck (its box moves, its image doesn't; always the topmost/selected
    // one). Resync the override from the translated primary so it moves with
    // the rest.
    KKBezierPath *primary =
        CanvasSelectedLayerForPaths(paths, self.selectedLayerID);
    if (primary)
      self.timeline = CanvasLayerTimelineForPath(primary, self.laneTemplates);
    [canvas setNeedsDisplay:YES];
    return;
  }
  if (self.pathEditController.dragging) {
    [self.pathEditController mouseDraggedAtX:p.x
                                           y:p.y
                                   modifiers:CanvasEditModsFromNS(modifiers)];
    [canvas setNeedsDisplay:YES];
    return;
  }
  if (self.anchorMini.isDragging) {
    [self.anchorMini applyDragToPoint:p
                          contentRect:cr
                            modifiers:modifiers
                               canvas:canvas];
    return;
  }
  if (self.positionMini.pathGrabbed) {
    [self.positionMini applyPathDragToPoint:p
                                contentRect:cr
                                  modifiers:modifiers];
    return;
  }
  if (self.scaleMini.isDragging) {
    [self.scaleMini applyDragToPoint:p
                         contentRect:cr
                           modifiers:modifiers
                              canvas:canvas];
    return;
  }
  if (![self pointHandleIsActive]) {
    [super miniViewer:canvas
        dragHandleToPoint:p
              contentRect:cr
                modifiers:modifiers];
    return;
  }
  [self applyPointDragToPoint:p
                  contentRect:cr
                       canvas:canvas
                    modifiers:modifiers];
}

- (void)miniViewerEndHandleDrag:(KKMiniViewerView *)canvas {
  // Body-drag move end: a real drag persists the move as one undo; a click (no
  // drag) just (re)selects the layer (collapses a multi-selection to it).
  if (self.layerMoveActive) {
    self.layerMoveActive = NO;
    if (self.layerMoveDidMove) {
      if (self.onPersistLayers)
        self.onPersistLayers(self.layers, self.selectedLayerID);
    } else if (self.layerMoveHitID.length) {
      if (self.onSelectLayers)
        self.onSelectLayers(@[ self.layerMoveHitID ], self.layerMoveHitID);
      else if (self.onSelectLayer)
        self.onSelectLayer(self.layerMoveHitID);
    }
    self.layerMoveStartLayers = nil;
    self.layerMoveHitID = nil;
    self.layerMoveDidMove = NO;
    [canvas setNeedsDisplay:YES];
    [canvas setHandlesNeedDisplay];
    return;
  }
  if (self.pathEditController.dragging) {
    [self.pathEditController mouseUp];
    [canvas setNeedsDisplay:YES];
    [canvas setHandlesNeedDisplay];
    return;
  }
  [self.anchorMini endDrag];
  [self.scaleMini endDrag];
  // endDrag resets the shared snap engine and reports whether a motion-path
  // drag was active (the only Position-side edit that persists the whole blob;
  // a plain Position-handle drag persists through the popover's keypose write).
  if ([self.positionMini endDrag]) {
    if (self.onTimelinePersist)
      self.onTimelinePersist(self.timeline);
    [canvas setNeedsDisplay:YES];
    [canvas setHandlesNeedDisplay];
    return;
  }
  [super miniViewerEndHandleDrag:canvas];
}

@end
