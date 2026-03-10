/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKParameterRowView.h"
#import "KKEventForwardingView.h"
#import "KKKeyframeDiamondView.h"
#import "KKMenuChevronView.h"
#import <Cocoa/Cocoa.h>
#import <CoreMedia/CMTime.h>
#import <FxPlug/FxPlugSDK.h>

static const double kKeyframeControlWidth = 80.0;
static const double kMenuChevronWidth = 20.0;
static const double kKeyframeDiamondWidth = 18.0;

@implementation KKParameterRowView {
  BOOL _isHovered;
  // No way for us to know if the host (Motion/FCP) has a context menu open
  // we are in ViewBridge Jail - we can only guess
  BOOL _isContextMenuOpen;
  NSView *_backgroundView;
  KKEventForwardingView *_controlsRegion;
  KKMenuChevronView *_menuChevron;
  KKKeyframeDiamondView *_keyframeDiamond;

  id _globalMonitor;
  id _localMonitor;
  NSInteger _monitorInstallerEventNumber;

  BOOL _isKeyframeDiamondPressed;
}

- (instancetype)initWithFrame:(NSRect)frameRect
                   apiManager:(id<PROAPIAccessing>)apiManager
                  parameterId:(UInt32)parameterId {
  self = [super initWithFrame:frameRect];
  if (self) {
    _apiManager = apiManager;
    _parameterId = parameterId;

    [self setupViews];
    [self setupConstraints];
    [self setupEventHandlers];

    [self updateControlsVisibility];
  }
  return self;
}

- (void)drawRect:(NSRect)dirtyRect {
  // drawRect runs anytime play head moves, keyframe is added/removed, etc
  [super drawRect:dirtyRect];
  [self refreshKeyframeState];
}

- (void)refreshKeyframeState {
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];

  CMTime currentTime = [actionAPI currentTime];
  id<FxKeyframeAPI_v3> keyframeAPI =
      [_apiManager apiForProtocol:@protocol(FxKeyframeAPI_v3)];

  BOOL hasKeyframe = NO;
  [keyframeAPI parameter:_parameterId
                 channel:0
             hasKeyframe:&hasKeyframe
                  atTime:currentTime];

  _keyframeDiamond.keyframeExists = hasKeyframe;

  [actionAPI endAction:self];

  [_keyframeDiamond setNeedsDisplay:YES];
}

- (void)setupViews {
  _backgroundView = [[NSView alloc] initWithFrame:NSZeroRect];
  _backgroundView.translatesAutoresizingMaskIntoConstraints = NO;
  _backgroundView.wantsLayer = YES;
  _backgroundView.layer.backgroundColor = [[NSColor redColor] CGColor];
  [self addSubview:_backgroundView];

  _controlsRegion = [[KKEventForwardingView alloc] initWithFrame:NSZeroRect];
  _controlsRegion.translatesAutoresizingMaskIntoConstraints = NO;
  _controlsRegion.wantsLayer = YES;
  // Effectively clearColor - using clearColor directly causes this NSView to no
  // longer participate in tracking events as all internal content is hidden
  // initially. Adding a pseudo-clear color keeps the view 'alive'
  _controlsRegion.layer.backgroundColor =
      [[[NSColor whiteColor] colorWithAlphaComponent:0.001] CGColor];
  [self addSubview:_controlsRegion];

  _menuChevron = [[KKMenuChevronView alloc] initWithFrame:NSZeroRect];
  _menuChevron.translatesAutoresizingMaskIntoConstraints = NO;
  _menuChevron.wantsLayer = YES;
  [_controlsRegion addSubview:_menuChevron];

  _keyframeDiamond = [[KKKeyframeDiamondView alloc] initWithFrame:NSZeroRect];
  _keyframeDiamond.translatesAutoresizingMaskIntoConstraints = NO;
  _keyframeDiamond.wantsLayer = YES;
  [_controlsRegion addSubview:_keyframeDiamond];
}

