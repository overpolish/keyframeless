/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MagicMoveMiniViewerRenderer_Internal.h"
#import "MagicMoveParamsBuild.h"
#import "ShaderTypes.h"
#import <KeyframelessKit/KeyframelessKit.h>
#import <Metal/Metal.h>

@implementation MagicMoveMiniViewerRenderer (Interaction)

- (NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
    motionPathPolylineForContentRect:(CGRect)cr {
  return [self.positionMini motionPathPolylineForContentRect:cr];
}

- (NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
    motionPathAnchorsForContentRect:(CGRect)cr {
  return [self.positionMini motionPathAnchorsForContentRect:cr];
}

- (NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
    motionPathHandleSegmentsForContentRect:(CGRect)cr {
  return [self.positionMini motionPathHandleSegmentsForContentRect:cr];
}

- (BOOL)pointHandleCenter:(out CGPoint *)outCenter forContentRect:(CGRect)cr {
  return [self.positionMini pointHandleCenter:outCenter forContentRect:cr];
}

// Scale transform box (mini-viewer parity with the viewer). All geometry +
// hit-test + drag live in the reusable KKScaleMiniController; these are the
// thin delegate forwards the shared KKMiniViewerView calls.
- (BOOL)miniViewer:(KKMiniViewerView *)canvas
      scaleBoxRect:(out CGRect *)outRect
    forContentRect:(CGRect)cr {
  return [self.scaleMini boxRect:outRect forContentRect:cr];
}

- (NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
    scaleHandleCentersForContentRect:(CGRect)cr {
  return [self.scaleMini handleCentersForContentRect:cr];
}

// Scale-box handle centres the box *would* have at explicit scale percents -
// the guide's "drag the corner out to 200%" target.
- (NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
       scaleHandleCentersForValues:(NSArray<NSNumber *> *)values
                       contentRect:(CGRect)cr {
  return [self.scaleMini handleCentersForValues:values contentRect:cr];
}

// The Scale transform box, appended to the base's boxes (Magic Move has no
// crop, so super returns none). The shared box path in KKMiniViewerView draws
// the border + 8 handles + readout uniformly with the crop box.
- (NSArray<KKMiniBox *> *)miniViewer:(KKMiniViewerView *)canvas
                 boxesForContentRect:(CGRect)cr {
  NSMutableArray<KKMiniBox *> *boxes = [[super miniViewer:canvas
                                      boxesForContentRect:cr] mutableCopy];
  CGRect sb;
  if ([self.scaleMini boxRect:&sb forContentRect:cr]) {
    [boxes addObject:[KKMiniBox boxWithRect:sb
                              handleCenters:[self.scaleMini
                                                handleCentersForContentRect:cr]
                                    readout:[self.scaleMini readoutText]
                                 ghostAlpha:[self.scaleMini ghostAlpha]]];
  }
  return boxes;
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
  // No-modifier path is only called on begin (kit's beginHandleDragAtPoint):
  // capture the press state, then apply with no modifiers.
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

// Mini-viewer drag is also called via the delegate dispatcher in
// KKMiniViewerView so the modifier variant takes precedence over the plain
// one.
- (void)miniViewer:(KKMiniViewerView *)canvas
    dragHandleToPoint:(CGPoint)p
          contentRect:(CGRect)cr
            modifiers:(NSEventModifierFlags)modifiers {
  if (_anchorGrabbed) {
    [self _applyAnchorDragToPoint:p contentRect:cr modifiers:modifiers];
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
  // Rotation drag has to be routed here too - the override was only added
  // so Position could see modifiers, but it accidentally swallowed every
  // non-point drag (rotation rings, crop). Route rotation first, then fall
  // through to point. Crop goes via the base renderer's path on super.
  if ([self rotationIsActive]) {
    [self applyRotationDragToPoint:p
                       contentRect:cr
                            canvas:canvas
                         modifiers:modifiers];
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

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    handleHitAtPoint:(CGPoint)p
         contentRect:(CGRect)cr {
  // Anchor pivot square is topmost (mirrors the viewer) so it is always
  // grabbable; the larger Position arc ring around it stays clickable.
  if ([self _anchorSquareHitAtPoint:p contentRect:cr])
    return YES;
  // The active keypose's position handle is next: when it coincides with a
  // path anchor or tangent handle, the handle wins. Handles are offset from the
  // anchor centre, so they stay grabbable away from it.
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

// Cursor hover (same precedence as -handleHitAtPoint:): the draggable points
// (anchor, position, path) show the move cursor; the scale box's handles show
// the matching resize cursor. Falls back to super (point / crop) for the rest.
- (NSCursor *)miniViewer:(KKMiniViewerView *)canvas
           cursorAtPoint:(CGPoint)p
             contentRect:(CGRect)cr {
  if (CGRectIsEmpty(cr))
    return nil;
  self.canvas = canvas;
  NSInteger idx;
  // Each handle shows the Opt-hover eye/eye.slash when an Opt-click would
  // toggle its visibility (labels match -optClickHandleAtPoint:), else its
  // move/resize cursor. Built-in point/crop/rotation fall to super (also
  // eye-aware).
  if ([self _anchorSquareHitAtPoint:p contentRect:cr])
    return [self kkVisibilityCursorForLabel:@"Anchor"] ?: KKPointMoveCursor();
  if ([self pointHandleHitAtPoint:p contentRect:cr])
    return [self kkVisibilityCursorForLabel:self.pointLabel]
               ?: KKPointMoveCursor();
  if ([self.positionMini pathHandleHitAtPoint:p contentRect:cr])
    return [self kkVisibilityCursorForLabel:@"Path"] ?: KKPointMoveCursor();
  if ([self.positionMini pathAnchorHitAtPoint:p contentRect:cr])
    return [self kkVisibilityCursorForLabel:@"Path"] ?: KKPointMoveCursor();
  if ([self.scaleMini handleHitAtPoint:p contentRect:cr outIndex:&idx])
    return [self kkVisibilityCursorForLabel:@"Scale"]
               ?: KKResizeCursorForBoxHandle(idx);
  return [super miniViewer:canvas cursorAtPoint:p contentRect:cr];
}

- (void)miniViewer:(KKMiniViewerView *)canvas
    beginHandleDragAtPoint:(CGPoint)p
               contentRect:(CGRect)cr {
  _anchorGrabbed = NO;
  // Anchor square grabs first (topmost, matches the hit-test priority).
  if ([self _anchorSquareHitAtPoint:p contentRect:cr]) {
    self.canvas = canvas;
    _anchorGrabbed = YES;
    NSArray<NSNumber *> *av = [self valuesForLabel:@"Anchor"];
    _anchorGrabValX = av.count > 0 ? av[0].doubleValue : 0.5;
    _anchorGrabValY = av.count > 1 ? av[1].doubleValue : 0.5;
    if (cr.size.width > 0 && cr.size.height > 0) {
      _anchorPressNX = (p.x - CGRectGetMinX(cr)) / cr.size.width;
      _anchorPressNY = (p.y - CGRectGetMinY(cr)) / cr.size.height;
    }
    return;
  }
  // Active keypose's position handle takes the grab next (matches the hit-test
  // priority), so a coincident path anchor/handle doesn't steal it.
  if ([self pointHandleHitAtPoint:p contentRect:cr]) {
    [super miniViewer:canvas beginHandleDragAtPoint:p contentRect:cr];
    return;
  }
  // Then the motion-path anchors / tangent handles (owned by the controller).
  self.canvas = canvas;
  if ([self.positionMini beginPathDragAtPoint:p contentRect:cr])
    return;
  if ([self.scaleMini beginDragAtPoint:p contentRect:cr]) {
    self.canvas = canvas;
    return;
  }
  [super miniViewer:canvas beginHandleDragAtPoint:p contentRect:cr];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    doubleClickAtPoint:(CGPoint)p
           contentRect:(CGRect)cr {
  self.canvas = canvas;
  return [self.positionMini toggleSmoothAtPoint:p contentRect:cr];
}

- (CGFloat)motionPathGhostAlpha {
  return [self ghostAlphaForLabel:@"Path"];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    optClickHandleAtPoint:(CGPoint)p
              contentRect:(CGRect)cr {
  // Anchor square is topmost, so it claims the opt-click first.
  if (self.onHandleVisibilityToggled && [self _anchorSquareHitAtPoint:p
                                                          contentRect:cr]) {
    self.onHandleVisibilityToggled(@"Anchor");
    [canvas setNeedsDisplay:YES];
    [canvas setHandlesNeedDisplay];
    return YES;
  }
  // Built-in handles (Position arc, rotation, crop) claim the opt-click next,
  // so at the active keypose the Position handle wins over the path anchor that
  // shares its spot when Position is revealed - matching the viewer. The path
  // then catches its own anchors/handles.
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

// Overlay-point centre of the anchor pivot: the clip centre (Position) shifted
// by the Anchor offset, in the same normalized clip space as the path anchors.
- (CGPoint)_anchorPointForContentRect:(CGRect)cr {
  NSArray<NSNumber *> *pos = [self valuesForLabel:@"Position"];
  NSArray<NSNumber *> *anc = [self valuesForLabel:@"Anchor"];
  double px = pos.count > 0 ? pos[0].doubleValue : 0.5;
  double py = pos.count > 1 ? pos[1].doubleValue : 0.5;
  double ax = anc.count > 0 ? anc[0].doubleValue : 0.5;
  double ay = anc.count > 1 ? anc[1].doubleValue : 0.5;
  return
      [self _handlePointForContentRect:cr
                              position:@[ @(px + ax - 0.5), @(py + ay - 0.5) ]];
}

// The anchor square shows when the Anchor lane is constant (a single fixed
// pivot) and not hidden - same convention as the other single-handle OSCs in
// the mini-viewer (animated lanes draw keypose dots instead).
- (BOOL)_anchorActiveForContentRect:(CGRect)cr {
  return !CGRectIsEmpty(cr) && [self isConstantLabel:@"Anchor"] &&
         [self labelVisibleOrRevealing:@"Anchor"];
}

- (BOOL)_anchorSquareHitAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  if (![self _anchorActiveForContentRect:cr])
    return NO;
  CGPoint c = [self _anchorPointForContentRect:cr];
  // Tight to the drawn square (Chebyshev, square hit region), and well under
  // the Position handle's 12pt grab so clicking the arc ring around the small
  // square still reaches Position - mirroring the viewer where the square is
  // physically smaller than the arc. Scales with the popover (canvas H / 230).
  CGFloat scale = self.canvas.bounds.size.height > 0
                      ? self.canvas.bounds.size.height / 230.0
                      : 1.0;
  CGFloat r = 5.0 * scale;
  return fmax(fabs(p.x - c.x), fabs(p.y - c.y)) < r;
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    anchorSquareCenter:(out CGPoint *)outCenter
           contentRect:(CGRect)cr {
  if (![self _anchorActiveForContentRect:cr])
    return NO;
  if (outCenter)
    *outCenter = [self _anchorPointForContentRect:cr];
  return YES;
}

- (CGFloat)anchorSquareGhostAlpha {
  return [self ghostAlphaForLabel:@"Anchor"];
}

// Delta drag like Position: the anchor value moves by the cursor's normalized
// offset from the grab point. Cmd snaps the PIVOT (Position + Anchor offset) to
// the clip's centre / corners / edge-midpoints / thirds, routed through the
// shared snap engine so the canvas strokes the yellow guide lines.
- (void)_applyAnchorDragToPoint:(CGPoint)p
                    contentRect:(CGRect)cr
                      modifiers:(NSEventModifierFlags)modifiers {
  if (cr.size.width <= 0 || cr.size.height <= 0)
    return;
  double nx = (p.x - CGRectGetMinX(cr)) / cr.size.width;
  double ny = (p.y - CGRectGetMinY(cr)) / cr.size.height;
  double newX = _anchorGrabValX + (nx - _anchorPressNX);
  double newY = _anchorGrabValY + (ny - _anchorPressNY);
  if (modifiers & NSEventModifierFlagCommand) {
    NSArray<NSNumber *> *pos = [self valuesForLabel:@"Position"];
    double posX = pos.count > 0 ? pos[0].doubleValue : 0.5;
    double posY = pos.count > 1 ? pos[1].doubleValue : 0.5;
    // Clip features in pivot-normalized content space (0/⅓/½/⅔/1 of the clip
    // offset from its centre by Position). Snapping the pivot here makes the
    // guide land on the clip's real edges/centre, not on a fixed value.
    static const double frac[] = {0.0, 1.0 / 3.0, 0.5, 2.0 / 3.0, 1.0};
    float ax[5], ay[5];
    for (int i = 0; i < 5; i++) {
      ax[i] = (float)(posX + frac[i] - 0.5);
      ay[i] = (float)(posY + frac[i] - 0.5);
    }
    float thrX = cr.size.width > 0 ? 6.0f / (float)cr.size.width : 0.02f;
    float thrY = cr.size.height > 0 ? 6.0f / (float)cr.size.height : 0.02f;
    simd_float2 pivot = {(float)(posX + newX - 0.5),
                         (float)(posY + newY - 0.5)};
    simd_float2 sn = [self.positionMini.snapEngine snapPoint:pivot
                                              canvasAnchorsX:ax
                                                      countX:5
                                              canvasAnchorsY:ay
                                                      countY:5
                                               objectTargets:NULL
                                                       count:0
                                                  thresholdX:thrX
                                                  thresholdY:thrY];
    newX = sn.x - posX + 0.5;
    newY = sn.y - posY + 0.5;
  } else {
    [self.positionMini.snapEngine reset];
  }
  [self commitValues:@[ @(newX), @(newY) ]
            forLabel:@"Anchor"
              canvas:self.canvas];
}

- (void)miniViewerEndHandleDrag:(KKMiniViewerView *)canvas {
  _anchorGrabbed = NO;
  [self.scaleMini endDrag];
  // endDrag resets the shared snap engine (so an anchor/position drag clears
  // its guides too) and reports whether a motion-path drag was active.
  if ([self.positionMini endDrag]) {
    if (self.onTimelinePersist)
      self.onTimelinePersist(self.timeline);
    [canvas setNeedsDisplay:YES];
    [canvas setHandlesNeedDisplay];
    return;
  }
  [super miniViewerEndHandleDrag:canvas];
}

// Opting in to the base's 3-ring gizmo. The drag state machine, hit-test,
// compose × axis(dAngle) → decompose-near, and commit all live in the base
// (`KKMiniViewerRenderer`). The only thing MagicMove-specific is anchoring
// the sphere to the Position handle so the rings move with the translated
// image.

@end
