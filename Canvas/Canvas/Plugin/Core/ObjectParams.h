/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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

/// Transform-aware primary: prefers a non-group, falls back to the first
/// selected group. Used wherever the inspector's transform params (Position,
/// later rotation/scale) need a target — groups support transform but not
/// stroke/fill/sketch, so non-group selections still take priority.
static inline KKBezierPath *_Nullable KKSelectedTransformTarget(
    NSIndexSet *_Nullable sel, NSArray<KKBezierPath *> *_Nonnull paths) {
  KKBezierPath *p = KKSelectedPath(sel, paths);
  if (p)
    return p;
  __block KKBezierPath *group = nil;
  [sel enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
    if (idx < paths.count && paths[idx].isGroup) {
      group = paths[idx];
      *stop = YES;
    }
  }];
  return group;
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

// --- Parameter visibility matrix ---
// Each parameter declares the conditions required for it to be visible.
// A single loop evaluates all of them — no scattered if/else chains.

typedef NS_OPTIONS(uint32_t, KKVisCondition) {
  KKVisAlways = 0,
  KKVisStrokeOpen = 1 << 0,            // stroke enabled + expanded
  KKVisFillOpen = 1 << 1,              // fill enabled + expanded
  KKVisSketchOpen = 1 << 2,            // sketch enabled + expanded
  KKVisOpenPath = 1 << 3,              // path is open (not closed)
  KKVisHasJoins = 1 << 4,              // path has >2 points
  KKVisNotImage = 1 << 5,              // not an image layer
  KKVisDashed = 1 << 6,                // strokeStyle == 1
  KKVisDotted = 1 << 7,                // strokeStyle == 2
  KKVisStartMarker = 1 << 8,           // startMarker != 0
  KKVisEndMarker = 1 << 9,             // endMarker != 0
  KKVisFillHasStyle = 1 << 10,         // fillStyle > 0
  KKVisIsImage = 1 << 11,              // is an image layer
  KKVisFillSolid = 1 << 12,            // fillStyle == 0 (solid)
  KKVisStrokeColorSolid = 1 << 13,     // strokeColorMode == 0
  KKVisStrokeColorGradient = 1 << 14,  // strokeColorMode == 1
  KKVisFillColorSolid = 1 << 15,       // fillColorMode == 0
  KKVisFillColorGradient = 1 << 16,    // fillColorMode == 1
  KKVisStrokeGradientLinear = 1 << 17, // strokeGradientType == 1 (linear)
  KKVisFillGradientLinear = 1 << 18,   // fillGradientType == 1 (linear)
  KKVisTransformOpen = 1 << 19,        // transform enabled + expanded
};

typedef struct {
  UInt32 paramID;
  KKVisCondition required;
  FxParameterFlags visibleFlags;
} KKParamVisRule;

