/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Group structure for the Layers panel: flat-list tree queries, the
// group/ungroup/remove context-menu actions, collapse, and the visibility /
// lock toggles that propagate through a group's subtree.

#import "CanvasLayerListView_Private.h"

#import "CanvasLayerTree.h"

#import <KeyframelessKit/KKBezierPath.h>

@implementation CanvasLayerListView (Grouping)

#pragma mark - Tree queries

- (BOOL)isRowLocked:(NSUInteger)idx {
  return idx < _paths.count && _paths[idx].locked;
}

- (NSInteger)_indexOfGroupID:(NSString *)gid {
  if (gid.length == 0)
    return -1;
  for (NSUInteger i = 0; i < _paths.count; i++)
    if (_paths[i].isGroup && [_paths[i].groupID isEqualToString:gid])
      return (NSInteger)i;
  return -1;
}

// Flat index just past the entry at `idx` and (if it's a group) its whole
// contiguous subtree.
- (NSInteger)subtreeEndFlatIndex:(NSUInteger)idx {
  if (idx >= _paths.count)
    return (NSInteger)_paths.count;
  if (!_paths[idx].isGroup)
    return (NSInteger)idx + 1;
  return (NSInteger)idx + 1 +
         (NSInteger)CanvasLayerDescendantIndices(idx, _paths).count;
}

// Depth at which children of group `gid` live (0 for the top level).
- (NSInteger)depthOfParentGroupID:(NSString *)gid {
  if (gid.length == 0)
    return 0;
  NSInteger gIdx = [self _indexOfGroupID:gid];
  if (gIdx < 0)
    return 0;
  return (NSInteger)CanvasLayerAncestorIndices((NSUInteger)gIdx, _paths).count +
         1;
}

// A row is hidden when any of its ancestor groups is collapsed.
- (BOOL)_isRowHiddenByCollapse:(NSUInteger)idx {
  if (_collapsedGroups.count == 0)
    return NO;
  NSString *pid = _paths[idx].parentGroupID;
  NSUInteger guard = 0;
  while (pid.length > 0 && guard++ < CanvasLayerGroupDepthGuard) {
    if ([_collapsedGroups containsObject:pid])
      return YES;
    NSInteger gIdx = [self _indexOfGroupID:pid];
    if (gIdx < 0)
      break;
    pid = _paths[(NSUInteger)gIdx].parentGroupID;
  }
  return NO;
}

// A group's descendants always travel with it, so expand the action targets to
// include them.
- (NSIndexSet *)_targetsWithDescendantsForTag:(NSUInteger)tag
                                        paths:(NSArray<KKBezierPath *> *)paths {
  NSMutableIndexSet *expanded = [[self _actionTargetsForTag:tag] mutableCopy];
  [[expanded copy] enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
    if (idx < paths.count && paths[idx].isGroup)
      [expanded addIndexes:CanvasLayerDescendantIndices(idx, paths)];
  }];
  return expanded;
}

#pragma mark - Collapse / visibility / lock

- (void)toggleCollapse:(NSButton *)sender {
  NSUInteger idx = (NSUInteger)sender.tag;
  if (idx >= _paths.count || !_paths[idx].isGroup)
    return;
  NSString *gid = _paths[idx].groupID;
  if (gid.length == 0)
    return;
  if ([_collapsedGroups containsObject:gid])
    [_collapsedGroups removeObject:gid];
  else
    [_collapsedGroups addObject:gid];
  [self _rebuildRows];
}

// Toggle `idx` (and, for a group, its whole subtree) plus un-hide/un-lock its
// ancestors when turning the flag OFF, so a revealed child isn't stranded
// inside a still-hidden group.
- (void)_setGroupFlagAtIndex:(NSUInteger)idx
                       paths:(NSMutableArray<KKBezierPath *> *)paths
                      hidden:(BOOL)isHidden
                       value:(BOOL)newVal {
  if (idx >= paths.count)
    return;
  void (^apply)(KKBezierPath *) = ^(KKBezierPath *p) {
    if (isHidden)
      p.hidden = newVal;
    else
      p.locked = newVal;
  };
  apply(paths[idx]);
  if (paths[idx].isGroup)
    [CanvasLayerDescendantIndices(idx, paths)
        enumerateIndexesUsingBlock:^(NSUInteger di, BOOL *stop) {
          apply(paths[di]);
        }];
  if (!newVal)
    [CanvasLayerAncestorIndices(idx, paths)
        enumerateIndexesUsingBlock:^(NSUInteger ai, BOOL *stop) {
          apply(paths[ai]);
        }];
}

