/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Foundation/Foundation.h>

/// Parameter ID reserved ranges shared across all plugins.
///
/// 1 – 8999   real (animatable) plugin parameters
/// 9000–9899  decorative UI parameters (info labels, separators)
/// 9900–9998  animation system parameters (added by KKPlugin)

static const UInt32 kKKParamAnimationSeparator __attribute__((unused)) = 9900;
static const UInt32 kKKParamAnimateIn __attribute__((unused)) = 9901;
static const UInt32 kKKParamAnimateOut __attribute__((unused)) = 9902;
static const UInt32 kKKParamAnimateInDuration __attribute__((unused)) = 9903;
static const UInt32 kKKParamAnimateInInterpolation __attribute__((unused)) =
    9904;
static const UInt32 kKKParamTimingCurvePreview __attribute__((unused)) = 9905;
static const UInt32 kKKParamAnimateOutDuration __attribute__((unused)) = 9906;
static const UInt32 kKKParamAnimateOutInterpolation __attribute__((unused)) =
    9907;
static const UInt32 kKKParamTimingExpanded __attribute__((unused)) = 9908;
static const UInt32 kKKParamTimingSelectedSection __attribute__((unused)) =
    9909;
static const UInt32 kKKParamHoldEffect __attribute__((unused)) = 9910;
static const UInt32 kKKParamAnimateInIntensity __attribute__((unused)) = 9911;
static const UInt32 kKKParamAnimateOutIntensity __attribute__((unused)) = 9912;
static const UInt32 kKKParamHoldIntensity __attribute__((unused)) = 9913;
static const UInt32 kKKParamAnimateInFrequency __attribute__((unused)) = 9914;
static const UInt32 kKKParamAnimateOutFrequency __attribute__((unused)) = 9915;
static const UInt32 kKKParamHoldFrequency __attribute__((unused)) = 9916;
static const UInt32 kKKParamHoldSeed __attribute__((unused)) = 9917;

/// Multi-stage timing parameters (9918–9921)
static const UInt32 kKKParamMultiStageEnabled __attribute__((unused)) = 9918;
static const UInt32 kKKParamMultiStageData __attribute__((unused)) = 9919;
static const UInt32 kKKParamMultiStageSelectedProperty __attribute__((unused)) =
    9920;
static const UInt32 kKKParamMultiStageSelectedStage __attribute__((unused)) =
    9921;

/// Hidden per-instance UUID — keys the static per-instance state map so
/// multiple copies of a plugin on the same timeline don't share state.
static const UInt32 kKKParamInstanceID __attribute__((unused)) = 9922;

/// Persisted toggle for sequencer loop-playback. The actual render-path loop
/// check reads the mirror in KKPluginInstanceState.loopEnabled (populated
/// from this param on apply-state ticks) to avoid touching FxParameter APIs
/// from inside the render callback.
static const UInt32 kKKParamTimingLoopEnabled __attribute__((unused)) = 9923;

/// Motion blur parameters (9924–9930). Registered by
/// `addMotionBlurParametersWithAPI:` as a custom group with an Enabled
/// checkbox; shutter/quality reveal when enabled.
static const UInt32 kKKParamMotionBlurSeparator __attribute__((unused)) = 9924;
static const UInt32 kKKParamMotionBlurEnabled __attribute__((unused)) = 9925;
static const UInt32 kKKParamMotionBlurShutter __attribute__((unused)) = 9926;
static const UInt32 kKKParamMotionBlurQuality __attribute__((unused)) = 9927;
static const UInt32 kKKParamMotionBlurExpanded __attribute__((unused)) = 9928;
static const UInt32 kKKParamMotionBlurTransitionsOnly __attribute__((unused)) =
    9929;
static const UInt32 kKKParamMotionBlurAdaptiveQuality __attribute__((unused)) =
    9930;

/// Color system parameters (9800–9810)
static const UInt32 kKKParamColorGroup __attribute__((unused)) = 9800;
static const UInt32 kKKParamColorMode __attribute__((unused)) = 9801;
static const UInt32 kKKParamColorSolid __attribute__((unused)) = 9802;
static const UInt32 kKKParamColorCustomUI __attribute__((unused)) = 9803;
static const UInt32 kKKParamColorExpanded __attribute__((unused)) = 9804;
static const UInt32 kKKParamGradientData __attribute__((unused)) = 9805;

typedef NS_ENUM(NSInteger, KKColorMode) {
  KKColorModeSolid = 0,
  KKColorModeGradient = 1,
  KKColorModeDynamic = 2,
};

static const UInt32 kKKParamLogoBanner __attribute__((unused)) = 9990;