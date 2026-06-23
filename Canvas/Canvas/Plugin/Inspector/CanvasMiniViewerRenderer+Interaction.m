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

@implementation CanvasMiniViewerRenderer (Interaction)

// The lone selected layer when EXACTLY one is selected, else nil. Mirrors the
// viewer's `_loneSelectedLayer`; drives the selection-type display rules.
- (KKBezierPath *)_loneSelectedLayer {
  NSArray<NSString *> *sel = [self _miniSelectedIDs];
  if (sel.count != 1)
    return nil;
  NSString *lid = sel.firstObject;
  for (KKBezierPath *p in self.layers)
    if ([p.layerID isEqualToString:lid])
      return p;
  return nil;
}

// Transform handles (Position / motion path / Scale box / Anchor square) show
// only under the cursor tool AND for a lone image / group - a drawing tool owns
// the canvas, and a lone path / multi / empty selection shows points or nothing
// instead (matching the viewer). Per-element visibility is still governed on top
// by the OSC visibility system.
- (BOOL)_transformHandlesActive {
  if ((self.toolbarTool ?: CanvasToolbarToolCursor) != CanvasToolbarToolCursor)
    return NO;
  KKBezierPath *lone = [self _loneSelectedLayer];
  return lone && (lone.isImage || lone.isGroup);
}

// Path point editing is live when the cursor tool is active and the Points
// anchors OSC is shown OR being revealed - labelVisibleOrRevealing: folds in
// the master tick, the per-element pill, and the Opt-peek/reveal exactly like
// the transform handles (master-on reveal = dim re-show ghost; master-off =
// peek and use). Editing only actually starts when it resolves to an
// interactive state: a master-on reveal click is routed to the opt-click
// re-show, not a drag.
- (BOOL)_pathEditContext {
  if ((self.toolbarTool ?: CanvasToolbarToolCursor) != CanvasToolbarToolCursor)
    return NO;
  // Point editing is off while a multi-selection is active (layer-level
  // selection - points show dimmed, non-editable), mirroring the viewer.
  if ([self _miniSelectedIDs].count > 1)
    return NO;
  // Match the transform OSCs: a constants popover only edits CONSTANT lanes; a
  // keypose (boundary) popover only the ANIMATED one it's editing. Without this
  // the Points OSC + corner widgets show / edit on an animated layer's constants
  // popover, unlike every other plugin's lanes.
  if (![self isConstantLabel:@"Points"])
    return NO;
  return [self labelVisibleOrRevealing:@"Points"];
}

// Auto-select hit-test in the mini. The content rect maps object X directly and
// object Y FLIPPED (content/Position is y-down: py=0 at the top per
// handlePointForContentRect; the render's object space is y-up), so
// objY = 1 - (p.y - minY)/h - matching the viewer's mouse-Y flip. Honors the
// toggle + the non-selectable gating (e.g. a keypose popover only lets you pick
// layers with a keypose at that time), mirroring the layer list.
- (NSString *)_autoSelectLayerAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  if (!self.autoSelectEnabled || cr.size.width <= 0 || cr.size.height <= 0)
    return nil;
  float objX = (float)((p.x - CGRectGetMinX(cr)) / cr.size.width);
  float objY = (float)(1.0 - (p.y - CGRectGetMinY(cr)) / cr.size.height);
  float aspect = (float)(cr.size.width / cr.size.height);
  return CanvasHitTestLayerID(self.layers ?: @[], self.editFraction, aspect,
                              objX, objY, /*alphaAware=*/YES,
                              self.nonSelectableLayerIDs,
                              /*requireEditableAtFrac=*/NO, /*templates=*/nil,
                              (float)self.renderHeight);
}

