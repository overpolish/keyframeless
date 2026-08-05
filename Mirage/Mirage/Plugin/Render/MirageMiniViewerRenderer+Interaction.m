/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageExprMiniSet.h"
#import "MirageMiniViewerRenderer_Internal.h"
#import <KeyframelessKit/KeyframelessKit.h>

// Mini-viewer parity for the shader's `#point osc` lanes. All geometry /
// hit-test / drag / motion-path / gating logic lives in the reusable
// KKPointOSCSet (the mini sibling of the viewer drawing every KKPositionOSC);
// these are the thin KKMiniViewerDelegate forwards. Mirage has no scale /
// anchor / crop / rotation controls, so anything the set doesn't claim falls
// through to super and keeps the base renderer's behaviour untouched.
@implementation MirageMiniViewerRenderer (Interaction)

// The set, resynced to the current shader source first (cheap string compare)
// so every delegate call sees the right controllers even without a preceding
// draw.
- (KKPointOSCSet *)_syncedSet {
  [self _syncMiniPointController];
  return self.pointSet;
}

- (KKRotationOSCSet *)_syncedRotSet {
  [self _syncMiniRotController];
  return self.rotSet;
}

- (MirageExprMiniSet *)_syncedExprSet {
  [self _syncMiniExprController];
  return self.exprSet;
}

- (NSArray<NSDictionary<NSString *, id> *> *)miniViewer:
                                                 (KKMiniViewerView *)canvas
                   extraPointHandleGlyphsForContentRect:(CGRect)cr {
  return [[self _syncedSet] handleGlyphsForContentRect:cr];
}

