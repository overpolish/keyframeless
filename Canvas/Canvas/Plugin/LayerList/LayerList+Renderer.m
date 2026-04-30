/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CapStyleView.h"
#import "FillStyleView.h"
#import "JoinStyleView.h"
#import "KKParamSync.h"
#import "LayerList_Private.h"
#import "MarkerStyleView.h"
#import "ObjectParams.h"
#import "StrokeStyleView.h"

NSIndexSet *KKDescendantIndices(NSUInteger groupIdx,
                                NSArray<KKBezierPath *> *paths) {
  NSString *gid = paths[groupIdx].groupID;
  if (!gid)
    return [NSIndexSet indexSet];
  NSMutableIndexSet *result = [NSMutableIndexSet indexSet];
  NSMutableSet<NSString *> *groupIDs = [NSMutableSet setWithObject:gid];
  for (NSUInteger i = 0; i < paths.count; i++) {
    if (i == groupIdx)
      continue;
    if (paths[i].parentGroupID &&
        [groupIDs containsObject:paths[i].parentGroupID]) {
      [result addIndex:i];
      if (paths[i].isGroup && paths[i].groupID)
        [groupIDs addObject:paths[i].groupID];
    }
  }
  return result;
}

NSIndexSet *_Nullable KKCanvasConsumePendingSelection(NSString *uuid) {
  KKLayerInstanceState *s = KKLayerStateForUUID(uuid);
  NSIndexSet *pending = s.pendingOSCSelection;
  s.pendingOSCSelection = nil;
  return pending;
}

void KKCacheCustomStyles(NSString *uuid, KKBezierPath *path) {
  KKLayerInstanceState *s = KKLayerStateForUUID(uuid);
  if (!s)
    return;
  s.cachedLineCap = path.lineCap;
  s.cachedLineJoin = path.lineJoin;
  s.cachedStrokeStyle = path.strokeStyle;
  s.cachedStartMarker = path.startMarker;
  s.cachedEndMarker = path.endMarker;
  s.cachedFillStyle = (uint8_t)path.sketchFillStyle;
}

void KKApplyCachedStyles(NSString *uuid, KKBezierPath *path) {
  KKLayerInstanceState *s = KKLayerStateForUUID(uuid);
  if (!s)
    return;
  path.lineCap = s.cachedLineCap;
  path.lineJoin = s.cachedLineJoin;
  path.strokeStyle = s.cachedStrokeStyle;
  path.startMarker = s.cachedStartMarker;
  path.endMarker = s.cachedEndMarker;
  path.sketchFillStyle = s.cachedFillStyle;
}

NSIndexSet *_Nullable KKCanvasCurrentSelection(NSString *uuid) {
  KKLayerInstanceState *s = KKLayerStateForUUID(uuid);
  return s.selectedIndices;
}

void KKCanvasUpdateSelection(NSString *uuid, NSIndexSet *indices) {
  KKLayerInstanceState *s = KKLayerStateForUUID(uuid);
  NSIndexSet *copy = [indices copy];
  s.selectedIndices = copy;
  dispatch_async(dispatch_get_main_queue(), ^{
    s.uiSelection = copy;
  });
}

static BOOL
isAncestorCollapsed(NSUInteger index, NSArray<NSString *> *parentGroupIDs,
                    NSArray<NSString *> *groupIDs,
                    NSArray<NSNumber *> *groupFlags,
                    NSDictionary<NSString *, NSNumber *> *groupIndexMap,
                    NSSet<NSString *> *collapsedGroupIDs) {
  NSString *pid = parentGroupIDs[index];
  NSUInteger guard = 0;
  while (pid.length > 0 && guard < kGroupDepthGuard) {
    guard++;
    NSNumber *parentIdx = groupIndexMap[pid];
    if (parentIdx &&
        [collapsedGroupIDs
            containsObject:groupIDs[parentIdx.unsignedIntegerValue]])
      return YES;
    if (parentIdx)
      pid = parentGroupIDs[parentIdx.unsignedIntegerValue];
    else
      break;
  }
  return NO;
}

static NSUInteger groupDepth(NSUInteger index,
                             NSArray<NSString *> *parentGroupIDs,
                             NSDictionary<NSString *, NSNumber *> *map) {
  NSUInteger depth = 0;
  NSString *pid = parentGroupIDs[index];
  while (pid.length > 0 && depth < kGroupDepthGuard) {
    depth++;
    NSNumber *pIdx = map[pid];
    if (pIdx)
      pid = parentGroupIDs[pIdx.unsignedIntegerValue];
    else
      break;
  }
  return depth;
}