// Toggle-independent geometric layer hit: is ANY layer under this point? Used to
// tell "empty canvas" (start a layer marquee) from "over a layer" (leave it for
// pick / body-drag), regardless of the auto-select toggle or selectability.
- (NSString *)_anyLayerAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  if (cr.size.width <= 0 || cr.size.height <= 0)
    return nil;
  float objX = (float)((p.x - CGRectGetMinX(cr)) / cr.size.width);
  float objY = (float)(1.0 - (p.y - CGRectGetMinY(cr)) / cr.size.height);
  float aspect = (float)(cr.size.width / cr.size.height);
  return CanvasHitTestLayerID(self.layers ?: @[], self.editFraction, aspect, objX,
                              objY, /*alphaAware=*/YES, /*excluded=*/nil,
                              /*requireEditableAtFrac=*/NO, /*templates=*/nil,
                              (float)self.renderHeight);
}

// The SELECTED layer under `p` (cursor tool, inside the rect), or nil - a drag
// here moves the whole selection. Mirrors the viewer's hover claim.
- (NSString *)_selectedLayerUnderPoint:(CGPoint)p contentRect:(CGRect)cr {
  if ((self.toolbarTool ?: CanvasToolbarToolCursor) != CanvasToolbarToolCursor)
    return nil;
  // Only filmstrip mode (renderMode 1) fans cells out beyond the content rect, so
  // only then is an outside-cr point another cell rather than off-frame canvas.
  if (self.canvas.renderMode == 1 && !CGRectContainsPoint(cr, p))
    return nil;
  NSString *hit = [self _anyLayerAtPoint:p contentRect:cr];
  NSSet<NSString *> *blocked =
      self.marqueeNonSelectableLayerIDs ?: self.nonSelectableLayerIDs;
  if (!hit.length || [blocked containsObject:hit])
    return nil; // not movable in this popover scope
  return [[self _miniSelectedIDs] containsObject:hit] ? hit : nil;
}

// Cursor-tool empty-canvas LAYER marquee allowed here? Inside the active rect,
// not on a handle/anchor (canMarquee), and no layer under the cursor - so a drag
// selects whole layers for ANY selection state (none / image / multi). The
// single-editable-path case is handled by the _pathEditContext block instead.
- (BOOL)_layerMarqueeAllowedAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  if ((self.toolbarTool ?: CanvasToolbarToolCursor) != CanvasToolbarToolCursor)
    return NO;
  // Restrict to the content rect ONLY in filmstrip mode (renderMode 1), where
  // inactive cells fan out beyond cr and need their click to switch cells. In
  // single-frame / onion mode the marquee may start anywhere, so a layer dragged
  // OUTSIDE the frame (into the letterbox) can still be marqueed - matching the
  // main viewer.
  if (self.canvas.renderMode == 1 && !CGRectContainsPoint(cr, p))
    return NO;
  if (![self.pathEditController canMarqueeAtX:p.x y:p.y])
    return NO;
  // Empty area -> always marquee. Over a layer body -> only with auto-select OFF
  // AND the layer not selected: with auto-select OFF nothing else claims an
  // unselected layer body, so a drag must still rubber-band over an image (a
  // SELECTED body is a move, claimed before this; with auto-select ON an
  // unselected layer is a click-pick).
  if ([self _anyLayerAtPoint:p contentRect:cr].length == 0)
    return YES;
  return !self.autoSelectEnabled &&
         [self _selectedLayerUnderPoint:p contentRect:cr].length == 0;
}

