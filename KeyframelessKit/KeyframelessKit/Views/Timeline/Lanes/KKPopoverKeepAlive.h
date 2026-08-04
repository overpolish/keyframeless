/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted when a value / constants ("static values") editing popover opens.
/// `object` is the `KKTimelineLanesView` that presented it (observe with that
/// object to scope to one inspector instance); `userInfo[@"window"]` is the
/// popover's `NSWindow`. A plugin observes this to show a companion panel
/// (e.g. a layer list) beside the popover.
extern NSNotificationName const KKStaticValuesPopoverDidOpenNotification;

/// Posted when that popover closes. `object` is the same `KKTimelineLanesView`.
extern NSNotificationName const KKStaticValuesPopoverDidCloseNotification;

/// Posted when an ALREADY-OPEN static popover changes what it is editing
/// WITHOUT closing: a keypose popover moving to a different boundary (cell
/// click / arrow nav), or the popover switching KIND in place
/// (keypose <-> constants). The window never closes, so DidOpen doesn't fire
/// and anything derived from the popover's kind or time goes stale. `object` is
/// the presenting `KKTimelineLanesView`; `userInfo` carries `kind` /
/// `isBoundary` / `fraction` only (the window is unchanged, so the placement
/// keys would say nothing new).
///
/// Deliberately NOT a re-post of DidOpen: the companion panels that ride that
/// pair (the browser, the color panel) tear down and re-slide their panel on
/// every open, so an arrow press would flicker them. Observe this one IN
/// ADDITION to DidOpen when all you do is re-derive from the popover's time -
/// e.g. graying the owners with no keypose there
/// (`-openKeyposePopoverLayerKeys`).
extern NSNotificationName const KKStaticValuesPopoverDidNavigateNotification;

/// Register / unregister a window whose clicks must NOT dismiss an open kit
/// popover - e.g. a companion side panel shown beside it. The popover's
/// outside-click dismissal treats points inside a registered window as
/// "inside". Held weakly; safe to leave registered across the window's life.
void KKPopoverAddKeepAliveWindow(NSWindow *window);
void KKPopoverRemoveKeepAliveWindow(NSWindow *window);

/// YES if `screenPoint` lies within any registered, visible keep-alive window.
BOOL KKPopoverPointInKeepAliveWindow(NSPoint screenPoint);

/// Install a consuming keyboard event tap for shortcuts that must remain live
/// while Final Cut, rather than the plugin panel, owns keyboard focus. Return
/// YES from `handler` to keep the event from also reaching Final Cut. The
/// caller must retain the returned token for the lifetime of the shortcut and
/// pass it to `KKRemoveGlobalKeyCapture` when finished. Returns nil when macOS
/// does not permit an active event tap.
FOUNDATION_EXPORT
    id _Nullable KKInstallGlobalKeyCapture(BOOL (^handler)(NSEvent *event));
FOUNDATION_EXPORT void KKRemoveGlobalKeyCapture(id _Nullable token);

/// Header button used by primary editors to momentarily reveal Final Cut's
/// full composition behind the panel. Unlike a normal click button, it owns
/// both halves of the gesture and calls `onHoldChanged(YES)` on mouse-down and
/// `onHoldChanged(NO)` wherever the matching mouse-up lands.
@interface KKPopoverPeekButton : NSButton
@property(nonatomic, copy, nullable) void (^onHoldChanged)(BOOL held);
@end

/// House-styled layered-rectangles peek button, including its localized
/// accessibility label and P-key tooltip.
FOUNDATION_EXPORT KKPopoverPeekButton *
KKCreateCompositionPeekButton(void (^onHoldChanged)(BOOL held));

/// Post `KKStaticValuesPopoverDidOpenNotification` for `popover` with the
/// standard companion-panel userInfo - `window`, `contentView`, and the visible
/// card's screen rect `contentRect` (the window frame includes shadow/arrow
/// padding, so a companion aligns to this), plus `kind` / `isBoundary` /
/// `fraction`. One source of truth for those keys; `object` is `sender` (the
/// presenting view) so observers can scope to one inspector. Safe if the
/// popover has no window yet.
void KKPostStaticValuesPopoverDidOpen(NSPopover *popover, id sender,
                                      NSString *kind, BOOL isBoundary,
                                      double fraction);

/// Panel-hosted equivalent of `KKPostStaticValuesPopoverDidOpen`. It posts the
/// same notification and keys so existing template, colour and layer-list
/// companions can attach without caring whether the primary editor uses an
/// NSPopover or a persistent panel.
void KKPostStaticValuesEditorDidOpen(NSWindow *window, NSView *contentView,
                                     id sender, NSString *kind, BOOL isBoundary,
                                     double fraction);

/// Post `KKStaticValuesPopoverDidNavigateNotification` for an in-place move of
/// the open popover to a new `fraction`. `sender` is the presenting view.
void KKPostStaticValuesPopoverDidNavigate(id sender, BOOL isBoundary,
                                          double fraction);

NS_ASSUME_NONNULL_END
