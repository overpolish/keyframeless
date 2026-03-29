/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Foundation/Foundation.h>

static NSString *const kPluginID = @"co.overpolish.keyframeless.MagicMove";

// Rotate with Motion
static const UInt32 kParamRotateWithMotion = 10;

// Parameter IDs — Point A
static const UInt32 kParamGroupPointA = 1;
static const UInt32 kParamPointA = 2;
static const UInt32 kParamRotationA = 3;
static const UInt32 kParamScaleA = 4;
static const UInt32 kParamPreviewA = 15;
static const UInt32 kParamOpacityA = 16;
static const UInt32 kParamRotationXA = 50;
static const UInt32 kParamRotationYA = 51;
static const UInt32 kParamScaleYA = 60;

// Parameter IDs — Point B
static const UInt32 kParamGroupPointB = 5;
static const UInt32 kParamPointB = 6;
static const UInt32 kParamRotationB = 7;
static const UInt32 kParamScaleB = 8;
static const UInt32 kParamPreviewB = 9;
static const UInt32 kParamOpacityB = 11;
static const UInt32 kParamRotationXB = 52;
static const UInt32 kParamRotationYB = 53;
static const UInt32 kParamScaleYB = 61;

// Drift
static const UInt32 kParamGroupDrift = 20;
static const UInt32 kParamDrift = 21;
static const UInt32 kParamDriftPoint = 22;
static const UInt32 kParamDriftRotation = 23;
static const UInt32 kParamDriftScale = 24;
static const UInt32 kParamPreviewDrift = 25;
static const UInt32 kParamDriftOpacity = 26;
static const UInt32 kParamDriftRotationX = 54;
static const UInt32 kParamDriftRotationY = 55;
static const UInt32 kParamDriftScaleY = 62;

// Exit
static const UInt32 kParamGroupExit = 30;
static const UInt32 kParamExit = 31;
static const UInt32 kParamExitPoint = 32;
static const UInt32 kParamExitRotation = 33;
static const UInt32 kParamExitScale = 34;
static const UInt32 kParamPreviewExit = 35;
static const UInt32 kParamExitOpacity = 36;
static const UInt32 kParamExitRotationX = 56;
static const UInt32 kParamExitRotationY = 57;
static const UInt32 kParamExitScaleY = 63;

// Path
static const UInt32 kParamPathAB = 40;
static const UInt32 kParamPathBDrift = 41;
static const UInt32 kParamPathDriftExit = 42;
static const UInt32 kParamPathBExit = 43;

// Info
static const UInt32 kParamInfoCompound = 9000;