/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import "Constants.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>

/// Find the first selected non-group path in a selection.
static inline KKBezierPath *_Nullable KKSelectedPath(
    NSIndexSet *_Nullable sel, NSArray<KKBezierPath *> *_Nonnull paths) {
  __block KKBezierPath *result = nil;
  [sel enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
    if (idx < paths.count && !paths[idx].isGroup) {
      result = paths[idx];
      *stop = YES;
    }
  }];
  return result;
}

/// Returns YES when the "Force Show All Parameters" toggle is ON.
static inline BOOL
KKIsForceShowEnabled(id<FxParameterRetrievalAPI_v6> _Nonnull paramGetAPI) {
  BOOL val = NO;
  [paramGetAPI getBoolValue:&val
              fromParameter:kParamForceShow
                     atTime:kCMTimeZero];
  return val;
}

/// Show/hide the stroke group header.
static inline void
KKSetStrokeGroupVisible(id<FxParameterSettingAPI_v5> _Nonnull paramSetAPI,
                        BOOL visible) {
  FxParameterFlags flags =
      visible ? (kFxParameterFlag_CUSTOM_UI | kFxParameterFlag_NOT_ANIMATABLE |
                 kFxParameterFlag_USE_FULL_VIEW_WIDTH)
              : kFxParameterFlag_HIDDEN;
  [paramSetAPI setParameterFlags:flags toParameter:kParamGroupStroke];
}

/// Show/hide the stroke group children based on enabled+expanded state.
static inline void
KKSetStrokeChildrenVisible(id<FxParameterSettingAPI_v5> _Nonnull paramSetAPI,
                           BOOL strokeEnabled, BOOL strokeExpanded) {
  BOOL show = strokeEnabled && strokeExpanded;
  FxParameterFlags flags =
      show ? kFxParameterFlag_DEFAULT : kFxParameterFlag_HIDDEN;
  [paramSetAPI setParameterFlags:flags toParameter:kParamStrokeWidth];
  [paramSetAPI setParameterFlags:flags toParameter:kParamStrokeColor];
  if (!show) {
    [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                       toParameter:kParamLineCap];
    [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                       toParameter:kParamLineJoin];
    [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                       toParameter:kParamStrokeStyle];
    [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                       toParameter:kParamDashLength];
    [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                       toParameter:kParamDashGap];
    [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                       toParameter:kParamDotGap];
  }
}

/// Show/hide the fill group header.
static inline void
KKSetFillGroupVisible(id<FxParameterSettingAPI_v5> _Nonnull paramSetAPI,
                      BOOL visible) {
  FxParameterFlags flags =
      visible ? (kFxParameterFlag_CUSTOM_UI | kFxParameterFlag_NOT_ANIMATABLE |
                 kFxParameterFlag_USE_FULL_VIEW_WIDTH)
              : kFxParameterFlag_HIDDEN;
  [paramSetAPI setParameterFlags:flags toParameter:kParamGroupFill];
}

/// Show/hide the fill group children based on enabled+expanded state.
static inline void
KKSetFillChildrenVisible(id<FxParameterSettingAPI_v5> _Nonnull paramSetAPI,
                         BOOL fillEnabled, BOOL fillExpanded) {
  BOOL show = fillEnabled && fillExpanded;
  FxParameterFlags flags =
      show ? kFxParameterFlag_DEFAULT : kFxParameterFlag_HIDDEN;
  [paramSetAPI setParameterFlags:flags toParameter:kParamFillColor];
  if (!show) {
    [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                       toParameter:kParamSketchFillStyle];
    [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                       toParameter:kParamSketchFillGap];
    [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                       toParameter:kParamSketchFillAngle];
    [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                       toParameter:kParamSketchFillWeight];
  }
}

/// Show/hide the sketch group header.
static inline void
KKSetSketchGroupVisible(id<FxParameterSettingAPI_v5> _Nonnull paramSetAPI,
                        BOOL visible) {
  FxParameterFlags flags =
      visible ? (kFxParameterFlag_CUSTOM_UI | kFxParameterFlag_NOT_ANIMATABLE |
                 kFxParameterFlag_USE_FULL_VIEW_WIDTH)
              : kFxParameterFlag_HIDDEN;
  [paramSetAPI setParameterFlags:flags toParameter:kParamGroupSketch];
}