// clang-format off
static const KKParamVisRule kParamVisibility[] = {
  // Param                    Required conditions                                          Flags when visible
  // ─── Always ───
  { kParamOpacity,            KKVisAlways,                                                 kFxParameterFlag_DEFAULT },
  { kParamClosedPath,         KKVisNotImage,                                               kFxParameterFlag_NOT_ANIMATABLE },
  // ─── Transform group children ───
  // (kParamTransformEnabled is rendered by the group header — keep it HIDDEN.)
  { kParamPosition,           KKVisTransformOpen,                                          kFxParameterFlag_DEFAULT },
  { kParamScaleX,             KKVisTransformOpen,                                          kFxParameterFlag_DEFAULT },
  { kParamScaleY,             KKVisTransformOpen,                                          kFxParameterFlag_DEFAULT },
  { kParamAnchor,             KKVisTransformOpen,                                          kFxParameterFlag_DEFAULT },
  { kParamRotation,           KKVisTransformOpen,                                          kFxParameterFlag_DEFAULT },
  // ─── Stroke group children ───
  { kParamStrokeWidth,        KKVisStrokeOpen,                                             kFxParameterFlag_DEFAULT },
  { kParamStrokeColorMode,    KKVisStrokeOpen,                                             kFxParameterFlag_NOT_ANIMATABLE },
  { kParamStrokeColor,        KKVisStrokeOpen | KKVisStrokeColorSolid,                     kFxParameterFlag_DEFAULT },
  { kParamStrokeGradientType, KKVisStrokeOpen | KKVisStrokeColorGradient,                  kFxParameterFlag_NOT_ANIMATABLE },
  { kParamStrokeGradientAngle,KKVisStrokeOpen | KKVisStrokeColorGradient | KKVisStrokeGradientLinear, kFxParameterFlag_DEFAULT },
  { kParamStrokeGradientUI,   KKVisStrokeOpen | KKVisStrokeColorGradient,                  kFxParameterFlag_CUSTOM_UI },
  { kParamEndWidth,           KKVisStrokeOpen | KKVisOpenPath,                             kFxParameterFlag_DEFAULT },
  { kParamLineCap,            KKVisStrokeOpen | KKVisOpenPath,                             kFxParameterFlag_CUSTOM_UI },
  { kParamLineJoin,           KKVisStrokeOpen | KKVisHasJoins,                             kFxParameterFlag_CUSTOM_UI },
  { kParamStrokeStyle,        KKVisStrokeOpen | KKVisNotImage,                             kFxParameterFlag_CUSTOM_UI },
  { kParamDashLength,         KKVisStrokeOpen | KKVisNotImage | KKVisDashed,               kFxParameterFlag_DEFAULT },
  { kParamDashGap,            KKVisStrokeOpen | KKVisNotImage | KKVisDashed,               kFxParameterFlag_DEFAULT },
  { kParamDotGap,             KKVisStrokeOpen | KKVisNotImage | KKVisDotted,               kFxParameterFlag_DEFAULT },
  { kParamStartMarker,        KKVisStrokeOpen | KKVisOpenPath,                             kFxParameterFlag_CUSTOM_UI },
  { kParamEndMarker,          KKVisStrokeOpen | KKVisOpenPath,                             kFxParameterFlag_CUSTOM_UI },
  { kParamStartMarkerSize,    KKVisStrokeOpen | KKVisOpenPath | KKVisStartMarker,          kFxParameterFlag_DEFAULT },
  { kParamEndMarkerSize,      KKVisStrokeOpen | KKVisOpenPath | KKVisEndMarker,            kFxParameterFlag_DEFAULT },
  // ─── Fill group children ───
  { kParamFillColorMode,      KKVisFillOpen,                                               kFxParameterFlag_NOT_ANIMATABLE },
  { kParamFillColor,          KKVisFillOpen | KKVisFillColorSolid,                         kFxParameterFlag_DEFAULT },
  { kParamFillGradientType,   KKVisFillOpen | KKVisFillColorGradient,                      kFxParameterFlag_NOT_ANIMATABLE },
  { kParamFillGradientAngle,  KKVisFillOpen | KKVisFillColorGradient | KKVisFillGradientLinear, kFxParameterFlag_DEFAULT },
  { kParamFillGradientUI,     KKVisFillOpen | KKVisFillColorGradient,                      kFxParameterFlag_CUSTOM_UI },
  { kParamSketchFillStyle,    KKVisFillOpen,                                               kFxParameterFlag_CUSTOM_UI },
  { kParamSketchFillGap,      KKVisFillOpen | KKVisFillHasStyle,                           kFxParameterFlag_DEFAULT },
  { kParamSketchFillAngle,    KKVisFillOpen | KKVisFillHasStyle,                           kFxParameterFlag_DEFAULT },
  { kParamSketchFillWeight,   KKVisFillOpen | KKVisFillHasStyle,                           kFxParameterFlag_DEFAULT },
  { kParamFillTint,           KKVisFillOpen | KKVisIsImage | KKVisFillSolid, kFxParameterFlag_DEFAULT },
  // ─── Sketch group children ───
  { kParamSketchRoughness,    KKVisSketchOpen | KKVisNotImage,                             kFxParameterFlag_DEFAULT },
  { kParamSketchBowing,       KKVisSketchOpen | KKVisNotImage,                             kFxParameterFlag_DEFAULT },
  { kParamSketchStrokes,      KKVisSketchOpen | KKVisNotImage,                             kFxParameterFlag_DEFAULT },
  { kParamSketchSeed,         KKVisSketchOpen | KKVisNotImage,                             kFxParameterFlag_CUSTOM_UI },
};
// clang-format on

static const size_t kParamVisibilityCount =
    sizeof(kParamVisibility) / sizeof(kParamVisibility[0]);

