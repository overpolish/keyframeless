/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKTimelineLanesView.h>

NS_ASSUME_NONNULL_BEGIN

/// Before, Split and Show Selection, as a small row of icons ON the mini
/// viewer.
///
/// They belong to the PREVIEW, not to the Color panel that used to carry them.
/// Every Mirage template has a mini viewer in its inspector and only a
/// `#color-surface` one has a panel, so a plain filter - Denoise above all,
/// where before/after is the whole point - had no way to compare at all and its
/// `preview=selection` marker was dead text.
///
/// Nothing here writes: the two compare controls are the mini viewer's own
/// session view state, and the selection switch is a live override pushed into
/// the preview's renderer. No lane, no parameter, no undo entry, and Final
/// Cut's viewer never shows the matte.
@interface MirageMiniCompareControls : NSObject

- (instancetype)initWithLanesView:(KKTimelineLanesView *)lanesView;

/// Whether the shader's selection - its matte - is showing, for THIS popover
/// session. The single source of truth for that switch: the Color panel reads
/// it to compose with its own active-key override, and resets to NO when the
/// popover closes.
@property(nonatomic, readonly) BOOL showSelectionActive;

/// Fired when the switch flips, so the host can re-assert the preview
/// overrides (the selection AND the panel's active key go through one push).
@property(nonatomic, copy, nullable) void (^onSelectionChanged)(BOOL showing);

/// Asked before a bare letter is consumed: YES means a gesture that owns the
/// keyboard is mid-flight and the key belongs to it. Left nil for "never".
@property(nonatomic, copy, nullable) BOOL (^shortcutsSuppressed)(void);

/// The shader may have gained or lost its `preview=selection` switch. Called
/// from -applyTimeline:, so a recompile adds or drops the button under an open
/// popover.
- (void)timelineDidChange;

/// Drop the row, the monitors and any held bypass. Called from the inspector's
/// dealloc, matching how the browser and Color panel controllers are retired.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