- (void)toggleVisibility:(NSButton *)sender {
  [self _commitRenameIfEditing];
  NSUInteger idx = (NSUInteger)sender.tag;
  BOOL option = (NSEvent.modifierFlags & NSEventModifierFlagOption) != 0;
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    if (idx >= paths.count)
      return;
    if (option) {
      // Solo: only `idx` (with its subtree + ancestors) visible. If already
      // soloed, restore all.
      NSMutableIndexSet *solo = [NSMutableIndexSet indexSetWithIndex:idx];
      if (paths[idx].isGroup)
        [solo addIndexes:CanvasLayerDescendantIndices(idx, paths)];
      [solo addIndexes:CanvasLayerAncestorIndices(idx, paths)];
      BOOL alreadySolo = YES;
      for (NSUInteger i = 0; i < paths.count; i++)
        if (paths[i].hidden == [solo containsIndex:i]) {
          alreadySolo = NO;
          break;
        }
      for (NSUInteger i = 0; i < paths.count; i++)
        paths[i].hidden = alreadySolo ? NO : ![solo containsIndex:i];
    } else {
      [self _setGroupFlagAtIndex:idx
                           paths:paths
                          hidden:YES
                           value:!paths[idx].hidden];
    }
  }];
}

- (void)toggleLock:(NSButton *)sender {
  [self _commitRenameIfEditing];
  NSUInteger idx = (NSUInteger)sender.tag;
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    if (idx >= paths.count)
      return;
    [self _setGroupFlagAtIndex:idx
                         paths:paths
                        hidden:NO
                         value:!paths[idx].locked];
  }];
}

#pragma mark - Group / ungroup / remove (context menu)

- (void)duplicateRow:(NSMenuItem *)sender {
  NSUInteger tag = (NSUInteger)sender.tag;
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    NSIndexSet *targets = [self _targetsWithDescendantsForTag:tag paths:paths];
    if (targets.count == 0)
      return;
    // Map every duplicated group's id to a fresh one first, so cloned children
    // re-link to the cloned parent (not the original).
    NSMutableDictionary<NSString *, NSString *> *groupIDMap =
        [NSMutableDictionary dictionary];
    [targets enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
      if (idx < paths.count && paths[idx].isGroup && paths[idx].groupID.length)
        groupIDMap[paths[idx].groupID] = [[NSUUID UUID] UUIDString];
    }];
    // Build the clones in tree order, then insert them as ONE contiguous block
    // after the originals - keeping each cloned group's descendants right
    // behind it (the display relies on that contiguity).
    NSMutableArray<KKBezierPath *> *clones = [NSMutableArray array];
    [targets enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
      if (idx >= paths.count)
        return;
      KKBezierPath *clone =
          [KKBezierPath pathWithData:[paths[idx] dataRepresentation]];
      clone.layerID = [[NSUUID UUID] UUIDString];
      if (clone.isGroup && groupIDMap[clone.groupID])
        clone.groupID = groupIDMap[clone.groupID];
      if (clone.parentGroupID && groupIDMap[clone.parentGroupID])
        clone.parentGroupID = groupIDMap[clone.parentGroupID];
      [clones addObject:clone];
    }];
    NSUInteger insertAt = MIN(targets.lastIndex + 1, paths.count);
    NSIndexSet *insertSet = [NSIndexSet
        indexSetWithIndexesInRange:NSMakeRange(insertAt, clones.count)];
    [paths insertObjects:clones atIndexes:insertSet];
    [self->_selection removeAllIndexes];
    [self->_selection addIndexes:insertSet];
  }];
}

- (void)deleteRow:(NSMenuItem *)sender {
  NSUInteger tag = (NSUInteger)sender.tag;
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    NSIndexSet *targets = [self _targetsWithDescendantsForTag:tag paths:paths];
    if (targets.count == 0)
      return;
    NSUInteger firstDeleted = targets.firstIndex;
    [targets enumerateIndexesWithOptions:NSEnumerationReverse
                              usingBlock:^(NSUInteger idx, BOOL *stop) {
                                if (idx < paths.count)
                                  [paths removeObjectAtIndex:idx];
                              }];
    [self->_selection removeAllIndexes];
    // A layer must always stay selected (unless the stack is now empty): pick
    // the row that shifted into the deleted slot, or the new last row.
    if (paths.count > 0)
      [self->_selection addIndex:MIN(firstDeleted, paths.count - 1)];
  }];
  // Drive the real selection-change so the inspector swaps to the surviving
  // layer (timeline, OSC set, reset-button state, panel highlight) instead of
  // leaving the deleted one active - see _notifyPrimaryLayerSelected.
  [self _notifyPrimaryLayerSelected];
}

