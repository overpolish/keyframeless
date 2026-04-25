/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Foundation/Foundation.h>

static NSString *const kPluginID = @"co.overpolish.keyframeless.MagicMove";

// Point (1–100)
static const UInt32 kParamPoint = 2;
static const UInt32 kParamRotation = 3;
static const UInt32 kParamScale = 4;
static const UInt32 kParamScaleY = 5;
static const UInt32 kParamOpacity = 6;
static const UInt32 kParamRotationX = 8;
static const UInt32 kParamRotationY = 9;

// Anchor (601)
static const UInt32 kParamAnchorPoint = 601;

// Alerts & Info (9000+)
static const UInt32 kParamForceShowAlerts = 9000;
static const UInt32 kParamInfoCompound = 9001;
static const UInt32 kParamAlertStackSelected = 9004;

// OSC part IDs
static const NSInteger kOSCPositionPart = 1;
static const NSInteger kOSCScaleRingPart = 2;
static const NSInteger kOSCRotPart = 3;
static const NSInteger kOSCRotXRingPart = 4;
static const NSInteger kOSCRotYRingPart = 5;
static const NSInteger kOSCOpacityIconPart = 7;
static const NSInteger kOSCScaleIconPart = 8;
static const NSInteger kOSCAnchorPart = 33;

typedef struct {
  double x, y, rotation, rotationX, rotationY, scaleX, scaleY, opacity;
} MagicMovePointValues;
