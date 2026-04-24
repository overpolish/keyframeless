/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Foundation/Foundation.h>

static NSString *const kPluginID = @"co.overpolish.keyframeless.Glow";

static const UInt32 kParamPreset = 109;
static const UInt32 kParamInfoUsage = 9000;
static const UInt32 kParamForceShow = 9001;

typedef NS_ENUM(NSInteger, GlowPreset) {
  GlowPresetSoftGlow = 0,
  GlowPresetShadow = 1,
  GlowPresetFire = 2,
};

static const UInt32 kParamRadiusX = 100;
static const UInt32 kParamRadiusY = 101;
static const UInt32 kParamIntensity = 102;
static const UInt32 kParamFalloff = 103;
static const UInt32 kParamNoise = 104;
static const UInt32 kParamNoiseOffset = 105;
static const UInt32 kParamGradientType = 106;
static const UInt32 kParamNoiseSpeed = 108;
static const UInt32 kParamGradientAngle = 107;
static const UInt32 kParamThreshold = 110;

static const UInt32 kParamNoiseGroup = 150;
static const UInt32 kParamNoiseExpanded = 151;

static const UInt32 kParamOffsetGroup = 200;
static const UInt32 kParamOffsetExpanded = 201;
static const UInt32 kParamOffsetX = 210;
static const UInt32 kParamOffsetY = 211;

static const NSInteger kOSCOffsetPart = 1;
static const NSInteger kOSCRadiusPart = 2;
