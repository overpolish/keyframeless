/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKPopoverExtraRow.h>

NS_ASSUME_NONNULL_BEGIN

/// Shared base for value-bearing rows (point, random, slider, etc.). Owns
/// the left-side title label and an optional lane-color stripe. Subclasses
/// fill `controlContainer` with their right-side control and override
/// `-popoverDidRefresh` to re-evaluate their binding.
///
/// Why a base class: keeps padding / label color / row height / stripe
/// styling in one place so every value-row inherits the same chrome - touch
/// a token here and every subclass updates.
@interface KKLaneRowView : NSView <KKPopoverExtraRow>

/// Subclasses add their control here. Pinned to the trailing edge with
/// vertical centring; subclasses set its width / height as needed.
@property(nonatomic, readonly) NSView *controlContainer;

/// Title label - exposed so subclasses can tweak tooltip / accessibility
/// after construction. Don't change font / color; use the base styling.
@property(nonatomic, readonly) NSTextField *titleLabel;

- (instancetype)initWithTitle:(NSString *)title
                      tooltip:(nullable NSString *)tooltip
                    laneColor:(nullable NSColor *)laneColor;

/// Subclass hook. Base implementation is a no-op; subclasses override to
/// pull live state from their binding closures. Called by popover hosts
/// (via the KKPopoverExtraRow protocol) after external mutations.
- (void)popoverDidRefresh NS_REQUIRES_SUPER;

@end

NS_ASSUME_NONNULL_END
