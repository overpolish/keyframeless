/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKJoyrideController_Private.h"
#import "KKLog.h"

static const NSEventModifierFlags kJoyrideModifierMask =
    NSEventModifierFlagShift | NSEventModifierFlagControl |
    NSEventModifierFlagOption | NSEventModifierFlagCommand;

@implementation KKJoyrideController (Monitors)

- (KKJoyrideStep *)_currentStep {
  return (_currentIndex < (NSInteger)_steps.count) ? _steps[_currentIndex]
                                                   : nil;
}

- (BOOL)_event:(NSEvent *)event
    matchesAdvanceCharacter:(NSString *)ch
              requiredFlags:(NSEventModifierFlags)reqFlags {
  NSString *pressed = [event.charactersIgnoringModifiers lowercaseString];
  return [pressed isEqualToString:ch] &&
         (event.modifierFlags & kJoyrideModifierMask) == reqFlags;
}

// Called when a click lands inside a pass-through spotlight — fires the step's
// spotlightMouseDown block and arms the drag monitors. global=YES means the
// click arrived on a background thread (global monitor) and must dispatch to
// main before calling the block; local monitors already run on main.
- (void)_activatePassthroughMouseDownAtScreenPoint:(NSPoint)mouse
                                             async:(BOOL)async {
  void (^downBlock)(NSPoint) = [self _currentStep].spotlightMouseDown;
  if (!downBlock)
    return;
  KKLogInfo(@"[Joyride] synthetic mouseDown at (%.1f,%.1f)", mouse.x, mouse.y);
  if (async) {
    dispatch_async(dispatch_get_main_queue(), ^{
      downBlock(mouse);
    });
  } else {
    downBlock(mouse);
  }
  [self _installDragMonitor];
}

// In ViewBridge XPC the panel blocks normal click delivery to XPC windows.
// Forward clicks inside the spotlight cutout to the appropriate XPC window.
// Skipped for pass-through steps (OSC / viewer) — ignoresMouseEvents lets the
// click reach the host app naturally.
- (void)_forwardMouseDown:(NSEvent *)event
    toXPCWindowAtScreenPoint:(NSPoint)mouse {
  NSWindow *extra = self.additionalPassthroughWindow;
  NSWindow *host = _hostView.window;
  NSWindow *target =
      (extra && NSPointInRect(mouse, extra.frame)) ? extra : host;
  if (!target)
    return;
  NSPoint winPt = [target convertPointFromScreen:mouse];
  NSEvent *fwd = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                    location:winPt
                               modifierFlags:event.modifierFlags
                                   timestamp:event.timestamp
                                windowNumber:target.windowNumber
                                     context:nil
                                 eventNumber:event.eventNumber
                                  clickCount:event.clickCount
                                    pressure:event.pressure];
  [target sendEvent:fwd];
}

- (void)_handleGlobalMouseDown:(NSEvent *)event {
  NSPoint mouse = NSEvent.mouseLocation;
  KKLogInfo(@"[Joyride] globalMonitor mouseDown at (%.1f,%.1f) step=%ld",
            mouse.x, mouse.y, (long)_currentIndex);
  NSRect nextRect = [_overlay screenNextRect];
  NSRect actionRect = [_overlay screenActionRect];
  NSRect spotRect = [_overlay screenSpotRect];
  KKLogInfo(@"[Joyride] branch check mouse=(%.1f,%.1f) nextRect=%@ "
            @"actionRect=%@ spotRect=%@ passThrough=%d",
            mouse.x, mouse.y, NSStringFromRect(nextRect),
            NSStringFromRect(actionRect), NSStringFromRect(spotRect),
            (int)_overlay.spotlightPassThrough);

  // On a pass-through step the spotlight is the primary interaction target
  // (the OSC handle lives under it). Checking buttons first would let Skip/
  // Next steal an OSC click. So for pass-through steps the spotlight wins:
  // a click inside it is never treated as a button press.
  BOOL spotFirst = _overlay.spotlightPassThrough && !NSIsEmptyRect(spotRect) &&
                   NSPointInRect(mouse, spotRect);
  if (!spotFirst) {
    if (!NSIsEmptyRect(nextRect) && NSPointInRect(mouse, nextRect)) {
      KKLogInfo(@"[Joyride] → hit NEXT button, advancing");
      if (_overlay.onNext)
        _overlay.onNext();
      return;
    }
    if (!NSIsEmptyRect(actionRect) && NSPointInRect(mouse, actionRect)) {
      KKLogInfo(@"[Joyride] → hit SKIP/DONE button, aborting guide");
      if (_overlay.onSkip)
        _overlay.onSkip();
      return;
    }
  } else {
    KKLogInfo(@"[Joyride] → spotlight wins (passthrough), skipping button "
              @"checks");
  }

  NSRect spotScreen = [_overlay screenSpotRect];
  if (NSIsEmptyRect(spotScreen) || !NSPointInRect(mouse, spotScreen)) {
    KKLogInfo(@"[Joyride] → click outside spotlight, ignored (passthrough "
              @"lets it reach FCP if windows allow)");
    return;
  }
  KKLogInfo(@"[Joyride] → click INSIDE spotlight");

  if (_overlay.spotlightPassThrough) {
    [self _activatePassthroughMouseDownAtScreenPoint:mouse async:YES];
    return;
  }
  [self _forwardMouseDown:event toXPCWindowAtScreenPoint:mouse];
}

