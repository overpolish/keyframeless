/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKJoyrideController_Private.h"
#import "KKLog.h"

@implementation KKJoyrideController (FocusObservers)

// Tear the guide down on anything that invalidates the spotlight's
// screen↔canvas mapping: the user switching away from the app, the host
// (inspector) window losing key, or that window being resized/moved. These
// all leave the cached canvas anchor stale, which is the root of the
// drifting-spotlight class of bugs. Observers live for the whole active
// guide (persist across step advance), torn down on dismiss/_complete.
- (void)_installFocusObservers {
  [self _removeFocusObservers];
  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
  NSWindow *hostWindow = _hostView.window;
  __weak typeof(self) weak = self;
  void (^bail)(NSString *) = ^(NSString *why) {
    __strong typeof(weak) strong = weak;
    if (!strong || !strong->_active)
      return;
    // Defer: notifications fire synchronously and dismiss runs an animation
    // + onComplete (which may applyTimeline:) - avoid reentrancy.
    dispatch_async(dispatch_get_main_queue(), ^{
      __strong typeof(weak) s = weak;
      if (s && s->_active)
        [s dismiss];
    });
  };
  _focusObservers = [NSMutableArray array];
  [_focusObservers
      addObject:[nc addObserverForName:NSApplicationDidResignActiveNotification
                                object:nil
                                 queue:nil
                            usingBlock:^(NSNotification *n) {
                              bail(@"app resigned active");
                            }]];
  if (hostWindow) {
    [_focusObservers
        addObject:[nc addObserverForName:NSWindowDidResignKeyNotification
                                  object:hostWindow
                                   queue:nil
                              usingBlock:^(NSNotification *n) {
                                bail(@"host window resigned key");
                              }]];
    [_focusObservers
        addObject:[nc addObserverForName:NSWindowDidResizeNotification
                                  object:hostWindow
                                   queue:nil
                              usingBlock:^(NSNotification *n) {
                                bail(@"host window resized");
                              }]];
    [_focusObservers
        addObject:[nc addObserverForName:NSWindowDidMoveNotification
                                  object:hostWindow
                                   queue:nil
                              usingBlock:^(NSNotification *n) {
                                bail(@"host window moved");
                              }]];
  }

  [self _installOcclusionDismissObserver];
}

// Dismiss the guide when a ViewBridge host window's occlusion changes - i.e.
// Mission Control / App Exposé / bringing FCP forward covered the overlay,
// even when focus returns to FCP (so NSApplicationDidResignActive never
// fires). The borderless non-activating panel's own occlusionState never
// changes, so the host (hostPassthroughWindows) windows are the signal.
// Verified from a full guided run that these produce ZERO occlusion events
// during the normal OSC click+drag, so this can't fire mid-interaction.
- (void)_installOcclusionDismissObserver {
  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
  __weak typeof(self) weak = self;
  [_focusObservers
      addObject:
          [nc addObserverForName:NSWindowDidChangeOcclusionStateNotification
                          object:nil
                           queue:nil
                      usingBlock:^(NSNotification *n) {
                        __strong typeof(weak) s = weak;
                        if (!s || !s->_active)
                          return;
                        NSWindow *w = [n.object isKindOfClass:[NSWindow class]]
                                          ? n.object
                                          : nil;
                        if (!w ||
                            ![s->_hostPassthroughWindows containsObject:w])
                          return;
                        dispatch_async(dispatch_get_main_queue(), ^{
                          __strong typeof(weak) s2 = weak;
                          if (s2 && s2->_active)
                            [s2 dismiss];
                        });
                      }]];
}

- (void)_removeFocusObservers {
  if (!_focusObservers)
    return;
  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
  for (id token in _focusObservers)
    [nc removeObserver:token];
  _focusObservers = nil;
}

@end
