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
/// `userInfo[@"contentView"]` identifies the exact editor/popover surface that
/// closed, so observers can ignore a temporary option popover closing over a
/// still-open primary editor.
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

/// Posted when the editor header's sidebar button changes whether the plugin's
/// primary companion browser should be shown. Mirage's template browser and
/// Canvas's layer list observe this; grading and other companion surfaces do
/// not. `userInfo[@"visible"]` is the requested state and the remaining keys
/// match DidOpen so a newly-shown sidebar can attach immediately.
extern NSNotificationName const
    KKStaticValuesSidebarVisibilityDidChangeNotification;

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

/// Header toggle beside composition peek. It controls the plugin's primary
/// template/layer sidebar and displays the L-key shortcut in its tooltip.
@interface KKPopoverSidebarButton : NSButton
@property(nonatomic, getter=isSidebarVisible) BOOL sidebarVisible;
@property(nonatomic, copy, nullable) void (^onVisibilityChanged)(BOOL visible);
@end

FOUNDATION_EXPORT KKPopoverSidebarButton *
KKCreateSidebarVisibilityButton(BOOL visible,
                                void (^onVisibilityChanged)(BOOL visible));

/// Opt-in mirror for a plugin-owned right companion panel (Mirage grading).
/// Uses the same toggle behaviour/style; plugins without a right panel do not
/// add this button.
FOUNDATION_EXPORT KKPopoverSidebarButton *
KKCreateRightPanelVisibilityButton(BOOL visible,
                                   void (^onVisibilityChanged)(BOOL visible));

/// Kit-wide "pinned" state of the editor panels (constants / keypose / curve /
/// gap). Pinned (the default) means a panel only closes on its X, Esc, or an
/// in-place replacement. Unpinned, a click outside the panel and its companions
/// closes it as if X had been pressed. One flag for every panel: it describes
/// how the user likes panels to behave, not any one panel. Persisted.
FOUNDATION_EXPORT BOOL KKEditorPanelsPinned(void);
FOUNDATION_EXPORT void KKSetEditorPanelsPinned(BOOL pinned);
/// Posted (object nil) after KKSetEditorPanelsPinned changes the value, so an
/// open panel can switch its dismissal and its pin button can mirror.
extern NSNotificationName const KKEditorPanelsPinnedDidChangeNotification;

/// Header toggle beside close: the pin. Reads/writes the kit-wide flag itself
/// and mirrors external changes, so a host only builds and places it.
@interface KKPopoverPinButton : NSButton
@end
FOUNDATION_EXPORT KKPopoverPinButton *KKCreateEditorPinButton(void);

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

/// Post the matching close for one exact editor/popover content surface.
/// Passing the content view is important when a temporary popover is layered
/// over a persistent editor: its close must not tear down companions belonging
/// to the editor underneath.
void KKPostStaticValuesSurfaceDidClose(NSView *_Nullable contentView,
                                       id sender);

/// Post the dedicated primary-sidebar visibility signal with enough live panel
/// geometry for a browser/list to attach again when toggled on.
void KKPostStaticValuesSidebarVisibility(NSWindow *window, NSView *contentView,
                                         id sender, NSString *kind,
                                         BOOL isBoundary, double fraction,
                                         BOOL visible);

/// Post `KKStaticValuesPopoverDidNavigateNotification` for an in-place move of
/// the open popover to a new `fraction`. `sender` is the presenting view.
void KKPostStaticValuesPopoverDidNavigate(id sender, BOOL isBoundary,
                                          double fraction);

NS_ASSUME_NONNULL_END
