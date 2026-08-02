/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Inline rename field for a list row / card inside a ViewBridge panel.
///
/// In a ViewBridge popover key events arrive as key equivalents to the window,
/// not as normal keyDown to the field editor, so the Edit-menu combos are
/// forwarded here (the mechanism KKValueTextField uses) and the accent
/// caret/selection styling is applied as soon as the field takes focus.
///
/// The rename LIFECYCLE stays with the host: who begins editing, where the
/// committed name goes, and the Delete-key / outside-click monitors that go
/// with it (KKMakeFieldOutsideClickMonitor). This class is only the field.
@interface KKInlineRenameField : NSTextField
@end

NS_ASSUME_NONNULL_END