// The point-handle centre the guide uses to spotlight / target the featured
// point. This is a SEPARATE selector from `miniViewer:pointHandleCenter:...`
// (which the mini-viewer's draw loop uses to paint a single "primary" handle):
// Mirage has no primary - it paints every point through
// `extraPointHandleGlyphs`
// - so answering the primary selector would double-draw the handle opaque over
// the correct dim ghost. Instead the guide's `pointHandleScreenRect` falls back
// to this `activePointHandleCenter` selector; we forward to the set's active
// controller (its `_handleActive` gate = the same constant / visible /
// keyed-at-fraction test the glyphs use).
- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    activePointHandleCenter:(out CGPoint *)outCenter
                contentRect:(CGRect)cr {
  return [[self _syncedSet] activeHandleCenter:outCenter forContentRect:cr];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    activePointHandleCenter:(out CGPoint *)outCenter
                  forValues:(NSArray<NSNumber *> *)values
                contentRect:(CGRect)cr {
  return [[self _syncedSet] activeHandleCenter:outCenter
                                     forValues:values
                                forContentRect:cr];
}

- (NSArray<NSDictionary<NSString *, id> *> *)miniViewer:
                                                 (KKMiniViewerView *)canvas
                               extraRingsForContentRect:(CGRect)cr {
  return [[self _syncedExprSet] ringBundlesForContentRect:cr];
}

- (NSArray<NSDictionary<NSString *, id> *> *)miniViewer:
                                                 (KKMiniViewerView *)canvas
                         extraFixedGlyphsForContentRect:(CGRect)cr {
  return [[self _syncedExprSet] glyphBundlesForContentRect:cr];
}

- (NSArray<KKMiniBox *> *)miniViewer:(KKMiniViewerView *)canvas
                 boxesForContentRect:(CGRect)cr {
  NSArray<KKMiniBox *> *base = [super miniViewer:canvas boxesForContentRect:cr];
  NSArray<KKMiniBox *> *mine =
      [[self _syncedExprSet] boxesForContentRect:cr
                                       mediaSize:canvas.sourceMediaSize];
  if (!base.count)
    return mine;
  if (!mine.count)
    return base;
  return [base arrayByAddingObjectsFromArray:mine];
}

- (NSArray<KKMiniRotation *> *)miniViewer:(KKMiniViewerView *)canvas
               rotationOSCsForContentRect:(CGRect)cr {
  return [[self _syncedRotSet] rotationsForContentRect:cr canvas:canvas];
}

- (NSArray<NSDictionary<NSString *, id> *> *)miniViewer:
                                                 (KKMiniViewerView *)canvas
                         extraMotionPathsForContentRect:(CGRect)cr {
  return [[self _syncedSet] motionPathBundlesForContentRect:cr];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    handleHitAtPoint:(CGPoint)p
         contentRect:(CGRect)cr {
  // The rotation set sizes its rings from the renderer's live canvas; set it
  // before the sets run (super would set it, but we call the sets first).
  self.canvas = canvas;
  // Positions, then the `@osc` primitives (point / ring / box), then rotation
  // rings LAST. The viewer walks one list in declaration order, so a point
  // declared before a rotate wins there; the mini splits them into two sets and
  // loses that ordering, so the rotate set has to go last or its rings swallow
  // any handle sitting inside them (an anchor at the pivot, always).
  // A point glyph outranks a position handle on the same pixel - the position
  // hit-tests as a filled disc even though it draws as an arc, so an anchor at
  // the pivot is otherwise unreachable. Matches the viewer.
  if ([[self _syncedExprSet] glyphHitAtPoint:p contentRect:cr])
    return YES;
  if ([[self _syncedSet] handleHitAtPoint:p contentRect:cr])
    return YES;
  if ([[self _syncedExprSet] handleHitAtPoint:p contentRect:cr])
    return YES;
  if ([[self _syncedRotSet] handleHitAtPoint:p contentRect:cr])
    return YES;
  return [super miniViewer:canvas handleHitAtPoint:p contentRect:cr];
}

- (NSCursor *)miniViewer:(KKMiniViewerView *)canvas
           cursorAtPoint:(CGPoint)p
             contentRect:(CGRect)cr {
  if (CGRectIsEmpty(cr))
    return nil;
  self.canvas = canvas; // rotation set reads the canvas for ring sizing
  NSCursor *c = nil;
  if ([[self _syncedExprSet] glyphHitAtPoint:p contentRect:cr])
    c = [[self _syncedExprSet] cursorAtPoint:p contentRect:cr];
  if (!c)
    c = [[self _syncedSet] cursorAtPoint:p contentRect:cr];
  if (c)
    return c;
  c = [[self _syncedExprSet] cursorAtPoint:p contentRect:cr];
  if (c)
    return c;
  c = [[self _syncedRotSet] cursorAtPoint:p contentRect:cr];
  return c ?: [super miniViewer:canvas cursorAtPoint:p contentRect:cr];
}

- (void)miniViewer:(KKMiniViewerView *)canvas
    beginHandleDragAtPoint:(CGPoint)p
               contentRect:(CGRect)cr {
  if ([[self _syncedExprSet] glyphHitAtPoint:p contentRect:cr] &&
      [[self _syncedExprSet] beginDragAtPoint:p contentRect:cr canvas:canvas])
    return;
  if ([[self _syncedSet] beginDragAtPoint:p contentRect:cr canvas:canvas]) {
    // Let the position drag snap onto the point OSCs (symmetric with the point
    // drag snapping onto positions). Seed the shared target set for this drag.
    NSArray<NSValue *> *pts =
        [[self _syncedExprSet] pointHandleValuePositionsForContentRect:cr];
    for (KKPositionMiniController *c in self.pointSet.controllers)
      c.externalSnapTargets = pts;
    return;
  }
  // DRAG routing keeps the ORIGINAL order (rotate before the other primitives).
  // Only hit-test / cursor / opt-click take the glyph-first precedence above:
  // reordering the drag as well let the expr set claim the ticks of a rotation
  // drag that the rotate set had already begun, so the ring stuck in its
  // pressed state and never moved or ended.
  if ([[self _syncedRotSet] beginDragAtPoint:p contentRect:cr canvas:canvas])
    return;
  if ([[self _syncedExprSet] beginDragAtPoint:p contentRect:cr canvas:canvas])
    return;
  [super miniViewer:canvas beginHandleDragAtPoint:p contentRect:cr];
}

- (void)miniViewer:(KKMiniViewerView *)canvas
    dragHandleToPoint:(CGPoint)p
          contentRect:(CGRect)cr
            modifiers:(NSEventModifierFlags)modifiers {
  if ([[self _syncedSet] dragToPoint:p
                         contentRect:cr
                              canvas:canvas
                           modifiers:modifiers])
    return;
  if ([[self _syncedRotSet] dragToPoint:p
                            contentRect:cr
                                 canvas:canvas
                              modifiers:modifiers])
    return;
  if ([[self _syncedExprSet] dragToPoint:p
                             contentRect:cr
                                  canvas:canvas
                               modifiers:modifiers])
    return;
  [super miniViewer:canvas
      dragHandleToPoint:p
            contentRect:cr
              modifiers:modifiers];
}

- (void)miniViewerEndHandleDrag:(KKMiniViewerView *)canvas {
  if ([self.pointSet endDragOnCanvas:canvas])
    return;
  if ([self.rotSet endDragOnCanvas:canvas])
    return;
  if ([self.exprSet endDragOnCanvas:canvas])
    return;
  [super miniViewerEndHandleDrag:canvas];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    doubleClickAtPoint:(CGPoint)p
           contentRect:(CGRect)cr {
  return [[self _syncedSet] doubleClickAtPoint:p contentRect:cr];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    optClickHandleAtPoint:(CGPoint)p
              contentRect:(CGRect)cr {
  if ([super miniViewer:canvas optClickHandleAtPoint:p contentRect:cr])
    return YES;
  // Same precedence as the hit test / drag: a glyph on the pixel beats the
  // position handle whose disc covers it, so an anchor at the pivot can be
  // opt-clicked to hide it.
  if ([[self _syncedExprSet] glyphHitAtPoint:p contentRect:cr] &&
      [[self _syncedExprSet] optClickAtPoint:p contentRect:cr canvas:canvas])
    return YES;
  if ([[self _syncedSet] optClickAtPoint:p contentRect:cr canvas:canvas])
    return YES;
  if ([[self _syncedRotSet] optClickAtPoint:p contentRect:cr canvas:canvas])
    return YES;
  return [[self _syncedExprSet] optClickAtPoint:p contentRect:cr canvas:canvas];
}

- (void)miniViewer:(KKMiniViewerView *)canvas
     snapGuideHasX:(out BOOL *)hasX
                 X:(out CGFloat *)outX
      fromKeyposeX:(out BOOL *)fromKeyposeX
              hasY:(out BOOL *)hasY
                 Y:(out CGFloat *)outY
      fromKeyposeY:(out BOOL *)fromKeyposeY {
  // A point OSC drag reports its own guides (canvas anchors + other handles);
  // otherwise the position set owns them.
  id guideSource =
      self.exprSet.draggingSnapPoint ? (id)self.exprSet : (id)self.pointSet;
  [guideSource snapGuideHasX:hasX
                           X:outX
                fromKeyposeX:fromKeyposeX
                        hasY:hasY
                           Y:outY
                fromKeyposeY:fromKeyposeY];
}

@end
