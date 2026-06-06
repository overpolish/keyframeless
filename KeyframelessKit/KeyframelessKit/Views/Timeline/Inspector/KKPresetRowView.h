/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

@class KKPreset;

NS_ASSUME_NONNULL_BEGIN

/// Shared layout metrics for the presets popover + its rows.
FOUNDATION_EXPORT const CGFloat KKPresetPopoverWidth;
FOUNDATION_EXPORT const CGFloat KKPresetRowHeight;

/// Top-down layout container so built-ins (added first) render at the top.
@interface KKPresetsFlippedView : NSView
@end

/// NSTextField that routes Cmd-A / C / V / X to the field editor (no Edit menu
/// in an FxPlug ViewBridge popover) and tints the caret/selection to the host
/// accent. Used for both the inline-rename field and the popover filter field.
@interface KKPresetNameTextField : NSTextField
@end

/// One preset row: name (inline-renamable for user presets), an accent-tinted
/// apply-at-playhead button, and either a "Default" badge (built-ins) or
/// rename / overwrite / delete buttons. Clicking the row body applies as an
/// override; hovering highlights it and shows a pointing-hand cursor.
@interface KKPresetRowView : NSView <NSTextFieldDelegate>
@property(nonatomic, strong) KKPreset *preset;
@property(nonatomic, copy, nullable) void (^onApply)
    (KKPreset *preset, BOOL atPlayhead);
@property(nonatomic, copy, nullable) void (^onDelete)(NSString *identifier);
@property(nonatomic, copy, nullable) void (^onOverwrite)(NSString *identifier);
@property(nonatomic, copy, nullable) void (^onRename)
    (NSString *identifier, NSString *newName);
- (instancetype)initWithPreset:(KKPreset *)preset;
@end

NS_ASSUME_NONNULL_END