static NSMenu *buildContextMenu(NSUInteger index, BOOL isGroup,
                                NSUInteger depth, BOOL multiSelect, id target) {
  NSMenu *menu = [[NSMenu alloc] init];

  if (!multiSelect)
    [menu addItem:KKMenuItem(@"Rename", @"pencil", target,
                             @selector(renameRow:), index)];

  if (isGroup)
    [menu addItem:KKMenuItem(@"Ungroup", @"folder.badge.minus", target,
                             @selector(ungroupRow:), index)];

  if (!isGroup)
    [menu addItem:KKMenuItem(@"Group", @"folder.badge.plus", target,
                             @selector(groupSelection:), index)];

  if (!isGroup && depth > 0)
    [menu addItem:KKMenuItem(@"Remove from Group",
                             @"rectangle.portrait.and.arrow.right", target,
                             @selector(removeFromGroup:), index)];

  [menu addItem:KKMenuItem(@"Duplicate", @"plus.rectangle.on.rectangle", target,
                           @selector(duplicateRow:), index)];

  [menu addItem:[NSMenuItem separatorItem]];

  NSMenuItem *deleteItem =
      KKMenuItem(@"Delete", @"trash", target, @selector(deleteRow:), index);
  deleteItem.attributedTitle = [[NSMutableAttributedString alloc]
      initWithString:@"Delete"
          attributes:@{NSForegroundColorAttributeName : [NSColor error]}];
  [menu addItem:deleteItem];

  return menu;
}

static KKLayerRow *buildRow(NSUInteger index, BOOL isGroup, BOOL isImage,
                            BOOL isCollapsed, BOOL isHidden, BOOL isLocked,
                            BOOL isSelected, BOOL isSolo, NSString *name,
                            NSString *gid, NSString *parentGID,
                            NSUInteger depth, BOOL multiSelect,
                            NSImageSymbolConfiguration *symConfig,
                            KKLayerActionTarget *target) {
  NSMutableArray<NSView *> *views = [NSMutableArray array];

  NSButton *folderBtn = nil;
  if (isGroup) {
    NSString *folderName = isCollapsed ? @"folder.fill" : @"folder";
    folderBtn = KKIconButton(folderName, symConfig, target,
                             @selector(toggleGroupCollapse:), index,
                             [NSColor secondaryLabelColor]);
    [views addObject:folderBtn];
  } else if (isImage) {
    NSImage *photoImg = [[NSImage imageWithSystemSymbolName:@"photo.fill"
                                   accessibilityDescription:nil]
        imageWithSymbolConfiguration:symConfig];
    NSImageView *photoView = [NSImageView imageViewWithImage:photoImg];
    photoView.contentTintColor = [NSColor secondaryLabelColor];
    [views addObject:photoView];
  }

  NSString *eyeName = isHidden ? @"eye.slash" : @"eye.fill";
  NSColor *eyeColor =
      isHidden ? [NSColor tertiaryLabelColor]
               : (isSolo ? [NSColor warning] : [NSColor secondaryLabelColor]);
  NSButton *eyeBtn =
      KKIconButton(eyeName, symConfig, target, @selector(toggleVisibility:),
                   index, eyeColor);
  [views addObject:eyeBtn];

  KKLayerButton *nameBtn =
      [KKLayerButton buttonWithTitle:name
                              target:target
                              action:@selector(selectRow:)];
  nameBtn.bezelStyle = NSBezelStyleInline;
  nameBtn.bordered = NO;
  nameBtn.tag = index;
  nameBtn.alignment = NSTextAlignmentLeft;
  nameBtn.font = isGroup ? [NSFont boldSystemFontOfSize:KKFontSizeSM]
                         : [NSFont systemFontOfSize:KKFontSizeSM];
  nameBtn.contentTintColor =
      isHidden ? [NSColor tertiaryLabelColor] : [NSColor labelColor];
  nameBtn.cell.lineBreakMode = NSLineBreakByTruncatingTail;
  [nameBtn setContentHuggingPriority:1
                      forOrientation:NSLayoutConstraintOrientationHorizontal];
  [views addObject:nameBtn];

  NSString *lockName = isLocked ? @"lock.fill" : @"lock.open";
  NSColor *lockColor =
      isLocked ? [NSColor secondaryLabelColor] : [NSColor tertiaryLabelColor];
  NSButton *lockBtn = KKIconButton(lockName, symConfig, target,
                                   @selector(toggleLock:), index, lockColor);
  [views addObject:lockBtn];

  CGFloat indent = depth * kLayerGroupIndent;
  KKLayerRow *row = [KKLayerRow stackViewWithViews:views];
  row.rowIndex = index;
  row.isGroupRow = isGroup;
  row.isImageRow = isImage;
  row.groupID = isGroup ? gid : nil;
  row.parentGroupID = parentGID;
  row.folderButton = folderBtn;
  row.visibilityButton = eyeBtn;
  row.nameButton = nameBtn;
  row.lockButton = lockBtn;
  nameBtn.parentRow = row;
  row.menu = buildContextMenu(index, isGroup, depth, multiSelect, target);
  row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  row.alignment = NSLayoutAttributeCenterY;
  row.distribution = NSStackViewDistributionFill;
  row.spacing = KKSpacingMD;
  row.edgeInsets = NSEdgeInsetsMake(0, KKPaddingMD + indent, 0, KKPaddingMD);
  row.wantsLayer = YES;
  row.layer.cornerRadius = KKRadiusSM;
  row.layer.backgroundColor =
      isSelected
          ? [[NSColor accent] colorWithAlphaComponent:kLayerSelectionAlpha]
                .CGColor
          : [NSColor clearColor].CGColor;
  row.translatesAutoresizingMaskIntoConstraints = NO;
  return row;
}

