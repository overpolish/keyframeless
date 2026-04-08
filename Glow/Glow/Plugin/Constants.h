/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Foundation/Foundation.h>

static NSString *const kPluginID = @"co.overpolish.keyframeless.Glow";

static const UInt32 kParamInfoUsage = 9000;
static const UInt32 kParamForceShow = 9001;

static const UInt32 kParamRadius = 100;
static const UInt32 kParamIntensity = 101;
static const UInt32 kParamFalloff = 102;

static const UInt32 kParamOffset = 103;
static const UInt32 kParamGradientType = 104;
static const UInt32 kParamGradientAngle = 105;

static const UInt32 kParamHoldRadius = 500;
static const UInt32 kParamHoldIntensity = 501;
static const UInt32 kParamHoldFalloff = 502;
static const UInt32 kParamHoldOffset = 503;

// OSC part IDs
static const NSInteger kOSCOffsetPart = 1;
static const NSInteger kOSCRadiusPart = 2;
