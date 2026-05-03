/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

@class KKBezierPath;

NS_ASSUME_NONNULL_BEGIN

static NSString *const kPluginID = @"co.overpolish.keyframeless.Canvas";

// Parameter IDs
static const UInt32 kParamPathData = 100;
static const UInt32 kParamStrokeWidth = 101;
static const UInt32 kParamStrokeColor = 102;
static const UInt32 kParamLayerList = 103;
static const UInt32 kParamInstanceID = 104;
static const UInt32 kParamFillEnabled = 105;
static const UInt32 kParamFillColor = 106;
static const UInt32 kParamOpacity = 107;
static const UInt32 kParamLastSelectedIndex = 108;
static const UInt32 kParamLineCap = 109;
static const UInt32 kParamStrokeEnabled = 110;
static const UInt32 kParamLineJoin = 111;
static const UInt32 kParamStrokeStyle = 112;
static const UInt32 kParamDashLength = 113;
static const UInt32 kParamDashGap = 114;
static const UInt32 kParamDotGap = 115;
static const UInt32 kParamClosedPath = 116;
static const UInt32 kParamStartMarker = 117;
static const UInt32 kParamEndMarker = 118;
static const UInt32 kParamStartMarkerSize = 119;
static const UInt32 kParamEndMarkerSize = 120;
static const UInt32 kParamSketchEnabled = 121;
static const UInt32 kParamSketchRoughness = 122;
static const UInt32 kParamSketchBowing = 123;
static const UInt32 kParamSketchStrokes = 124;
static const UInt32 kParamSketchFillStyle = 125;
static const UInt32 kParamSketchFillGap = 126;
static const UInt32 kParamSketchFillAngle = 127;
static const UInt32 kParamSketchFillWeight = 128;
static const UInt32 kParamSketchSeed = 129;
static const UInt32 kParamGroupStroke = 130;
static const UInt32 kParamExpandedStroke = 131;
static const UInt32 kParamGroupFill = 132;
static const UInt32 kParamExpandedFill = 133;
static const UInt32 kParamGroupSketch = 134;
static const UInt32 kParamExpandedSketch = 135;
static const UInt32 kParamEndWidth = 136;
static const UInt32 kParamFillTint = 137;
static const UInt32 kParamStrokeColorMode = 138;
static const UInt32 kParamStrokeGradientType = 139;
static const UInt32 kParamStrokeGradientAngle = 140;
static const UInt32 kParamStrokeGradientData = 141;
static const UInt32 kParamFillColorMode = 142;
static const UInt32 kParamFillGradientType = 143;
static const UInt32 kParamFillGradientAngle = 144;
static const UInt32 kParamFillGradientData = 145;
static const UInt32 kParamStrokeGradientUI = 146;
static const UInt32 kParamFillGradientUI = 147;
static const UInt32 kParamGroupTransform = 148;
static const UInt32 kParamExpandedTransform = 149;
// 150: reserved (was kParamTransformOSCVisible — replaced by per-lane sequencer
// toggle)
static const UInt32 kParamPosition = 151;
static const UInt32 kParamRotation = 152;
static const UInt32 kParamTransformEnabled = 153;
static const UInt32 kParamScaleX = 154;
static const UInt32 kParamScaleY = 155;
static const UInt32 kParamAnchor = 156;
static const UInt32 kParamRotationX = 157;
static const UInt32 kParamRotationY = 158;
static const UInt32 kParamRotateWithMotion = 159;
static const UInt32 kParamDrawOnStart = 160;
static const UInt32 kParamDrawOnEnd = 161;
static const UInt32 kParamMarchingAntsSpeed = 162;
static const UInt32 kParamMarchingAntsOffset = 163;
static const UInt32 kParamDrawOnOrigin = 164;

static const UInt32 kParamForceShow = 9000;
static const UInt32 kParamHideOSC = 9001;
static const UInt32 kParamAutoSelect = 9002;
static const UInt32 kParamGridEnabled = 9003;
static const UInt32 kParamLastTool = 9004;
static const UInt32 kParamGridSpacing = 9005;
static const UInt32 kParamGridAdaptive = 9006;
static const UInt32 kParamSnapToGrid = 9007;

@protocol PROAPIAccessing;
NSString *_Nullable KKLayerUUIDForAPI(id<PROAPIAccessing> _Nonnull api);

void KKCanvasUpdateSelection(NSString *_Nonnull uuid, NSIndexSet *indices);
NSIndexSet *_Nullable KKCanvasConsumePendingSelection(NSString *_Nonnull uuid);
NSIndexSet *_Nullable KKCanvasCurrentSelection(NSString *_Nonnull uuid);
void KKCacheCustomStyles(NSString *_Nonnull uuid, KKBezierPath *_Nonnull path);
void KKApplyCachedStyles(NSString *_Nonnull uuid, KKBezierPath *_Nonnull path);

