/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "KKJoyrideController.h"
#import "KKJoyrideController_Internal.h"

NS_ASSUME_NONNULL_BEGIN

@interface KKJoyrideController () {
@protected
  __weak NSView *_hostView;
  NSArray<KKJoyrideStep *> *_steps;
  NSInteger _currentIndex;
  void (^_onComplete)(void);
  void (^_passthroughActivationHandler)(void);
  NSPanel *_panel;
  __weak _KKJoyrideOverlayView *_overlay;
  id _globalMonitor;
  id _keyMonitor;
  id _localKeyMonitor;
  id _dragMonitor;
  id _localDragMonitor;
  id _localMouseDownMonitor;
  id _globalMoveMonitor;
  id _localMoveMonitor;
  BOOL _active;
  BOOL _syntheticDragActive;
  NSMutableArray *_focusObservers;
  NSArray<NSWindow *> *_hostPassthroughWindows;
}
@end

/// Event-monitor machinery (mouse/key/drag global+local monitors and the
/// pass-through forwarding) - implemented in KKJoyrideController+Monitors.m.
@interface KKJoyrideController (Monitors)
/// Current step, or nil past the end.
- (nullable KKJoyrideStep *)_currentStep;
- (void)_installGlobalMonitor;
- (void)_removeGlobalMonitor;
- (void)_installDragMonitor;
- (void)_handleGlobalMouseDown:(NSEvent *)event;
- (void)_handleLocalMouseDown:(NSEvent *)event;
- (void)_handleSyntheticDragEvent:(NSEvent *)event source:(NSString *)src;
- (void)_activatePassthroughMouseDownAtScreenPoint:(NSPoint)mouse
                                             async:(BOOL)async;
- (void)_forwardMouseDown:(NSEvent *)event
    toXPCWindowAtScreenPoint:(NSPoint)mouse;
- (BOOL)_event:(NSEvent *)event
    matchesAdvanceCharacter:(NSString *)ch
              requiredFlags:(NSEventModifierFlags)reqFlags;
@end

/// Focus / occlusion dismiss observers - implemented in
/// KKJoyrideController+FocusObservers.m.
@interface KKJoyrideController (FocusObservers)
- (void)_installFocusObservers;
- (void)_installOcclusionDismissObserver;
- (void)_removeFocusObservers;
@end

NS_ASSUME_NONNULL_END