/// Show/hide the sketch group children based on enabled+expanded state.
static inline void
KKSetSketchChildrenVisible(id<FxParameterSettingAPI_v5> _Nonnull paramSetAPI,
                           BOOL sketchEnabled, BOOL sketchExpanded) {
  BOOL show = sketchEnabled && sketchExpanded;
  FxParameterFlags flags =
      show ? kFxParameterFlag_DEFAULT : kFxParameterFlag_HIDDEN;
  [paramSetAPI setParameterFlags:flags toParameter:kParamSketchRoughness];
  [paramSetAPI setParameterFlags:flags toParameter:kParamSketchBowing];
  [paramSetAPI setParameterFlags:flags toParameter:kParamSketchStrokes];
  FxParameterFlags seedFlags =
      show ? (kFxParameterFlag_CUSTOM_UI | kFxParameterFlag_NOT_ANIMATABLE)
           : kFxParameterFlag_HIDDEN;
  [paramSetAPI setParameterFlags:seedFlags toParameter:kParamSketchSeed];
}

/// Show all per-object param rows (flags only, no values).
/// Add new per-object properties here.
static inline void
KKShowObjectParams(id<FxParameterSettingAPI_v5> _Nonnull paramSetAPI) {
  KKSetStrokeGroupVisible(paramSetAPI, YES);
  KKSetFillGroupVisible(paramSetAPI, YES);
  KKSetSketchGroupVisible(paramSetAPI, YES);
  [paramSetAPI setParameterFlags:kFxParameterFlag_DEFAULT
                     toParameter:kParamOpacity];
  [paramSetAPI setParameterFlags:kFxParameterFlag_NOT_ANIMATABLE
                     toParameter:kParamClosedPath];
}

/// Hide all per-object param rows and clear the saved selection.
/// Add new per-object properties here.
static inline void
KKHideObjectParams(id<FxParameterSettingAPI_v5> _Nonnull paramSetAPI) {
  KKSetStrokeGroupVisible(paramSetAPI, YES);
  KKSetFillGroupVisible(paramSetAPI, YES);
  KKSetSketchGroupVisible(paramSetAPI, YES);
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamStrokeWidth];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamStrokeColor];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamFillColor];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamOpacity];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamLineCap];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamLineJoin];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamStrokeStyle];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamDashLength];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamDashGap];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamDotGap];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamClosedPath];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamSketchRoughness];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamSketchBowing];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamSketchStrokes];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamSketchFillStyle];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamSketchFillGap];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamSketchFillAngle];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamSketchFillWeight];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamSketchSeed];
}

/// Show/hide the Line Cap param row based on whether the path is open.
static inline void
KKSetLineCapVisible(id<FxParameterSettingAPI_v5> _Nonnull paramSetAPI,
                    BOOL visible) {
  FxParameterFlags flags =
      visible ? (kFxParameterFlag_CUSTOM_UI | kFxParameterFlag_NOT_ANIMATABLE)
              : kFxParameterFlag_HIDDEN;
  [paramSetAPI setParameterFlags:flags toParameter:kParamLineCap];
}

/// Show/hide the Line Join param row based on whether the path has >2 points.
static inline void
KKSetLineJoinVisible(id<FxParameterSettingAPI_v5> _Nonnull paramSetAPI,
                     BOOL visible) {
  FxParameterFlags flags =
      visible ? (kFxParameterFlag_CUSTOM_UI | kFxParameterFlag_NOT_ANIMATABLE)
              : kFxParameterFlag_HIDDEN;
  [paramSetAPI setParameterFlags:flags toParameter:kParamLineJoin];
}

/// Show/hide the Stroke Style param row.
static inline void
KKSetStrokeStyleVisible(id<FxParameterSettingAPI_v5> _Nonnull paramSetAPI,
                        BOOL visible) {
  FxParameterFlags flags =
      visible ? (kFxParameterFlag_CUSTOM_UI | kFxParameterFlag_NOT_ANIMATABLE)
              : kFxParameterFlag_HIDDEN;
  [paramSetAPI setParameterFlags:flags toParameter:kParamStrokeStyle];
}

