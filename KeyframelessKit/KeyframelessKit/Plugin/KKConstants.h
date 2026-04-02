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
static const UInt32 kKKParamAnimateInInterpolation __attribute__((unused)) = 9904;
static const UInt32 kKKParamTimingCurvePreview __attribute__((unused)) = 9905;
static const UInt32 kKKParamAnimateOutDuration __attribute__((unused)) = 9906;
static const UInt32 kKKParamAnimateOutInterpolation __attribute__((unused)) = 9907;
static const UInt32 kKKParamTimingExpanded __attribute__((unused)) = 9908;
static const UInt32 kKKParamTimingSelectedSection __attribute__((unused)) = 9909;
static const UInt32 kKKParamMidHoldEffect __attribute__((unused)) = 9910;

static const UInt32 kKKParamUpdateBanner __attribute__((unused)) = 9990;