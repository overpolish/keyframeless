/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Inspector chrome strip carrying the Keyframeless logo (centered) plus
/// optional accessories: a help button pinned to the leading edge when
/// `onHelpTap` is set, and an "Update available" CTA on the trailing edge
/// when one is detected.
@interface KKLogoBannerView : NSView

/// When non-nil, a help (`?`) button is shown on the leading edge and
/// invokes this block on click. When nil, no help button is rendered.
@property(nonatomic, copy, nullable) void (^onHelpTap)(void);

- (instancetype)init;

- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
