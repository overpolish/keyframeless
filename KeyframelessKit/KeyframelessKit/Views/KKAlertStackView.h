/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKAlertView.h>

NS_ASSUME_NONNULL_BEGIN

/// A container that manages multiple KKAlertViews in a vertical stack,
/// showing one at a time with an icon bar for switching between them.
/// Designed for XPC stability with NSStackView detachesHiddenViews.
@interface KKAlertStackView : NSView

/// Initialize with a default alert that is shown when no other alerts are
/// active.
- (instancetype)initWithDefaultAlert:(KKAlertView *)defaultAlert;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/// Add an alert. Lower priority values are shown first when multiple are
/// active.
- (void)addAlert:(KKAlertView *)alert priority:(NSUInteger)priority;

/// Mark an alert as active or inactive. The stack automatically selects the
/// highest-priority active alert to display, falling back to the default.
- (void)setAlert:(KKAlertView *)alert active:(BOOL)active;

@end

NS_ASSUME_NONNULL_END
