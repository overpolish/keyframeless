/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "LayerList_Private.h"
#import "ObjectParams.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wprotocol"

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
    NSIndexSet *prevSel = KKLayerStateForUUID(_instanceUUID).uiSelection;
    [self _writeBackObjectParams:paramGetAPI toPaths:paths selection:prevSel];
    block(paths);
    NSData *newBlob = [KKBezierPath blobFromPaths:paths];
    [paramSetAPI
        setStringParameterValue:[newBlob base64EncodedStringWithOptions:0]
                    toParameter:kParamPathData];
    NSIndexSet *sel = KKLayerStateForUUID(_instanceUUID).uiSelection;
    [self _syncObjectParamsForSelection:sel
                                  paths:paths
                            paramSetAPI:paramSetAPI];
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

- (NSIndexSet *)_ancestorIndicesForIndex:(NSUInteger)idx
                                   paths:(NSArray<KKBezierPath *> *)paths {
  NSMutableIndexSet *result = [NSMutableIndexSet indexSet];
  NSString *pid = paths[idx].parentGroupID;
  NSUInteger guard = 0;
  while (pid.length > 0 && guard < kGroupDepthGuard) {
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
    guard++;
  }
  return [result copy];
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

- (void)_commitEditing {
  KKLayerListContainer *container =
      KKLayerStateForUUID(_instanceUUID).container;
  if (!container || !KKLayerStateForUUID(_instanceUUID).isEditing)
    return;
  [container.contentView.window makeFirstResponder:container.contentView];
}

- (void)_writeBackObjectParams:(id<FxParameterRetrievalAPI_v6>)paramGetAPI
                       toPaths:(NSMutableArray<KKBezierPath *> *)paths
                     selection:(NSIndexSet *)sel {
  KKBezierPath *prev = KKSelectedPath(sel, paths ?: @[]);
  if (prev)
    KKParamsToPath(paramGetAPI, prev);
}

- (void)_syncObjectParamsForSelection:(NSIndexSet *)sel
                                paths:(NSArray<KKBezierPath *> *)paths
                          paramSetAPI:
                              (id<FxParameterSettingAPI_v5>)paramSetAPI {
  KKBezierPath *selected = KKSelectedPath(sel, paths ?: @[]);
  if (selected) {
    KKPathToParams(paramSetAPI, selected);
    KKSaveSelectedIndex(paramSetAPI,
                        (NSInteger)[paths indexOfObjectIdenticalTo:selected]);
  } else {
    id<FxParameterRetrievalAPI_v6> getAPI =
        [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    if (!KKIsForceShowEnabled(getAPI)) {
      KKHideObjectParams(paramSetAPI);
      KKSaveSelectedIndex(paramSetAPI, -1);
    }
  }
}

- (void)toggleVisibility:(NSButton *)sender {
  NSUInteger idx = sender.tag;
  BOOL optionHeld = (NSEvent.modifierFlags & NSEventModifierFlagOption) != 0;
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    if (idx >= paths.count)
      return;
    if (optionHeld) {
      NSMutableIndexSet *soloMut = [NSMutableIndexSet indexSetWithIndex:idx];
      if (paths[idx].isGroup)
        [soloMut addIndexes:KKDescendantIndices(idx, paths)];
      [soloMut addIndexes:[self _ancestorIndicesForIndex:idx paths:paths]];
      NSIndexSet *soloSet = [soloMut copy];
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
      KKLayerStateForUUID(_instanceUUID).soloActive = hideOthers;
    } else {
      KKLayerStateForUUID(_instanceUUID).soloActive = NO;
      BOOL newVal = !paths[idx].hidden;
      [self _toggleGroupProperty:idx
                           paths:paths
                           apply:^(KKBezierPath *p) {
                             p.hidden = newVal;
                           }];
      if (!newVal) {
        NSIndexSet *ancestors = [self _ancestorIndicesForIndex:idx paths:paths];
        [ancestors enumerateIndexesUsingBlock:^(NSUInteger ai, BOOL *stop) {
          paths[ai].hidden = NO;
        }];
      }
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
    if (!newVal) {
      NSIndexSet *ancestors = [self _ancestorIndicesForIndex:idx paths:paths];
      [ancestors enumerateIndexesUsingBlock:^(NSUInteger ai, BOOL *stop) {
        paths[ai].locked = NO;
      }];
    }
  }];
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
    if (idx >= paths.count || !paths[idx].parentGroupID)
      return;
    NSString *pgid = paths[idx].parentGroupID;
    NSUInteger groupIdx = NSNotFound;
    for (NSUInteger i = 0; i < paths.count; i++) {
      if (paths[i].isGroup && [paths[i].groupID isEqualToString:pgid]) {
        groupIdx = i;
        break;
      }
    }
    paths[idx].parentGroupID =
        paths[groupIdx != NSNotFound ? groupIdx : idx].parentGroupID;
    NSUInteger insertAt = groupIdx != NSNotFound ? groupIdx : 0;
    [paths insertObject:paths[idx] atIndex:insertAt];
    [paths removeObjectAtIndex:idx + 1];
    KKSetLayerSelection(_instanceUUID, [NSIndexSet indexSetWithIndex:insertAt]);
  }];
}

- (void)ungroupRow:(NSMenuItem *)sender {
  NSUInteger idx = sender.tag;
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    if (idx >= paths.count || !paths[idx].isGroup)
      return;
    NSString *gid = paths[idx].groupID;
    NSString *parentGID = paths[idx].parentGroupID;

    NSMutableIndexSet *childSel = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < paths.count; i++) {
      if (i == idx)
        continue;
      if ([paths[i].parentGroupID isEqualToString:gid ?: @""]) {
        paths[i].parentGroupID = parentGID;
        [childSel addIndex:i];
      }
    }
    [paths removeObjectAtIndex:idx];

    NSMutableIndexSet *adjusted = [NSMutableIndexSet indexSet];
    [childSel enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
      [adjusted addIndex:i > idx ? i - 1 : i];
    }];
    KKSetLayerSelection(_instanceUUID, [adjusted copy]);
  }];
}

@end
#pragma clang diagnostic pop