/// Show/hide the dash/dot sub-params based on the current stroke style.
/// 0=solid (hide all), 1=dashed (show length+gap), 2=dotted (show gap only).
static inline void
KKSetDashDotParamsForStyle(id<FxParameterSettingAPI_v5> _Nonnull paramSetAPI,
                           uint8_t strokeStyle) {
  BOOL showDash = (strokeStyle == 1);
  BOOL showDot = (strokeStyle == 2);
  [paramSetAPI setParameterFlags:showDash ? kFxParameterFlag_DEFAULT
                                          : kFxParameterFlag_HIDDEN
                     toParameter:kParamDashLength];
  [paramSetAPI setParameterFlags:showDash ? kFxParameterFlag_DEFAULT
                                          : kFxParameterFlag_HIDDEN
                     toParameter:kParamDashGap];
  [paramSetAPI setParameterFlags:showDot ? kFxParameterFlag_DEFAULT
                                         : kFxParameterFlag_HIDDEN
                     toParameter:kParamDotGap];
}

/// Show/hide the sketch roughness/bowing sliders based on sketch enabled state.
static inline void
KKSetSketchParamsVisible(id<FxParameterSettingAPI_v5> _Nonnull paramSetAPI,
                         BOOL visible) {
  FxParameterFlags flags =
      visible ? kFxParameterFlag_DEFAULT : kFxParameterFlag_HIDDEN;
  [paramSetAPI setParameterFlags:flags toParameter:kParamSketchRoughness];
  [paramSetAPI setParameterFlags:flags toParameter:kParamSketchBowing];
  [paramSetAPI setParameterFlags:flags toParameter:kParamSketchStrokes];
  FxParameterFlags seedFlags =
      visible ? (kFxParameterFlag_CUSTOM_UI | kFxParameterFlag_NOT_ANIMATABLE)
              : kFxParameterFlag_HIDDEN;
  [paramSetAPI setParameterFlags:seedFlags toParameter:kParamSketchSeed];
}

/// Show/hide fill style and sub-params based on whether fill is enabled.
static inline void
KKSetFillStyleParamsVisible(id<FxParameterSettingAPI_v5> _Nonnull paramSetAPI,
                            BOOL fillEnabled, int fillStyle) {
  FxParameterFlags styleFlags =
      fillEnabled
          ? (kFxParameterFlag_CUSTOM_UI | kFxParameterFlag_NOT_ANIMATABLE)
          : kFxParameterFlag_HIDDEN;
  [paramSetAPI setParameterFlags:styleFlags toParameter:kParamSketchFillStyle];
  FxParameterFlags subFlags = (fillEnabled && fillStyle > 0)
                                  ? kFxParameterFlag_DEFAULT
                                  : kFxParameterFlag_HIDDEN;
  [paramSetAPI setParameterFlags:subFlags toParameter:kParamSketchFillGap];
  [paramSetAPI setParameterFlags:subFlags toParameter:kParamSketchFillAngle];
  [paramSetAPI setParameterFlags:subFlags toParameter:kParamSketchFillWeight];
}

/// Save the index of the currently-selected path so it survives clip switches.
static inline void
KKSaveSelectedIndex(id<FxParameterSettingAPI_v5> _Nonnull paramSetAPI,
                    NSInteger index) {
  [paramSetAPI setFloatValue:(double)index
                 toParameter:kParamLastSelectedIndex
                      atTime:kCMTimeZero];
}

/// Read the last-selected path index (-1 if none).
static inline NSInteger
KKReadSelectedIndex(id<FxParameterRetrievalAPI_v6> _Nonnull paramGetAPI) {
  double v = -1.0;
  [paramGetAPI getFloatValue:&v
               fromParameter:kParamLastSelectedIndex
                      atTime:kCMTimeZero];
  return (NSInteger)v;
}

/// Read the fill style of the currently-selected path (0 if none).
static inline int
KKReadSelectedFillStyle(id<FxParameterRetrievalAPI_v6> _Nonnull paramGetAPI) {
  NSString *str = nil;
  [paramGetAPI getStringParameterValue:&str fromParameter:kParamPathData];
  NSInteger selIdx = KKReadSelectedIndex(paramGetAPI);
  if (str.length > 0 && selIdx >= 0) {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
    NSArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
    if ((NSUInteger)selIdx < paths.count)
      return (int)paths[selIdx].sketchFillStyle;
  }
  return 0;
}

