/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Optional protocol popover hosts use to refresh extras rows after an
/// external mutation (cmd-Z, parameter sync etc.) without closing and
/// reopening the popover. Any extras view returned from
/// `KKTimelineInspectorView.gapPopoverExtraRows` may conform; rows that don't
/// implement it are simply skipped.
@protocol KKPopoverExtraRow <NSObject>
@optional
- (void)popoverDidRefresh;
@end

/// Compact label + right-aligned checkbox row used inside gap-popover extras
/// (and elsewhere - reuse this rather than rolling new label+checkbox layouts).
///
/// `binding` is the live-state oracle. The row evaluates it on construction
/// (to seed the initial check state) and again on `popoverDidRefresh` so
/// cmd-Z and similar external mutations land in the checkbox automatically.
/// `onToggle` fires when the user clicks; pass nil for read-only rows.
/// `disabledBinding` (optional) returns YES to dim the row + swallow clicks;
/// re-evaluated on every refresh too.
@interface KKCheckboxRowView : NSView <KKPopoverExtraRow>

- (instancetype)initWithTitle:(NSString *)title
                      tooltip:(nullable NSString *)tooltip
                      binding:(BOOL (^)(void))binding
              disabledBinding:(nullable BOOL (^)(void))disabledBinding
                     onToggle:(nullable void (^)(BOOL on))onToggle;

@end

NS_ASSUME_NONNULL_END
