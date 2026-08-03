/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPopoverKeepAlive.h"

#import "KKLog.h"

NSNotificationName const KKStaticValuesPopoverDidOpenNotification =
    @"KKStaticValuesPopoverDidOpenNotification";
NSNotificationName const KKStaticValuesPopoverDidCloseNotification =
    @"KKStaticValuesPopoverDidCloseNotification";
NSNotificationName const KKStaticValuesPopoverDidNavigateNotification =
    @"KKStaticValuesPopoverDidNavigateNotification";

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

// Post once the popover has a WINDOW, retrying briefly if it doesn't yet.
//
// `showRelativeToRect:` doesn't guarantee the content view is in a window by
// the time it returns, and on a cold FCP boot the first popover routinely
// isn't - its views are being built from scratch. Posting then omitted the
// `window` key, and every companion observer (Canvas's layer list, Mirage's
// template browser) bails without it, so the side panel silently never
// appeared until the popover was closed and reopened warm. Intermittent
// exactly as a first-open race would be.
//
// Bounded: a popover that is dismissed (or never lands in a window) stops the
// chain rather than retrying forever, and posts a last window-less
// notification so a `kind`-only observer still hears the open.
static void KKPostPopoverOpenWhenWindowed(NSPopover *popover, id sender,
                                          NSString *kind, BOOL isBoundary,
                                          double fraction, NSInteger attempt) {
  // ~5s. `popover.isShown` is the real stop condition - this cap only bounds a
  // popover that is shown but never lands in a window. It was ~1s, which a COLD
  // FCP boot routinely exceeds: the whole inspector is being built for the
  // first time, the deadline passed, and the window-less notification below
  // then told every companion panel there was nothing to attach to. That is the
  // long- standing "first popover after launch shows no side panel" bug, and it
  // was never specific to one panel.
  static const NSInteger kMaxAttempts = 100;
  static const NSTimeInterval kRetryDelay = 0.05;
  NSView *contentView = popover.contentViewController.view;
  if (!contentView.window && popover.isShown && attempt < kMaxAttempts) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRetryDelay * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          KKPostPopoverOpenWhenWindowed(popover, sender, kind, isBoundary,
                                        fraction, attempt + 1);
        });
    return;
  }
  NSWindow *window = contentView.window;
  NSMutableDictionary *info = [NSMutableDictionary dictionary];
  if (window) {
    info[@"window"] = window;
    info[@"contentView"] = contentView; // companion can re-align on flip
    info[@"contentRect"] = [NSValue
        valueWithRect:[window
                          convertRectToScreen:[contentView
                                                  convertRect:contentView.bounds
                                                       toView:nil]]];
  } else if (contentView) {
    // Windowless give-up. Pass the content view anyway: it is the one object
    // that WILL acquire a window, so an observer can keep waiting on it instead
    // of being told there is nothing to attach to. Without this the
    // notification carried `kind` alone and every companion panel silently gave
    // up.
    info[@"contentView"] = contentView;
    KKLogWarn(@"[Popover] %@ never windowed in %.1fs, companions must resolve "
              @"the window from contentView",
              kind ?: @"constants", kMaxAttempts * kRetryDelay);
  }
  info[@"isBoundary"] = @(isBoundary);
  info[@"fraction"] = @(fraction);
  info[@"kind"] = kind ?: @"constants";
  [NSNotificationCenter.defaultCenter
      postNotificationName:KKStaticValuesPopoverDidOpenNotification
                    object:sender
                  userInfo:info];
}

void KKPostStaticValuesPopoverDidOpen(NSPopover *popover, id sender,
                                      NSString *kind, BOOL isBoundary,
                                      double fraction) {
  KKPostPopoverOpenWhenWindowed(popover, sender, kind, isBoundary, fraction, 0);
}

void KKPostStaticValuesPopoverDidNavigate(id sender, BOOL isBoundary,
                                          double fraction) {
  [NSNotificationCenter.defaultCenter
      postNotificationName:KKStaticValuesPopoverDidNavigateNotification
                    object:sender
                  userInfo:@{
                    @"isBoundary" : @(isBoundary),
                    @"fraction" : @(fraction),
                    @"kind" : isBoundary ? @"keypose" : @"constants",
                  }];
}