// OSC part IDs
static const NSInteger kOSCCanvas = 1;
static const NSInteger kOSCToolbarCursor = 2;
static const NSInteger kOSCToolbarPen = 3;
static const NSInteger kOSCToolbarRect = 4;
static const NSInteger kOSCToolbarEllipse = 5;
static const NSInteger kOSCToolbarLine = 11;
static const NSInteger kOSCClosePath = 15;
static const NSInteger kOSCCornerRadiusTL = 6;
static const NSInteger kOSCCornerRadiusTR = 7;
static const NSInteger kOSCCornerRadiusBR = 8;
static const NSInteger kOSCCornerRadiusBL = 9;
static const NSInteger kOSCBoundingBox = 10;
static const NSInteger kOSCRotateHandle = 12;
static const NSInteger kOSCTransformPosition = 13;
static const NSInteger kOSCTransformScaleRing = 14;
static const NSInteger kOSCTransformAnchor = 16;
static const NSInteger kOSCTransformRotZ = 17;
static const NSInteger kOSCTransformRotXRing = 18;
static const NSInteger kOSCTransformRotYRing = 19;

// Position-lane path-editing parts. Encoding mirrors MagicMove's:
// segmentIndex * 1000 + role-offset
//   curve = 50, point[i] = 100+i, in[i] = 200+i, out[i] = 300+i
static const NSInteger kOSCPositionPathBase = 1000000;
static inline NSInteger kkOSCPositionPathCurve(NSInteger seg) {
  return kOSCPositionPathBase + seg * 1000 + 50;
}
static inline NSInteger kkOSCPositionPathPoint(NSInteger seg, NSUInteger i) {
  return kOSCPositionPathBase + seg * 1000 + 100 + (NSInteger)i;
}
static inline NSInteger kkOSCPositionPathInHandle(NSInteger seg, NSUInteger i) {
  return kOSCPositionPathBase + seg * 1000 + 200 + (NSInteger)i;
}
static inline NSInteger kkOSCPositionPathOutHandle(NSInteger seg,
                                                   NSUInteger i) {
  return kOSCPositionPathBase + seg * 1000 + 300 + (NSInteger)i;
}
static inline BOOL kkIsOSCPositionPath(NSInteger part) {
  return part >= kOSCPositionPathBase;
}
static inline NSInteger kkOSCPositionPathSeg(NSInteger part) {
  return (part - kOSCPositionPathBase) / 1000;
}
static inline NSInteger kkOSCPositionPathRole(NSInteger part) {
  return (part - kOSCPositionPathBase) % 1000;
}
// Role-decode predicates: role buckets are curve=50, point=100..199,
// in-handle=200..299, out-handle=300..399. Use these instead of hard-coded
// numeric ranges at call sites.
static inline BOOL kkOSCPositionPathRoleIsCurve(NSInteger role) {
  return role == 50;
}
static inline BOOL kkOSCPositionPathRoleIsPoint(NSInteger role) {
  return role >= 100 && role < 200;
}
static inline BOOL kkOSCPositionPathRoleIsInHandle(NSInteger role) {
  return role >= 200 && role < 300;
}
static inline BOOL kkOSCPositionPathRoleIsOutHandle(NSInteger role) {
  return role >= 300 && role < 400;
}
static inline NSUInteger kkOSCPositionPathRolePointIndex(NSInteger role) {
  if (kkOSCPositionPathRoleIsPoint(role))
    return (NSUInteger)(role - 100);
  if (kkOSCPositionPathRoleIsInHandle(role))
    return (NSUInteger)(role - 200);
  if (kkOSCPositionPathRoleIsOutHandle(role))
    return (NSUInteger)(role - 300);
  return 0;
}
static const NSInteger kOSCResizeHandleBase = 20000; // 20000 + index (0-7)
static const NSInteger kOSCPathPointBase = 10000;    // 10000 + index
static const NSInteger kOSCInHandleBase = 100000;    // 100000 + index
static const NSInteger kOSCOutHandleBase = 200000;   // 200000 + index
static const NSInteger kOSCPathSegmentBase = 300000; // 300000 + segment index

// Grid toolbar
static const NSInteger kOSCGridToggle = 40001;
static const NSInteger kOSCGridMinus = 40002;
static const NSInteger kOSCGridPlus = 40003;
static const NSInteger kOSCGridAdaptive = 40004;
static const NSInteger kOSCGridStepper = 40005;
static const NSInteger kOSCSnapToggle = 40006;

// Path combine toolbar
static const NSInteger kOSCPathUnion = 30001;
static const NSInteger kOSCPathSubtract = 30002;
static const NSInteger kOSCPathIntersect = 30003;
static const NSInteger kOSCPathXOR = 30004;
static const NSInteger kOSCPathOutline = 30005;

NS_ASSUME_NONNULL_END