/// Build the active-condition bitmask from the current selection state.
static inline KKVisCondition
KKBuildVisConditions(BOOL isImage, BOOL isOpen, BOOL hasJoins, BOOL strokeOpen,
                     BOOL fillOpen, BOOL sketchOpen, BOOL transformOpen,
                     uint8_t strokeStyle, int8_t startMarker, int8_t endMarker,
                     int fillStyle, uint8_t strokeColorMode,
                     uint8_t fillColorMode, uint8_t strokeGradientType,
                     uint8_t fillGradientType) {
  KKVisCondition c = KKVisAlways;
  if (strokeOpen)
    c |= KKVisStrokeOpen;
  if (fillOpen)
    c |= KKVisFillOpen;
  if (sketchOpen)
    c |= KKVisSketchOpen;
  if (transformOpen)
    c |= KKVisTransformOpen;
  if (isOpen)
    c |= KKVisOpenPath;
  if (hasJoins)
    c |= KKVisHasJoins;
  if (!isImage)
    c |= KKVisNotImage;
  if (isImage)
    c |= KKVisIsImage;
  if (strokeStyle == 1)
    c |= KKVisDashed;
  if (strokeStyle == 2)
    c |= KKVisDotted;
  if (startMarker > 0)
    c |= KKVisStartMarker;
  if (endMarker > 0)
    c |= KKVisEndMarker;
  if (fillStyle > 0)
    c |= KKVisFillHasStyle;
  if (fillStyle == 0)
    c |= KKVisFillSolid;
  if (strokeColorMode == 0)
    c |= KKVisStrokeColorSolid;
  else
    c |= KKVisStrokeColorGradient;
  if (fillColorMode == 0)
    c |= KKVisFillColorSolid;
  else
    c |= KKVisFillColorGradient;
  if (strokeGradientType == 1)
    c |= KKVisStrokeGradientLinear;
  if (fillGradientType == 1)
    c |= KKVisFillGradientLinear;
  return c;
}

