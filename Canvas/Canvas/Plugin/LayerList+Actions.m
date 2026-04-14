/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "LayerList_Private.h"

@implementation KKLayerActionTarget

- (void)_modifyPaths:(void (^)(NSMutableArray<KKBezierPath *> *))block {
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

  NSString *str = nil;
  [paramGetAPI getStringParameterValue:&str fromParameter:kParamPathData];
  if (str.length > 0) {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
    NSMutableArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
    block(paths);
    NSData *newBlob = [KKBezierPath blobFromPaths:paths];
    [paramSetAPI
        setStringParameterValue:[newBlob base64EncodedStringWithOptions:0]
                    toParameter:kParamPathData];
    KKLayerStateForUUID(_instanceUUID).forceRefresh = YES;
    KKCanvasRefreshLayerList(_instanceUUID, paths.count, paths);
  }
  [actionAPI endAction:self];
}

- (void)_forceRedrawAndRefresh {
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSString *str = nil;
  [paramGetAPI getStringParameterValue:&str fromParameter:kParamPathData];
  [paramSetAPI setStringParameterValue:str ?: @"" toParameter:kParamPathData];
  [actionAPI endAction:self];

  if (str.length > 0) {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
    NSArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
    KKLayerStateForUUID(_instanceUUID).forceRefresh = YES;
    KKCanvasRefreshLayerList(_instanceUUID, paths.count, paths);
  }
}

- (void)_toggleGroupProperty:(NSUInteger)idx
                       paths:(NSMutableArray<KKBezierPath *> *)paths
                       apply:(void (^)(KKBezierPath *))apply {
  if (idx >= paths.count)
    return;
  apply(paths[idx]);
  if (paths[idx].isGroup) {
    NSIndexSet *desc = KKDescendantIndices(idx, paths);
    [desc enumerateIndexesUsingBlock:^(NSUInteger di, BOOL *stop) {
      apply(paths[di]);
    }];
  }
}

- (void)toggleVisibility:(NSButton *)sender {
  NSUInteger idx = sender.tag;
  BOOL optionHeld = (NSEvent.modifierFlags & NSEventModifierFlagOption) != 0;
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    if (idx >= paths.count)
      return;
    if (optionHeld) {
      NSIndexSet *soloSet = [NSIndexSet indexSetWithIndex:idx];
      if (paths[idx].isGroup)
        soloSet = ({
          NSMutableIndexSet *s = [soloSet mutableCopy];
          [s addIndexes:KKDescendantIndices(idx, paths)];
          [s copy];
        });
      BOOL alreadySolo = YES;
      for (NSUInteger i = 0; i < paths.count; i++) {
        if ([soloSet containsIndex:i] && paths[i].hidden) {
          alreadySolo = NO;
          break;
        }
        if (![soloSet containsIndex:i] && !paths[i].hidden) {
          alreadySolo = NO;
          break;
        }
      }
      BOOL hideOthers = !alreadySolo;
      for (NSUInteger i = 0; i < paths.count; i++)
        paths[i].hidden = hideOthers ? ![soloSet containsIndex:i] : NO;
    } else {
      BOOL newVal = !paths[idx].hidden;
      [self _toggleGroupProperty:idx
                           paths:paths
                           apply:^(KKBezierPath *p) {
                             p.hidden = newVal;
                           }];
    }
  }];
}

- (void)toggleLock:(NSButton *)sender {
  NSUInteger idx = sender.tag;
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    if (idx >= paths.count)
      return;
    BOOL newVal = !paths[idx].locked;
    [self _toggleGroupProperty:idx
                         paths:paths
                         apply:^(KKBezierPath *p) {
                           p.locked = newVal;
                         }];
  }];
}

- (void)_commitEditing {
  KKLayerListContainer *container =
      KKLayerStateForUUID(_instanceUUID).container;
  if (!container || !KKLayerStateForUUID(_instanceUUID).isEditing)
    return;
  [container.contentView.window makeFirstResponder:container.contentView];
}

