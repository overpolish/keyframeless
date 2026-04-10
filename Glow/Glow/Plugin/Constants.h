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

static const UInt32 kParamNoiseGroup = 150;
static const UInt32 kParamNoiseExpanded = 151;

static const UInt32 kParamOffsetGroup = 200;
static const UInt32 kParamOffsetExpanded = 201;
static const UInt32 kParamOffsetX = 210;
static const UInt32 kParamOffsetY = 211;

static const UInt32 kParamHoldRadius = 500;
static const UInt32 kParamHoldIntensity = 501;
static const UInt32 kParamHoldFalloff = 502;
static const UInt32 kParamHoldOffset = 503;
static const UInt32 kParamHoldNoise = 504;
static const UInt32 kParamHoldColor = 505;
static const UInt32 kParamHoldNoiseOffset = 506;

static const UInt32 kParamInRadius = 600;
static const UInt32 kParamInIntensity = 601;
static const UInt32 kParamInFalloff = 602;
static const UInt32 kParamInOffset = 603;
static const UInt32 kParamInNoise = 604;
static const UInt32 kParamInColor = 605;
static const UInt32 kParamInNoiseOffset = 606;

static const UInt32 kParamOutRadius = 700;
static const UInt32 kParamOutIntensity = 701;
static const UInt32 kParamOutFalloff = 702;
static const UInt32 kParamOutOffset = 703;
static const UInt32 kParamOutNoise = 704;
static const UInt32 kParamOutColor = 705;
static const UInt32 kParamOutNoiseOffset = 706;

static const UInt32 kParamTimingInColor = 800;
static const UInt32 kParamTimingHoldColor = 801;
static const UInt32 kParamTimingOutColor = 802;
static const UInt32 kParamTimingInGradient = 803;
static const UInt32 kParamTimingHoldGradient = 804;
static const UInt32 kParamTimingOutGradient = 805;

static const NSInteger kOSCOffsetPart = 1;
static const NSInteger kOSCRadiusPart = 2;
