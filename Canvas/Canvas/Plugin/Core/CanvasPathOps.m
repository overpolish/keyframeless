/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasPathOps.h"
#import "CanvasCornerFillet.h" // CanvasPathByExpandingCorners
#import "CanvasLayerRender.h"  // CanvasProjCtx / project / unproject
#import <KeyframelessKit/KKBezierPath.h>

static KKBezierPath *CanvasCornerExpanded(KKBezierPath *p, float aspect);

// Copy the placement (group + transform) that a boolean result must adopt from
// its anchor operand - the same fields KKPathBoolean's copyPlacementProperties
// uses, so the result lands in the anchor's space.
static void CanvasCopyOperandPlacement(KKBezierPath *dst, KKBezierPath *src) {
  dst.parentGroupID = src.parentGroupID;
  dst.transformEnabled = src.transformEnabled;
  dst.translateX = src.translateX;
  dst.translateY = src.translateY;
  dst.scaleX = src.scaleX;
  dst.scaleY = src.scaleY;
  dst.rotationZ = src.rotationZ;
  dst.anchorX = src.anchorX;
  dst.anchorY = src.anchorY;
}

// Corner-expand `src`, then bake its geometry into `anchor`'s LOCAL space:
// project each anchor + handle endpoint through src's own transform/group to
// canvas-object space, then unproject through the anchor's transform/group. The
// returned copy carries the anchor's placement (so a boolean result inherits
// it) and a cleared layerID (so a preview projects it through the anchor's
// group, not its own stack slot). Combining operands baked this way means a
// boolean merges the shapes WHERE THEY APPEAR, and the result - placed in the
// anchor's space - renders without anything shifting. `layers` is the full
// layer stack.
static KKBezierPath *CanvasBakeBooleanOperand(KKBezierPath *src,
                                              KKBezierPath *anchor,
                                              NSArray<KKBezierPath *> *layers,
                                              double frac, float aspect) {
  KKBezierPath *ce = CanvasCornerExpanded(src, aspect);
  CanvasProjCtx srcCtx = CanvasProjCtxMake(layers, src, frac, aspect);
  NSUInteger n = ce.count;
  KKBezierPoint *pts =
      (KKBezierPoint *)malloc(sizeof(KKBezierPoint) * MAX(n, 1u));
  simd_float2 (^bake)(float, float) = ^simd_float2(float x, float y) {
    simd_float2 cv = CanvasProjectWithCtx(&srcCtx, x, y);
    return CanvasUnprojectLayerPointObj(layers, anchor, frac, aspect, cv.x,
                                        cv.y);
  };
  for (NSUInteger i = 0; i < n; i++) {
    KKBezierPoint p = [ce pointAtIndex:i];
    simd_float2 a = bake(p.x, p.y);
    simd_float2 in = bake(p.x + p.inX, p.y + p.inY);
    simd_float2 out = bake(p.x + p.outX, p.y + p.outY);
    KKBezierPoint q = p;
    q.x = a.x;
    q.y = a.y;
    q.inX = in.x - a.x;
    q.inY = in.y - a.y;
    q.outX = out.x - a.x;
    q.outY = out.y - a.y;
    pts[i] = q;
  }
  NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
  for (NSUInteger c = 1; c < ce.contourCount; c++)
    [starts addObject:@([ce contourRangeAtIndex:c].location)];
  KKBezierPath *out = [ce copy];
  [out setBezierPoints:pts count:n closed:ce.closed];
  if (starts.count)
    [out setContourStarts:starts];
  free(pts);
  // The geometry now sits in the anchor's space, so the ONLY transform that may
  // apply is the anchor's (stamped below). Drop the source's own transform +
  // animation - otherwise the preview's projection re-applies the source's
  // rotation/tilt on top of the baked points and the operand reads as
  // over-rotated/stretched vs the (animation-free) result. Stale morph
  // snapshots reference the old geometry, so clear them too.
  out.animationJSON = nil;
  out.morphTargets = nil;
  CanvasCopyOperandPlacement(out, anchor);
  out.layerID = @"";
  return out;
}

