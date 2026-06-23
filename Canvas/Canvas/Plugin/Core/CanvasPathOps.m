/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasPathOps.h"
#import "CanvasCornerFillet.h" // CanvasPathByExpandingCorners
#import <KeyframelessKit/KKBezierPath.h>

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
                                          KKBooleanOp op, float aspect) {
  if (selIDs.count < 2)
    return nil;
  // Operands top-of-stack first (reverse index order), so the lowest index -
  // the bottom-most operand - is the `first` the op keeps as its base (subtract
  // = base minus the upper operands). The boolean runs on the corner-expanded
  // geometry (so rounding is honored); the ORIGINAL paths are removed by index.
  NSMutableArray<KKBezierPath *> *operands = [NSMutableArray array];
  NSMutableIndexSet *operandIndices = [NSMutableIndexSet indexSet];
  for (NSInteger i = (NSInteger)paths.count - 1; i >= 0; i--) {
    KKBezierPath *p = paths[i];
    if (!p.isImage && !p.isGroup &&
        [selIDs containsObject:(p.layerID ?: @"")]) {
      [operands addObject:CanvasCornerExpanded(p, aspect)];
      [operandIndices addIndex:(NSUInteger)i];
    }
  }
  if (operands.count < 2)
    return nil;

  KKBezierPath *result = KKPathBooleanApply(operands, op);
  if (!result)
    return nil;
  result.name = paths[operandIndices.firstIndex].name;

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
                         NSArray<KKBezierPath *> **outOperands,
                         NSArray<KKBezierPath *> **outResults) {
  *outOperands = nil;
  *outResults = nil;
  // Selected vector paths, top-of-stack first (same order the ops consume
  // them).
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

  if (vec.count < 2)
    return NO;
  float aspect = refHeight > 0 ? (float)(refWidth / refHeight) : 1.0f;
  NSMutableArray<KKBezierPath *> *expanded = [NSMutableArray array];
  for (KKBezierPath *p in vec)
    [expanded addObject:CanvasCornerExpanded(p, aspect)];
  KKBezierPath *result = KKPathBooleanApply(expanded, op);
  if (!result)
    return NO;
  *outOperands = expanded; // red preview shows the rounded operands
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
