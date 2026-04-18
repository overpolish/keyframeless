/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
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

static const UInt32 kParamForceShow = 9000;
static const UInt32 kParamHideOSC = 9001;
static const UInt32 kParamAutoSelect = 9002;

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
static const NSInteger kOSCResizeHandleBase = 20000; // 20000 + index (0-7)
static const NSInteger kOSCPathPointBase = 10000;    // 10000 + index
static const NSInteger kOSCInHandleBase = 100000;    // 100000 + index
static const NSInteger kOSCOutHandleBase = 200000;   // 200000 + index
static const NSInteger kOSCPathSegmentBase = 300000; // 300000 + segment index

NS_ASSUME_NONNULL_END
