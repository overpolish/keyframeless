/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

@class KKHelpSection;
@class KKHelpGuide;

NS_ASSUME_NONNULL_BEGIN

/// Renders an optional Guides section followed by KKHelpSections as a
/// documentation-style page. A faded rotated logo sits behind the content.
@interface KKHelpView : NSView

- (instancetype)initWithSections:(NSArray<KKHelpSection *> *)sections
                          guides:(nullable NSArray<KKHelpGuide *> *)guides
    NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithSections:(NSArray<KKHelpSection *> *)sections;

- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

// refreshGuideRows / observeGuideRefreshNotificationNamed: live on the
// KKHelpView (Guides) category — import "KKHelpView+Guides.h" to call them.

@end

NS_ASSUME_NONNULL_END
