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
  KKVisStrokeOpen = 1 << 0,    // stroke enabled + expanded
  KKVisFillOpen = 1 << 1,      // fill enabled + expanded
  KKVisSketchOpen = 1 << 2,    // sketch enabled + expanded
  KKVisOpenPath = 1 << 3,      // path is open (not closed)
  KKVisHasJoins = 1 << 4,      // path has >2 points
  KKVisNotImage = 1 << 5,      // not an image layer
  KKVisDashed = 1 << 6,        // strokeStyle == 1
  KKVisDotted = 1 << 7,        // strokeStyle == 2
  KKVisStartMarker = 1 << 8,   // startMarker != 0
  KKVisEndMarker = 1 << 9,     // endMarker != 0
  KKVisFillHasStyle = 1 << 10, // fillStyle > 0
  KKVisIsImage = 1 << 11,      // is an image layer
  KKVisFillSolid = 1 << 12,    // fillStyle == 0 (solid)
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
  // ─── Stroke group children ───
  { kParamStrokeWidth,        KKVisStrokeOpen,                                             kFxParameterFlag_DEFAULT },
  { kParamStrokeColor,        KKVisStrokeOpen,                                             kFxParameterFlag_DEFAULT },
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
  { kParamFillColor,          KKVisFillOpen,                                               kFxParameterFlag_DEFAULT },
  { kParamSketchFillStyle,    KKVisFillOpen,                                               kFxParameterFlag_CUSTOM_UI },
  { kParamSketchFillGap,      KKVisFillOpen | KKVisFillHasStyle,                           kFxParameterFlag_DEFAULT },
  { kParamSketchFillAngle,    KKVisFillOpen | KKVisFillHasStyle,                           kFxParameterFlag_DEFAULT },
  { kParamSketchFillWeight,   KKVisFillOpen | KKVisFillHasStyle,                           kFxParameterFlag_DEFAULT },
  { kParamFillTint,           KKVisFillOpen | KKVisIsImage | KKVisFillSolid,               kFxParameterFlag_DEFAULT },
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
                     BOOL fillOpen, BOOL sketchOpen, uint8_t strokeStyle,
                     int8_t startMarker, int8_t endMarker, int fillStyle) {
  KKVisCondition c = KKVisAlways;
  if (strokeOpen)
    c |= KKVisStrokeOpen;
  if (fillOpen)
    c |= KKVisFillOpen;
  if (sketchOpen)
    c |= KKVisSketchOpen;
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
  KKBezierPath *primary = KKSelectedPath(sel, paths);
  if (!primary)
    return;

  // Snapshot the primary path's values before applying params.
  float oldStrokeWidth = primary.strokeWidth;
  float oldEndWidth = primary.endWidth;
  float oldStrokeR = primary.strokeR;
  float oldStrokeG = primary.strokeG;
  float oldStrokeB = primary.strokeB;
  BOOL oldStrokeEnabled = primary.strokeEnabled;
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

    if (primary.strokeEnabled != oldStrokeEnabled)
      p.strokeEnabled = primary.strokeEnabled;
    if (primary.strokeWidth != oldStrokeWidth)
      p.strokeWidth = primary.strokeWidth;
    if (primary.endWidth != oldEndWidth)
      p.endWidth = primary.endWidth;
    if (strokeColorChanged) {
      p.strokeR = primary.strokeR;
      p.strokeG = primary.strokeG;
      p.strokeB = primary.strokeB;
    }
    if (primary.fillEnabled != oldFillEnabled)
      p.fillEnabled = primary.fillEnabled;
    if (fillColorChanged) {
      p.fillR = primary.fillR;
      p.fillG = primary.fillG;
      p.fillB = primary.fillB;
    }
    if (primary.fillTint != oldFillTint)
      p.fillTint = primary.fillTint;
    if (primary.opacity != oldOpacity)
      p.opacity = primary.opacity;
    if (primary.dashLength != oldDashLength)
      p.dashLength = primary.dashLength;
    if (primary.dashGap != oldDashGap)
      p.dashGap = primary.dashGap;
    if (primary.dotGap != oldDotGap)
      p.dotGap = primary.dotGap;
    if (primary.startMarkerSize != oldStartMarkerSize)
      p.startMarkerSize = primary.startMarkerSize;
    if (primary.endMarkerSize != oldEndMarkerSize)
      p.endMarkerSize = primary.endMarkerSize;
    if (primary.sketchEnabled != oldSketchEnabled)
      p.sketchEnabled = primary.sketchEnabled;
    if (primary.sketchRoughness != oldSketchRoughness)
      p.sketchRoughness = primary.sketchRoughness;
    if (primary.sketchBowing != oldSketchBowing)
      p.sketchBowing = primary.sketchBowing;
    if (primary.sketchStrokes != oldSketchStrokes)
      p.sketchStrokes = primary.sketchStrokes;
    if (primary.sketchFillGap != oldSketchFillGap)
      p.sketchFillGap = primary.sketchFillGap;
    if (primary.sketchFillAngle != oldSketchFillAngle)
      p.sketchFillAngle = primary.sketchFillAngle;
    if (primary.sketchFillWeight != oldSketchFillWeight)
      p.sketchFillWeight = primary.sketchFillWeight;
  }];
}

/// Write a path's per-object values to FxPlug params (values only, no flags).
/// Add new per-object properties here.
static inline void
KKPathToParams(id<FxParameterSettingAPI_v5> _Nonnull paramSetAPI,
               KKBezierPath *_Nonnull path) {
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
