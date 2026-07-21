/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "ShaderExprMiniSet.h"
#import "ShaderMiniViewerRenderer_Internal.h"
#import <KeyframelessKit/KeyframelessKit.h>

// Mini-viewer parity for the shader's `#point osc` lanes. All geometry /
// hit-test / drag / motion-path / gating logic lives in the reusable
// KKPointOSCSet (the mini sibling of the viewer drawing every KKPositionOSC);
// these are the thin KKMiniViewerDelegate forwards. Shader has no scale /
// anchor / crop / rotation controls, so anything the set doesn't claim falls
// through to super and keeps the base renderer's behaviour untouched.
@implementation ShaderMiniViewerRenderer (Interaction)

// The set, resynced to the current shader source first (cheap string compare)
// so every delegate call sees the right controllers even without a preceding
// draw.
- (KKPointOSCSet *)_syncedSet {
  [self _syncMiniPointController];
  return self.pointSet;
}

- (KKRingOSCSet *)_syncedRingSet {
  [self _syncMiniRadialControllers];
  return self.ringSet;
}

- (KKBoxOSCSet *)_syncedBoxSet {
  [self _syncMiniRadialControllers];
  return self.boxSet;
}

- (KKRotationOSCSet *)_syncedRotSet {
  [self _syncMiniRotController];
  return self.rotSet;
}

- (ShaderExprMiniSet *)_syncedExprSet {
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
// Shader has no primary - it paints every point through
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
  return [[self _syncedRingSet] ringBundlesForContentRect:cr];
}

- (NSArray<NSDictionary<NSString *, id> *> *)miniViewer:
                                                 (KKMiniViewerView *)canvas
                         extraFixedGlyphsForContentRect:(CGRect)cr {
  return [[self _syncedExprSet] glyphBundlesForContentRect:cr];
}

- (NSArray<KKMiniBox *> *)miniViewer:(KKMiniViewerView *)canvas
                 boxesForContentRect:(CGRect)cr {
  NSArray<KKMiniBox *> *base = [super miniViewer:canvas boxesForContentRect:cr];
  NSArray<KKMiniBox *> *mine = [[self _syncedBoxSet] boxesForContentRect:cr];
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
  // Points foreground, then rings, then boxes, then rotation rings (matching
  // the viewer precedence).
  if ([[self _syncedSet] handleHitAtPoint:p contentRect:cr])
    return YES;
  if ([[self _syncedRingSet] handleHitAtPoint:p contentRect:cr])
    return YES;
  if ([[self _syncedBoxSet] handleHitAtPoint:p contentRect:cr])
    return YES;
  if ([[self _syncedRotSet] handleHitAtPoint:p contentRect:cr])
    return YES;
  if ([[self _syncedExprSet] handleHitAtPoint:p contentRect:cr])
    return YES;
  return [super miniViewer:canvas handleHitAtPoint:p contentRect:cr];
}

- (NSCursor *)miniViewer:(KKMiniViewerView *)canvas
           cursorAtPoint:(CGPoint)p
             contentRect:(CGRect)cr {
  if (CGRectIsEmpty(cr))
    return nil;
  self.canvas = canvas; // rotation set reads the canvas for ring sizing
  NSCursor *c = [[self _syncedSet] cursorAtPoint:p contentRect:cr];
  if (c)
    return c;
  c = [[self _syncedRingSet] cursorAtPoint:p contentRect:cr];
  if (c)
    return c;
  c = [[self _syncedBoxSet] cursorAtPoint:p contentRect:cr];
  if (c)
    return c;
  c = [[self _syncedRotSet] cursorAtPoint:p contentRect:cr];
  if (c)
    return c;
  c = [[self _syncedExprSet] cursorAtPoint:p contentRect:cr];
  return c ?: [super miniViewer:canvas cursorAtPoint:p contentRect:cr];
}

- (void)miniViewer:(KKMiniViewerView *)canvas
    beginHandleDragAtPoint:(CGPoint)p
               contentRect:(CGRect)cr {
  if ([[self _syncedSet] beginDragAtPoint:p contentRect:cr canvas:canvas])
    return;
  if ([[self _syncedRingSet] beginDragAtPoint:p contentRect:cr canvas:canvas])
    return;
  if ([[self _syncedBoxSet] beginDragAtPoint:p contentRect:cr canvas:canvas])
    return;
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
  if ([[self _syncedRingSet] dragToPoint:p
                             contentRect:cr
                                  canvas:canvas
                               modifiers:modifiers])
    return;
  if ([[self _syncedBoxSet] dragToPoint:p
                            contentRect:cr
                                 canvas:canvas
                              modifiers:modifiers])
    return;
  if ([[self _syncedRotSet] dragToPoint:p
                            contentRect:cr
                                 canvas:canvas
                              modifiers:modifiers])
    return;
  if ([[self _syncedExprSet] dragToPoint:p contentRect:cr canvas:canvas])
    return;
  [super miniViewer:canvas
      dragHandleToPoint:p
            contentRect:cr
              modifiers:modifiers];
}

- (void)miniViewerEndHandleDrag:(KKMiniViewerView *)canvas {
  if ([self.pointSet endDragOnCanvas:canvas])
    return;
  if ([self.ringSet endDragOnCanvas:canvas])
    return;
  if ([self.boxSet endDragOnCanvas:canvas])
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
  if ([[self _syncedSet] optClickAtPoint:p contentRect:cr canvas:canvas])
    return YES;
  if ([[self _syncedRingSet] optClickAtPoint:p contentRect:cr canvas:canvas])
    return YES;
  if ([[self _syncedBoxSet] optClickAtPoint:p contentRect:cr canvas:canvas])
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
  [self.pointSet snapGuideHasX:hasX
                             X:outX
                  fromKeyposeX:fromKeyposeX
                          hasY:hasY
                             Y:outY
                  fromKeyposeY:fromKeyposeY];
}

@end
