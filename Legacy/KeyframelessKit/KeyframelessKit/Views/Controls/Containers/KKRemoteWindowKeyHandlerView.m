/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKRemoteWindowKeyHandlerView.h"

@implementation KKRemoteWindowKeyHandlerView

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window && !self.eventMonitor) {
    __weak typeof(self) weakSelf = self;
    self.eventMonitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                     handler:^NSEvent *(NSEvent *evt) {
                                       __strong typeof(weakSelf) s = weakSelf;
                                       if (!s)
                                         return evt;
                                       if (evt.window != s.window)
                                         return evt;
                                       NSString *chars =
                                           evt.charactersIgnoringModifiers;
                                       NSEventModifierFlags mods =
                                           evt.modifierFlags &
                                           NSEventModifierFlagDeviceIndependentFlagsMask;
                                       BOOL cmd =
                                           (mods &
                                            NSEventModifierFlagCommand) != 0;
                                       BOOL shift =
                                           (mods & NSEventModifierFlagShift) !=
                                           0;
                                       if ([chars isEqualToString:@" "] &&
                                           !cmd && s.onTogglePlayback) {
                                         s.onTogglePlayback();
                                         return nil;
                                       }
                                       if (cmd && [[chars lowercaseString]
                                                      isEqualToString:@"z"]) {
                                         if (shift) {
                                           if (s.onRedo) {
                                             s.onRedo();
                                             return nil;
                                           }
                                         } else if (s.onUndo) {
                                           s.onUndo();
                                           return nil;
                                         }
                                       }
                                       return evt;
                                     }];
  } else if (!self.window && self.eventMonitor) {
    [NSEvent removeMonitor:self.eventMonitor];
    self.eventMonitor = nil;
  }
}

- (void)dealloc {
  if (_eventMonitor)
    [NSEvent removeMonitor:_eventMonitor];
}

@end