- (void)renameRow:(NSMenuItem *)sender {
  [self _commitEditing];

  NSInteger index = sender.tag;
  KKLayerListContainer *container =
      KKLayerStateForUUID(_instanceUUID).container;
  if (!container)
    return;

  NSView *content = container.contentView;
  for (NSStackView *row in content.subviews) {
    if (![row isKindOfClass:[NSStackView class]])
      continue;
    for (NSView *v in row.arrangedSubviews) {
      if ([v isKindOfClass:[NSButton class]] && v.tag == index &&
          [(NSButton *)v action] == @selector(selectRow:)) {
        NSButton *btn = (NSButton *)v;
        KKEditableLabel *field =
            [KKEditableLabel textFieldWithString:btn.title];
        field.font = btn.font;
        field.tag = index;
        field.bordered = NO;
        field.focusRingType = NSFocusRingTypeNone;
        field.drawsBackground = NO;
        field.textColor = [NSColor labelColor];
        field.delegate = self;
        field.translatesAutoresizingMaskIntoConstraints = NO;
        [field
            setContentHuggingPriority:1
                       forOrientation:NSLayoutConstraintOrientationHorizontal];

        NSUInteger viewIndex = [row.arrangedSubviews indexOfObject:btn];
        [row removeArrangedSubview:btn];
        [btn removeFromSuperview];
        [row insertArrangedSubview:field atIndex:viewIndex];

        KKLayerStateForUUID(_instanceUUID).isEditing = YES;
        [field.window makeFirstResponder:field];
        return;
      }
    }
  }
}

- (void)controlTextDidEndEditing:(NSNotification *)note {
  NSTextField *field = note.object;
  NSString *newName = field.stringValue;
  NSInteger index = field.tag;

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

  NSString *str = nil;
  [paramGetAPI getStringParameterValue:&str fromParameter:kParamPathData];
  if (str.length > 0) {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
    NSMutableArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
    if (index >= 0 && (NSUInteger)index < paths.count) {
      paths[index].name = newName.length > 0 ? newName : nil;
      NSData *newBlob = [KKBezierPath blobFromPaths:paths];
      [paramSetAPI
          setStringParameterValue:[newBlob base64EncodedStringWithOptions:0]
                      toParameter:kParamPathData];
    }
  }
  [actionAPI endAction:self];

  KKLayerStateForUUID(_instanceUUID).isEditing = NO;
  KKLayerStateForUUID(_instanceUUID).forceRefresh = YES;
}

- (void)duplicateRow:(NSMenuItem *)sender {
  NSIndexSet *sel = KKLayerStateForUUID(_instanceUUID).uiSelection;
  if (!sel || sel.count <= 1 || ![sel containsIndex:sender.tag])
    sel = [NSIndexSet indexSetWithIndex:sender.tag];
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    NSMutableIndexSet *newSel = [NSMutableIndexSet indexSet];
    __block NSUInteger offset = 0;
    [sel enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
      NSUInteger src = idx + offset;
      if (src >= paths.count)
        return;
      KKBezierPath *clone =
          [KKBezierPath pathWithData:[paths[src] dataRepresentation]];
      [paths insertObject:clone atIndex:src + 1];
      [newSel addIndex:src + 1];
      offset++;
    }];
    KKSetLayerSelection(_instanceUUID, [newSel copy]);
  }];
}

- (void)deleteRow:(NSMenuItem *)sender {
  NSIndexSet *sel = KKLayerStateForUUID(_instanceUUID).uiSelection;
  if (!sel || sel.count <= 1 || ![sel containsIndex:sender.tag])
    sel = [NSIndexSet indexSetWithIndex:sender.tag];
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    NSMutableIndexSet *expanded = [sel mutableCopy];
    [sel enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
      if (idx < paths.count && paths[idx].isGroup)
        [expanded addIndexes:KKDescendantIndices(idx, paths)];
    }];
    [expanded enumerateIndexesWithOptions:NSEnumerationReverse
                               usingBlock:^(NSUInteger idx, BOOL *stop) {
                                 if (idx < paths.count)
                                   [paths removeObjectAtIndex:idx];
                               }];
    NSMutableIndexSet *adjusted =
        [KKLayerStateForUUID(_instanceUUID).uiSelection mutableCopy]
            ?: [NSMutableIndexSet indexSet];
    [expanded enumerateIndexesWithOptions:NSEnumerationReverse
                               usingBlock:^(NSUInteger idx, BOOL *stop) {
                                 [adjusted removeIndex:idx];
                                 [adjusted shiftIndexesStartingAtIndex:idx + 1
                                                                    by:-1];
                               }];
    KKSetLayerSelection(_instanceUUID, [adjusted copy]);
  }];
}

