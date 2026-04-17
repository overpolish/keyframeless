/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "LayerList_Private.h"
#import "ObjectParams.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wimplicit-retain-self"
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
  NSMutableArray<KKBezierPath *> *paths;
  if (str.length > 0) {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
    paths = [KKBezierPath pathsFromBlob:blob];
    NSIndexSet *prevSel = KKLayerStateForUUID(_instanceUUID).uiSelection;
    [self _writeBackObjectParams:paramGetAPI toPaths:paths selection:prevSel];
  } else {
    paths = [NSMutableArray array];
  }
  block(paths);
  NSData *newBlob = [KKBezierPath blobFromPaths:paths];
  [paramSetAPI
      setStringParameterValue:[newBlob base64EncodedStringWithOptions:0]
                  toParameter:kParamPathData];
  NSIndexSet *sel = KKLayerStateForUUID(_instanceUUID).uiSelection;
  [self _syncObjectParamsForSelection:sel paths:paths paramSetAPI:paramSetAPI];
  KKLayerStateForUUID(_instanceUUID).forceRefresh = YES;
  KKCanvasRefreshLayerList(_instanceUUID, paths.count, paths);
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
    {
      id<FxParameterRetrievalAPI_v6> getAPI =
          [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      BOOL strokeExpanded = NO;
      [getAPI getBoolValue:&strokeExpanded
             fromParameter:kParamExpandedStroke
                    atTime:kCMTimeZero];
      KKSetStrokeChildrenVisible(paramSetAPI, selected.strokeEnabled,
                                 strokeExpanded);
      BOOL fillExpanded = NO;
      [getAPI getBoolValue:&fillExpanded
             fromParameter:kParamExpandedFill
                    atTime:kCMTimeZero];
      KKSetFillChildrenVisible(paramSetAPI, selected.fillEnabled, fillExpanded);
      BOOL sketchExpanded = NO;
      [getAPI getBoolValue:&sketchExpanded
             fromParameter:kParamExpandedSketch
                    atTime:kCMTimeZero];
      KKSetSketchChildrenVisible(paramSetAPI, selected.sketchEnabled,
                                 sketchExpanded);
    }
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

- (void)_importSVGString:(NSString *)svgString
                    name:(NSString *)name
                 atIndex:(NSUInteger)index {
  KKLayerInstanceState *state = KKLayerStateForUUID(_instanceUUID);
  float cw = state.canvasWidth > 0 ? state.canvasWidth : 1920.0f;
  float ch = state.canvasHeight > 0 ? state.canvasHeight : 1080.0f;
  NSArray<KKBezierPath *> *imported = [KKSVGParser pathsFromSVGString:svgString
                                                          canvasWidth:cw
                                                         canvasHeight:ch];
  if (imported.count == 0)
    return;

  KKLog *log = [KKLog loggerForPlugin:@"co.overpolish.keyframeless"];
  [log info:@"[SVG] Imported %lu paths (canvas %.0fx%.0f)",
            (unsigned long)imported.count, cw, ch];
  for (NSUInteger p = 0; p < imported.count; p++) {
    KKBezierPath *ip = imported[p];
    [log
        info:
            @"[SVG] Path %lu: %lu points, closed=%d, fill=%d (%.3f,%.3f,%.3f), "
            @"stroke=%d (%.3f,%.3f,%.3f w=%.2f), contours=%lu",
            (unsigned long)p, (unsigned long)ip.count, ip.closed,
            ip.fillEnabled, ip.fillR, ip.fillG, ip.fillB, ip.strokeEnabled,
            ip.strokeR, ip.strokeG, ip.strokeB, ip.strokeWidth,
            (unsigned long)ip.contourCount];
    for (NSUInteger i = 0; i < ip.count; i++) {
      KKBezierPoint pt = [ip pointAtIndex:i];
      [log info:@"[SVG]   [%lu] pos=(%.4f,%.4f) in=(%.4f,%.4f) out=(%.4f,%.4f) "
                @"type=%u",
                (unsigned long)i, pt.x, pt.y, pt.inX, pt.inY, pt.outX, pt.outY,
                pt.type];
    }
  }

  // SVG paints first-to-last (back-to-front), layer list is top-to-bottom
  imported = [[imported reverseObjectEnumerator] allObjects];

  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    NSUInteger insertAt = MIN(index, paths.count);

    if (imported.count == 1) {
      KKBezierPath *single = imported.firstObject;
      if (!single.name)
        single.name = name;
      [paths insertObject:single atIndex:insertAt];
      KKSetLayerSelection(_instanceUUID,
                          [NSIndexSet indexSetWithIndex:insertAt]);
    } else {
      KKBezierPath *group = [[KKBezierPath alloc] init];
      group.isGroup = YES;
      group.groupID = [[NSUUID UUID] UUIDString];
      group.name = name;
      [paths insertObject:group atIndex:insertAt];

      for (NSUInteger i = 0; i < imported.count; i++) {
        KKBezierPath *child = imported[i];
        child.parentGroupID = group.groupID;
        if (!child.name)
          child.name =
              [NSString stringWithFormat:@"Path %lu", (unsigned long)(i + 1)];
        [paths insertObject:child atIndex:insertAt + 1 + i];
      }
      KKSetLayerSelection(_instanceUUID,
                          [NSIndexSet indexSetWithIndex:insertAt]);
    }
  }];
}

@end
#pragma clang diagnostic pop