/// Evaluate the visibility table and set all parameter flags in one pass.
/// When forceShow is YES, every parameter is made visible.
static inline void
KKApplyParamVisibility(id<FxParameterSettingAPI_v5> _Nonnull setAPI,
                       KKVisCondition active, BOOL forceShow) {
  // Group headers are always visible (interactivity is handled separately).
  FxParameterFlags groupFlags = kFxParameterFlag_CUSTOM_UI |
                                kFxParameterFlag_NOT_ANIMATABLE |
                                kFxParameterFlag_USE_FULL_VIEW_WIDTH;
  [setAPI setParameterFlags:groupFlags toParameter:kParamGroupTransform];
  [setAPI setParameterFlags:groupFlags toParameter:kParamGroupStroke];
  [setAPI setParameterFlags:groupFlags toParameter:kParamGroupFill];
  [setAPI setParameterFlags:groupFlags toParameter:kParamGroupSketch];

  for (size_t i = 0; i < kParamVisibilityCount; i++) {
    KKVisCondition req = kParamVisibility[i].required;
    BOOL visible = forceShow || ((active & req) == req);
    FxParameterFlags flags =
        visible ? kParamVisibility[i].visibleFlags : kFxParameterFlag_HIDDEN;
    [setAPI setParameterFlags:flags toParameter:kParamVisibility[i].paramID];
  }
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

/// Read the four gradient sub-params (mode/type/angle/data) for one side
/// (stroke or fill) and apply them to the path's matching properties.
static inline void
KKReadGradientParamsToPath(id<FxParameterRetrievalAPI_v6> _Nonnull api,
                           KKBezierPath *_Nonnull path, BOOL isStroke,
                           UInt32 modeID, UInt32 typeID, UInt32 angleID,
                           UInt32 dataID) {
  int mode = 0;
  [api getIntValue:&mode fromParameter:modeID atTime:kCMTimeZero];
  int type = 1;
  [api getIntValue:&type fromParameter:typeID atTime:kCMTimeZero];
  double angle = 0.0;
  [api getFloatValue:&angle fromParameter:angleID atTime:kCMTimeZero];
  NSString *json = nil;
  [api getStringParameterValue:&json fromParameter:dataID];
  if (isStroke) {
    path.strokeColorMode = (uint8_t)mode;
    path.strokeGradientType = (uint8_t)type;
    path.strokeGradientAngle = (float)angle;
    path.strokeGradientJSON = json;
  } else {
    path.fillColorMode = (uint8_t)mode;
    path.fillGradientType = (uint8_t)type;
    path.fillGradientAngle = (float)angle;
    path.fillGradientJSON = json;
  }
}

/// Inverse of `KKReadGradientParamsToPath` — write one side's gradient
/// properties out to FxPlug params.
static inline void
KKWriteGradientParamsFromPath(id<FxParameterSettingAPI_v5> _Nonnull api,
                              KKBezierPath *_Nonnull path, BOOL isStroke,
                              UInt32 modeID, UInt32 typeID, UInt32 angleID,
                              UInt32 dataID) {
  uint8_t mode = isStroke ? path.strokeColorMode : path.fillColorMode;
  uint8_t type = isStroke ? path.strokeGradientType : path.fillGradientType;
  float angle = isStroke ? path.strokeGradientAngle : path.fillGradientAngle;
  NSString *json = isStroke ? path.strokeGradientJSON : path.fillGradientJSON;
  [api setIntValue:(int)mode toParameter:modeID atTime:kCMTimeZero];
  [api setIntValue:(int)type toParameter:typeID atTime:kCMTimeZero];
  [api setFloatValue:angle toParameter:angleID atTime:kCMTimeZero];
  [api setStringParameterValue:(json ?: @"") toParameter:dataID];
}

/// Read the transformEnabled / position / scale / anchor params and apply
/// to `path`. Shared by both the group-only path and the full per-object
/// reader so the two can't drift.
static inline void
KKReadTransformParamsToPath(id<FxParameterRetrievalAPI_v6> _Nonnull paramGetAPI,
                            KKBezierPath *_Nonnull path) {
  BOOL txEn = YES;
  [paramGetAPI getBoolValue:&txEn
              fromParameter:kParamTransformEnabled
                     atTime:kCMTimeZero];
  path.transformEnabled = txEn;
  double px = 0.5, py = 0.5;
  [paramGetAPI getXValue:&px
                  YValue:&py
           fromParameter:kParamPosition
                  atTime:kCMTimeZero];
  path.translateX = (float)(px - 0.5);
  path.translateY = (float)(py - 0.5);
  double sx = 1.0, sy = 1.0;
  [paramGetAPI getFloatValue:&sx fromParameter:kParamScaleX atTime:kCMTimeZero];
  [paramGetAPI getFloatValue:&sy fromParameter:kParamScaleY atTime:kCMTimeZero];
  path.scaleX = (float)sx;
  path.scaleY = (float)sy;
  double ax = 0.0, ay = 0.0;
  [paramGetAPI getXValue:&ax
                  YValue:&ay
           fromParameter:kParamAnchor
                  atTime:kCMTimeZero];
  path.anchorX = (float)ax;
  path.anchorY = (float)ay;
  double rz = 0.0;
  [paramGetAPI getFloatValue:&rz
               fromParameter:kParamRotation
                      atTime:kCMTimeZero];
  path.rotationZ = (float)rz;
}

/// Mirror of KKReadTransformParamsToPath.
static inline void KKWriteTransformParamsFromPath(
    id<FxParameterSettingAPI_v5> _Nonnull paramSetAPI,
    KKBezierPath *_Nonnull path) {
  [paramSetAPI setBoolValue:path.transformEnabled
                toParameter:kParamTransformEnabled
                     atTime:kCMTimeZero];
  [paramSetAPI setXValue:0.5 + path.translateX
                  YValue:0.5 + path.translateY
             toParameter:kParamPosition
                  atTime:kCMTimeZero];
  [paramSetAPI setFloatValue:path.scaleX
                 toParameter:kParamScaleX
                      atTime:kCMTimeZero];
  [paramSetAPI setFloatValue:path.scaleY
                 toParameter:kParamScaleY
                      atTime:kCMTimeZero];
  [paramSetAPI setXValue:path.anchorX
                  YValue:path.anchorY
             toParameter:kParamAnchor
                  atTime:kCMTimeZero];
  [paramSetAPI setFloatValue:path.rotationZ
                 toParameter:kParamRotation
                      atTime:kCMTimeZero];
}

/// Read the transform-only subset of params (the only fields a group owns).
static inline void
KKReadGroupTransformParams(id<FxParameterRetrievalAPI_v6> _Nonnull paramGetAPI,
                           KKBezierPath *_Nonnull path) {
  KKReadTransformParamsToPath(paramGetAPI, path);
}

/// Mirror of KKReadGroupTransformParams.
static inline void
KKWriteGroupTransformParams(id<FxParameterSettingAPI_v5> _Nonnull paramSetAPI,
                            KKBezierPath *_Nonnull path) {
  KKWriteTransformParamsFromPath(paramSetAPI, path);
}

/// Read per-object param values from FxPlug and apply to a path.
/// Add new per-object properties here.
static inline void
KKParamsToPath(id<FxParameterRetrievalAPI_v6> _Nonnull paramGetAPI,
               KKBezierPath *_Nonnull path) {
  if (path.isGroup) {
    // Groups carry only transform-related state; reading stroke/fill/sketch
    // params would clobber unused fields with whatever the inspector last
    // showed for a non-group selection.
    KKReadGroupTransformParams(paramGetAPI, path);
    return;
  }
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
  double ew = 8.0;
  [paramGetAPI getFloatValue:&ew
               fromParameter:kParamEndWidth
                      atTime:kCMTimeZero];
  path.strokeWidth = (float)w;
  path.endWidth = (float)ew;
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

  double ft = 100.0;
  [paramGetAPI getFloatValue:&ft
               fromParameter:kParamFillTint
                      atTime:kCMTimeZero];
  path.fillTint = (float)(ft / 100.0);

  double op = 100.0;
  [paramGetAPI getFloatValue:&op
               fromParameter:kParamOpacity
                      atTime:kCMTimeZero];
  path.opacity = (float)(op / 100.0);

  KKReadTransformParamsToPath(paramGetAPI, path);

  KKReadGradientParamsToPath(
      paramGetAPI, path, YES, kParamStrokeColorMode, kParamStrokeGradientType,
      kParamStrokeGradientAngle, kParamStrokeGradientData);
  KKReadGradientParamsToPath(paramGetAPI, path, NO, kParamFillColorMode,
                             kParamFillGradientType, kParamFillGradientAngle,
                             kParamFillGradientData);

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

  double sms = 3.0;
  [paramGetAPI getFloatValue:&sms
               fromParameter:kParamStartMarkerSize
                      atTime:kCMTimeZero];
  path.startMarkerSize = (float)sms;

  double ems = 3.0;
  [paramGetAPI getFloatValue:&ems
               fromParameter:kParamEndMarkerSize
                      atTime:kCMTimeZero];
  path.endMarkerSize = (float)ems;

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

  int sStrokes = kSketchStrokesDefault;
  [paramGetAPI getIntValue:&sStrokes
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

/// Modify a property of all selected paths inside an action scope.
/// The block receives each selected non-group path for mutation.
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
  if (str.length > 0) {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
    NSMutableArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
    NSString *uuid = KKLayerUUIDForAPI(api);
    NSIndexSet *sel = uuid ? KKCanvasCurrentSelection(uuid) : nil;
    BOOL modified = NO;
    if (sel.count > 0) {
      [sel enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx < paths.count && !paths[idx].isGroup)
          block(paths[idx]);
      }];
      modified = YES;
    } else {
      NSInteger selIdx = KKReadSelectedIndex(getAPI);
      if (selIdx >= 0 && (NSUInteger)selIdx < paths.count) {
        block(paths[selIdx]);
        modified = YES;
      }
    }
    if (modified) {
      NSData *newBlob = [KKBezierPath blobFromPaths:paths];
      [setAPI setStringParameterValue:[newBlob base64EncodedStringWithOptions:0]
                          toParameter:kParamPathData];
    }
  }
  [actAPI endAction:api];
}

