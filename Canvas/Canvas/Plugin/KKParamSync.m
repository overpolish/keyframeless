/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKParamSync.h"
#import "LayerList_Private.h"
#import "ObjectParams.h"

void KKParamSyncApplyFromSnapshot(KKCanvasStoreSnapshot *snap,
                                  KKBezierPath *selectedPath, NSString *uuid,
                                  id<PROAPIAccessing> api) {
  KKLayerInstanceState *st = KKLayerStateForUUID(uuid);
  if (!st)
    return;

  BOOL forceShow = snap.forceShow;
  BOOL isImage = selectedPath.isImage;
  BOOL hasPath = (selectedPath != nil && !isImage);
  BOOL isOpen = hasPath && !selectedPath.closed;
  BOOL hasJoins = hasPath && selectedPath.count > 2;
  uint8_t strokeStyle = hasPath ? selectedPath.strokeStyle : 0;
  int8_t startMarker =
      (hasPath && isOpen) ? (int8_t)selectedPath.startMarker : -1;
  int8_t endMarker = (hasPath && isOpen) ? (int8_t)selectedPath.endMarker : -1;
  int fillStyle = hasPath ? (int)selectedPath.sketchFillStyle : 0;

  BOOL strokeOpen =
      (snap.strokeEnabled || forceShow) && (snap.strokeExpanded || forceShow);
  BOOL fillOpen =
      (snap.fillEnabled || forceShow) && (snap.fillExpanded || forceShow);
  BOOL sketchOpen =
      (snap.sketchEnabled || forceShow) && (snap.sketchExpanded || forceShow);

  KKVisCondition active = KKBuildVisConditions(
      isImage, isOpen, hasJoins, strokeOpen, fillOpen, sketchOpen, strokeStyle,
      startMarker, endMarker, fillStyle);

  NSUInteger vh = (NSUInteger)active * 31 + forceShow;
  if (vh == st.visHash)
    return;
  st.visHash = vh;

  id<FxCustomParameterActionAPI_v4> actAPI =
      [api apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:api];
  id<FxParameterSettingAPI_v5> setAPI =
      [api apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

  KKApplyParamVisibility(setAPI, active, forceShow);

  [actAPI endAction:api];
}
