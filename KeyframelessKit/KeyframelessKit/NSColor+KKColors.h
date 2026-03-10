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

+ (NSColor *)primaryColor;
+ (NSColor *)outlineColor;
+ (NSColor *)hoverColor;
+ (NSColor *)activeColor;
+ (NSColor *)transparentColor;

- (simd_float4)simdFloat4;

@end