/// Read per-object param values from FxPlug and apply to all selected
/// (non-group) paths.  Only properties that actually changed relative to
/// the primary path's pre-existing values are cascaded to the other paths,
/// so unchanged properties (e.g. fill colour) are preserved per-object.
static inline void
KKParamsToSelectedPaths(id<FxParameterRetrievalAPI_v6> _Nonnull paramGetAPI,
                        NSIndexSet *_Nullable sel,
                        NSMutableArray<KKBezierPath *> *_Nonnull paths) {
  KKBezierPath *primary = KKSelectedTransformTarget(sel, paths);
  if (!primary)
    return;

  // Snapshot the primary path's values before applying params.
  float oldStrokeWidth = primary.strokeWidth;
  float oldEndWidth = primary.endWidth;
  float oldStrokeR = primary.strokeR;
  float oldStrokeG = primary.strokeG;
  float oldStrokeB = primary.strokeB;
  BOOL oldStrokeEnabled = primary.strokeEnabled;
  BOOL oldTransformEnabled = primary.transformEnabled;
  float oldTranslateX = primary.translateX;
  float oldTranslateY = primary.translateY;
  float oldScaleX = primary.scaleX;
  float oldScaleY = primary.scaleY;
  float oldAnchorX = primary.anchorX;
  float oldAnchorY = primary.anchorY;
  float oldRotationZ = primary.rotationZ;
  BOOL oldFillEnabled = primary.fillEnabled;
  float oldFillR = primary.fillR;
  float oldFillG = primary.fillG;
  float oldFillB = primary.fillB;
  float oldFillTint = primary.fillTint;
  float oldOpacity = primary.opacity;
  float oldDashLength = primary.dashLength;
  float oldDashGap = primary.dashGap;
  float oldDotGap = primary.dotGap;
  float oldStartMarkerSize = primary.startMarkerSize;
  float oldEndMarkerSize = primary.endMarkerSize;
  BOOL oldSketchEnabled = primary.sketchEnabled;
  float oldSketchRoughness = primary.sketchRoughness;
  float oldSketchBowing = primary.sketchBowing;
  uint8_t oldSketchStrokes = primary.sketchStrokes;
  float oldSketchFillGap = primary.sketchFillGap;
  float oldSketchFillAngle = primary.sketchFillAngle;
  float oldSketchFillWeight = primary.sketchFillWeight;
  uint8_t oldStrokeColorMode = primary.strokeColorMode;
  uint8_t oldStrokeGradientType = primary.strokeGradientType;
  float oldStrokeGradientAngle = primary.strokeGradientAngle;
  NSString *oldStrokeGradientJSON = primary.strokeGradientJSON;
  uint8_t oldFillColorMode = primary.fillColorMode;
  uint8_t oldFillGradientType = primary.fillGradientType;
  float oldFillGradientAngle = primary.fillGradientAngle;
  NSString *oldFillGradientJSON = primary.fillGradientJSON;

  // Apply all inspector params to the primary path.
  KKParamsToPath(paramGetAPI, primary);

  // Single selection — nothing else to cascade.
  if (!sel || sel.count <= 1)
    return;

  // Detect which colour groups changed (treat RGB as atomic).
  BOOL strokeColorChanged =
      (primary.strokeR != oldStrokeR || primary.strokeG != oldStrokeG ||
       primary.strokeB != oldStrokeB);
  BOOL fillColorChanged =
      (primary.fillR != oldFillR || primary.fillG != oldFillG ||
       primary.fillB != oldFillB);

  // Apply only the delta to every other selected non-group path.
  [sel enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
    if (idx >= paths.count || paths[idx].isGroup)
      return;
    KKBezierPath *p = paths[idx];
    if (p == primary)
      return;

#define KK_COPY_IF_CHANGED(field, snap)                                        \
  do {                                                                         \
    if (primary.field != snap)                                                 \
      p.field = primary.field;                                                 \
  } while (0)
    KK_COPY_IF_CHANGED(strokeEnabled, oldStrokeEnabled);
    KK_COPY_IF_CHANGED(transformEnabled, oldTransformEnabled);
    KK_COPY_IF_CHANGED(translateX, oldTranslateX);
    KK_COPY_IF_CHANGED(translateY, oldTranslateY);
    KK_COPY_IF_CHANGED(scaleX, oldScaleX);
    KK_COPY_IF_CHANGED(scaleY, oldScaleY);
    KK_COPY_IF_CHANGED(anchorX, oldAnchorX);
    KK_COPY_IF_CHANGED(anchorY, oldAnchorY);
    KK_COPY_IF_CHANGED(rotationZ, oldRotationZ);
    KK_COPY_IF_CHANGED(strokeWidth, oldStrokeWidth);
    KK_COPY_IF_CHANGED(endWidth, oldEndWidth);
    if (strokeColorChanged) {
      p.strokeR = primary.strokeR;
      p.strokeG = primary.strokeG;
      p.strokeB = primary.strokeB;
    }
    KK_COPY_IF_CHANGED(fillEnabled, oldFillEnabled);
    if (fillColorChanged) {
      p.fillR = primary.fillR;
      p.fillG = primary.fillG;
      p.fillB = primary.fillB;
    }
    KK_COPY_IF_CHANGED(fillTint, oldFillTint);
    KK_COPY_IF_CHANGED(opacity, oldOpacity);
    KK_COPY_IF_CHANGED(dashLength, oldDashLength);
    KK_COPY_IF_CHANGED(dashGap, oldDashGap);
    KK_COPY_IF_CHANGED(dotGap, oldDotGap);
    KK_COPY_IF_CHANGED(startMarkerSize, oldStartMarkerSize);
    KK_COPY_IF_CHANGED(endMarkerSize, oldEndMarkerSize);
    KK_COPY_IF_CHANGED(sketchEnabled, oldSketchEnabled);
    KK_COPY_IF_CHANGED(sketchRoughness, oldSketchRoughness);
    KK_COPY_IF_CHANGED(sketchBowing, oldSketchBowing);
    KK_COPY_IF_CHANGED(sketchStrokes, oldSketchStrokes);
    KK_COPY_IF_CHANGED(sketchFillGap, oldSketchFillGap);
    KK_COPY_IF_CHANGED(sketchFillAngle, oldSketchFillAngle);
    KK_COPY_IF_CHANGED(sketchFillWeight, oldSketchFillWeight);
    KK_COPY_IF_CHANGED(strokeColorMode, oldStrokeColorMode);
    KK_COPY_IF_CHANGED(strokeGradientType, oldStrokeGradientType);
    KK_COPY_IF_CHANGED(strokeGradientAngle, oldStrokeGradientAngle);
    if (![primary.strokeGradientJSON isEqualToString:oldStrokeGradientJSON] &&
        !(primary.strokeGradientJSON == nil && oldStrokeGradientJSON == nil))
      p.strokeGradientJSON = primary.strokeGradientJSON;
    KK_COPY_IF_CHANGED(fillColorMode, oldFillColorMode);
    KK_COPY_IF_CHANGED(fillGradientType, oldFillGradientType);
    KK_COPY_IF_CHANGED(fillGradientAngle, oldFillGradientAngle);
    if (![primary.fillGradientJSON isEqualToString:oldFillGradientJSON] &&
        !(primary.fillGradientJSON == nil && oldFillGradientJSON == nil))
      p.fillGradientJSON = primary.fillGradientJSON;
#undef KK_COPY_IF_CHANGED
  }];
}

