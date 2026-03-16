/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A full-width horizontal rule displayed in the inspector. When text and/or
/// an icon are provided they appear centred between two line segments:
///   ──── [icon] [text] ────
/// All arguments are optional; passing nil for both renders a plain divider.
@interface KKSeparatorView : NSView

- (instancetype)init;
- (instancetype)initWithText:(nullable NSString *)text
                        icon:(nullable NSBezierPath *)icon;

- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@property(nonatomic, copy, nullable) NSString *text;
@property(nonatomic, strong, nullable) NSBezierPath *icon;
@property(nonatomic, strong) NSColor *color;

@end

NS_ASSUME_NONNULL_END
