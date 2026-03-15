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

static const UInt32 kKKParamAnimationSeparator = 9900;
static const UInt32 kKKParamAnimateIn = 9901;
static const UInt32 kKKParamAnimateOut = 9902;
static const UInt32 kKKParamAnimationDuration = 9903;
static const UInt32 kKKParamAnimationInterpolation = 9904;