// A click on the preview body (no handle hit) picks the topmost selectable
// image layer under the cursor, like the viewer OSC; editing then follows via
// onSelectLayer -> the inspector's _selectLayer.
- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    backgroundClickAtPoint:(CGPoint)p
               contentRect:(CGRect)cr {
  NSString *hit = [self _autoSelectLayerAtPoint:p contentRect:cr];
  if (!hit.length)
    return NO;
  // Shift / Cmd makes the click additive (toggle into / out of the
  // multi-selection); a plain click replaces it, or collapses a multi-selection
  // to the clicked layer. Mirrors the viewer OSC.
  BOOL additive = (NSEvent.modifierFlags & (NSEventModifierFlagShift |
                                            NSEventModifierFlagCommand)) != 0;
  NSArray<NSString *> *cur = [self _miniSelectedIDs];
  BOOL alreadySel = [cur containsObject:hit];
  if (!additive && alreadySel && cur.count <= 1)
    return NO; // clicking the only-selected layer is a no-op
  NSMutableArray<NSString *> *set = [cur mutableCopy];
  NSString *primary;
  if (additive) {
    if (alreadySel) {
      [set removeObject:hit];
      primary = set.count ? set.firstObject : @"";
    } else {
      [set addObject:hit];
      primary = hit;
    }
  } else {
    set = [@[ hit ] mutableCopy];
    primary = hit;
  }
  if (self.onSelectLayers)
    self.onSelectLayers(set, primary);
  else if (self.onSelectLayer)
    self.onSelectLayer(hit);
  return YES;
}

