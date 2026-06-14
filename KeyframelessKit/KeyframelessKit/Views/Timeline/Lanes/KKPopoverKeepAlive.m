/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPopoverKeepAlive.h"

NSNotificationName const KKStaticValuesPopoverDidOpenNotification =
    @"KKStaticValuesPopoverDidOpenNotification";
NSNotificationName const KKStaticValuesPopoverDidCloseNotification =
    @"KKStaticValuesPopoverDidCloseNotification";

// Weak set of windows that count as "inside" for popover outside-click
// dismissal. Registry + popover dismissal both run on the main thread, so no
// locking is needed.
static NSHashTable<NSWindow *> *KKKeepAliveWindows(void) {
  static NSHashTable<NSWindow *> *windows;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    windows = [NSHashTable weakObjectsHashTable];
  });
  return windows;
}

void KKPopoverAddKeepAliveWindow(NSWindow *window) {
  if (window)
    [KKKeepAliveWindows() addObject:window];
}

void KKPopoverRemoveKeepAliveWindow(NSWindow *window) {
  if (window)
    [KKKeepAliveWindows() removeObject:window];
}

BOOL KKPopoverPointInKeepAliveWindow(NSPoint screenPoint) {
  for (NSWindow *w in KKKeepAliveWindows())
    if (w.isVisible && NSPointInRect(screenPoint, w.frame))
      return YES;
  return NO;
}
