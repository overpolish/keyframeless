/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKParamSync.h"
#import "LayerList_Private.h"
#import "ObjectParams.h"
#import <objc/runtime.h>

static const void *kRenameButtonAssocKey = &kRenameButtonAssocKey;

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
        btn.hidden = YES;
        [row insertArrangedSubview:field atIndex:viewIndex];
        objc_setAssociatedObject(field, kRenameButtonAssocKey, btn,
                                 OBJC_ASSOCIATION_ASSIGN);

        KKLayerStateForUUID(self.instanceUUID).isEditing = YES;
        [field.window makeFirstResponder:field];
        return;
      }
    }
  }
}

- (void)controlTextDidEndEditing:(NSNotification *)note {
  NSTextField *field = note.object;
  if (!field || !KKLayerStateForUUID(self.instanceUUID).isEditing)
    return;
  NSInteger index = field.tag;
  NSButton *btn = objc_getAssociatedObject(field, kRenameButtonAssocKey);
  NSString *originalTitle = btn.title;
  NSString *newName = field.stringValue;

  if (newName.length > 0 && ![newName isEqualToString:originalTitle]) {
    [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
      if (index >= 0 && (NSUInteger)index < paths.count)
        paths[index].name = newName;
    }];
  }

  KKLayerStateForUUID(self.instanceUUID).isEditing = NO;

  NSStackView *row = (NSStackView *)field.superview;
  if ([row isKindOfClass:[NSStackView class]]) {
    [row removeArrangedSubview:field];
  }
  [field removeFromSuperview];
  if (btn) {
    btn.title =
        newName.length > 0
            ? newName
            : [NSString stringWithFormat:@"Path %ld", (long)(index + 1)];
    btn.hidden = NO;
  }
}

- (BOOL)control:(NSControl *)control
               textView:(NSTextView *)textView
    doCommandBySelector:(SEL)cmd {
  if (cmd == @selector(cancelOperation:) || cmd == @selector(cancel:)) {
    NSTextField *tf = (NSTextField *)control;
    NSButton *btn = objc_getAssociatedObject(tf, kRenameButtonAssocKey);
    if (btn)
      tf.stringValue = btn.title ?: @"";
    [textView insertNewline:nil];
    return YES;
  }
  return NO;
}

- (void)selectRow:(NSButton *)sender {
  [self _commitEditing];
  NSUInteger clicked = sender.tag;
  NSEventModifierFlags flags = NSApp.currentEvent.modifierFlags;
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
  NSString *str = KKCanvasReadPathData(paramGetAPI);

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
    KKCanvasWritePathData([newBlob base64EncodedStringWithOptions:0],
                          paramSetAPI);
  } else {
    KKCanvasWritePathData(str, paramSetAPI);
  }

  // Persist the selection in a hidden FCP param so cmd-Z can revert it
  // alongside the path blob. `kParamLastSelectedIndex` only encodes a
  // single path index (-1 for groups), so it can't restore group
  // selection on undo — this fills that gap. See ObjectParams.h for the
  // string format.
  NSString *selStr = KKSerializeCanvasSelection(newSel, paths ?: @[]);
  [paramSetAPI setStringParameterValue:selStr
                           toParameter:kParamCanvasSelection];

  // Push to the in-process store + apply visibility flags BEFORE endAction
  // so any flag flips coalesce with the param writes above as one undo
  // entry. Without this, the async store-observer fires after endAction,
  // calls KKParamSyncApplyFromSnapshot in its own scope, and the resulting
  // group-container flag writes (kParamGroupStroke/Fill/Sketch/Transform)
  // become a second undo entry per click. Mirrors the fix in _modifyPaths.
  KKCanvasStore *store = KKLayerStateForUUID(self.instanceUUID).store;
  if (store) {
    [store performBatch:^{
      if (paths)
        [store setPaths:paths];
      [store setSelectedIndices:newSel];
      [store syncSelectedPathProperties];
    }];
    KKCanvasStoreSnapshot *snap = [store snapshot];
    KKBezierPath *selPath =
        KKSelectedTransformTarget(snap.selectedIndices, snap.paths);
    KKParamSyncApplyFromSnapshotInScope(snap, selPath, self.instanceUUID,
                                        self.apiManager);
  }

  [actionAPI endAction:self];
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
  NSString *str = KKCanvasReadPathData(paramGetAPI);
  KKCanvasWritePathData(str, paramSetAPI);

  NSSet<NSString *> *newCollapsed = nil;
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
      newCollapsed = [mut copy];
      // Persist to a hidden param so the disclosure state survives FCP
      // project reload (the in-memory lst dies with the XPC instance).
      NSString *joined =
          [[newCollapsed allObjects] componentsJoinedByString:@","];
      [paramSetAPI setStringParameterValue:joined ?: @""
                               toParameter:kParamCollapsedGroups];
    }
  }
  [actionAPI endAction:self];

  if (newCollapsed) {
    KKLayerInstanceState *lst = KKLayerStateForUUID(self.instanceUUID);
    lst.collapsedGroupIDs = newCollapsed;
    [lst.store performBatch:^{
      [lst.store setCollapsedGroupIDs:newCollapsed];
    }];
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
