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
/// 9900–9999  animation system parameters (added by KKPlugin)

static const UInt32 kKKParamUpdateBanner __attribute__((unused)) = 9990;
static const UInt32 kKKParamAnimationSeparator __attribute__((unused)) = 9900;
static const UInt32 kKKParamAnimateIn __attribute__((unused)) = 9901;
static const UInt32 kKKParamAnimateOut __attribute__((unused)) = 9902;
static const UInt32 kKKParamAnimationDuration __attribute__((unused)) = 9903;
static const UInt32 kKKParamAnimationInterpolation __attribute__((unused)) = 9904;
static const UInt32 kKKParamTimingCurvePreview __attribute__((unused)) = 9905;