static void updateRow(KKLayerRow *row, NSUInteger index, BOOL isGroup,
                      BOOL isImage, BOOL isCollapsed, BOOL isHidden,
                      BOOL isLocked, BOOL isSelected, BOOL isSolo,
                      NSString *name, NSString *gid, NSString *parentGID,
                      NSUInteger depth, BOOL multiSelect,
                      NSImageSymbolConfiguration *symConfig,
                      KKLayerActionTarget *target) {
  row.rowIndex = index;
  row.groupID = isGroup ? gid : nil;
  row.parentGroupID = parentGID;

  if (isGroup && row.folderButton) {
    NSString *folderName = isCollapsed ? @"folder.fill" : @"folder";
    row.folderButton.image = [[NSImage imageWithSystemSymbolName:folderName
                                        accessibilityDescription:nil]
        imageWithSymbolConfiguration:symConfig];
    row.folderButton.tag = index;
  }

  NSString *eyeName = isHidden ? @"eye.slash" : @"eye.fill";
  NSColor *eyeColor =
      isHidden ? [NSColor tertiaryLabelColor]
               : (isSolo ? [NSColor warning] : [NSColor secondaryLabelColor]);
  row.visibilityButton.image = [[NSImage imageWithSystemSymbolName:eyeName
                                          accessibilityDescription:nil]
      imageWithSymbolConfiguration:symConfig];
  row.visibilityButton.contentTintColor = eyeColor;
  row.visibilityButton.tag = index;

  row.nameButton.title = name;
  row.nameButton.tag = index;
  row.nameButton.font = isGroup ? [NSFont boldSystemFontOfSize:KKFontSizeSM]
                                : [NSFont systemFontOfSize:KKFontSizeSM];
  row.nameButton.contentTintColor =
      isHidden ? [NSColor tertiaryLabelColor] : [NSColor labelColor];

  NSString *lockName = isLocked ? @"lock.fill" : @"lock.open";
  NSColor *lockColor =
      isLocked ? [NSColor secondaryLabelColor] : [NSColor tertiaryLabelColor];
  row.lockButton.image = [[NSImage imageWithSystemSymbolName:lockName
                                    accessibilityDescription:nil]
      imageWithSymbolConfiguration:symConfig];
  row.lockButton.contentTintColor = lockColor;
  row.lockButton.tag = index;

  CGFloat indent = depth * kLayerGroupIndent;
  row.edgeInsets = NSEdgeInsetsMake(0, KKPaddingMD + indent, 0, KKPaddingMD);
  row.layer.backgroundColor =
      isSelected
          ? [[NSColor accent] colorWithAlphaComponent:kLayerSelectionAlpha]
                .CGColor
          : [NSColor clearColor].CGColor;

  row.menu = buildContextMenu(index, isGroup, depth, multiSelect, target);
}

static void syncStyleView(NSView *view, NSInteger snapshotValue) {
  if (!view)
    return;
  if (snapshotValue >= 0)
    [(id)view setSelectedIndex:snapshotValue];
  [view setNeedsLayout:YES];
  [view setNeedsDisplay:YES];
}