- (void)setupConstraints {
  // Layout lag when resizing inspector is most likely down to ViewBridge XPC
  // round-trip, it takes time for our view to get the new size from the host
  // app
  [NSLayoutConstraint activateConstraints:@[
    [_backgroundView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [_backgroundView.topAnchor constraintEqualToAnchor:self.topAnchor],
    [_backgroundView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    [_backgroundView.trailingAnchor
        constraintEqualToAnchor:self.trailingAnchor
                       constant:-kKeyframeControlWidth],

    [_controlsRegion.leadingAnchor
        constraintEqualToAnchor:_backgroundView.trailingAnchor],
    [_controlsRegion.trailingAnchor
        constraintEqualToAnchor:self.trailingAnchor],
    [_controlsRegion.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [_controlsRegion.heightAnchor constraintEqualToAnchor:self.heightAnchor],

    [_menuChevron.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [_menuChevron.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [_menuChevron.widthAnchor constraintEqualToConstant:kMenuChevronWidth],
    [_menuChevron.heightAnchor constraintEqualToAnchor:self.heightAnchor],

    [_keyframeDiamond.trailingAnchor
        constraintEqualToAnchor:_menuChevron.leadingAnchor],
    [_keyframeDiamond.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [_keyframeDiamond.widthAnchor
        constraintEqualToConstant:kKeyframeDiamondWidth],
    [_keyframeDiamond.heightAnchor constraintEqualToAnchor:self.heightAnchor]
  ]];
}

- (void)setupEventHandlers {
  __weak typeof(self) weakSelf = self;
  _controlsRegion.onMouseDown = ^(NSEvent *event) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }

    NSPoint locationInWindow = [event locationInWindow];
    NSPoint locationInRegion =
        [strongSelf->_controlsRegion convertPoint:locationInWindow
                                         fromView:nil];

    if ([strongSelf->_menuChevron hitTest:locationInRegion]) {
      [strongSelf handleMenuChevronClick:event];
    } else if ([strongSelf->_keyframeDiamond hitTest:locationInRegion]) {
      // Hide diamond and let the underlying Motion/FCP button handle state
      [strongSelf handleKeyframeDiamondClick:event];
    }
  };
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];

  for (NSTrackingArea *area in self.trackingAreas) {
    [self removeTrackingArea:area];
  }

  NSTrackingArea *trackingArea = [[NSTrackingArea alloc]
      initWithRect:self.bounds
           options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                   NSTrackingInVisibleRect
             owner:self
          userInfo:nil];
  [self addTrackingArea:trackingArea];
}

/// Updates the diamond's visibility while it is held pressed.
/// When pressed and hovering over the diamond, the host app shows its own
/// state so we hide ours. When pressed but cursor moves away, the row hover
/// effect takes over and we show both controls again.
- (void)updateKeyframeDiamondHoverState:(NSEvent *)event {
  if (!_isKeyframeDiamondPressed) {
    return;
  }

  NSPoint locationInWindow = [event locationInWindow];
  NSPoint locationInRegion = [_controlsRegion convertPoint:locationInWindow
                                                  fromView:nil];

  BOOL diamondHovered = [_keyframeDiamond hitTest:locationInRegion];

  if (diamondHovered) {
    _keyframeDiamond.hidden = YES;
  } else {
    _keyframeDiamond.hidden = NO;
    _menuChevron.hidden = NO;
  }
}

- (void)mouseEntered:(NSEvent *)event {
  if ([NSApp isActive] && !_isContextMenuOpen) {
    _isHovered = YES;
    [self updateControlsVisibility];
    [self updateKeyframeDiamondHoverState:event];
  }
}

- (void)mouseExited:(NSEvent *)event {
  if (!_isContextMenuOpen) {
    _isHovered = NO;
    [self updateControlsVisibility];
    [self updateKeyframeDiamondHoverState:event];
  }
}

- (void)handleMenuChevronClick:(NSEvent *)event {
  if ([self wasSimulatedEvent:event]) {
    return;
  }

  if (event.eventNumber == _monitorInstallerEventNumber) {
    return;
  }

  if (_isContextMenuOpen) {
    // Keyframe region clicked whilst menu is already open
    [self closeMenu];
    return;
  }

  _monitorInstallerEventNumber = event.eventNumber;
  _isContextMenuOpen = YES;
  _isHovered = YES;
  [self updateControlsVisibility];

  // Wait for current mouse click to complete - avoids monitors reacting to the
  // initial click
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        __weak typeof(self) weakSelf = self;
        [weakSelf
            installMonitors:NSEventMaskLeftMouseDown |
                            NSEventMaskRightMouseDown |
                            NSEventMaskOtherMouseDown | NSEventMaskLeftMouseUp |
                            NSEventMaskRightMouseUp | NSEventMaskOtherMouseUp |
                            NSEventMaskKeyDown
               eventHandler:^(NSEvent *event) {
                 __strong typeof(weakSelf) strongSelf = weakSelf;
                 if (!strongSelf) {
                   return;
                 }

                 [strongSelf closeMenu];
               }
                      delay:0.5];
      });
}

- (void)handleKeyframeDiamondClick:(NSEvent *)event {
  if ([self wasSimulatedEvent:event]) {
    return;
  }

  if (event.eventNumber == _monitorInstallerEventNumber) {
    return;
  }

  _monitorInstallerEventNumber = event.eventNumber;
  _isHovered = YES;
  _isKeyframeDiamondPressed = YES;
  [self updateControlsVisibility];
  [self updateKeyframeDiamondHoverState:event];

  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        __weak typeof(self) weakSelf = self;
        [weakSelf installMonitors:NSEventMaskLeftMouseUp
                     eventHandler:^(NSEvent *event) {
                       __strong typeof(weakSelf) strongSelf = weakSelf;
                       if (!strongSelf) {
                         return;
                       }

                       strongSelf->_isKeyframeDiamondPressed = NO;
                       [strongSelf updateControlsVisibility];
                     }
                            delay:0.0];
      });
}

