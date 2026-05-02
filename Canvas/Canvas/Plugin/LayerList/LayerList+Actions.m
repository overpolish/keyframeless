/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "LayerList_Private.h"
#import "ObjectParams.h"
#import <AppKit/AppKit.h>

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
    KKParamsToSelectedPaths(paramGetAPI, sel, paths);
}

- (void)_syncObjectParamsForSelection:(NSIndexSet *)sel
                                paths:(NSArray<KKBezierPath *> *)paths
                          paramSetAPI:
                              (id<FxParameterSettingAPI_v5>)paramSetAPI {
  KKBezierPath *selected = KKSelectedPath(sel, paths ?: @[]);
  if (selected) {
    KKPathToParams(paramSetAPI, selected);
    KKCacheCustomStyles(_instanceUUID, selected);
    KKSaveSelectedIndex(paramSetAPI,
                        (NSInteger)[paths indexOfObjectIdenticalTo:selected]);
    // Sync the store's enabled flags so the inspector header toggles reflect
    // the selected path's actual values (e.g. after SVG import).
    KKCanvasStore *store = KKLayerStateForUUID(_instanceUUID).store;
    if (store) {
      [store setStrokeEnabled:selected.strokeEnabled];
      [store setFillEnabled:selected.fillEnabled];
      [store setSketchEnabled:selected.sketchEnabled];
    }
  } else {
    KKSaveSelectedIndex(paramSetAPI, -1);
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
  NSMutableIndexSet *expanded = [sel mutableCopy];
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    [sel enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
      if (idx < paths.count && paths[idx].isGroup)
        [expanded addIndexes:KKDescendantIndices(idx, paths)];
    }];
    NSMutableIndexSet *newSel = [NSMutableIndexSet indexSet];
    NSMutableDictionary<NSString *, NSString *> *groupIDMap =
        [NSMutableDictionary dictionary];
    __block NSUInteger offset = 0;
    [expanded enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
      NSUInteger src = idx + offset;
      if (src >= paths.count)
        return;
      KKBezierPath *clone =
          [KKBezierPath pathWithData:[paths[src] dataRepresentation]];
      clone.layerID = [[NSUUID UUID] UUIDString];
      if (clone.isGroup && clone.groupID) {
        NSString *newID = [[NSUUID UUID] UUIDString];
        groupIDMap[clone.groupID] = newID;
        clone.groupID = newID;
      }
      if (clone.parentGroupID && groupIDMap[clone.parentGroupID])
        clone.parentGroupID = groupIDMap[clone.parentGroupID];
      [paths insertObject:clone atIndex:src + 1];
      if ([sel containsIndex:idx])
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

- (void)_importImageAtPath:(NSString *)path
                      name:(NSString *)name
                   atIndex:(NSUInteger)index {
  KKLayerInstanceState *state = KKLayerStateForUUID(_instanceUUID);
  float cw = state.canvasWidth > 0 ? state.canvasWidth : 1920.0f;
  float ch = state.canvasHeight > 0 ? state.canvasHeight : 1080.0f;

  NSImage *img = [[NSImage alloc] initWithContentsOfFile:path];
  if (!img)
    return;
  NSSize imgSize = img.size;
  if (imgSize.width <= 0 || imgSize.height <= 0)
    return;

  // Aspect-fit the image into the canvas, centered, at 50% canvas size.
  float scale = fminf((cw * 0.5f) / (float)imgSize.width,
                      (ch * 0.5f) / (float)imgSize.height);
  float w = (float)imgSize.width * scale / cw;
  float h = (float)imgSize.height * scale / ch;
  float x0 = 0.5f - w / 2.0f;
  float y0 = 0.5f - h / 2.0f;
  float x1 = x0 + w;
  float y1 = y0 + h;

  KKBezierPath *p = [[KKBezierPath alloc] init];
  p.isImage = YES;
  p.isRect = YES;
  p.closed = YES;
  p.imagePath = path;
  p.imageAspect = (float)imgSize.width / (float)imgSize.height;
  p.name = name;
  p.strokeEnabled = NO;
  p.fillEnabled = NO;
  // 4-corner rect matching setRoundedRectWithMin:max: order (TL, TR, BR, BL)
  [p insertAtIndex:0 position:(simd_float2){x0, y1}];
  [p insertAtIndex:1 position:(simd_float2){x1, y1}];
  [p insertAtIndex:2 position:(simd_float2){x1, y0}];
  [p insertAtIndex:3 position:(simd_float2){x0, y0}];

  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    NSUInteger insertAt = MIN(index, paths.count);
    [paths insertObject:p atIndex:insertAt];
    KKSetLayerSelection(_instanceUUID, [NSIndexSet indexSetWithIndex:insertAt]);
  }];
}

@end
#pragma clang diagnostic pop
