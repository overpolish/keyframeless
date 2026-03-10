/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>
#import <simd/simd.h>

@interface NSColor (KKColors)

+ (NSColor *)inspectorLabelColor;
+ (NSColor *)inspectorBackground;

// Mainly for OSC
+ (NSColor *)primaryColor;
+ (NSColor *)outlineColor;
+ (NSColor *)hoverColor;
+ (NSColor *)activeColor;
+ (NSColor *)transparentColor;

+ (NSColor *)sliderTrackBackground;
+ (NSColor *)sliderTrackFill;
+ (NSColor *)sliderKnobFill;
+ (NSColor *)sliderKnobOutline;

- (simd_float4)simdFloat4;

@end
