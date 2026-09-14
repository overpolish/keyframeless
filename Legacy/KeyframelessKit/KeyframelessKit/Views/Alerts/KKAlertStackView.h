/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKAlertView.h>

NS_ASSUME_NONNULL_BEGIN

@protocol PROAPIAccessing;

/// A container that manages multiple KKAlertViews in a vertical stack,
/// showing one at a time with an icon bar for switching between them.
/// Designed for XPC stability with NSStackView detachesHiddenViews.
@interface KKAlertStackView : NSView

/// Initialize with a default alert and optional persistence via an FxPlug
/// string parameter. Pass 0 for parameterID to disable persistence.
- (instancetype)initWithDefaultAlert:(KKAlertView *)defaultAlert
                          apiManager:(nullable id<PROAPIAccessing>)apiManager
                  persistParameterID:(UInt32)parameterID;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/// Add an alert. Lower priority values are shown first when multiple are
/// active.
- (void)addAlert:(KKAlertView *)alert priority:(NSUInteger)priority;

/// Mark an alert as active or inactive. The stack automatically selects the
/// highest-priority active alert to display, falling back to the default.
- (void)setAlert:(KKAlertView *)alert active:(BOOL)active;

/// Force-select an alert by tag (-1 = default, 0+ = entry index).
- (void)selectAlertWithTag:(NSInteger)tag;

/// Called when the user manually taps an icon to switch alerts.
@property(nonatomic, copy, nullable) void (^onSelectedChanged)(NSInteger tag);

@end

NS_ASSUME_NONNULL_END