- (void)installMonitors:(NSEventMask)eventMasks
           eventHandler:(void (^)(NSEvent *event))eventHandler
                  delay:(NSTimeInterval)delay {
  [self removeMonitors];

  NSTimeInterval monitorInstallTime = [NSDate timeIntervalSinceReferenceDate];
  __weak typeof(self) weakSelf = self;

  _globalMonitor = [NSEvent
      addGlobalMonitorForEventsMatchingMask:eventMasks
                                    handler:^(NSEvent *event) {
                                      __strong typeof(weakSelf) strongSelf =
                                          weakSelf;
                                      if (strongSelf &&
                                          [strongSelf
                                              shouldHandleEvent:event
                                                    installTime:
                                                        monitorInstallTime
                                                          delay:delay]) {
                                        eventHandler(event);
                                      }
                                    }];

  _localMonitor = [NSEvent
      addLocalMonitorForEventsMatchingMask:eventMasks
                                   handler:^NSEvent *(NSEvent *event) {
                                     __strong typeof(weakSelf) strongSelf =
                                         weakSelf;
                                     if (strongSelf &&
                                         [strongSelf
                                             shouldHandleEvent:event
                                                   installTime:
                                                       monitorInstallTime
                                                         delay:delay]) {
                                       eventHandler(event);
                                     }
                                     return event;
                                   }];
}

- (BOOL)shouldHandleEvent:(NSEvent *)event
              installTime:(NSTimeInterval)monitorInstallTime
                    delay:(NSTimeInterval)delay {
  if ([self wasSimulatedEvent:event]) {
    return NO;
  }

  // If need to wait before handling
  if (delay > 0.0) {
    NSTimeInterval timeSinceInstall =
        [NSDate timeIntervalSinceReferenceDate] - monitorInstallTime;
    if (timeSinceInstall < delay && [self isMouseOverView]) {
      return NO;
    }
  }

  return YES;
}

- (BOOL)wasSimulatedEvent:(NSEvent *)event {
  CGEventRef cgEvent = [event CGEvent];
  if (cgEvent) {
    int64_t userData =
        CGEventGetIntegerValueField(cgEvent, kCGEventSourceUserData);
    if (userData == kSimulatedEventMarker) {
      return YES;
    }
  }
  return NO;
}

/// Marks the menu as closed, updates state and relevant UI.
- (void)closeMenu {
  _isContextMenuOpen = NO;
  _isHovered = [self isMouseOverView];
  [self updateControlsVisibility];
  [self removeMonitors];
}

- (BOOL)isMouseOverView {
  NSPoint mouseLocation = [NSEvent mouseLocation];
  NSPoint windowPoint = [self.window convertPointFromScreen:mouseLocation];
  NSPoint viewPoint = [self convertPoint:windowPoint fromView:nil];
  return [self mouse:viewPoint inRect:self.bounds];
}

- (void)removeMonitors {
  if (_globalMonitor) {
    [NSEvent removeMonitor:_globalMonitor];
    _globalMonitor = nil;
  }
  if (_localMonitor) {
    [NSEvent removeMonitor:_localMonitor];
    _localMonitor = nil;
  }
}

- (void)updateControlsVisibility {
  BOOL visible = _isContextMenuOpen || _isHovered;
  _menuChevron.hidden = !visible;
  _keyframeDiamond.hidden = !visible;
}

- (void)dealloc {
  [self removeMonitors];
}

@end
