/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPopoverKeepAlive.h"

#import "KKLocalized.h"
#import "KKLog.h"
#import "NSColor+KKColors.h"

NSNotificationName const KKStaticValuesPopoverDidOpenNotification =
    @"KKStaticValuesPopoverDidOpenNotification";
NSNotificationName const KKStaticValuesPopoverDidCloseNotification =
    @"KKStaticValuesPopoverDidCloseNotification";
NSNotificationName const KKStaticValuesPopoverDidNavigateNotification =
    @"KKStaticValuesPopoverDidNavigateNotification";
NSNotificationName const KKStaticValuesSidebarVisibilityDidChangeNotification =
    @"KKStaticValuesSidebarVisibilityDidChangeNotification";

@interface _KKGlobalKeyCapture : NSObject
- (instancetype)initWithHandler:(BOOL (^)(NSEvent *event))handler;
- (void)invalidate;
@end

@implementation _KKGlobalKeyCapture {
  CFMachPortRef _tap;
  CFRunLoopSourceRef _source;
  BOOL (^_handler)(NSEvent *event);
}

static CGEventRef KKGlobalKeyCaptureCallback(CGEventTapProxy proxy,
                                             CGEventType type, CGEventRef event,
                                             void *context) {
  _KKGlobalKeyCapture *capture = (__bridge _KKGlobalKeyCapture *)context;
  if (type == kCGEventTapDisabledByTimeout ||
      type == kCGEventTapDisabledByUserInput) {
    if (capture->_tap)
      CGEventTapEnable(capture->_tap, true);
    return event;
  }
  if (type != kCGEventKeyDown && type != kCGEventKeyUp)
    return event;
  NSEvent *keyEvent = [NSEvent eventWithCGEvent:event];
  return (keyEvent && capture->_handler && capture->_handler(keyEvent)) ? NULL
                                                                        : event;
}

- (instancetype)initWithHandler:(BOOL (^)(NSEvent *event))handler {
  if (!(self = [super init]))
    return nil;
  _handler = [handler copy];
  CGEventMask mask =
      CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp);
  _tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                          kCGEventTapOptionDefault, mask,
                          KKGlobalKeyCaptureCallback, (__bridge void *)self);
  if (!_tap)
    return nil;
  _source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _tap, 0);
  if (!_source) {
    CFRelease(_tap);
    _tap = NULL;
    return nil;
  }
  CFRunLoopAddSource(CFRunLoopGetMain(), _source, kCFRunLoopCommonModes);
  CGEventTapEnable(_tap, true);
  return self;
}

- (void)invalidate {
  _handler = nil;
  if (_source) {
    CFRunLoopRemoveSource(CFRunLoopGetMain(), _source, kCFRunLoopCommonModes);
    CFRelease(_source);
    _source = NULL;
  }
  if (_tap) {
    CGEventTapEnable(_tap, false);
    CFRelease(_tap);
    _tap = NULL;
  }
}

- (void)dealloc {
  [self invalidate];
}

@end

id KKInstallGlobalKeyCapture(BOOL (^handler)(NSEvent *event)) {
  if (!handler)
    return nil;
  _KKGlobalKeyCapture *capture =
      [[_KKGlobalKeyCapture alloc] initWithHandler:handler];
  if (!capture)
    KKLogWarn(@"[Shortcuts] Could not install consuming global key capture");
  return capture;
}

void KKRemoveGlobalKeyCapture(id token) {
  if ([token isKindOfClass:[_KKGlobalKeyCapture class]])
    [(id)token invalidate];
}

