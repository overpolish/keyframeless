/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Static factory that returns NSBezierPath objects for Lucide icons.
///
/// All paths are defined in a 24×24 coordinate space matching the Lucide
/// SVG viewBox. Pass the result to KKIcon for rendering.
@interface KKIcons : NSObject

/// Lucide `info` - https://lucide.dev/icons/info
+ (NSBezierPath *)info;

@end

NS_ASSUME_NONNULL_END
