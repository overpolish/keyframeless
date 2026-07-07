/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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

/// View injected at the very start of the leading accessory stack (left of
/// any help / changelog / feedback buttons). Used to host the AI button,
/// built in `KeyframelessAI` as an `NSHostingView` so the banner doesn't
/// need to depend on SwiftUI.
- (void)setLeadingAccessoryView:(nullable NSView *)view;

- (instancetype)init;

/// Best-effort screen rect of FCP's effect header row for *this* banner's
/// inspector. FCP exposes no API for it; the banner is the first plugin
/// parameter, immediately below the header, so the header is approximated as
/// the strip directly above the banner. Returns NSZeroRect when this banner
/// isn't in a window. Instance-scoped so multi-instance timelines resolve the
/// correct effect's header.
- (NSRect)effectHeaderScreenRect;

/// Screen rect of the leading Help (`?`) button, or NSZeroRect when the button
/// isn't present (no `onHelpTap` set) or the banner isn't in a window. Used to
/// spotlight the Help button from a guide's closing step.
- (NSRect)helpButtonScreenRect;

- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