- (NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
    motionPathPolylineForContentRect:(CGRect)cr {
  if (![self _transformHandlesActive])
    return @[];
  return [self.positionMini motionPathPolylineForContentRect:cr];
}

- (NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
    motionPathAnchorsForContentRect:(CGRect)cr {
  if (![self _transformHandlesActive])
    return @[];
  return [self.positionMini motionPathAnchorsForContentRect:cr];
}

- (NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
    motionPathHandleSegmentsForContentRect:(CGRect)cr {
  if (![self _transformHandlesActive])
    return @[];
  return [self.positionMini motionPathHandleSegmentsForContentRect:cr];
}

- (CGFloat)motionPathGhostAlpha {
  return [self ghostAlphaForLabel:@"Path"];
}

// Anchor pivot square - the kit canvas draws it from these; geometry + ghost
// live in the reusable KKAnchorMiniController.
- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    anchorSquareCenter:(out CGPoint *)outCenter
           contentRect:(CGRect)cr {
  self.canvas = canvas;
  if (![self _transformHandlesActive])
    return NO;
  return [self.anchorMini squareCenter:outCenter forContentRect:cr];
}

- (CGFloat)anchorSquareGhostAlpha {
  return [self.anchorMini ghostAlpha];
}

- (BOOL)pointHandleCenter:(out CGPoint *)outCenter forContentRect:(CGRect)cr {
  if (![self _transformHandlesActive])
    return NO;
  return [self.positionMini pointHandleCenter:outCenter forContentRect:cr];
}

- (BOOL)pointHandleCenter:(out CGPoint *)outCenter
                 forValue:(double)value
           forContentRect:(CGRect)cr {
  // Position is 2D; no single-scalar guide target.
  return NO;
}

- (BOOL)pointHandleCenter:(out CGPoint *)outCenter
                forValues:(NSArray<NSNumber *> *)values
           forContentRect:(CGRect)cr {
  if (![self _transformHandlesActive])
    return NO;
  return [self.positionMini pointHandleCenter:outCenter
                                    forValues:values
                               forContentRect:cr];
}

- (BOOL)pointHandleHitAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  return [self.positionMini pointHandleHitAtPoint:p contentRect:cr];
}

- (void)applyPointDragToPoint:(CGPoint)p
                  contentRect:(CGRect)cr
                       canvas:(KKMiniViewerView *)canvas {
  // No-modifier path is only called on begin (the kit's
  // beginHandleDragAtPoint): capture the press state, then apply with no
  // modifiers. Ongoing drag ticks go through -dragHandleToPoint:modifiers:
  // below (which applies without re-capturing).
  [self.positionMini beginPointDragAtPoint:p contentRect:cr];
  [self.positionMini applyPointDragToPoint:p
                               contentRect:cr
                                    canvas:canvas
                                 modifiers:0];
}

- (void)applyPointDragToPoint:(CGPoint)p
                  contentRect:(CGRect)cr
                       canvas:(KKMiniViewerView *)canvas
                    modifiers:(NSEventModifierFlags)modifiers {
  [self.positionMini applyPointDragToPoint:p
                               contentRect:cr
                                    canvas:canvas
                                 modifiers:modifiers];
}

// Scale transform box (parity with the viewer). All geometry + hit-test + drag
// live in the reusable KKScaleMiniController; these are the thin delegate
// forwards the shared KKMiniViewerView calls.
- (BOOL)miniViewer:(KKMiniViewerView *)canvas
      scaleBoxRect:(out CGRect *)outRect
    forContentRect:(CGRect)cr {
  if (![self _transformHandlesActive])
    return NO;
  return [self.scaleMini boxRect:outRect forContentRect:cr];
}

- (NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
    scaleHandleCentersForContentRect:(CGRect)cr {
  if (![self _transformHandlesActive])
    return @[];
  return [self.scaleMini handleCentersForContentRect:cr];
}

- (NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
       scaleHandleCentersForValues:(NSArray<NSNumber *> *)values
                       contentRect:(CGRect)cr {
  if (![self _transformHandlesActive])
    return @[];
  return [self.scaleMini handleCentersForValues:values contentRect:cr];
}

// The Scale transform box, appended to the base's boxes (Canvas has no crop, so
// super returns none). The shared box path in KKMiniViewerView draws the border
// + 8 handles + readout.
- (NSArray<KKMiniBox *> *)miniViewer:(KKMiniViewerView *)canvas
                 boxesForContentRect:(CGRect)cr {
  NSMutableArray<KKMiniBox *> *boxes = [[super miniViewer:canvas
                                      boxesForContentRect:cr] mutableCopy];
  CGRect sb = CGRectZero;
  if ([self _transformHandlesActive] && [self.scaleMini boxRect:&sb
                                                 forContentRect:cr]) {
    [boxes addObject:[KKMiniBox boxWithRect:sb
                              handleCenters:[self.scaleMini
                                                handleCentersForContentRect:cr]
                                    readout:[self.scaleMini readoutText]
                                 ghostAlpha:[self.scaleMini ghostAlpha]]];
  }
  return boxes;
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    doubleClickAtPoint:(CGPoint)p
           contentRect:(CGRect)cr {
  self.canvas = canvas;
  self.penContentRect = cr;
  // A path anchor under the double-click converts corner<->smooth first; else
  // the Position motion-path anchor's smooth toggle.
  if ([self _pathEditContext] && [self.pathEditController toggleSmoothAtX:p.x
                                                                        y:p.y])
    return YES;
  return [self.positionMini toggleSmoothAtPoint:p contentRect:cr];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    optClickHandleAtPoint:(CGPoint)p
              contentRect:(CGRect)cr {
  // Anchor square (tight central zone) claims the opt-click first.
  self.canvas = canvas;
  if (self.onHandleVisibilityToggled && [self.anchorMini squareHitAtPoint:p
                                                              contentRect:cr]) {
    self.onHandleVisibilityToggled(@"Anchor");
    [canvas setNeedsDisplay:YES];
    [canvas setHandlesNeedDisplay];
    return YES;
  }
  // The built-in Position handle claims the opt-click next (so at the active
  // keypose it wins over the coincident path anchor), then the path catches its
  // own anchors / tangents.
  if ([super miniViewer:canvas optClickHandleAtPoint:p contentRect:cr])
    return YES;
  if (self.onHandleVisibilityToggled &&
      ([self.positionMini pathHandleHitAtPoint:p contentRect:cr] ||
       [self.positionMini pathAnchorHitAtPoint:p contentRect:cr])) {
    self.onHandleVisibilityToggled(@"Path");
    [canvas setNeedsDisplay:YES];
    [canvas setHandlesNeedDisplay];
    return YES;
  }
  if (self.onHandleVisibilityToggled &&
      [self.scaleMini handleHitAtPoint:p contentRect:cr outIndex:NULL]) {
    self.onHandleVisibilityToggled(@"Scale");
    [canvas setNeedsDisplay:YES];
    [canvas setHandlesNeedDisplay];
    return YES;
  }
  // Path anchors catch the opt-click last (transform handles win a coincident
  // hit, matching the viewer). Toggles the Points OSC's visibility.
  if (self.onHandleVisibilityToggled && [self _pathEditContext] &&
      [self.pathEditController hitTestAtX:p.x y:p.y] != CanvasPathEditHitNone) {
    self.onHandleVisibilityToggled(@"Points");
    [canvas setNeedsDisplay:YES];
    [canvas setHandlesNeedDisplay];
    return YES;
  }
  return NO;
}

- (NSCursor *)miniViewer:(KKMiniViewerView *)canvas
           cursorAtPoint:(CGPoint)p
             contentRect:(CGRect)cr {
  if (CGRectIsEmpty(cr))
    return nil;
  self.canvas = canvas;
  self.penContentRect = cr;
  if ([self _pathEditContext] &&
      [self.pathEditController hitTestAtX:p.x y:p.y] != CanvasPathEditHitNone)
    return [self kkVisibilityCursorForLabel:@"Points"] ?: KKPointMoveCursor();
  // Live-corner radius widget: crosshair, matching the viewer (which crosshairs
  // the path-edit empty area the widget sits in).
  if ([self _pathEditContext] &&
      [self.pathEditController cornerWidgetHitAtX:p.x y:p.y])
    return [NSCursor crosshairCursor];
  if ([self.anchorMini squareHitAtPoint:p contentRect:cr])
    return [self kkVisibilityCursorForLabel:@"Anchor"] ?: KKPointMoveCursor();
  if ([self pointHandleHitAtPoint:p contentRect:cr])
    return [self kkVisibilityCursorForLabel:self.pointLabel]
               ?: KKPointMoveCursor();
  if ([self.positionMini pathHandleHitAtPoint:p contentRect:cr])
    return [self kkVisibilityCursorForLabel:@"Path"] ?: KKPointMoveCursor();
  if ([self.positionMini pathAnchorHitAtPoint:p contentRect:cr])
    return [self kkVisibilityCursorForLabel:@"Path"] ?: KKPointMoveCursor();
  NSInteger idx;
  if ([self.scaleMini handleHitAtPoint:p contentRect:cr outIndex:&idx])
    return [self kkVisibilityCursorForLabel:@"Scale"]
               ?: KKResizeCursorForBoxHandle(idx);
  // Over a SELECTED layer body: open hand (a drag moves the selection),
  // matching the viewer OSC's body-drag cursor.
  if ([self _selectedLayerUnderPoint:p contentRect:cr].length)
    return [NSCursor openHandCursor];
  // Over a selectable unselected layer body (auto-select would pick it):
  // pointing hand, matching the viewer OSC's hover cursor.
  NSString *pick = [self _autoSelectLayerAtPoint:p contentRect:cr];
  if (pick.length && ![pick isEqualToString:self.selectedLayerID])
    return [NSCursor pointingHandCursor];
  // Empty canvas: crosshair (a drag marquees), matching the viewer.
  if ([self _layerMarqueeAllowedAtPoint:p contentRect:cr])
    return [NSCursor crosshairCursor];
  return [super miniViewer:canvas cursorAtPoint:p contentRect:cr];
}

- (void)miniViewer:(KKMiniViewerView *)canvas
     snapGuideHasX:(out BOOL *)hasX
                 X:(out CGFloat *)outX
      fromKeyposeX:(out BOOL *)fromKeyposeX
              hasY:(out BOOL *)hasY
                 Y:(out CGFloat *)outY
      fromKeyposeY:(out BOOL *)fromKeyposeY {
  [self.positionMini snapGuideHasX:hasX
                                 X:outX
                      fromKeyposeX:fromKeyposeX
                              hasY:hasY
                                 Y:outY
                      fromKeyposeY:fromKeyposeY];
}

@end
