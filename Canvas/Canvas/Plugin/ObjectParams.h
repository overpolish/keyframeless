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

/// Read per-object param values from FxPlug and apply to a path.
/// Add new per-object properties here.
static inline void
KKParamsToPath(id<FxParameterRetrievalAPI_v6> _Nonnull paramGetAPI,
               KKBezierPath *_Nonnull path) {
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
}

/// Write a path's per-object values to FxPlug params and show the rows.
/// Add new per-object properties here.
static inline void
KKPathToParams(id<FxParameterSettingAPI_v5> _Nonnull paramSetAPI,
               KKBezierPath *_Nonnull path) {
  [paramSetAPI setParameterFlags:kFxParameterFlag_DEFAULT
                     toParameter:kParamStrokeWidth];
  [paramSetAPI setParameterFlags:kFxParameterFlag_DEFAULT
                     toParameter:kParamStrokeColor];
  [paramSetAPI setFloatValue:path.strokeWidth
                 toParameter:kParamStrokeWidth
                      atTime:kCMTimeZero];
  [paramSetAPI setRedValue:path.strokeR
                greenValue:path.strokeG
                 blueValue:path.strokeB
               toParameter:kParamStrokeColor
                    atTime:kCMTimeZero];

  [paramSetAPI setParameterFlags:kFxParameterFlag_NOT_ANIMATABLE
                     toParameter:kParamFillEnabled];
  [paramSetAPI setParameterFlags:kFxParameterFlag_DEFAULT
                     toParameter:kParamFillColor];
  [paramSetAPI setBoolValue:path.fillEnabled
                toParameter:kParamFillEnabled
                     atTime:kCMTimeZero];
  [paramSetAPI setRedValue:path.fillR
                greenValue:path.fillG
                 blueValue:path.fillB
               toParameter:kParamFillColor
                    atTime:kCMTimeZero];
}

/// Hide all per-object param rows.
/// Add new per-object properties here.
static inline void
KKHideObjectParams(id<FxParameterSettingAPI_v5> _Nonnull paramSetAPI) {
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamStrokeWidth];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamStrokeColor];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamFillEnabled];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamFillColor];
}
