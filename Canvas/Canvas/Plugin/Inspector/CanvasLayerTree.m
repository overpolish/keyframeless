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

NSIndexSet *CanvasLayerAncestorIndices(NSUInteger idx,
                                       NSArray<KKBezierPath *> *paths) {
  if (idx >= paths.count)
    return [NSIndexSet indexSet];
  NSMutableIndexSet *result = [NSMutableIndexSet indexSet];
  NSString *pid = paths[idx].parentGroupID;
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
