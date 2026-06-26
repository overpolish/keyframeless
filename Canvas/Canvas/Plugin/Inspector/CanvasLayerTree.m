/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerTree.h"

#import <KeyframelessKit/KKBezierPath.h>

NSIndexSet *CanvasLayerDescendantIndices(NSUInteger groupIdx,
                                         NSArray<KKBezierPath *> *paths) {
  if (groupIdx >= paths.count)
    return [NSIndexSet indexSet];
  NSString *gid = paths[groupIdx].groupID;
  if (gid.length == 0)
    return [NSIndexSet indexSet];
  NSMutableIndexSet *result = [NSMutableIndexSet indexSet];
  NSMutableSet<NSString *> *groupIDs = [NSMutableSet setWithObject:gid];
  for (NSUInteger i = 0; i < paths.count; i++) {
    if (i == groupIdx)
      continue;
    if (paths[i].parentGroupID &&
        [groupIDs containsObject:paths[i].parentGroupID]) {
      [result addIndex:i];
      if (paths[i].isGroup && paths[i].groupID.length)
        [groupIDs addObject:paths[i].groupID];
    }
  }
  return result;
}

NSString *CanvasDeleteLayersByID(NSMutableArray<KKBezierPath *> *paths,
                                 NSArray<NSString *> *selIDs) {
  if (paths.count == 0 || selIDs.count == 0)
    return nil;
  NSSet<NSString *> *want = [NSSet setWithArray:selIDs];
  NSMutableIndexSet *kill = [NSMutableIndexSet indexSet];
  for (NSUInteger i = 0; i < paths.count; i++)
    if ([want containsObject:(paths[i].layerID ?: @"")]) {
      [kill addIndex:i];
      if (paths[i].isGroup)
        [kill addIndexes:CanvasLayerDescendantIndices(i, paths)];
    }
  if (kill.count == 0)
    return nil;
  NSUInteger firstDeleted = kill.firstIndex;
  [kill enumerateIndexesWithOptions:NSEnumerationReverse
                         usingBlock:^(NSUInteger idx, BOOL *stop) {
                           if (idx < paths.count)
                             [paths removeObjectAtIndex:idx];
                         }];
  if (paths.count == 0)
    return nil;
  return paths[MIN(firstDeleted, paths.count - 1)].layerID;
}

NSIndexSet *CanvasLayerAncestorIndices(NSUInteger idx,
                                       NSArray<KKBezierPath *> *paths) {
  if (idx >= paths.count)
    return [NSIndexSet indexSet];
  return CanvasLayerAncestorIndicesForParentID(paths[idx].parentGroupID, paths);
}

NSIndexSet *
CanvasLayerAncestorIndicesForParentID(NSString *parentGroupID,
                                      NSArray<KKBezierPath *> *paths) {
  NSMutableIndexSet *result = [NSMutableIndexSet indexSet];
  NSString *pid = parentGroupID;
  NSUInteger guard = 0;
  while (pid.length > 0 && guard++ < CanvasLayerGroupDepthGuard) {
    BOOL found = NO;
    for (NSUInteger i = 0; i < paths.count; i++) {
      if (paths[i].isGroup && [paths[i].groupID isEqualToString:pid]) {
        [result addIndex:i];
        pid = paths[i].parentGroupID;
        found = YES;
        break;
      }
    }
    if (!found)
      break;
  }
  return result;
}
