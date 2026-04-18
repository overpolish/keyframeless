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

  // All visibility inputs come from the snapshot — no FxPlug param reads.
  BOOL strokeExpanded = snap.strokeExpanded;
  BOOL fillExpanded = snap.fillExpanded;
  BOOL sketchExpanded = snap.sketchExpanded;
  BOOL strokeEnabled = snap.strokeEnabled;
  BOOL fillEnabled = snap.fillEnabled;
  BOOL sketchEnabled = snap.sketchEnabled;

  BOOL isImage = selectedPath.isImage;
  BOOL hasPath = (selectedPath != nil && !isImage);
  BOOL isOpen = hasPath && !selectedPath.closed;
  BOOL hasJoins = hasPath && selectedPath.count > 2;
  uint8_t strokeStyle = hasPath ? selectedPath.strokeStyle : 0;
  int8_t startMarker =
      (hasPath && isOpen) ? (int8_t)selectedPath.startMarker : -1;
  int8_t endMarker = (hasPath && isOpen) ? (int8_t)selectedPath.endMarker : -1;
  int fillStyle = hasPath ? (int)selectedPath.sketchFillStyle : 0;

  // Compute visibility hash.
  NSUInteger vh = 1;
  vh = vh * 31 + isImage;
  vh = vh * 31 + hasPath;
  vh = vh * 31 + isOpen;
  vh = vh * 31 + hasJoins;
  vh = vh * 31 + strokeEnabled;
  vh = vh * 31 + strokeExpanded;
  vh = vh * 31 + fillEnabled;
  vh = vh * 31 + fillExpanded;
  vh = vh * 31 + sketchEnabled;
  vh = vh * 31 + sketchExpanded;
  vh = vh * 31 + (NSUInteger)(strokeStyle + 1);
  vh = vh * 31 + (NSUInteger)(startMarker + 2);
  vh = vh * 31 + (NSUInteger)(endMarker + 2);
  vh = vh * 31 + (NSUInteger)(fillStyle + 1);
  vh = vh * 31 + forceShow;

  if (vh == st.visHash)
    return;
  st.visHash = vh;

  id<FxCustomParameterActionAPI_v4> actAPI =
      [api apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:api];
  id<FxParameterSettingAPI_v5> setAPI =
      [api apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

  if (isImage) {
    KKHideObjectParams(setAPI);
    // Show only opacity for image layers.
    [setAPI setParameterFlags:kFxParameterFlag_DEFAULT
                  toParameter:kParamOpacity];
    [actAPI endAction:api];
    return;
  }

  KKShowObjectParams(setAPI);

  BOOL strokeOpen =
      (strokeEnabled || forceShow) && (strokeExpanded || forceShow);
  KKSetStrokeChildrenVisible(setAPI, strokeEnabled || forceShow,
                             strokeExpanded || forceShow);
  if (strokeOpen) {
    KKSetEndWidthVisible(setAPI, isOpen || forceShow);
    KKSetLineCapVisible(setAPI, isOpen || forceShow);
    KKSetMarkersVisible(setAPI, isOpen || forceShow);
    if ((isOpen || forceShow) && startMarker >= 0)
      KKSetMarkerSizeVisible(setAPI, (uint8_t)startMarker,
                             endMarker >= 0 ? (uint8_t)endMarker : 0);
    KKSetLineJoinVisible(setAPI, hasJoins || forceShow);
    KKSetStrokeStyleVisible(setAPI, YES);
    if (forceShow) {
      [setAPI setParameterFlags:kFxParameterFlag_DEFAULT
                    toParameter:kParamDashLength];
      [setAPI setParameterFlags:kFxParameterFlag_DEFAULT
                    toParameter:kParamDashGap];
      [setAPI setParameterFlags:kFxParameterFlag_DEFAULT
                    toParameter:kParamDotGap];
    } else {
      KKSetDashDotParamsForStyle(setAPI, strokeStyle);
    }
  }

  BOOL fillOpen = (fillEnabled || forceShow) && (fillExpanded || forceShow);
  KKSetFillChildrenVisible(setAPI, fillEnabled || forceShow,
                           fillExpanded || forceShow);
  if (fillOpen) {
    if (forceShow)
      KKSetFillStyleParamsVisible(setAPI, YES, 1);
    else
      KKSetFillStyleParamsVisible(setAPI, YES, fillStyle);
  }

  KKSetSketchChildrenVisible(setAPI, sketchEnabled || forceShow,
                             sketchExpanded || forceShow);

  [actAPI endAction:api];
}
