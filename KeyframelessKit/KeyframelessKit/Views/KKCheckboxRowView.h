/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KKLaneRowView.h>

NS_ASSUME_NONNULL_BEGIN

/// Compact label + right-aligned checkbox row. Subclass of `KKLaneRowView`
/// so it inherits the shared chrome (label, optional lane color stripe,
/// padding tokens) and the `KKPopoverExtraRow` auto-refresh affordance.
///
/// `binding` is the live-state oracle. The row evaluates it on construction
/// (to seed the initial check state) and again on `popoverDidRefresh` so
/// cmd-Z and similar external mutations land in the checkbox automatically.
/// `onToggle` fires when the user clicks; pass nil for read-only rows.
/// `disabledBinding` (optional) returns YES to dim the row + swallow clicks;
/// re-evaluated on every refresh too.
@interface KKCheckboxRowView : KKLaneRowView

- (instancetype)initWithTitle:(NSString *)title
                      tooltip:(nullable NSString *)tooltip
                    laneColor:(nullable NSColor *)laneColor
                      binding:(BOOL (^)(void))binding
              disabledBinding:(nullable BOOL (^)(void))disabledBinding
                     onToggle:(nullable void (^)(BOOL on))onToggle;

/// Legacy initializer without `laneColor` (passes nil). New code should use
/// the full initializer above.
- (instancetype)initWithTitle:(NSString *)title
                      tooltip:(nullable NSString *)tooltip
                      binding:(BOOL (^)(void))binding
              disabledBinding:(nullable BOOL (^)(void))disabledBinding
                     onToggle:(nullable void (^)(BOOL on))onToggle;

@end

NS_ASSUME_NONNULL_END