- (void)groupSelection:(NSMenuItem *)sender {
  NSIndexSet *sel = KKLayerStateForUUID(_instanceUUID).uiSelection;
  if (!sel || sel.count == 0)
    return;
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    NSUInteger insertAt = sel.firstIndex;
    NSString *inheritedParent =
        insertAt < paths.count ? paths[insertAt].parentGroupID : nil;

    NSMutableArray<KKBezierPath *> *children = [NSMutableArray array];
    [sel enumerateIndexesWithOptions:NSEnumerationReverse
                          usingBlock:^(NSUInteger idx, BOOL *stop) {
                            if (idx < paths.count) {
                              [children insertObject:paths[idx] atIndex:0];
                              [paths removeObjectAtIndex:idx];
                            }
                          }];
    KKBezierPath *group = [[KKBezierPath alloc] init];
    group.isGroup = YES;
    group.groupID = [[NSUUID UUID] UUIDString];
    group.parentGroupID = inheritedParent;
    group.name = @"Group";
    for (KKBezierPath *child in children) {
      if ([child.parentGroupID isEqual:inheritedParent] ||
          (!child.parentGroupID && !inheritedParent))
        child.parentGroupID = group.groupID;
    }
    insertAt = MIN(insertAt, paths.count);
    [paths insertObject:group atIndex:insertAt];
    for (NSUInteger i = 0; i < children.count; i++)
      [paths insertObject:children[i] atIndex:insertAt + 1 + i];

    KKSetLayerSelection(_instanceUUID, [NSIndexSet indexSetWithIndex:insertAt]);
  }];
}

- (void)removeFromGroup:(NSMenuItem *)sender {
  NSUInteger idx = sender.tag;
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    if (idx >= paths.count)
      return;
    paths[idx].parentGroupID = nil;
  }];
}

- (void)ungroupRow:(NSMenuItem *)sender {
  NSUInteger idx = sender.tag;
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    if (idx >= paths.count || !paths[idx].isGroup)
      return;
    NSString *gid = paths[idx].groupID;
    NSString *parentGID = paths[idx].parentGroupID;
    [paths removeObjectAtIndex:idx];

    NSMutableIndexSet *childSel = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < paths.count; i++) {
      if ([paths[i].parentGroupID isEqualToString:gid ?: @""]) {
        paths[i].parentGroupID = parentGID;
        [childSel addIndex:i];
      }
    }
    KKSetLayerSelection(_instanceUUID, [childSel copy]);
  }];
}

- (void)toggleGroupCollapse:(id)sender {
  NSUInteger idx = [(NSView *)sender tag];

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSString *str = nil;
  [paramGetAPI getStringParameterValue:&str fromParameter:kParamPathData];
  [paramSetAPI setStringParameterValue:str ?: @"" toParameter:kParamPathData];
  [actionAPI endAction:self];

  if (str.length > 0) {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
    NSArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
    if (idx < paths.count && paths[idx].groupID) {
      NSString *gid = paths[idx].groupID;
      NSMutableSet<NSString *> *mut =
          KKLayerStateForUUID(_instanceUUID).collapsedGroupIDs
              ? [KKLayerStateForUUID(_instanceUUID)
                        .collapsedGroupIDs mutableCopy]
              : [NSMutableSet set];
      if ([mut containsObject:gid])
        [mut removeObject:gid];
      else
        [mut addObject:gid];
      KKLayerStateForUUID(_instanceUUID).collapsedGroupIDs = [mut copy];
    }
    KKLayerStateForUUID(_instanceUUID).forceRefresh = YES;
    KKCanvasRefreshLayerList(_instanceUUID, paths.count, paths);
  }
}

- (void)selectRow:(NSButton *)sender {
  [self _commitEditing];
  NSUInteger clicked = sender.tag;
  NSEventModifierFlags flags = NSEvent.modifierFlags;
  NSMutableIndexSet *sel =
      [KKLayerStateForUUID(_instanceUUID).uiSelection mutableCopy]
          ?: [NSMutableIndexSet indexSet];

  if (flags & NSEventModifierFlagCommand) {
    if ([sel containsIndex:clicked])
      [sel removeIndex:clicked];
    else
      [sel addIndex:clicked];
  } else if (flags & NSEventModifierFlagShift) {
    NSUInteger anchor = sel.count > 0 ? sel.lastIndex : 0;
    NSUInteger lo = MIN(anchor, clicked);
    NSUInteger hi = MAX(anchor, clicked);
    [sel addIndexesInRange:NSMakeRange(lo, hi - lo + 1)];
  } else {
    [sel removeAllIndexes];
    [sel addIndex:clicked];
  }

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSString *str = nil;
  [paramGetAPI getStringParameterValue:&str fromParameter:kParamPathData];

  if (str.length > 0) {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
    NSArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
    if (clicked < paths.count && paths[clicked].isGroup)
      [sel addIndexes:KKDescendantIndices(clicked, paths)];
  }

  KKSetLayerSelection(_instanceUUID, [sel copy]);

  [paramSetAPI setStringParameterValue:str ?: @"" toParameter:kParamPathData];
  [actionAPI endAction:self];

  if (str.length > 0) {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
    NSArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
    KKLayerStateForUUID(_instanceUUID).forceRefresh = YES;
    KKCanvasRefreshLayerList(_instanceUUID, paths.count, paths);
  }
}

