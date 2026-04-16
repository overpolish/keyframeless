/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "CapStyleView.h"
#import "JoinStyleView.h"
#import "LayerList_Private.h"
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

static NSUInteger layerListHash(NSUInteger count,
                                NSArray<KKBezierPath *> *paths,
                                NSIndexSet *selection) {
  NSUInteger h = count;
  for (NSUInteger i = 0; i < count; i++) {
    h = h * 31 + (paths[i].hidden ? 1 : 0);
    h = h * 31 + (paths[i].locked ? 2 : 0);
    h = h * 31 + paths[i].name.hash;
    h = h * 31 + paths[i].count;
    h = h * 31 + (paths[i].closed ? 1 : 0);
    h = h * 31 + (paths[i].isRect ? 1 : 0);
  }
  h = h * 31 + selection.hash;
  return h;
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

  if (!isGroup)
    [menu addItem:KKMenuItem(@"Duplicate", @"plus.rectangle.on.rectangle",
                             target, @selector(duplicateRow:), index)];

  [menu addItem:[NSMenuItem separatorItem]];

  NSMenuItem *deleteItem =
      KKMenuItem(@"Delete", @"trash", target, @selector(deleteRow:), index);
  deleteItem.attributedTitle = [[NSMutableAttributedString alloc]
      initWithString:@"Delete"
          attributes:@{NSForegroundColorAttributeName : [NSColor error]}];
  [menu addItem:deleteItem];

  return menu;
}

