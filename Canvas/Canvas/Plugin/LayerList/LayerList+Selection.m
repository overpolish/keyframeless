/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "LayerList_Private.h"
#import "ObjectParams.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation KKLayerActionTarget (Selection)

- (void)renameRow:(NSMenuItem *)sender {
  [self _commitEditing];

  NSInteger index = sender.tag;
  KKLayerListContainer *container =
      KKLayerStateForUUID(self.instanceUUID).container;
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

        KKLayerStateForUUID(self.instanceUUID).isEditing = YES;
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
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

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

  KKLayerStateForUUID(self.instanceUUID).isEditing = NO;
}

- (void)selectRow:(NSButton *)sender {
  [self _commitEditing];
  NSUInteger clicked = sender.tag;
  NSEventModifierFlags flags = NSEvent.modifierFlags;
  NSMutableIndexSet *sel =
      [KKLayerStateForUUID(self.instanceUUID).uiSelection mutableCopy]
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
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSString *str = nil;
  [paramGetAPI getStringParameterValue:&str fromParameter:kParamPathData];

  NSMutableArray<KKBezierPath *> *paths = nil;
  if (str.length > 0) {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
    paths = [KKBezierPath pathsFromBlob:blob];

    NSIndexSet *oldSel = KKLayerStateForUUID(self.instanceUUID).uiSelection;
    [self _writeBackObjectParams:paramGetAPI toPaths:paths selection:oldSel];
  }

  NSIndexSet *newSel = [sel copy];
  KKSetLayerSelection(self.instanceUUID, newSel);

  [self _syncObjectParamsForSelection:sel
                                paths:paths ?: @[]
                          paramSetAPI:paramSetAPI];
  if (paths) {
    NSData *newBlob = [KKBezierPath blobFromPaths:paths];
    [paramSetAPI
        setStringParameterValue:[newBlob base64EncodedStringWithOptions:0]
                    toParameter:kParamPathData];
  } else {
    [paramSetAPI setStringParameterValue:str ?: @"" toParameter:kParamPathData];
  }
  [actionAPI endAction:self];

  // Fire the store observer on this tick so the layer list and sequencer
  // refresh immediately, instead of waiting for FCP to round-trip the param
  // writes through drawOSC.
  KKCanvasStore *store = KKLayerStateForUUID(self.instanceUUID).store;
  if (store) {
    [store performBatch:^{
      if (paths)
        [store setPaths:paths];
      [store setSelectedIndices:newSel];
      [store syncSelectedPathProperties];
    }];
  }
}

- (void)toggleGroupCollapse:(id)sender {
  NSUInteger idx = [(NSView *)sender tag];

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
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
          KKLayerStateForUUID(self.instanceUUID).collapsedGroupIDs
              ? [KKLayerStateForUUID(self.instanceUUID)
                        .collapsedGroupIDs mutableCopy]
              : [NSMutableSet set];
      if ([mut containsObject:gid])
        [mut removeObject:gid];
      else
        [mut addObject:gid];
      KKLayerStateForUUID(self.instanceUUID).collapsedGroupIDs = [mut copy];
    }
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

    NSMutableIndexSet *descendantIndices = [NSMutableIndexSet indexSet];
    [indices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
      if (idx < paths.count && paths[idx].isGroup)
        [descendantIndices addIndexes:KKDescendantIndices(idx, paths)];
    }];
    NSMutableSet *directItems = [NSMutableSet set];
    [indices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
      if (idx < paths.count && ![descendantIndices containsIndex:idx])
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
        self.instanceUUID,
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
      clone.layerID = [[NSUUID UUID] UUIDString];
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
        self.instanceUUID,
        [NSIndexSet
            indexSetWithIndexesInRange:NSMakeRange(insertAt, clones.count)]);
  }];
}

@end
#pragma clang diagnostic pop
