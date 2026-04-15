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

/// Show all per-object param rows (flags only, no values).
/// Add new per-object properties here.
static inline void
KKShowObjectParams(id<FxParameterSettingAPI_v5> _Nonnull paramSetAPI) {
  [paramSetAPI setParameterFlags:kFxParameterFlag_NOT_ANIMATABLE
                     toParameter:kParamStrokeEnabled];
  [paramSetAPI setParameterFlags:kFxParameterFlag_DEFAULT
                     toParameter:kParamStrokeWidth];
  [paramSetAPI setParameterFlags:kFxParameterFlag_DEFAULT
                     toParameter:kParamStrokeColor];
  [paramSetAPI setParameterFlags:kFxParameterFlag_NOT_ANIMATABLE
                     toParameter:kParamFillEnabled];
  [paramSetAPI setParameterFlags:kFxParameterFlag_DEFAULT
                     toParameter:kParamFillColor];
  [paramSetAPI setParameterFlags:kFxParameterFlag_DEFAULT
                     toParameter:kParamOpacity];
  [paramSetAPI setParameterFlags:kFxParameterFlag_NOT_ANIMATABLE
                     toParameter:kParamClosedPath];
}

/// Hide all per-object param rows and clear the saved selection.
/// Add new per-object properties here.
static inline void
KKHideObjectParams(id<FxParameterSettingAPI_v5> _Nonnull paramSetAPI) {
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamStrokeEnabled];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamStrokeWidth];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamStrokeColor];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamFillEnabled];
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
                     toParameter:kParamCornerRadiusTL];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamCornerRadiusTR];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamCornerRadiusBR];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamCornerRadiusBL];
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

/// Show/hide the corner radius param rows based on whether the path is a rect.
static inline void
KKSetCornerRadiiVisible(id<FxParameterSettingAPI_v5> _Nonnull paramSetAPI,
                        BOOL visible) {
  FxParameterFlags flags =
      visible ? kFxParameterFlag_DEFAULT : kFxParameterFlag_HIDDEN;
  [paramSetAPI setParameterFlags:flags toParameter:kParamCornerRadiusTL];
  [paramSetAPI setParameterFlags:flags toParameter:kParamCornerRadiusTR];
  [paramSetAPI setParameterFlags:flags toParameter:kParamCornerRadiusBR];
  [paramSetAPI setParameterFlags:flags toParameter:kParamCornerRadiusBL];
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

  double rtl = 0.0;
  [paramGetAPI getFloatValue:&rtl
               fromParameter:kParamCornerRadiusTL
                      atTime:kCMTimeZero];
  path.cornerRadiusTL = (float)rtl;

  double rtr = 0.0;
  [paramGetAPI getFloatValue:&rtr
               fromParameter:kParamCornerRadiusTR
                      atTime:kCMTimeZero];
  path.cornerRadiusTR = (float)rtr;

  double rbr = 0.0;
  [paramGetAPI getFloatValue:&rbr
               fromParameter:kParamCornerRadiusBR
                      atTime:kCMTimeZero];
  path.cornerRadiusBR = (float)rbr;

  double rbl = 0.0;
  [paramGetAPI getFloatValue:&rbl
               fromParameter:kParamCornerRadiusBL
                      atTime:kCMTimeZero];
  path.cornerRadiusBL = (float)rbl;
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
  [paramSetAPI setFloatValue:path.cornerRadiusTL
                 toParameter:kParamCornerRadiusTL
                      atTime:kCMTimeZero];
  [paramSetAPI setFloatValue:path.cornerRadiusTR
                 toParameter:kParamCornerRadiusTR
                      atTime:kCMTimeZero];
  [paramSetAPI setFloatValue:path.cornerRadiusBR
                 toParameter:kParamCornerRadiusBR
                      atTime:kCMTimeZero];
  [paramSetAPI setFloatValue:path.cornerRadiusBL
                 toParameter:kParamCornerRadiusBL
                      atTime:kCMTimeZero];
}