static void syncStyleViews(KKLayerInstanceState *st,
                           KKCanvasStoreSnapshot *snap) {
  syncStyleView(st.capStyleView, snap.selectedLineCap);
  syncStyleView(st.joinStyleView, snap.selectedLineJoin);
  syncStyleView(st.strokeStyleView, snap.selectedStrokeStyle);
  syncStyleView(st.startMarkerView, snap.selectedStartMarker);
  syncStyleView(st.endMarkerView, snap.selectedEndMarker);
  syncStyleView(st.fillStyleView, snap.selectedFillStyle);
}

static void syncGroupHeaders(KKLayerInstanceState *st,
                             KKCanvasStoreSnapshot *snap,
                             BOOL selectedIsImage) {
  KKCustomGroupHeaderView *strokeHeader = st.strokeGroupHeader;
  if (strokeHeader) {
    strokeHeader.isInteractive = YES;
    strokeHeader.isEnabled = snap.strokeEnabled;
    strokeHeader.isExpanded = snap.strokeExpanded;
    strokeHeader.statusText = nil;
  }
  KKCustomGroupHeaderView *fillHeader = st.fillGroupHeader;
  if (fillHeader) {
    fillHeader.isInteractive = YES;
    fillHeader.isEnabled = snap.fillEnabled;
    fillHeader.isExpanded = snap.fillExpanded;
    fillHeader.statusText = nil;
  }
  KKCustomGroupHeaderView *sketchHeader = st.sketchGroupHeader;
  if (sketchHeader) {
    sketchHeader.isInteractive = !selectedIsImage;
    sketchHeader.isEnabled = selectedIsImage ? NO : snap.sketchEnabled;
    sketchHeader.isExpanded = selectedIsImage ? NO : snap.sketchExpanded;
    sketchHeader.statusText =
        selectedIsImage ? @"Not available for images" : nil;
  }
}