@implementation KKPopoverPeekButton {
  BOOL _holding;
  id _mouseUpLocalMonitor;
  id _mouseUpGlobalMonitor;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

- (void)mouseDown:(NSEvent *)event {
  if (!self.onHoldChanged) {
    [super mouseDown:event];
    return;
  }
  if (_holding)
    return;
  _holding = YES;
  self.highlighted = YES;

  // Arm release BEFORE the callback hides or parks the editor window.
  // ViewBridge can reroute the matching mouse-up to FCP as soon as that
  // happens; adding monitors afterwards leaves a small but real gap where the
  // release is lost.
  __weak typeof(self) weak = self;
  _mouseUpLocalMonitor =
      [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseUp
                                            handler:^NSEvent *(NSEvent *e) {
                                              [weak _endHold];
                                              return e;
                                            }];
  _mouseUpGlobalMonitor =
      [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseUp
                                             handler:^(NSEvent *e) {
                                               [weak _endHold];
                                             }];
  self.onHoldChanged(YES);
}

- (void)_endHold {
  [self _removeHoldMonitors];
  if (!_holding)
    return;
  _holding = NO;
  self.highlighted = NO;
  if (self.onHoldChanged)
    self.onHoldChanged(NO);
}

- (void)_removeHoldMonitors {
  if (_mouseUpLocalMonitor) {
    [NSEvent removeMonitor:_mouseUpLocalMonitor];
    _mouseUpLocalMonitor = nil;
  }
  if (_mouseUpGlobalMonitor) {
    [NSEvent removeMonitor:_mouseUpGlobalMonitor];
    _mouseUpGlobalMonitor = nil;
  }
}

- (void)dealloc {
  [self _removeHoldMonitors];
}

@end

KKPopoverPeekButton *
KKCreateCompositionPeekButton(void (^onHoldChanged)(BOOL held)) {
  KKPopoverPeekButton *button = [KKPopoverPeekButton buttonWithTitle:@""
                                                              target:nil
                                                              action:nil];
  button.translatesAutoresizingMaskIntoConstraints = NO;
  button.bordered = NO;
  button.bezelStyle = NSBezelStyleShadowlessSquare;
  button.imageScaling = NSImageScaleProportionallyDown;
  NSString *label = KKLoc(@"View composition",
                          @"Accessibility label for the button held to hide "
                           "an editor panel and reveal Final Cut's viewer.");
  button.image = [NSImage imageWithSystemSymbolName:@"rectangle.on.rectangle"
                           accessibilityDescription:label];
  button.accessibilityLabel = label;
  button.toolTip = KKLoc(@"Hold to view the full composition. (P)",
                         @"Tooltip for the composition-peek button in an "
                          "editor panel header.");
  button.onHoldChanged = onHoldChanged;
  return button;
}

@implementation KKPopoverSidebarButton

- (void)setSidebarVisible:(BOOL)sidebarVisible {
  _sidebarVisible = sidebarVisible;
  self.state = sidebarVisible ? NSControlStateValueOn : NSControlStateValueOff;
  // Off matches the adjacent close and peek buttons' normal AppKit tint. Only
  // the selected state needs a deliberate host-accent colour.
  self.contentTintColor = sidebarVisible ? [NSColor accentMatchingHost] : nil;
}

- (void)_sidebarClicked:(id)sender {
  self.sidebarVisible = !self.sidebarVisible;
  if (self.onVisibilityChanged)
    self.onVisibilityChanged(self.sidebarVisible);
}

@end

KKPopoverSidebarButton *
KKCreateSidebarVisibilityButton(BOOL visible,
                                void (^onVisibilityChanged)(BOOL visible)) {
  KKPopoverSidebarButton *button = [KKPopoverSidebarButton buttonWithTitle:@""
                                                                    target:nil
                                                                    action:nil];
  button.translatesAutoresizingMaskIntoConstraints = NO;
  button.bordered = NO;
  button.bezelStyle = NSBezelStyleShadowlessSquare;
  button.imageScaling = NSImageScaleProportionallyDown;
  NSString *label =
      KKLoc(@"Show templates or layers",
            @"Accessibility label for the editor sidebar toggle.");
  button.image = [NSImage imageWithSystemSymbolName:@"sidebar.left"
                           accessibilityDescription:label];
  button.accessibilityLabel = label;
  button.toolTip = KKLoc(@"Show or hide templates/layers. (L)",
                         @"Tooltip for the editor sidebar toggle.");
  button.target = button;
  button.action = @selector(_sidebarClicked:);
  [button.cell sendActionOn:NSEventMaskLeftMouseDown];
  button.onVisibilityChanged = onVisibilityChanged;
  button.sidebarVisible = visible;
  return button;
}

KKPopoverSidebarButton *
KKCreateRightPanelVisibilityButton(BOOL visible,
                                   void (^onVisibilityChanged)(BOOL visible)) {
  KKPopoverSidebarButton *button =
      KKCreateSidebarVisibilityButton(visible, onVisibilityChanged);
  NSString *label = KKLoc(@"Show grading panel",
                          @"Accessibility label for a plugin's optional right "
                           "editor panel toggle.");
  button.image = [NSImage imageWithSystemSymbolName:@"sidebar.right"
                           accessibilityDescription:label];
  button.accessibilityLabel = label;
  button.toolTip = KKLoc(@"Show or hide the grading panel. (G)",
                         @"Tooltip for Mirage's grading-panel toggle.");
  return button;
}

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

void KKPostStaticValuesEditorDidOpen(NSWindow *window, NSView *contentView,
                                     id sender, NSString *kind, BOOL isBoundary,
                                     double fraction) {
  NSMutableDictionary *info = [NSMutableDictionary dictionary];
  if (window)
    info[@"window"] = window;
  if (contentView) {
    info[@"contentView"] = contentView;
    NSWindow *liveWindow = contentView.window ?: window;
    if (liveWindow) {
      NSRect rect = [liveWindow
          convertRectToScreen:[contentView convertRect:contentView.bounds
                                                toView:nil]];
      info[@"contentRect"] = [NSValue valueWithRect:rect];
    }
  }
  info[@"isBoundary"] = @(isBoundary);
  info[@"fraction"] = @(fraction);
  info[@"kind"] = kind ?: @"constants";
  BOOL sidebarVisible = YES;
  if ([sender respondsToSelector:NSSelectorFromString(@"editorSidebarVisible")])
    sidebarVisible = [[sender valueForKey:@"editorSidebarVisible"] boolValue];
  info[@"sidebarVisible"] = @(sidebarVisible);
  [NSNotificationCenter.defaultCenter
      postNotificationName:KKStaticValuesPopoverDidOpenNotification
                    object:sender
                  userInfo:info];
}

void KKPostStaticValuesSidebarVisibility(NSWindow *window, NSView *contentView,
                                         id sender, NSString *kind,
                                         BOOL isBoundary, double fraction,
                                         BOOL visible) {
  NSMutableDictionary *info = [NSMutableDictionary dictionary];
  if (window)
    info[@"window"] = window;
  if (contentView) {
    info[@"contentView"] = contentView;
    NSWindow *liveWindow = contentView.window ?: window;
    if (liveWindow) {
      NSRect rect = [liveWindow
          convertRectToScreen:[contentView convertRect:contentView.bounds
                                                toView:nil]];
      info[@"contentRect"] = [NSValue valueWithRect:rect];
    }
  }
  info[@"isBoundary"] = @(isBoundary);
  info[@"fraction"] = @(fraction);
  info[@"kind"] = kind ?: @"constants";
  info[@"visible"] = @(visible);
  [NSNotificationCenter.defaultCenter
      postNotificationName:KKStaticValuesSidebarVisibilityDidChangeNotification
                    object:sender
                  userInfo:info];
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
