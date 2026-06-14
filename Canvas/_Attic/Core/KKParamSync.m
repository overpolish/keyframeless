/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKParamSync.h"
#import "Constants.h"
#import "KKCanvasStore.h"
#import "LayerList_Private.h"
#import "ObjectParams.h"

NSString *KKCanvasReadPathData(id<FxParameterRetrievalAPI_v6> getAPI) {
  return KKReadCustomParamString(getAPI, kParamPathData);
}

NSString *KKCanvasReadPathDataMirror(id<FxParameterRetrievalAPI_v6> getAPI) {
  if (!getAPI)
    return nil;
  NSString *value = nil;
  [getAPI getStringParameterValue:&value fromParameter:kParamPathDataMirror];
  return value;
}

void KKCanvasWritePathData(NSString *base64,
                           id<FxParameterSettingAPI_v5> setAPI) {
  if (!setAPI)
    return;
  KKWriteCustomParamString(setAPI, base64 ?: @"", kParamPathData);
  [setAPI setStringParameterValue:base64 ?: @""
                      toParameter:kParamPathDataMirror];
}

BOOL KKCanvasSelectionIsGroupOnly(KKCanvasStoreSnapshot *snap) {
  NSIndexSet *sel = snap.selectedIndices;
  if (sel.count == 0)
    return NO;
  NSArray<KKBezierPath *> *p = snap.paths;
  for (NSUInteger idx = sel.firstIndex; idx != NSNotFound;
       idx = [sel indexGreaterThanIndex:idx]) {
    if (idx < p.count && !p[idx].isGroup)
      return NO;
  }
  return YES;
}

void KKCanvasApplyExpandedToStore(KKCanvasStore *store, UInt32 paramID,
                                  BOOL expanded) {
  switch (paramID) {
  case kParamExpandedStroke:
    [store setStrokeExpanded:expanded];
    break;
  case kParamExpandedFill:
    [store setFillExpanded:expanded];
    break;
  case kParamExpandedSketch:
    [store setSketchExpanded:expanded];
    break;
  case kParamExpandedTransform:
    [store setTransformExpanded:expanded];
    break;
  }
}

void KKCanvasApplyEnabledToStore(KKCanvasStore *store, UInt32 paramID,
                                 BOOL enabled) {
  switch (paramID) {
  case kParamStrokeEnabled:
    [store setStrokeEnabled:enabled];
    break;
  case kParamFillEnabled:
    [store setFillEnabled:enabled];
    break;
  case kParamSketchEnabled:
    [store setSketchEnabled:enabled];
    break;
  case kParamTransformEnabled:
    [store setTransformEnabled:enabled];
    break;
  }
}

// Compute KKVisCondition + visHash from a snapshot + selected path.
// Returns YES if writes are needed (caller still has to do them); NO if
// the visHash already matches and the caller can early-exit.
//
// `fallback*` values are consulted only when no path is selected - they
// let the inspector reveal sub-params (dash/dot, marker size, sketch
// fill gap/angle/weight) that depend on the persisted cycle params on
// empty canvas. Pass 0 to disable a given fallback.
typedef struct {
  uint8_t strokeStyle;
  int8_t startMarker;
  int8_t endMarker;
  int sketchFillStyle;
} KKVisFallback;

static BOOL kkComputeActiveVis(KKCanvasStoreSnapshot *snap,
                               KKBezierPath *selectedPath,
                               KKLayerInstanceState *st, KKVisFallback fallback,
                               KKVisCondition *outActive, BOOL *outForceShow) {
  BOOL forceShow = snap.forceShow;
  BOOL isImage = selectedPath.isImage;
  BOOL isGroup = selectedPath.isGroup;
  BOOL hasPath = (selectedPath != nil && !isImage && !isGroup);
  BOOL isOpen = hasPath && !selectedPath.closed;
  BOOL hasJoins = hasPath && selectedPath.count > 2;
  uint8_t strokeStyle =
      hasPath ? selectedPath.strokeStyle : fallback.strokeStyle;
  // When no path: assume "open" semantics so marker fallbacks are honored
  // (markers only apply to open paths visually, but on empty canvas the
  // user still wants to pick them and see the size param).
  int8_t startMarker = hasPath
                           ? (isOpen ? (int8_t)selectedPath.startMarker : -1)
                           : fallback.startMarker;
  int8_t endMarker = hasPath ? (isOpen ? (int8_t)selectedPath.endMarker : -1)
                             : fallback.endMarker;
  int fillStyle =
      hasPath ? (int)selectedPath.sketchFillStyle : fallback.sketchFillStyle;
  uint8_t strokeColorMode = snap.strokeColorMode;
  uint8_t fillColorMode = snap.fillColorMode;
  uint8_t strokeGradType = snap.strokeGradientType;
  uint8_t fillGradType = snap.fillGradientType;

  BOOL strokeOpen =
      (snap.strokeEnabled || forceShow) && (snap.strokeExpanded || forceShow);
  BOOL fillOpen =
      (snap.fillEnabled || forceShow) && (snap.fillExpanded || forceShow);
  BOOL sketchOpen =
      (snap.sketchEnabled || forceShow) && (snap.sketchExpanded || forceShow);
  BOOL transformOpen = (snap.transformEnabled || forceShow) &&
                       (snap.transformExpanded || forceShow);

  KKVisCondition active = KKBuildVisConditions(
      isImage, isGroup, isOpen, hasJoins, strokeOpen, fillOpen, sketchOpen,
      transformOpen, strokeStyle, startMarker, endMarker, fillStyle,
      strokeColorMode, fillColorMode, strokeGradType, fillGradType);

  NSUInteger vh = (NSUInteger)active * 31 + forceShow;
  if (vh == st.visHash)
    return NO;
  st.visHash = vh;
  *outActive = active;
  *outForceShow = forceShow;
  return YES;
}

