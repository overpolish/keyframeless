/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Shared inspector value-entry field: only takes focus on an explicit click
/// (so its popover doesn't steal keyboard shortcuts), accent caret/selection,
/// and hands focus back to the window when editing ends.
///
/// `kkEditing` is YES for the whole editing session - set at
/// `textDidBeginEditing` (editing can re-start without a fresh
/// `becomeFirstResponder`) and cleared after `textDidEndEditing`'s super call.
/// An owner's redisplay must skip a field while `kkEditing`: writing its
/// stringValue mid-edit re-creates the field editor and re-selects all, yanking
/// focus back so it can never be defocused. (`currentEditor` is an unreliable
/// guard - already nil by the time `textDidEndEditing:` fires.)
@interface KKValueTextField : NSTextField
@property(nonatomic, readonly) BOOL kkEditing;

/// Click-and-drag scrubbing: dragging horizontally on the field changes its
/// value (and fires `action`, so the owner's normal commit path - clamping,
/// aspect-link, sibling redisplay - runs unchanged). The cursor hides and
/// freezes for the drag, reappearing where it started. A drag shorter than the
/// start threshold is treated as a plain click and begins text editing instead.
///
/// `scrubStep` is the value change per scrub step (default 1.0). Hold Shift for
/// 10x steps (coarse), Option for 0.1x (fine). Owners set a per-field step that
/// matches the field's units (e.g. 1 for pixels/degrees, 0.01 for a 0..1
/// factor). Set `scrubDisabled` to opt a field out entirely.
@property(nonatomic) double scrubStep;
@property(nonatomic) BOOL scrubDisabled;

/// Bracket a whole scrub drag (begin on first step, end on mouse-up) - wire
/// these to the owner's drag-undo grouping (onDragBegin/onDragEnd) so one drag
/// is one undo step rather than one per tick.
@property(nonatomic, copy, nullable) void (^onScrubBegin)(void);
@property(nonatomic, copy, nullable) void (^onScrubEnd)(void);

/// A field styled for inspector value entry: monospaced digits, right-aligned,
/// borderless, clear background, fires its action on Return and on focus loss.
+ (instancetype)valueField;
@end

/// Call from an owner's `control:textView:doCommandBySelector:`. Handles Return
/// by fully defocusing (which commits via focus loss), suppressing AppKit's
/// default Return handling that otherwise re-selects all and re-focuses the
/// field. Returns YES when it handled the command.
FOUNDATION_EXPORT BOOL KKValueFieldHandleReturnCommand(
    NSWindow *_Nullable window, SEL commandSelector);

/// Call from an owner's `control:textView:doCommandBySelector:` (after the
/// Return handler). On Tab / Shift-Tab, moves editing focus to the next /
/// previous value field in the same popover. Returns YES when handled.
FOUNDATION_EXPORT BOOL KKValueFieldHandleTabCommand(NSTextField *field,
                                                    SEL commandSelector);

NS_ASSUME_NONNULL_END
