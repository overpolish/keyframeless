/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Foundation/Foundation.h>

static NSString *const kPluginID = @"co.overpolish.keyframeless.Canvas";

// Parameter IDs
static const UInt32 kParamPathData = 100;
static const UInt32 kParamStrokeWidth = 101;
static const UInt32 kParamStrokeColor = 102;

// OSC part IDs
static const NSInteger kOSCCanvas = 1;
static const NSInteger kOSCToolbarCursor = 2;
static const NSInteger kOSCToolbarPen = 3;
static const NSInteger kOSCToolbarRect = 4;
static const NSInteger kOSCToolbarEllipse = 5;
static const NSInteger kOSCClosePath = 15;
static const NSInteger kOSCCornerRadiusTL = 6;
static const NSInteger kOSCCornerRadiusTR = 7;
static const NSInteger kOSCCornerRadiusBR = 8;
static const NSInteger kOSCCornerRadiusBL = 9;
static const NSInteger kOSCBoundingBox = 10;
static const NSInteger kOSCResizeHandleBase = 20000; // 20000 + index (0-7)
static const NSInteger kOSCPathPointBase = 10000;    // 10000 + index
static const NSInteger kOSCInHandleBase = 100000;    // 100000 + index
static const NSInteger kOSCOutHandleBase = 200000;   // 200000 + index
static const NSInteger kOSCPathSegmentBase = 300000; // 300000 + segment index
