/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerRender.h"
#import "CanvasMiniViewerRenderer_Internal.h"
#import "CanvasToolbar.h" // CanvasToolbarToolCursor
#import <KeyframelessKit/KeyframelessKit.h>

@implementation CanvasMiniViewerRenderer (Interaction)

// Transform handles (Position / motion path / Scale box / Anchor square) only
// show under the cursor tool; a drawing tool (pen, rect, ellipse) owns the
// canvas and hides them, matching the viewer OSC's pen branch. (Per-element
// visibility - incl. the gizmo being hidden by default - is governed separately
// by the OSC visibility system.)
- (BOOL)_transformHandlesActive {
  return (self.toolbarTool ?: CanvasToolbarToolCursor) == CanvasToolbarToolCursor;
}

// NS modifiers -> the shared controller's surface-neutral flags.
static CanvasPenModifiers CanvasEditModsFromNS(NSEventModifierFlags m) {
  CanvasPenModifiers o = CanvasPenModNone;
  if (m & NSEventModifierFlagShift)
    o |= CanvasPenModShift;
  if (m & NSEventModifierFlagCommand)
    o |= CanvasPenModCmd;
  if (m & NSEventModifierFlagControl)
    o |= CanvasPenModCtrl;
  return o;
}

// Path point editing is live when the cursor tool is active and the Points
// anchors OSC is shown (master on + not individually hidden).
- (BOOL)_pathEditContext {
  if ((self.toolbarTool ?: CanvasToolbarToolCursor) != CanvasToolbarToolCursor)
    return NO;
  return !self.handlesHidden &&
         ![self.hiddenHandleLabels containsObject:@"Points"];
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

// A click on the preview body (no handle hit) picks the topmost selectable image
// layer under the cursor, like the viewer OSC; editing then follows via
// onSelectLayer -> the inspector's _selectLayer.
- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    backgroundClickAtPoint:(CGPoint)p
               contentRect:(CGRect)cr {
  NSString *hit = [self _autoSelectLayerAtPoint:p contentRect:cr];
  if (!hit.length || [hit isEqualToString:self.selectedLayerID])
    return NO;
  if (self.onSelectLayer)
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
  CGRect sb;
  if ([self _transformHandlesActive] &&
      [self.scaleMini boxRect:&sb forContentRect:cr]) {
    [boxes addObject:[KKMiniBox boxWithRect:sb
                              handleCenters:[self.scaleMini
                                                handleCentersForContentRect:cr]
                                    readout:[self.scaleMini readoutText]
                                 ghostAlpha:[self.scaleMini ghostAlpha]]];
  }
  return boxes;
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    handleHitAtPoint:(CGPoint)p
         contentRect:(CGRect)cr {
  // Anchor square is topmost so its TIGHT central grab zone (hitRadiusPt = 3)
  // wins, but the larger Position handle around it stays clickable - so clicking
  // the centre square grabs the anchor while the Position arc/ring grabs Position.
  // The anchor is also grabbable wherever it's offset (e.g. a group, whose pivot
  // is its content centre).
  self.canvas = canvas;
  self.penContentRect = cr;
  // Path point editing claims first (so the overlay grabs the click for an
  // anchor/handle instead of letting it fall through to a view pan).
  if ([self _pathEditContext] &&
      [self.pathEditController hitTestAtX:p.x y:p.y] != CanvasPathEditHitNone)
    return YES;
  if ([self.anchorMini squareHitAtPoint:p contentRect:cr])
    return YES;
  // The active keypose's Position handle wins where it coincides with a path
  // anchor/tangent (handles sit offset from the anchor, so they stay grabbable).
  if ([self pointHandleHitAtPoint:p contentRect:cr])
    return YES;
  if ([self.positionMini pathHandleHitAtPoint:p contentRect:cr])
    return YES;
  if ([self.positionMini pathAnchorHitAtPoint:p contentRect:cr])
    return YES;
  if ([self.scaleMini handleHitAtPoint:p contentRect:cr outIndex:NULL])
    return YES;
  return [super miniViewer:canvas handleHitAtPoint:p contentRect:cr];
}

- (void)miniViewer:(KKMiniViewerView *)canvas
    beginHandleDragAtPoint:(CGPoint)p
               contentRect:(CGRect)cr {
  self.canvas = canvas;
  self.penContentRect = cr;
  // Path point editing grabs an anchor / handle first (the gizmo is hidden for a
  // selected path, so this is the primary interaction).
  if ([self _pathEditContext] &&
      [self.pathEditController mouseDownAtX:p.x y:p.y modifiers:CanvasPenModNone])
    return;
  // Anchor square grabs first (tight central zone, matches the hit-test priority).
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
  [super miniViewer:canvas beginHandleDragAtPoint:p contentRect:cr];
}

- (void)miniViewer:(KKMiniViewerView *)canvas
    dragHandleToPoint:(CGPoint)p
          contentRect:(CGRect)cr
            modifiers:(NSEventModifierFlags)modifiers {
  self.penContentRect = cr;
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

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    doubleClickAtPoint:(CGPoint)p
           contentRect:(CGRect)cr {
  self.canvas = canvas;
  return [self.positionMini toggleSmoothAtPoint:p contentRect:cr];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    optClickHandleAtPoint:(CGPoint)p
              contentRect:(CGRect)cr {
  // Anchor square (tight central zone) claims the opt-click first.
  self.canvas = canvas;
  if (self.onHandleVisibilityToggled &&
      [self.anchorMini squareHitAtPoint:p contentRect:cr]) {
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
    return KKPointMoveCursor();
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
  // Over a selectable layer body (auto-select would pick it): pointing hand,
  // matching the viewer OSC's hover cursor.
  NSString *pick = [self _autoSelectLayerAtPoint:p contentRect:cr];
  if (pick.length && ![pick isEqualToString:self.selectedLayerID])
    return [NSCursor pointingHandCursor];
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