- (void)_reorderFromIndices:(NSIndexSet *)indices
                    toIndex:(NSUInteger)target
              parentGroupID:(NSString *)parentGroupID {
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    NSMutableIndexSet *expanded = [indices mutableCopy];
    [indices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
      if (idx < paths.count && paths[idx].isGroup)
        [expanded addIndexes:KKDescendantIndices(idx, paths)];
    }];

    NSMutableSet *directItems = [NSMutableSet set];
    [indices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
      if (idx < paths.count)
        [directItems addObject:paths[idx]];
    }];

    NSMutableArray<KKBezierPath *> *dragged = [NSMutableArray array];
    [expanded enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
      if (idx < paths.count)
        [dragged addObject:paths[idx]];
    }];

    NSUInteger insertBefore = target;
    insertBefore -=
        [expanded countOfIndexesInRange:NSMakeRange(0, insertBefore)];

    [expanded enumerateIndexesWithOptions:NSEnumerationReverse
                               usingBlock:^(NSUInteger idx, BOOL *stop) {
                                 if (idx < paths.count)
                                   [paths removeObjectAtIndex:idx];
                               }];

    NSUInteger insertAt = MIN(insertBefore, paths.count);
    for (NSUInteger i = 0; i < dragged.count; i++) {
      if ([directItems containsObject:dragged[i]])
        dragged[i].parentGroupID = parentGroupID;
      [paths insertObject:dragged[i] atIndex:insertAt + i];
    }

    KKSetLayerSelection(
        _instanceUUID,
        [NSIndexSet
            indexSetWithIndexesInRange:NSMakeRange(insertAt, dragged.count)]);
  }];
}

- (void)_duplicateFromIndices:(NSIndexSet *)indices
                      toIndex:(NSUInteger)target
                parentGroupID:(NSString *)parentGroupID {
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    NSMutableIndexSet *expanded = [indices mutableCopy];
    [indices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
      if (idx < paths.count && paths[idx].isGroup)
        [expanded addIndexes:KKDescendantIndices(idx, paths)];
    }];

    NSMutableSet *directItems = [NSMutableSet set];
    [indices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
      if (idx < paths.count)
        [directItems addObject:paths[idx]];
    }];

    NSMutableDictionary<NSString *, NSString *> *groupIDMap =
        [NSMutableDictionary dictionary];
    NSMutableArray<KKBezierPath *> *clones = [NSMutableArray array];
    [expanded enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
      if (idx >= paths.count)
        return;
      KKBezierPath *clone =
          [KKBezierPath pathWithData:[paths[idx] dataRepresentation]];
      if (clone.isGroup && clone.groupID) {
        NSString *newGID = [[NSUUID UUID] UUIDString];
        groupIDMap[clone.groupID] = newGID;
        clone.groupID = newGID;
      }
      [clones addObject:clone];
    }];

    for (KKBezierPath *clone in clones) {
      if (clone.parentGroupID && groupIDMap[clone.parentGroupID])
        clone.parentGroupID = groupIDMap[clone.parentGroupID];
    }

    NSMutableSet *directClones = [NSMutableSet set];
    __block NSUInteger ci = 0;
    [expanded enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
      if (idx < paths.count && [directItems containsObject:paths[idx]])
        [directClones addObject:clones[ci]];
      ci++;
    }];

    NSUInteger insertAt = MIN(target, paths.count);
    for (NSUInteger i = 0; i < clones.count; i++) {
      if ([directClones containsObject:clones[i]])
        clones[i].parentGroupID = parentGroupID;
      [paths insertObject:clones[i] atIndex:insertAt + i];
    }

    KKSetLayerSelection(
        _instanceUUID,
        [NSIndexSet
            indexSetWithIndexesInRange:NSMakeRange(insertAt, clones.count)]);
  }];
}

@end