// Path ops act on the geometry that's actually RENDERED, so a path with
// per-corner radii is corner-expanded first - otherwise the op (outline or
// boolean) follows the stored sharp corners and ignores the rounding.
static KKBezierPath *CanvasCornerExpanded(KKBezierPath *p, float aspect) {
  return p.hasCornerRadii ? CanvasPathByExpandingCorners(p, aspect) : p;
}

static KKBezierPath *CanvasOutlineInput(KKBezierPath *p, CGFloat refWidth,
                                        CGFloat refHeight) {
  return CanvasCornerExpanded(p, refHeight > 0 ? (float)(refWidth / refHeight)
                                               : 1.0f);
}

NSArray<NSString *> *CanvasApplyBooleanOp(NSMutableArray<KKBezierPath *> *paths,
                                          NSArray<NSString *> *selIDs,
                                          KKBooleanOp op, float aspect,
                                          double frac) {
  if (selIDs.count < 2)
    return nil;
  // Collect the selected CLOSED vector operands, top-of-stack first (reverse
  // index order). Open paths (a centerline / stroke) have no area, so they're
  // excluded like images - the op runs on the closed ones and leaves the open
  // ones untouched. The original paths are removed by index afterward.
  NSMutableArray<KKBezierPath *> *origs = [NSMutableArray array];
  NSMutableIndexSet *operandIndices = [NSMutableIndexSet indexSet];
  for (NSInteger i = (NSInteger)paths.count - 1; i >= 0; i--) {
    KKBezierPath *p = paths[i];
    if (!p.isImage && !p.isGroup && p.closed &&
        [selIDs containsObject:(p.layerID ?: @"")]) {
      [origs addObject:p];
      [operandIndices addIndex:(NSUInteger)i];
    }
  }
  if (origs.count < 2)
    return nil;

  // Anchor = the TOP-most selected operand (lowest index). Every operand is
  // baked into its space, and the result inherits its placement - so the merge
  // happens where the shapes appear and the result lands as the top-most layer
  // (e.g. top-level when that layer is ungrouped) without anything shifting.
  KKBezierPath *anchor = paths[operandIndices.firstIndex];
  NSMutableArray<KKBezierPath *> *operands = [NSMutableArray array];
  for (KKBezierPath *o in origs)
    [operands
        addObject:CanvasBakeBooleanOperand(o, anchor, paths, frac, aspect)];

  KKBezierPath *result = KKPathBooleanApply(operands, op);
  if (!result)
    return nil;
  // The boolean copied operands[0]'s placement, but every baked operand carries
  // the ANCHOR's placement, so the result is already anchored correctly; stamp
  // it explicitly for clarity and take the anchor's name.
  CanvasCopyOperandPlacement(result, anchor);
  result.name = anchor.name;

  NSUInteger insertIdx = operandIndices.firstIndex;
  [operandIndices enumerateIndexesWithOptions:NSEnumerationReverse
                                   usingBlock:^(NSUInteger idx, BOOL *stop) {
                                     [paths removeObjectAtIndex:idx];
                                   }];
  [paths insertObject:result atIndex:insertIdx];
  return result.layerID.length ? @[ result.layerID ] : @[];
}

