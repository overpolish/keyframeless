/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Foundation/Foundation.h>

static NSString *const kPluginID = @"co.overpolish.keyframeless.MagicMove";

// Parameter IDs — Point A
static const UInt32 kParamGroupPointA = 1;
static const UInt32 kParamPointA = 2;
static const UInt32 kParamRotationA = 3;
static const UInt32 kParamScaleA = 4;

// Parameter IDs — Point B
static const UInt32 kParamGroupPointB = 5;
static const UInt32 kParamPointB = 6;
static const UInt32 kParamRotationB = 7;
static const UInt32 kParamScaleB = 8;

// Rotate with Motion
static const UInt32 kParamRotateWithMotion = 10;

// Drift
static const UInt32 kParamGroupDrift = 20;
static const UInt32 kParamDrift = 21;
static const UInt32 kParamDriftPoint = 22;
static const UInt32 kParamDriftRotation = 23;
static const UInt32 kParamDriftScale = 24;

// Info
static const UInt32 kParamInfoCompound = 9000;