/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>
#import <simd/simd.h>

@interface NSColor (KKColors)

#pragma mark FxPlug

+ (NSColor *)inspectorLabel;
+ (NSColor *)inspectorBackground;

#pragma mark Workflow Extension

+ (NSColor *)windowBackground;
+ (NSColor *)timelineLabel;
+ (NSColor *)timelineTick;

#pragma mark Shared

// Mainly for OSC
+ (NSColor *)primary;
+ (NSColor *)outline;
+ (NSColor *)hover;
+ (NSColor *)active;
+ (NSColor *)transparent;

+ (NSColor *)ringIdleFill;
+ (NSColor *)ringIdleStroke;
+ (NSColor *)ringHoverFill;
+ (NSColor *)ringHoverStroke;
+ (NSColor *)ringActiveFill;
+ (NSColor *)ringActiveStroke;

+ (NSColor *)accent;
+ (NSColor *)warning;
+ (NSColor *)error;
- (NSColor *)shiftedHueBy:(CGFloat)amount;
- (NSColor *)compound;

- (simd_float4)simdFloat4;

@end
