/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <CoreFoundation/CFCGTypes.h>

/// Standard UI spacing unit used for padding and gaps.
static const CGFloat KKSpacingMD = 6.0;

/// Hairline border/stroke width.
static const CGFloat KKBorderWidthHairline = 0.5;

/// Small radius for badges and inline elements (e.g. kbd).
static const CGFloat KKRadiusSM = 2.5;

/// Medium radius for cards and content areas (e.g. info view).
static const CGFloat KKRadiusMD = 8.0;

/// Height of a single inspector row (matches Motion).
static const CGFloat KKInspectorRowHeight = 23.0;

/// Horizontal inset of inspector content (matches Motion).
static const CGFloat KKInspectorHorizontalInset = 21.0;

/// Outline ring width around OSC controls.
static const float KKOSCOutlineWidth = 2.0f;

/// Default radius of a point OSC control.
static const float KKOSCPointRadius = 7.0f;

/// Default radius of an arc OSC control.
static const float KKOSCArcRadius = 23.0f;

/// Default stroke width of an arc OSC control.
static const float KKOSCArcStrokeWidth = 10.0f;
