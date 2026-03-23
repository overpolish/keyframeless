/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Renders a keyboard shortcut badge as an inline NSAttributedString segment.
///
/// Usage:
///   NSMutableAttributedString *s = [[NSMutableAttributedString alloc]
///       initWithString:@"Best used on an Adjustment Clip "];
///   [s appendAttributedString:[KKKbd attributedStringWithKey:@"⌥ A"]];
@interface KKKbd : NSObject

/// Returns an attributed string containing the key badge using the default
/// label color.
+ (NSAttributedString *)attributedStringWithKey:(NSString *)key;

/// Returns an attributed string containing the key badge tinted with the given
/// color.
+ (NSAttributedString *)attributedStringWithKey:(NSString *)key
                                          color:(NSColor *)color;

@end

NS_ASSUME_NONNULL_END