void KKParamSyncApplyFromSnapshotInScope(KKCanvasStoreSnapshot *snap,
                                         KKBezierPath *selectedPath,
                                         NSString *uuid,
                                         id<PROAPIAccessing> api) {
  static BOOL sApplying = NO;
  if (sApplying)
    return;
  KKLayerInstanceState *st = KKLayerStateForUUID(uuid);
  if (!st)
    return;
  // Read fallbacks up front (caller is in scope, so getAPI resolves).
  id<FxParameterRetrievalAPI_v6> getAPI =
      [api apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  KKVisFallback fallback = {
      .strokeStyle = (uint8_t)KKReadCustomParamInt(getAPI, kParamStrokeStyle),
      .startMarker = (int8_t)KKReadCustomParamInt(getAPI, kParamStartMarker),
      .endMarker = (int8_t)KKReadCustomParamInt(getAPI, kParamEndMarker),
      .sketchFillStyle = KKReadCustomParamInt(getAPI, kParamSketchFillStyle),
  };
  KKVisCondition active = KKVisAlways;
  BOOL forceShow = NO;
  if (!kkComputeActiveVis(snap, selectedPath, st, fallback, &active,
                          &forceShow))
    return;

  sApplying = YES;
  id<FxParameterSettingAPI_v5> setAPI =
      [api apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (getAPI && setAPI) {
    if (!st.lastWrittenFlags)
      st.lastWrittenFlags = [NSMutableDictionary dictionary];
    KKApplyParamVisibility(setAPI, getAPI, active, forceShow,
                           st.lastWrittenFlags);
  }
  sApplying = NO;
}

void KKParamSyncApplyFromSnapshot(KKCanvasStoreSnapshot *snap,
                                  KKBezierPath *selectedPath, NSString *uuid,
                                  id<PROAPIAccessing> api) {
  static BOOL sApplying = NO;
  if (sApplying)
    return;
  KKLayerInstanceState *st = KKLayerStateForUUID(uuid);
  if (!st)
    return;
  // Open scope first so getAPI resolves; read fallback for visibility
  // computation (drives KKVisDashed/Dotted on empty canvas).
  sApplying = YES;
  id<FxCustomParameterActionAPI_v4> actAPI =
      [api apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:api];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [api apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [api apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  KKVisFallback fallback = {
      .strokeStyle = (uint8_t)KKReadCustomParamInt(getAPI, kParamStrokeStyle),
      .startMarker = (int8_t)KKReadCustomParamInt(getAPI, kParamStartMarker),
      .endMarker = (int8_t)KKReadCustomParamInt(getAPI, kParamEndMarker),
      .sketchFillStyle = KKReadCustomParamInt(getAPI, kParamSketchFillStyle),
  };
  KKVisCondition active = KKVisAlways;
  BOOL forceShow = NO;
  if (!kkComputeActiveVis(snap, selectedPath, st, fallback, &active,
                          &forceShow)) {
    [actAPI endAction:api];
    sApplying = NO;
    return;
  }
  if (getAPI && setAPI) {
    if (!st.lastWrittenFlags)
      st.lastWrittenFlags = [NSMutableDictionary dictionary];
    KKApplyParamVisibility(setAPI, getAPI, active, forceShow,
                           st.lastWrittenFlags);
  }
  [actAPI endAction:api];
  sApplying = NO;
}