/// Write a path's per-object values to FxPlug params (values only, no flags).
/// Add new per-object properties here.
static inline void
KKPathToParams(id<FxParameterSettingAPI_v5> _Nonnull paramSetAPI,
               KKBezierPath *_Nonnull path) {
  if (path.isGroup) {
    // Groups own only transform state — leave stroke/fill/sketch params at
    // whatever the previous selection set them to, so visibility cascades
    // and snapshot defaults stay coherent.
    KKWriteGroupTransformParams(paramSetAPI, path);
    return;
  }
  [paramSetAPI setBoolValue:path.strokeEnabled
                toParameter:kParamStrokeEnabled
                     atTime:kCMTimeZero];
  [paramSetAPI setFloatValue:path.strokeWidth
                 toParameter:kParamStrokeWidth
                      atTime:kCMTimeZero];
  [paramSetAPI
      setFloatValue:(path.endWidth > 0 ? path.endWidth : path.strokeWidth)
        toParameter:kParamEndWidth
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
  [paramSetAPI setFloatValue:path.fillTint * 100.0f
                 toParameter:kParamFillTint
                      atTime:kCMTimeZero];
  [paramSetAPI setFloatValue:path.opacity * 100.0f
                 toParameter:kParamOpacity
                      atTime:kCMTimeZero];
  KKWriteTransformParamsFromPath(paramSetAPI, path);
  KKWriteGradientParamsFromPath(
      paramSetAPI, path, YES, kParamStrokeColorMode, kParamStrokeGradientType,
      kParamStrokeGradientAngle, kParamStrokeGradientData);
  KKWriteGradientParamsFromPath(paramSetAPI, path, NO, kParamFillColorMode,
                                kParamFillGradientType, kParamFillGradientAngle,
                                kParamFillGradientData);
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
  [paramSetAPI setIntValue:(int)path.sketchStrokes
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
  [paramSetAPI setFloatValue:path.startMarkerSize
                 toParameter:kParamStartMarkerSize
                      atTime:kCMTimeZero];
  [paramSetAPI setFloatValue:path.endMarkerSize
                 toParameter:kParamEndMarkerSize
                      atTime:kCMTimeZero];
}