BOOL CanvasPathOpPreview(NSArray<KKBezierPath *> *paths,
                         NSArray<NSString *> *selIDs, BOOL outline,
                         KKBooleanOp op, CGFloat refWidth, CGFloat refHeight,
                         double frac, NSArray<KKBezierPath *> **outOperands,
                         NSArray<KKBezierPath *> **outResults) {
  *outOperands = nil;
  *outResults = nil;
  // Selected vector paths, top-of-stack first (same order the ops consume
  // them). The LAST entry is the lowest index = the top-most layer.
  NSMutableArray<KKBezierPath *> *vec = [NSMutableArray array];
  for (NSInteger i = (NSInteger)paths.count - 1; i >= 0; i--) {
    KKBezierPath *p = paths[i];
    if (!p.isImage && !p.isGroup && [selIDs containsObject:(p.layerID ?: @"")])
      [vec addObject:p];
  }

  if (outline) {
    NSMutableArray<KKBezierPath *> *strokeOps = [NSMutableArray array];
    for (KKBezierPath *p in vec)
      if (p.strokeEnabled)
        [strokeOps addObject:CanvasOutlineInput(p, refWidth, refHeight)];
    if (strokeOps.count == 0)
      return NO;
    NSArray<KKBezierPath *> *outlines =
        KKPathStrokeToOutline(strokeOps, refWidth, refHeight);
    NSMutableArray<KKBezierPath *> *res = [NSMutableArray array];
    for (id o in outlines)
      if ([o isKindOfClass:[KKBezierPath class]])
        [res addObject:o];
    if (res.count == 0)
      return NO;
    *outOperands = strokeOps;
    *outResults = res;
    return YES;
  }

  float aspect = refHeight > 0 ? (float)(refWidth / refHeight) : 1.0f;
  // Booleans act on CLOSED operands only (open strokes have no area); exclude
  // the open ones, like the commit does. Bake each into the TOP-most operand's
  // space (matching the commit) so the red/green preview shows exactly where
  // the merge lands - nothing shifts vs the originals.
  NSMutableArray<KKBezierPath *> *closed = [NSMutableArray array];
  for (KKBezierPath *p in vec)
    if (p.closed)
      [closed addObject:p];
  if (closed.count < 2)
    return NO;
  KKBezierPath *anchor = closed.lastObject; // lowest index = top-most layer
  NSMutableArray<KKBezierPath *> *operands = [NSMutableArray array];
  for (KKBezierPath *p in closed)
    [operands
        addObject:CanvasBakeBooleanOperand(p, anchor, paths, frac, aspect)];
  KKBezierPath *result = KKPathBooleanApply(operands, op);
  if (!result)
    return NO;
  *outOperands = operands; // baked into anchor space (drawn through its group)
  *outResults = @[ result ];
  return YES;
}

NSArray<NSString *> *CanvasApplyOutlineOp(NSMutableArray<KKBezierPath *> *paths,
                                          NSArray<NSString *> *selIDs,
                                          CGFloat refWidth, CGFloat refHeight) {
  if (selIDs.count == 0)
    return nil;
  NSMutableArray<KKBezierPath *> *operands = [NSMutableArray array];
  NSMutableArray<NSNumber *> *opIdx = [NSMutableArray array];
  for (NSUInteger i = 0; i < paths.count; i++) {
    KKBezierPath *p = paths[i];
    if (!p.isImage && !p.isGroup && p.strokeEnabled &&
        [selIDs containsObject:(p.layerID ?: @"")]) {
      [operands addObject:CanvasOutlineInput(p, refWidth, refHeight)];
      [opIdx addObject:@(i)];
    }
  }
  if (operands.count == 0)
    return nil;

  NSArray<KKBezierPath *> *outlines =
      KKPathStrokeToOutline(operands, refWidth, refHeight);
  if (outlines.count != operands.count)
    return nil;

  // Insert descending so the earlier indices stay valid as we mutate.
  NSMutableArray<NSString *> *newSel = [NSMutableArray array];
  for (NSInteger k = (NSInteger)operands.count - 1; k >= 0; k--) {
    id outlineObj = outlines[(NSUInteger)k];
    if (![outlineObj isKindOfClass:[KKBezierPath class]])
      continue;
    KKBezierPath *outline = outlineObj;
    NSUInteger idx = [opIdx[(NSUInteger)k] unsignedIntegerValue];
    paths[idx].strokeEnabled = NO;
    [paths insertObject:outline atIndex:idx + 1];
    if (outline.layerID.length)
      [newSel addObject:outline.layerID];
  }
  return newSel;
}