/// Read per-object param values from FxPlug and apply to a path.
/// Add new per-object properties here.
static inline void
KKParamsToPath(id<FxParameterRetrievalAPI_v6> _Nonnull paramGetAPI,
               KKBezierPath *_Nonnull path) {
  BOOL strokeOn = YES;
  [paramGetAPI getBoolValue:&strokeOn
              fromParameter:kParamStrokeEnabled
                     atTime:kCMTimeZero];
  path.strokeEnabled = strokeOn;

  double w = 8.0;
  [paramGetAPI getFloatValue:&w
               fromParameter:kParamStrokeWidth
                      atTime:kCMTimeZero];
  double r = 1.0, g = 0.0, b = 0.0;
  [paramGetAPI getRedValue:&r
                greenValue:&g
                 blueValue:&b
             fromParameter:kParamStrokeColor
                    atTime:kCMTimeZero];
  path.strokeWidth = (float)w;
  path.strokeR = (float)r;
  path.strokeG = (float)g;
  path.strokeB = (float)b;

  BOOL fillOn = NO;
  [paramGetAPI getBoolValue:&fillOn
              fromParameter:kParamFillEnabled
                     atTime:kCMTimeZero];
  double fr = 1.0, fg = 1.0, fb = 1.0;
  [paramGetAPI getRedValue:&fr
                greenValue:&fg
                 blueValue:&fb
             fromParameter:kParamFillColor
                    atTime:kCMTimeZero];
  path.fillEnabled = fillOn;
  path.fillR = (float)fr;
  path.fillG = (float)fg;
  path.fillB = (float)fb;

  double op = 100.0;
  [paramGetAPI getFloatValue:&op
               fromParameter:kParamOpacity
                      atTime:kCMTimeZero];
  path.opacity = (float)(op / 100.0);

  double dl = 20.0;
  [paramGetAPI getFloatValue:&dl
               fromParameter:kParamDashLength
                      atTime:kCMTimeZero];
  path.dashLength = (float)dl;

  double dg = 10.0;
  [paramGetAPI getFloatValue:&dg
               fromParameter:kParamDashGap
                      atTime:kCMTimeZero];
  path.dashGap = (float)dg;

  double dotg = 10.0;
  [paramGetAPI getFloatValue:&dotg
               fromParameter:kParamDotGap
                      atTime:kCMTimeZero];
  path.dotGap = (float)dotg;

  BOOL closedPath = YES;
  [paramGetAPI getBoolValue:&closedPath
              fromParameter:kParamClosedPath
                     atTime:kCMTimeZero];
  path.closed = closedPath;

  BOOL sketchOn = NO;
  [paramGetAPI getBoolValue:&sketchOn
              fromParameter:kParamSketchEnabled
                     atTime:kCMTimeZero];
  path.sketchEnabled = sketchOn;

  double sRough = kSketchRoughnessDefault;
  [paramGetAPI getFloatValue:&sRough
               fromParameter:kParamSketchRoughness
                      atTime:kCMTimeZero];
  path.sketchRoughness = (float)sRough;

  double sBow = kSketchBowingDefault;
  [paramGetAPI getFloatValue:&sBow
               fromParameter:kParamSketchBowing
                      atTime:kCMTimeZero];
  path.sketchBowing = (float)sBow;

  double sStrokes = kSketchStrokesDefault;
  [paramGetAPI getFloatValue:&sStrokes
               fromParameter:kParamSketchStrokes
                      atTime:kCMTimeZero];
  path.sketchStrokes = (uint8_t)sStrokes;

  double fGap = kSketchFillGapDefault;
  [paramGetAPI getFloatValue:&fGap
               fromParameter:kParamSketchFillGap
                      atTime:kCMTimeZero];
  path.sketchFillGap = (float)fGap;

  double fAngle = kSketchFillAngleDefault;
  [paramGetAPI getFloatValue:&fAngle
               fromParameter:kParamSketchFillAngle
                      atTime:kCMTimeZero];
  path.sketchFillAngle = (float)fAngle;

  double fWeight = kSketchFillWeightDefault;
  [paramGetAPI getFloatValue:&fWeight
               fromParameter:kParamSketchFillWeight
                      atTime:kCMTimeZero];
  path.sketchFillWeight = (float)fWeight;
}

