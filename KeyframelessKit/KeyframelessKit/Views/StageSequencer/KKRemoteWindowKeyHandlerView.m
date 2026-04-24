/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
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
                                       if (evt.window == s.window &&
                                           [evt.charactersIgnoringModifiers
                                               isEqualToString:@" "] &&
                                           s.onTogglePlayback) {
                                         s.onTogglePlayback();
                                         return nil;
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
