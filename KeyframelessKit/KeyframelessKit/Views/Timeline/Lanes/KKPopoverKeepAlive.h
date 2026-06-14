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

/// Register / unregister a window whose clicks must NOT dismiss an open kit
/// popover - e.g. a companion side panel shown beside it. The popover's
/// outside-click dismissal treats points inside a registered window as
/// "inside". Held weakly; safe to leave registered across the window's life.
void KKPopoverAddKeepAliveWindow(NSWindow *window);
void KKPopoverRemoveKeepAliveWindow(NSWindow *window);

/// YES if `screenPoint` lies within any registered, visible keep-alive window.
BOOL KKPopoverPointInKeepAliveWindow(NSPoint screenPoint);

NS_ASSUME_NONNULL_END