/// Modify a property of the currently-selected path inside an action scope.
/// The block receives the selected path for mutation.
static inline void
KKModifySelectedPathProperty(id<PROAPIAccessing> _Nonnull api,
                             void (^_Nonnull block)(KKBezierPath *_Nonnull)) {
  id<FxCustomParameterActionAPI_v4> actAPI =
      [api apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:api];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [api apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [api apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSString *str = nil;
  [getAPI getStringParameterValue:&str fromParameter:kParamPathData];
  NSInteger selIdx = KKReadSelectedIndex(getAPI);
  if (str.length > 0 && selIdx >= 0) {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
    NSMutableArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
    if ((NSUInteger)selIdx < paths.count) {
      block(paths[selIdx]);
      NSData *newBlob = [KKBezierPath blobFromPaths:paths];
      [setAPI setStringParameterValue:[newBlob base64EncodedStringWithOptions:0]
                          toParameter:kParamPathData];
    }
  }
  [actAPI endAction:api];
}

/// Write a path's per-object values to FxPlug params and show the rows.
/// Add new per-object properties here.
static inline void
KKPathToParams(id<FxParameterSettingAPI_v5> _Nonnull paramSetAPI,
               KKBezierPath *_Nonnull path) {
  KKShowObjectParams(paramSetAPI);
  [paramSetAPI setBoolValue:path.strokeEnabled
                toParameter:kParamStrokeEnabled
                     atTime:kCMTimeZero];
  [paramSetAPI setFloatValue:path.strokeWidth
                 toParameter:kParamStrokeWidth
                      atTime:kCMTimeZero];
  [paramSetAPI setRedValue:path.strokeR
                greenValue:path.strokeG
                 blueValue:path.strokeB
               toParameter:kParamStrokeColor
                    atTime:kCMTimeZero];
  [paramSetAPI setBoolValue:path.fillEnabled
                toParameter:kParamFillEnabled
                     atTime:kCMTimeZero];
  [paramSetAPI setRedValue:path.fillR
                greenValue:path.fillG
                 blueValue:path.fillB
               toParameter:kParamFillColor
                    atTime:kCMTimeZero];
  [paramSetAPI setFloatValue:path.opacity * 100.0f
                 toParameter:kParamOpacity
                      atTime:kCMTimeZero];
  [paramSetAPI setFloatValue:path.dashLength
                 toParameter:kParamDashLength
                      atTime:kCMTimeZero];
  [paramSetAPI setFloatValue:path.dashGap
                 toParameter:kParamDashGap
                      atTime:kCMTimeZero];
  [paramSetAPI setFloatValue:path.dotGap
                 toParameter:kParamDotGap
                      atTime:kCMTimeZero];
  [paramSetAPI setBoolValue:path.closed
                toParameter:kParamClosedPath
                     atTime:kCMTimeZero];
  [paramSetAPI setBoolValue:path.sketchEnabled
                toParameter:kParamSketchEnabled
                     atTime:kCMTimeZero];
  [paramSetAPI setFloatValue:path.sketchRoughness
                 toParameter:kParamSketchRoughness
                      atTime:kCMTimeZero];
  [paramSetAPI setFloatValue:path.sketchBowing
                 toParameter:kParamSketchBowing
                      atTime:kCMTimeZero];
  [paramSetAPI setFloatValue:(double)path.sketchStrokes
                 toParameter:kParamSketchStrokes
                      atTime:kCMTimeZero];
  [paramSetAPI setFloatValue:path.sketchFillGap
                 toParameter:kParamSketchFillGap
                      atTime:kCMTimeZero];
  [paramSetAPI setFloatValue:path.sketchFillAngle
                 toParameter:kParamSketchFillAngle
                      atTime:kCMTimeZero];
  [paramSetAPI setFloatValue:path.sketchFillWeight
                 toParameter:kParamSketchFillWeight
                      atTime:kCMTimeZero];
}