// Group the current selection (Cmd-G). Anchors on the topmost selected row so
// the shared path picks up the whole selection.
- (void)groupSelectedRows {
  if (_selection.count == 0)
    return;
  [self _groupTargetsForTag:_selection.firstIndex];
}

// Wrap the selected rows (plus any selected group's descendants) in a new
// group, inserted at the topmost selected position.
- (void)groupSelection:(NSMenuItem *)sender {
  [self _groupTargetsForTag:(NSUInteger)sender.tag];
}

- (void)_groupTargetsForTag:(NSUInteger)tag {
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    NSIndexSet *targets = [self _targetsWithDescendantsForTag:tag paths:paths];
    if (targets.count == 0)
      return;
    NSUInteger insertAt = targets.firstIndex;
    NSString *inheritedParent =
        insertAt < paths.count ? paths[insertAt].parentGroupID : nil;

    // Pull the targets out (top-to-bottom order preserved).
    NSMutableArray<KKBezierPath *> *members = [NSMutableArray array];
    [targets enumerateIndexesWithOptions:NSEnumerationReverse
                              usingBlock:^(NSUInteger idx, BOOL *stop) {
                                if (idx < paths.count) {
                                  [members insertObject:paths[idx] atIndex:0];
                                  [paths removeObjectAtIndex:idx];
                                }
                              }];

    KKBezierPath *group = [[KKBezierPath alloc] init];
    group.isGroup = YES;
    group.groupID = [[NSUUID UUID] UUIDString];
    group.parentGroupID = inheritedParent;
    group.name = @"Group";
    group.strokeEnabled = NO;
    group.fillEnabled = NO;
    // Top-level members of the selection reparent to the new group; already
    // nested members keep their (relative) parent.
    for (KKBezierPath *m in members) {
      BOOL topLevel = [m.parentGroupID isEqual:inheritedParent] ||
                      (!m.parentGroupID && !inheritedParent);
      if (topLevel)
        m.parentGroupID = group.groupID;
    }

    insertAt = MIN(insertAt, paths.count);
    [paths insertObject:group atIndex:insertAt];
    for (NSUInteger i = 0; i < members.count; i++)
      [paths insertObject:members[i] atIndex:insertAt + 1 + i];

    [self->_selection removeAllIndexes];
    [self->_selection addIndex:insertAt];
  }];
}

// Dissolve a group: its direct children reparent to the group's parent, the
// group entry is removed.
- (void)ungroupRow:(NSMenuItem *)sender {
  NSUInteger idx = (NSUInteger)sender.tag;
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    if (idx >= paths.count || !paths[idx].isGroup)
      return;
    NSString *gid = paths[idx].groupID ?: @"";
    NSString *parentGID = paths[idx].parentGroupID;
    NSMutableIndexSet *childSel = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < paths.count; i++) {
      if (i == idx)
        continue;
      if ([paths[i].parentGroupID isEqualToString:gid]) {
        paths[i].parentGroupID = parentGID;
        [childSel addIndex:i];
      }
    }
    [paths removeObjectAtIndex:idx];
    NSMutableIndexSet *adjusted = [NSMutableIndexSet indexSet];
    [childSel enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
      [adjusted addIndex:i > idx ? i - 1 : i];
    }];
    [self->_selection removeAllIndexes];
    [self->_selection addIndexes:adjusted];
  }];
}

// Lift an entry out of its group to the group's level. It pops out ABOVE the
// group if it sits in the top half of the group's contents, BELOW if in the
// bottom half (matching where the eye would expect it to land).
- (void)removeFromGroup:(NSMenuItem *)sender {
  NSUInteger idx = (NSUInteger)sender.tag;
  if (idx >= _paths.count || !_paths[idx].parentGroupID.length)
    return;
  NSInteger groupIdx = [self _indexOfGroupID:_paths[idx].parentGroupID];
  if (groupIdx < 0)
    return;
  NSIndexSet *desc = CanvasLayerDescendantIndices((NSUInteger)groupIdx, _paths);
  NSUInteger before = [desc countOfIndexesInRange:NSMakeRange(0, idx)];
  BOOL bottomHalf = desc.count > 0 && (before * 2 >= desc.count);
  NSInteger dropIdx =
      bottomHalf ? [self subtreeEndFlatIndex:(NSUInteger)groupIdx] : groupIdx;
  // Reuse the group-aware move (handles the removal shift + subtree if the
  // lifted entry is itself a group).
  [self
      performRowReorderFromIndices:[NSIndexSet indexSetWithIndex:idx]
                       toFlatIndex:dropIdx
                     parentGroupID:_paths[(NSUInteger)groupIdx].parentGroupID];
}

@end
