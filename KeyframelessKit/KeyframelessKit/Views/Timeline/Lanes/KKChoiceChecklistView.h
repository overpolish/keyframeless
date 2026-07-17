/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

#import "KKLaneChecklistView.h"

NS_ASSUME_NONNULL_BEGIN

/// A single-select picker over plain option labels, wearing the Animated
/// dropdown's chrome (search + rows + category-less list).
///
/// The only checklist here whose rows aren't lanes: a `#choice` directive's
/// options are just strings a shader author typed. That works because the base
/// builds rows from labels - `-appendRowWithLabel:` - and only its DEFAULT
/// rebuild walks lanes, which this overrides.
///
/// Shown in a popover off its trigger, like the Animated dropdown.
///
/// The list caps at `maxBodyHeight` and scrolls behind the standard top/bottom
/// fade past it - the option count is whatever a shader author typed, so it
/// can't be allowed to size the popover freely.
///
/// A host MUST set the base's `popover` and then call `-refilterAndResize`
/// BEFORE showing it: that is what sizes the popover to the (capped) list. The
/// popover is not known at init - it is built around this view - so the size
/// can only be settled once the host wires the two together.
@interface KKChoiceChecklistView : _KKLaneChecklistView

/// `options` are the choice labels in directive order, `selectedIndex` the one
/// currently checked (out of range = nothing checked). `maxBodyHeight` caps the
/// row area (it scrolls beyond that); a row is `kRowHeight` tall.
- (instancetype)initWithOptions:(NSArray<NSString *> *)options
                  selectedIndex:(NSInteger)selectedIndex
                  maxBodyHeight:(CGFloat)maxBodyHeight;

/// Fires with the option's index on pick. Re-picking the checked row still
/// fires: a picker has no "off", so a click is always a pick.
@property(nonatomic, copy, nullable) void (^onSelect)(NSInteger index);

/// Moves the check without firing `onSelect` (for a host syncing an outside
/// change, e.g. an undo).
- (void)setSelectedIndex:(NSInteger)selectedIndex;

@end

NS_ASSUME_NONNULL_END