// Local monitor catches clicks that land in our own XPC process instead of
// FCP — this happens for pass-through steps when an XPC window sits above
// the FCP viewer at the spotlight position.
- (void)_handleLocalMouseDown:(NSEvent *)event {
  NSPoint mouse = NSEvent.mouseLocation;
  KKLogInfo(@"[Joyride] localMonitor mouseDown at (%.1f,%.1f) step=%ld",
            mouse.x, mouse.y, (long)_currentIndex);
  if (!_overlay.spotlightPassThrough)
    return;
  NSRect spotScreen = [_overlay screenSpotRect];
  if (NSIsEmptyRect(spotScreen) || !NSPointInRect(mouse, spotScreen))
    return;
  [self _activatePassthroughMouseDownAtScreenPoint:mouse async:NO];
}

- (void)_installGlobalMonitor {
  [self _removeGlobalMonitor];
  __weak typeof(self) weak = self;

  KKJoyrideStep *currentStep = [self _currentStep];
  if (currentStep.advanceOnCharacter.length > 0) {
    NSString *ch = [currentStep.advanceOnCharacter lowercaseString];
    NSEventModifierFlags reqFlags =
        currentStep.advanceOnModifierFlags & kJoyrideModifierMask;
    void (^tryAdvance)(NSEvent *) = ^(NSEvent *event) {
      __strong typeof(weak) s = weak;
      if (!s || !s->_active)
        return;
      if (![s _event:event matchesAdvanceCharacter:ch requiredFlags:reqFlags])
        return;
      dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weak) ss = weak;
        if (ss && ss->_active)
          [ss advance];
      });
    };
    _keyMonitor =
        [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                               handler:tryAdvance];
    _localKeyMonitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                     handler:^NSEvent *(NSEvent *event) {
                                       tryAdvance(event);
                                       return event;
                                     }];
  }

  _globalMonitor =
      [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
                                             handler:^(NSEvent *event) {
                                               __strong typeof(weak) s = weak;
                                               if (!s || !s->_active)
                                                 return;
                                               [s _handleGlobalMouseDown:event];
                                             }];

  _localMouseDownMonitor =
      [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
                                            handler:^NSEvent *(NSEvent *event) {
                                              __strong typeof(weak) s = weak;
                                              if (s && s->_active)
                                                [s _handleLocalMouseDown:event];
                                              return event;
                                            }];
}

- (void)_removeGlobalMonitor {
  if (_globalMonitor) {
    [NSEvent removeMonitor:_globalMonitor];
    _globalMonitor = nil;
  }
  if (_keyMonitor) {
    [NSEvent removeMonitor:_keyMonitor];
    _keyMonitor = nil;
  }
  if (_localKeyMonitor) {
    [NSEvent removeMonitor:_localKeyMonitor];
    _localKeyMonitor = nil;
  }
  if (_localMouseDownMonitor) {
    [NSEvent removeMonitor:_localMouseDownMonitor];
    _localMouseDownMonitor = nil;
  }
  if (_dragMonitor) {
    [NSEvent removeMonitor:_dragMonitor];
    _dragMonitor = nil;
  }
  if (_localDragMonitor) {
    [NSEvent removeMonitor:_localDragMonitor];
    _localDragMonitor = nil;
  }
  _syntheticDragActive = NO;
}

- (void)_handleSyntheticDragEvent:(NSEvent *)event source:(NSString *)src {
  if (!_active || !_syntheticDragActive)
    return;
  NSPoint pt = NSEvent.mouseLocation;
  KKJoyrideStep *step =
      (_currentIndex < (NSInteger)_steps.count) ? _steps[_currentIndex] : nil;
  if (event.type == NSEventTypeLeftMouseDragged) {
    void (^dragBlock)(NSPoint) = step.spotlightMouseDragged;
    KKLogInfo(
        @"[Joyride] dragMonitor(%@) dragged idx=%ld hasBlock=%d pt=(%.1f,%.1f)",
        src, (long)_currentIndex, dragBlock != nil, pt.x, pt.y);
    if (dragBlock)
      dispatch_async(dispatch_get_main_queue(), ^{
        dragBlock(pt);
      });
  } else {
    void (^upBlock)(NSPoint) = step.spotlightMouseUp;
    KKLogInfo(
        @"[Joyride] dragMonitor(%@) mouseUp idx=%ld hasBlock=%d pt=(%.1f,%.1f)",
        src, (long)_currentIndex, upBlock != nil, pt.x, pt.y);
    if (upBlock)
      dispatch_async(dispatch_get_main_queue(), ^{
        upBlock(pt);
      });
    _syntheticDragActive = NO;
    if (_dragMonitor) {
      [NSEvent removeMonitor:_dragMonitor];
      _dragMonitor = nil;
    }
    if (_localDragMonitor) {
      [NSEvent removeMonitor:_localDragMonitor];
      _localDragMonitor = nil;
    }
  }
}

- (void)_installDragMonitor {
  if (_dragMonitor && _localDragMonitor)
    return;
  __weak typeof(self) weak = self;
  _syntheticDragActive = YES;
  NSEventMask mask = NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp;
  if (!_dragMonitor)
    _dragMonitor = [NSEvent
        addGlobalMonitorForEventsMatchingMask:mask
                                      handler:^(NSEvent *event) {
                                        __strong typeof(weak) s = weak;
                                        dispatch_async(
                                            dispatch_get_main_queue(), ^{
                                              [s _handleSyntheticDragEvent:event
                                                                    source:
                                                                        @"globa"
                                                                        @"l"];
                                            });
                                      }];
  if (!_localDragMonitor)
    _localDragMonitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:mask
                                     handler:^NSEvent *(NSEvent *event) {
                                       __strong typeof(weak) s = weak;
                                       [s _handleSyntheticDragEvent:event
                                                             source:@"local"];
                                       return event;
                                     }];
}

@end
