/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Replaces macOS 26's liquid-glass popover chrome with a solid, opaque
/// inspector-matched fill so popover content stays legible instead of sitting
/// on see-through glass. Call from the popover content view's
/// -viewDidMoveToWindow once the view is in a window. Safe to call repeatedly;
/// a no-op when no NSPopoverFrame / GlassView is present.
void KKApplyPopoverBackground(NSView *view);

NS_ASSUME_NONNULL_END
