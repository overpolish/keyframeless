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

NS_ASSUME_NONNULL_END
