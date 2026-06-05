/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <simd/simd.h>

@interface NSColor (KKColors)

#pragma mark FxPlug

+ (NSColor *)inspectorLabel;
+ (NSColor *)inspectorBackground;
+ (NSColor *)remoteWindowBackground;

#pragma mark Workflow Extension

+ (NSColor *)windowBackground;
+ (NSColor *)timelineLabel;
+ (NSColor *)timelineTick;

#pragma mark Shared

+ (NSColor *)accent;
+ (NSColor *)accentMatchingHost;
+ (NSColor *)warning;
+ (NSColor *)error;
+ (NSColor *)success;
+ (NSColor *)transparent;

/// Onion-skin ghost tints, matched to the mini-canvas onion shader so the
/// `<red>` / `<blue>` markup that explains them reads the same hue: earlier
/// frames red, later frames blue.
+ (NSColor *)onionPrevTint;
+ (NSColor *)onionNextTint;

- (NSColor *)shiftedHueBy:(CGFloat)amount;
- (NSColor *)compound;

- (simd_float4)simdFloat4;

@end
