/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMiniViewerGuideScroll.h"

#import "KKMiniViewerView.h"

@implementation KKMiniViewerGuideScroll {
  __weak KKMiniViewerView *_canvas;
  BOOL (^_activeWhen)(void);
  id _scrollLocalMon;
  id _scrollMon;
  id _magnifyLocalMon;
  id _magnifyMon;
}

- (instancetype)initWithCanvas:(KKMiniViewerView *)canvas
                    activeWhen:(BOOL (^)(void))activeWhen {
  self = [super init];
  if (self) {
    _canvas = canvas;
    _activeWhen = [activeWhen copy];
  }
  return self;
}

- (void)dealloc {
  [self teardown];
}

- (void)teardown {
  for (id m in @[
         _scrollLocalMon ?: @0, _scrollMon ?: @0, _magnifyLocalMon ?: @0,
         _magnifyMon ?: @0
       ])
    if (![m isEqual:@0])
      [NSEvent removeMonitor:m];
  _scrollLocalMon = _scrollMon = _magnifyLocalMon = _magnifyMon = nil;
}

- (void)install {
  [self teardown];
  __weak typeof(self) weak = self;
  void (^route)(NSEvent *, BOOL) = ^(NSEvent *e, BOOL pinch) {
    __strong typeof(self) s = weak;
    if (!s || !s->_activeWhen())
      return;
    KKMiniViewerView *c = s->_canvas;
    if (!c || ![c pointerOverCanvas])
      return;
    if (pinch)
      [c applyMagnifyEvent:e];
    else
      [c applyScrollEvent:e];
  };
  NSEvent * (^scrollLocal)(NSEvent *) = ^NSEvent *(NSEvent *e) {
    route(e, NO);
    return e;
  };
  NSEvent * (^magnifyLocal)(NSEvent *) = ^NSEvent *(NSEvent *e) {
    route(e, YES);
    return e;
  };
  _scrollLocalMon =
      [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel
                                            handler:scrollLocal];
  _scrollMon =
      [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskScrollWheel
                                             handler:^(NSEvent *e) {
                                               route(e, NO);
                                             }];
  _magnifyLocalMon =
      [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMagnify
                                            handler:magnifyLocal];
  _magnifyMon =
      [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskMagnify
                                             handler:^(NSEvent *e) {
                                               route(e, YES);
                                             }];
}

@end
