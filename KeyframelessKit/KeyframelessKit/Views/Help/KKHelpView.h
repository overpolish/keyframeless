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

/// `headerTitle`/`headerIcon`, when given, render a title bar at the very top
/// of the page (the plugin's name beside its icon). A section whose title
/// matches `headerTitle` has its inline heading dropped - its title now lives
/// in the header - and its body is promoted to an intro block, above the
/// table of contents and excluded from it.
- (instancetype)initWithSections:(NSArray<KKHelpSection *> *)sections
                          guides:(nullable NSArray<KKHelpGuide *> *)guides
                     headerTitle:(nullable NSString *)headerTitle
                      headerIcon:(nullable NSImage *)headerIcon
    NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithSections:(NSArray<KKHelpSection *> *)sections
                          guides:(nullable NSArray<KKHelpGuide *> *)guides;

- (instancetype)initWithSections:(NSArray<KKHelpSection *> *)sections;

- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

// refreshGuideRows / observeGuideRefreshNotificationNamed: live on the
// KKHelpView (Guides) category - import "KKHelpView+Guides.h" to call them.

@end

NS_ASSUME_NONNULL_END
