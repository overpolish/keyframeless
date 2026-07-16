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
/// Shown in a popover off its trigger, like the Animated dropdown. Set the
/// base's `popover` so the list resizes to the visible rows as a search narrows
/// it.
@interface KKChoiceChecklistView : _KKLaneChecklistView

/// `options` are the choice labels in directive order, `selectedIndex` the one
/// currently checked (out of range = nothing checked).
- (instancetype)initWithOptions:(NSArray<NSString *> *)options
                  selectedIndex:(NSInteger)selectedIndex
                  minimumHeight:(CGFloat)minimumHeight;

/// Fires with the option's index on pick. Re-picking the checked row still
/// fires: a picker has no "off", so a click is always a pick.
@property(nonatomic, copy, nullable) void (^onSelect)(NSInteger index);

/// Moves the check without firing `onSelect` (for a host syncing an outside
/// change, e.g. an undo).
- (void)setSelectedIndex:(NSInteger)selectedIndex;

@end

NS_ASSUME_NONNULL_END
