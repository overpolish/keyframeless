/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A compact banner shown in the FxPlug inspector when an update is available.
/// Displays a message and a "Download" button that opens the release page.
/// Returns a zero-height view when no update is available.
@interface KKUpdateBannerView : NSView

- (instancetype)init;

- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
