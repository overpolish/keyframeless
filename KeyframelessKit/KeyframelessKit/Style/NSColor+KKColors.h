/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>
#import <simd/simd.h>

@interface NSColor (KKColors)

+ (NSColor *)inspectorLabel;
+ (NSColor *)inspectorBackground;

// Mainly for OSC
+ (NSColor *)primary;
+ (NSColor *)outline;
+ (NSColor *)hover;
+ (NSColor *)active;
+ (NSColor *)transparent;

+ (NSColor *)accent;
+ (NSColor *)warning;
+ (NSColor *)secondaryLabel;

- (simd_float4)simdFloat4;

@end