static KKLayerRow *
buildRow(NSUInteger index, BOOL isGroup, BOOL isCollapsed, BOOL isHidden,
         BOOL isLocked, BOOL isSelected, BOOL isSolo, NSString *name,
         NSString *gid, NSString *parentGID, NSUInteger depth, BOOL multiSelect,
         NSImageSymbolConfiguration *symConfig, KKLayerActionTarget *target) {
  NSMutableArray<NSView *> *views = [NSMutableArray array];

  if (isGroup) {
    NSString *folderName = isCollapsed ? @"folder.fill" : @"folder";
    [views addObject:KKIconButton(folderName, symConfig, target,
                                  @selector(toggleGroupCollapse:), index,
                                  [NSColor secondaryLabelColor])];
  }

  NSString *eyeName = isHidden ? @"eye.slash" : @"eye.fill";
  NSColor *eyeColor =
      isHidden ? [NSColor tertiaryLabelColor]
               : (isSolo ? [NSColor warning] : [NSColor secondaryLabelColor]);
  [views addObject:KKIconButton(eyeName, symConfig, target,
                                @selector(toggleVisibility:), index, eyeColor)];

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
  [views addObject:KKIconButton(lockName, symConfig, target,
                                @selector(toggleLock:), index, lockColor)];

  CGFloat indent = depth * kLayerGroupIndent;
  KKLayerRow *row = [KKLayerRow stackViewWithViews:views];
  row.rowIndex = index;
  row.groupID = isGroup ? gid : nil;
  row.parentGroupID = parentGID;
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

void KKCanvasRefreshLayerList(NSString *uuid, NSUInteger pathCount,
                              NSArray<KKBezierPath *> *paths) {
  KKLayerInstanceState *st = KKLayerStateForUUID(uuid);
  if (!st)
    return;
  NSIndexSet *selection = st.selectedIndices ?: [NSIndexSet indexSet];
  NSUInteger hash = layerListHash(pathCount, paths, selection);
  if (hash == st.listHash && !st.forceRefresh)
    return;
  st.listHash = hash;
  st.forceRefresh = NO;

  NSIndexSet *capturedSelection = [selection copy];
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
  for (NSUInteger i = 0; i < pathCount; i++) {
    [hiddenStates addObject:@(paths[i].hidden)];
    [lockedStates addObject:@(paths[i].locked)];
    [groupFlags addObject:@(paths[i].isGroup)];
    [groupIDs addObject:paths[i].groupID ?: @""];
    [parentGroupIDs addObject:paths[i].parentGroupID ?: @""];
    [names addObject:paths[i].name
                         ?: [NSString stringWithFormat:@"Path %lu",
                                                       (unsigned long)(i + 1)]];
  }

  // Capture selected path's style properties for the style view updates.
  __block NSInteger selectedLineCap = -1;
  __block NSInteger selectedLineJoin = -1;
  __block NSInteger selectedStrokeStyle = -1;
  __block BOOL selectedHasJoins = NO;
  __block BOOL selectedIsRect = NO;
  __block BOOL selectedSketchEnabled = NO;
  __block BOOL selectedFillEnabled = NO;
  __block NSInteger selectedFillStyle = 0;
  __block BOOL selectedStrokeEnabled = NO;
  __block BOOL selectedStrokeExpanded = NO;
  __block BOOL selectedFillExpanded = NO;
  __block BOOL selectedSketchExpanded = NO;
  [selection enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
    if (idx < pathCount && !paths[idx].isGroup) {
      if (!paths[idx].closed)
        selectedLineCap = paths[idx].lineCap;
      if (paths[idx].count > 2) {
        selectedLineJoin = paths[idx].lineJoin;
        selectedHasJoins = YES;
      }
      selectedStrokeStyle = paths[idx].strokeStyle;
      selectedIsRect = paths[idx].isRect;
      selectedSketchEnabled = paths[idx].sketchEnabled;
      selectedFillEnabled = paths[idx].fillEnabled;
      selectedFillStyle = paths[idx].sketchFillStyle;
      selectedStrokeEnabled = paths[idx].strokeEnabled;
      *stop = YES;
    }
  }];

  dispatch_async(dispatch_get_main_queue(), ^{
    KKLayerListContainer *container = st.container;
    if (!container)
      return;
    if (st.isEditing || st.isDragging)
      return;

    NSView *content = container.contentView;
    [content.subviews
        makeObjectsPerformSelector:@selector(removeFromSuperview)];

    if (pathCount == 0) {
      container.emptyView.hidden = NO;
      [content addSubview:container.emptyView];
      container.contentHeightConstraint.constant = kLayerListHeight;

      KKLayerActionTarget *at = container.actionTarget;
      if (at.apiManager) {
        id<FxCustomParameterActionAPI_v4> actAPI = [at.apiManager
            apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
        [actAPI startAction:at];
        id<FxParameterSettingAPI_v5> setAPI =
            [at.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
        id<FxParameterRetrievalAPI_v6> getAPI = [at.apiManager
            apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
        if (!KKIsForceShowEnabled(getAPI))
          KKHideObjectParams(setAPI);
        [actAPI endAction:at];
      }
      return;
    }

    container.emptyView.hidden = YES;

    NSImageSymbolConfiguration *symConfig = [NSImageSymbolConfiguration
        configurationWithPointSize:KKSymbolPointSize
                            weight:NSFontWeightRegular];

    NSMutableDictionary<NSString *, NSNumber *> *groupIndexMap =
        [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < pathCount; i++) {
      if (groupFlags[i].boolValue && groupIDs[i].length > 0)
        groupIndexMap[groupIDs[i]] = @(i);
    }

    BOOL multiSelect = capturedSelection.count > 1;
    BOOL solo = st.soloActive;
    NSUInteger visRow = 0;

    for (NSUInteger i = 0; i < pathCount; i++) {
      if (isAncestorCollapsed(i, parentGroupIDs, groupIDs, groupFlags,
                              groupIndexMap, st.collapsedGroupIDs))
        continue;

      BOOL isGroup = groupFlags[i].boolValue;
      BOOL collapsed = isGroup && groupIDs[i].length > 0 &&
                       [st.collapsedGroupIDs containsObject:groupIDs[i]];
      NSUInteger depth = groupDepth(i, parentGroupIDs, groupIndexMap);
      NSString *pgid = parentGroupIDs[i].length > 0 ? parentGroupIDs[i] : nil;

      KKLayerRow *row = buildRow(
          i, isGroup, collapsed, hiddenStates[i].boolValue,
          lockedStates[i].boolValue, [capturedSelection containsIndex:i],
          solo && !hiddenStates[i].boolValue, names[i], groupIDs[i], pgid,
          depth, multiSelect, symConfig, container.actionTarget);

      [content addSubview:row];
      [row.leadingAnchor constraintEqualToAnchor:content.leadingAnchor
                                        constant:KKPaddingSM]
          .active = YES;
      [row.trailingAnchor constraintEqualToAnchor:content.trailingAnchor
                                         constant:-KKPaddingSM]
          .active = YES;
      [row.topAnchor constraintEqualToAnchor:content.topAnchor
                                    constant:kLayerListVerticalPad +
                                             visRow * kLayerRowStride]
          .active = YES;
      [row.heightAnchor constraintEqualToConstant:kLayerRowHeight].active = YES;
      visRow++;
    }

    CGFloat totalHeight =
        MAX(visRow * kLayerRowStride + kLayerListVerticalPad + kLayerRowHeight,
            kLayerListHeight);
    container.contentHeightConstraint.constant = totalHeight;

    // Sync per-object param visibility using an action scope so it
    // persists. This runs on main queue from drawOSC, same as the
    // layer list UI update.
    KKLayerActionTarget *at = container.actionTarget;
    if (at.apiManager) {
      id<FxCustomParameterActionAPI_v4> actAPI = [at.apiManager
          apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
      [actAPI startAction:at];
      id<FxParameterSettingAPI_v5> setAPI =
          [at.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      id<FxParameterRetrievalAPI_v6> getAPI =
          [at.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      BOOL forceShow = KKIsForceShowEnabled(getAPI);
      if (capturedSelection.count > 0) {
        BOOL hasPath = NO;
        BOOL isOpen = NO;
        for (NSUInteger i = 0; i < pathCount; i++) {
          if ([capturedSelection containsIndex:i] && !groupFlags[i].boolValue) {
            hasPath = YES;
            isOpen = (selectedLineCap >= 0); // open path had lineCap captured
            break;
          }
        }
        if (hasPath || forceShow) {
          KKShowObjectParams(setAPI);

          [getAPI getBoolValue:&selectedStrokeExpanded
                 fromParameter:kParamExpandedStroke
                        atTime:kCMTimeZero];
          BOOL strokeOpen = (selectedStrokeEnabled || forceShow) &&
                            (selectedStrokeExpanded || forceShow);
          KKSetStrokeChildrenVisible(setAPI, selectedStrokeEnabled || forceShow,
                                     selectedStrokeExpanded || forceShow);

          if (strokeOpen) {
            KKSetLineCapVisible(setAPI, isOpen || forceShow);
            KKSetLineJoinVisible(setAPI, selectedHasJoins || forceShow);
            KKSetStrokeStyleVisible(setAPI, YES);
            if (forceShow) {
              [setAPI setParameterFlags:kFxParameterFlag_DEFAULT
                            toParameter:kParamDashLength];
              [setAPI setParameterFlags:kFxParameterFlag_DEFAULT
                            toParameter:kParamDashGap];
              [setAPI setParameterFlags:kFxParameterFlag_DEFAULT
                            toParameter:kParamDotGap];
            } else {
              KKSetDashDotParamsForStyle(
                  setAPI,
                  selectedStrokeStyle >= 0 ? (uint8_t)selectedStrokeStyle : 0);
            }
          }
          [getAPI getBoolValue:&selectedFillExpanded
                 fromParameter:kParamExpandedFill
                        atTime:kCMTimeZero];
          BOOL fillOpen = (selectedFillEnabled || forceShow) &&
                          (selectedFillExpanded || forceShow);
          KKSetFillChildrenVisible(setAPI, selectedFillEnabled || forceShow,
                                   selectedFillExpanded || forceShow);
          if (fillOpen) {
            if (forceShow) {
              KKSetFillStyleParamsVisible(setAPI, YES, 1);
            } else {
              KKSetFillStyleParamsVisible(setAPI, YES, (int)selectedFillStyle);
            }
          }
          [getAPI getBoolValue:&selectedSketchExpanded
                 fromParameter:kParamExpandedSketch
                        atTime:kCMTimeZero];
          KKSetSketchChildrenVisible(setAPI, selectedSketchEnabled || forceShow,
                                     selectedSketchExpanded || forceShow);
          KKSetCornerRadiiVisible(setAPI, selectedIsRect || forceShow);
        } else {
          KKHideObjectParams(setAPI);
        }
      } else if (!forceShow) {
        KKHideObjectParams(setAPI);
      }
      [actAPI endAction:at];
    }

    // Sync cap style view selection and layout.
    KKCapStyleView *capView = st.capStyleView;
    if (capView) {
      if (selectedLineCap >= 0)
        capView.selectedIndex = selectedLineCap;
      [capView setNeedsLayout:YES];
      [capView setNeedsDisplay:YES];
    }

    // Sync join style view selection and layout.
    KKJoinStyleView *joinView = st.joinStyleView;
    if (joinView) {
      if (selectedLineJoin >= 0)
        joinView.selectedIndex = selectedLineJoin;
      [joinView setNeedsLayout:YES];
      [joinView setNeedsDisplay:YES];
    }

    // Sync stroke style view selection and layout.
    KKStrokeStyleView *strokeStyleView = st.strokeStyleView;
    if (strokeStyleView) {
      if (selectedStrokeStyle >= 0)
        strokeStyleView.selectedIndex = selectedStrokeStyle;
      [strokeStyleView setNeedsLayout:YES];
      [strokeStyleView setNeedsDisplay:YES];
    }

    // Determine if there's a selected non-group path for header sync.
    BOOL hasPath = NO;
    for (NSUInteger i = 0; i < pathCount; i++) {
      if ([capturedSelection containsIndex:i] && !groupFlags[i].boolValue) {
        hasPath = YES;
        break;
      }
    }

    // Sync stroke group header enabled/expanded state.
    KKCustomGroupHeaderView *strokeHeader = st.strokeGroupHeader;
    if (strokeHeader) {
      strokeHeader.isInteractive = hasPath;
      if (hasPath) {
        strokeHeader.isEnabled = selectedStrokeEnabled;
        strokeHeader.isExpanded = selectedStrokeExpanded;
      } else {
        strokeHeader.isEnabled = NO;
        strokeHeader.isExpanded = NO;
      }
    }

    // Sync fill group header enabled/expanded state.
    KKCustomGroupHeaderView *fillHeader = st.fillGroupHeader;
    if (fillHeader) {
      fillHeader.isInteractive = hasPath;
      if (hasPath) {
        fillHeader.isEnabled = selectedFillEnabled;
        fillHeader.isExpanded = selectedFillExpanded;
      } else {
        fillHeader.isEnabled = NO;
        fillHeader.isExpanded = NO;
      }
    }

    // Sync sketch group header enabled/expanded state.
    KKCustomGroupHeaderView *sketchHeader = st.sketchGroupHeader;
    if (sketchHeader) {
      sketchHeader.isInteractive = hasPath;
      if (hasPath) {
        sketchHeader.isEnabled = selectedSketchEnabled;
        sketchHeader.isExpanded = selectedSketchExpanded;
      } else {
        sketchHeader.isEnabled = NO;
        sketchHeader.isExpanded = NO;
      }
    }
  });
}
