/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Renders a simple markup string into an NSAttributedString with inline
/// KKKbd keyboard badges and SF Symbol images.
///
/// Supported tags:
///   <kbd>⌥ G</kbd>         - keyboard shortcut badge
///   <symbol info.circle />   - inline SF Symbol (inherits label color)
///   <symbol squareshape.fill color=white /> - SF Symbol with explicit tint
///
/// Everything else is plain text.
@interface KKMarkup : NSObject

+ (NSAttributedString *)attributedStringFromMarkup:(NSString *)markup;

@end

NS_ASSUME_NONNULL_END
