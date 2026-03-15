/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// An NSView that renders a stroke-only Lucide-style icon.
///
/// Paths are defined in a 24×24 coordinate space (matching Lucide's viewBox).
/// The view scales the path to fit its bounds while preserving aspect ratio,
/// and flips the Y-axis so SVG coordinates work as-is.
///
/// @code
/// KKIcon *icon = [[KKIcon alloc] initWithPath:[KKIcons info]
///                                 strokeColor:[NSColor accent]];
/// icon.frame = NSMakeRect(0, 0, 16, 16);
/// @endcode
@interface KKIcon : NSView

/// The path to render, defined in 24×24 SVG coordinate space.
@property(nonatomic, strong) NSBezierPath *path;

/// Color used to stroke the path. Defaults to NSColor.accent.
@property(nonatomic, strong) NSColor *strokeColor;

/// Stroke width in screen points (not scaled with the icon). Defaults to 1.5.
@property(nonatomic) CGFloat strokeWidth;

- (instancetype)initWithPath:(nullable NSBezierPath *)path
                 strokeColor:(NSColor *)strokeColor NS_DESIGNATED_INITIALIZER;

/// Uses NSColor.accent as the stroke color.
- (instancetype)initWithPath:(NSBezierPath *)path;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