void KKCanvasRefreshLayerListFromSnapshot(KKCanvasStoreSnapshot *snap,
                                          KKLayerInstanceState *st,
                                          id<PROAPIAccessing> api) {
  if (!st)
    return;
  KKLayerListContainer *container = st.container;
  if (!container)
    return;
  if (snap.isEditing || snap.isDragging)
    return;

  NSArray<KKBezierPath *> *paths = snap.paths;
  NSUInteger pathCount = paths.count;
  NSIndexSet *capturedSelection = snap.selectedIndices;
  NSView *content = container.contentView;

  if (pathCount == 0) {
    [content.subviews
        makeObjectsPerformSelector:@selector(removeFromSuperview)];
    container.emptyView.hidden = NO;
    [content addSubview:container.emptyView];
    [container.emptyView.centerXAnchor
        constraintEqualToAnchor:content.centerXAnchor]
        .active = YES;
    [container.emptyView.centerYAnchor
        constraintEqualToAnchor:content.centerYAnchor]
        .active = YES;
    container.contentHeightConstraint.constant = kLayerListHeight;
    KKParamSyncApplyFromSnapshot(snap, nil, st.store.uuid, api);
    return;
  }

  container.emptyView.hidden = YES;
  [container.emptyView removeFromSuperview];

  NSImageSymbolConfiguration *symConfig = [NSImageSymbolConfiguration
      configurationWithPointSize:KKSymbolPointSize
                          weight:NSFontWeightRegular];

  NSMutableArray<NSNumber *> *hiddenStates =
      [NSMutableArray arrayWithCapacity:pathCount];
  NSMutableArray<NSNumber *> *lockedStates =
      [NSMutableArray arrayWithCapacity:pathCount];
  NSMutableArray<NSNumber *> *groupFlags =
      [NSMutableArray arrayWithCapacity:pathCount];
  NSMutableArray<NSString *> *groupIDs =
      [NSMutableArray arrayWithCapacity:pathCount];
  NSMutableArray<NSString *> *parentGroupIDs =
      [NSMutableArray arrayWithCapacity:pathCount];
  NSMutableArray<NSString *> *names =
      [NSMutableArray arrayWithCapacity:pathCount];
  NSMutableArray<NSNumber *> *imageFlags =
      [NSMutableArray arrayWithCapacity:pathCount];
  for (NSUInteger i = 0; i < pathCount; i++) {
    [hiddenStates addObject:@(paths[i].hidden)];
    [lockedStates addObject:@(paths[i].locked)];
    [groupFlags addObject:@(paths[i].isGroup)];
    [imageFlags addObject:@(paths[i].isImage)];
    [groupIDs addObject:paths[i].groupID ?: @""];
    [parentGroupIDs addObject:paths[i].parentGroupID ?: @""];
    [names addObject:paths[i].name
                         ?: [NSString stringWithFormat:@"Path %lu",
                                                       (unsigned long)(i + 1)]];
  }

  NSMutableDictionary<NSString *, NSNumber *> *groupIndexMap =
      [NSMutableDictionary dictionary];
  for (NSUInteger i = 0; i < pathCount; i++) {
    if (groupFlags[i].boolValue && groupIDs[i].length > 0)
      groupIndexMap[groupIDs[i]] = @(i);
  }

  BOOL multiSelect = capturedSelection.count > 1;
  BOOL solo = snap.soloActive;

  NSMutableArray<NSNumber *> *visibleIndices =
      [NSMutableArray arrayWithCapacity:pathCount];
  for (NSUInteger i = 0; i < pathCount; i++) {
    if (!isAncestorCollapsed(i, parentGroupIDs, groupIDs, groupFlags,
                             groupIndexMap, snap.collapsedGroupIDs))
      [visibleIndices addObject:@(i)];
  }

  NSMutableArray<KKLayerRow *> *oldRows = [NSMutableArray array];
  for (NSView *sub in content.subviews) {
    if ([sub isKindOfClass:[KKLayerRow class]])
      [oldRows addObject:(KKLayerRow *)sub];
  }

  NSUInteger visCount = visibleIndices.count;
  NSMutableArray<KKLayerRow *> *newRows =
      [NSMutableArray arrayWithCapacity:visCount];

  for (NSUInteger v = 0; v < visCount; v++) {
    NSUInteger i = visibleIndices[v].unsignedIntegerValue;
    BOOL isGroup = groupFlags[i].boolValue;
    BOOL isImage = imageFlags[i].boolValue;
    BOOL collapsed = isGroup && groupIDs[i].length > 0 &&
                     [snap.collapsedGroupIDs containsObject:groupIDs[i]];
    NSUInteger depth = groupDepth(i, parentGroupIDs, groupIndexMap);
    NSString *pgid = parentGroupIDs[i].length > 0 ? parentGroupIDs[i] : nil;

    KKLayerRow *row = nil;
    if (v < oldRows.count && oldRows[v].isGroupRow == isGroup &&
        oldRows[v].isImageRow == isImage) {
      row = oldRows[v];
      updateRow(row, i, isGroup, isImage, collapsed, hiddenStates[i].boolValue,
                lockedStates[i].boolValue, [capturedSelection containsIndex:i],
                solo && !hiddenStates[i].boolValue, names[i], groupIDs[i], pgid,
                depth, multiSelect, symConfig, container.actionTarget);
    } else {
      row = buildRow(
          i, isGroup, isImage, collapsed, hiddenStates[i].boolValue,
          lockedStates[i].boolValue, [capturedSelection containsIndex:i],
          solo && !hiddenStates[i].boolValue, names[i], groupIDs[i], pgid,
          depth, multiSelect, symConfig, container.actionTarget);
    }
    [newRows addObject:row];
  }

  [content.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
  for (NSUInteger v = 0; v < newRows.count; v++) {
    KKLayerRow *row = newRows[v];
    [content addSubview:row];
    [row.leadingAnchor constraintEqualToAnchor:content.leadingAnchor
                                      constant:KKPaddingSM]
        .active = YES;
    [row.trailingAnchor constraintEqualToAnchor:content.trailingAnchor
                                       constant:-KKPaddingSM]
        .active = YES;
    [row.topAnchor
        constraintEqualToAnchor:content.topAnchor
                       constant:kLayerListVerticalPad + v * kLayerRowStride]
        .active = YES;
    [row.heightAnchor constraintEqualToConstant:kLayerRowHeight].active = YES;
  }

  CGFloat totalHeight =
      MAX(visCount * kLayerRowStride + kLayerListVerticalPad + kLayerRowHeight,
          kLayerListHeight);
  container.contentHeightConstraint.constant = totalHeight;

  KKBezierPath *syncPath = nil;
  for (NSUInteger i = 0; i < pathCount; i++) {
    if ([capturedSelection containsIndex:i] && !groupFlags[i].boolValue) {
      syncPath = paths[i];
      break;
    }
  }
  KKParamSyncApplyFromSnapshot(snap, syncPath, st.store.uuid, api);

  syncStyleViews(st, snap);
  syncGroupHeaders(st, snap, syncPath.isImage);
}
