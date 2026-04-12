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
static const NSInteger kOSCCanvas = 1;          // empty space (captures clicks)
static const NSInteger kOSCToolbarPen = 2;      // pen tool button
static const NSInteger kOSCToolbarRect = 3;     // rect tool button
static const NSInteger kOSCPathPointBase = 100; // 100 + index
static const NSInteger kOSCInHandleBase = 1000; // 1000 + index
static const NSInteger kOSCOutHandleBase = 2000;   // 2000 + index
static const NSInteger kOSCPathSegmentBase = 3000; // 3000 + segment index
static const NSInteger kOSCClosePath =
    4000; // close path by clicking first point
