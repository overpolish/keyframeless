/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineLanesView_Popovers.h"
#import <QuartzCore/QuartzCore.h>

@implementation KKTimelineLanesView (PopoversInternal)

- (void)_showManagePopoverFromView:(NSView *)anchorView {
  NSSet<NSString *> *checked = [self _optedInLabelsSet];
  __weak typeof(self) weak = self;

  __block _KKManagePopoverView *manageView = nil;
  manageView = [[_KKManagePopoverView alloc]
      initWithLanes:_availableLanes
      checkedLabels:checked
           onToggle:^(NSString *label) {
             __strong typeof(weak) s = weak;
             if (!s)
               return;
             if ([s _laneForLabel:label]) {
               [s _optOutLaneWithLabel:label];
             } else {
               [s _optInLaneWithLabel:label
                               values:[s _defaultValuesForLabel:label]];
               if (s.onLaneOptedIn)
                 s.onLaneOptedIn(label);
             }
             [manageView updateCheckedLabels:[s _optedInLabelsSet]];
           }];

  _openManageView = manageView;

  NSPopover *pop = [self _showPopoverWithContent:manageView
                                        fromView:anchorView
                                         onClose:^{
                                           __strong typeof(weak) s = weak;
                                           if (!s)
                                             return;
                                           s->_openManageView = nil;
                                           if (s.onManagePopoverClosed)
                                             s.onManagePopoverClosed();
                                         }];
  _openManagePopover = pop;

  if (self.onManagePopoverWillOpen) {
    NSString *targetLabel =
        self.managePopoverSpotlightLabel ?: _availableLanes.firstObject.label;
    __weak _KKManagePopoverView *weakManage = _openManageView;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          __strong typeof(weak) strong = weak;
          __strong _KKManagePopoverView *mv = weakManage;
          if (!strong || !mv || !targetLabel)
            return;
          NSView *targetRow = [mv rowViewForLabel:targetLabel];
          if (targetRow && strong.onManagePopoverWillOpen)
            strong.onManagePopoverWillOpen(targetRow);
        });
  }
}

- (NSPopover *)_showPopoverWithContent:(NSView *)content
                              fromView:(NSView *)anchor
                               onClose:(void (^)(void))onClose {
  _KKLVPopoverContentView *wrapper = [[_KKLVPopoverContentView alloc] init];
  wrapper.frame = content.bounds;
  content.translatesAutoresizingMaskIntoConstraints = NO;
  [wrapper addSubview:content];
  [NSLayoutConstraint activateConstraints:@[
    [content.leadingAnchor constraintEqualToAnchor:wrapper.leadingAnchor],
    [content.trailingAnchor constraintEqualToAnchor:wrapper.trailingAnchor],
    [content.topAnchor constraintEqualToAnchor:wrapper.topAnchor],
    [content.bottomAnchor constraintEqualToAnchor:wrapper.bottomAnchor],
  ]];

  NSViewController *vc = [[NSViewController alloc] init];
  vc.view = wrapper;

  NSPopover *popover = [[NSPopover alloc] init];
  // ApplicationDefined instead of Transient: Transient closes the popover if
  // ANY event targets a different window — ViewBridge-routed clicks from FCP
  // target the inspector window, not the popover, triggering that immediately.
  // We replicate outside-click close with local + global mouseDown monitors.
  popover.behavior = NSPopoverBehaviorApplicationDefined;
  popover.contentViewController = vc;

  [popover showRelativeToRect:anchor.bounds
                       ofView:anchor
                preferredEdge:NSRectEdgeMinY];

  NSWindow *popoverWindow = popover.contentViewController.view.window;
  CFTimeInterval shownAt = CACurrentMediaTime();
  __weak NSPopover *weakPopover = popover;
  __block id localMon = nil;
  __block id globalMon = nil;
  __block id mouseLocalMon = nil;
  __block id mouseGlobalMon = nil;

  void (^removeMonitors)(void) = ^{
    if (localMon) {
      [NSEvent removeMonitor:localMon];
      localMon = nil;
    }
    if (globalMon) {
      [NSEvent removeMonitor:globalMon];
      globalMon = nil;
    }
    if (mouseLocalMon) {
      [NSEvent removeMonitor:mouseLocalMon];
      mouseLocalMon = nil;
    }
    if (mouseGlobalMon) {
      [NSEvent removeMonitor:mouseGlobalMon];
      mouseGlobalMon = nil;
    }
  };

  __block id closeObs = [NSNotificationCenter.defaultCenter
      addObserverForName:NSPopoverWillCloseNotification
                  object:popover
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification *n) {
                removeMonitors();
                if (onClose)
                  onClose();
                [NSNotificationCenter.defaultCenter removeObserver:closeObs];
              }];

  localMon =
      [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel
                                            handler:^NSEvent *(NSEvent *e) {
                                              if (e.window != popoverWindow)
                                                [weakPopover close];
                                              return e;
                                            }];

  globalMon =
      [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskScrollWheel
                                             handler:^(NSEvent *e) {
                                               [weakPopover close];
                                             }];

  // Replaces Transient's built-in outside-click close. Without the joyride
  // overlay, clicks in the XPC custom view are local events; clicks elsewhere
  // in FCP are global events. Both monitors are needed to cover all cases.
  void (^closeIfOutsidePopover)(void) = ^{
    NSWindow *pw = [weakPopover contentViewController].view.window;
    if (pw && NSPointInRect(NSEvent.mouseLocation, pw.frame))
      return;
    [weakPopover close];
  };
  mouseLocalMon = [NSEvent
      addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
                                   handler:^NSEvent *(NSEvent *e) {
                                     // ViewBridge delivers the real click as a
                                     // local event ~50-100ms after the joyride
                                     // global monitor fires; ignore events in
                                     // that window to avoid false-closing the
                                     // popover.
                                     if (CACurrentMediaTime() - shownAt < 0.2)
                                       return e;
                                     if (e.window != popoverWindow)
                                       closeIfOutsidePopover();
                                     return e;
                                   }];
  mouseGlobalMon =
      [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
                                             handler:^(NSEvent *e) {
                                               closeIfOutsidePopover();
                                             }];

  return popover;
}

@end

@implementation KKTimelineLanesView (Popovers)

- (void)closeManagePopover {
  [_openManagePopover close];
}

- (void)showStaticValuesPopoverFromView:(NSView *)anchor {
  NSArray<KKLane *> *unopted = [self _unoptedLanes];
  if (unopted.count == 0)
    return;
  __weak typeof(self) weak = self;

  _KKStaticValuesPopoverView *staticView =
      [[_KKStaticValuesPopoverView alloc] initWithLanes:unopted];
  _openStaticView = staticView;

  NSPopover *popover = [self _showPopoverWithContent:staticView
                                            fromView:anchor
                                             onClose:^{
                                               __strong typeof(weak) s = weak;
                                               if (s)
                                                 s->_openStaticView = nil;
                                             }];
  staticView.popover = popover;
}

@end
