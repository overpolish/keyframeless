/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKFloatingPanel.h"

#import "KKLog.h"
#import "KKPopoverKeepAlive.h"
#import "KKScopedDefaults.h"
#import "NSColor+KKColors.h"

// Remembered positions are UI state, not per-shader state, so they get their
// own fixed scope rather than the active one. Mirage's active scope carries the
// loaded shader's id, which would give every shader its own panel position.
static NSString *const kPositionScope = @"ui";

static const CGFloat kCardGap = 8.0;
static const CGFloat kCornerRadius = 9.0;
// How much of the panel must land on a screen for a remembered origin to be
// worth restoring. Enough to grab and drag back, so a monitor that went away
// can't strand it.
static const CGFloat kMinVisibleWidth = 90.0;
static const CGFloat kMinVisibleHeight = 44.0;

@implementation KKPanelDragHandleView {
  NSTrackingArea *_cursorArea;
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_cursorArea)
    [self removeTrackingArea:_cursorArea];
  _cursorArea = [[NSTrackingArea alloc]
      initWithRect:self.bounds
           options:NSTrackingMouseEnteredAndExited | NSTrackingCursorUpdate |
                   NSTrackingActiveAlways
             owner:self
          userInfo:nil];
  [self addTrackingArea:_cursorArea];
}

- (void)cursorUpdate:(NSEvent *)event {
  [NSCursor.openHandCursor set];
}

- (void)mouseEntered:(NSEvent *)event {
  [NSCursor.openHandCursor set];
}

- (void)mouseExited:(NSEvent *)event {
  [NSCursor.arrowCursor set];
}

@end

@implementation KKFloatingPanel {
  NSString *_positionKey;
  BOOL _dragging;
  /// Cursor screen point minus panel origin at mouseDown, so each tick can
  /// place the panel absolutely under the cursor.
  NSPoint _grabOffset;
  id _dragLocalMonitor;
  id _dragGlobalMonitor;
  BOOL _screenClampScheduled;
}

@synthesize allowsKeyWindow = _allowsKeyWindow;
@synthesize userMovable = _userMovable;
@synthesize keepsEntireFrameVisible = _keepsEntireFrameVisible;

- (instancetype)initWithContentSize:(NSSize)size
                        positionKey:(NSString *)positionKey {
  if ((self =
           [super initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
                            styleMask:NSWindowStyleMaskBorderless |
                                      NSWindowStyleMaskNonactivatingPanel
                              backing:NSBackingStoreBuffered
                                defer:YES])) {
    _positionKey = [positionKey copy];
    self.becomesKeyOnlyIfNeeded = NO;
    self.hasShadow = YES;
    self.releasedWhenClosed = NO;
    // NSPanel defaults this to YES, and in a ViewBridge process activation
    // churns constantly - each deactivation would order the panel out AND drop
    // the parent/child link, orphaning it until the popover was reopened.
    self.hidesOnDeactivate = NO;
    self.backgroundColor = NSColor.clearColor;
    self.opaque = NO;
    self.animationBehavior = NSWindowAnimationBehaviorNone;
    self.movableByWindowBackground = NO; // dragging is handled here, see below
    _userMovable = YES;
  }
  return self;
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
  [self _removeDragMonitors];
}

// Control-only panels are never key by default, deliberately.
//
// Undo is why. A companion panel that takes key takes the keyboard with it, and
// Cmd-Z then goes to a window with no undo stack of its own: the user drags a
// control here, presses Cmd-Z, nothing happens, and the shortcut only starts
// working again once they click back into the popover. Refusing key leaves the
// popover holding the keyboard the whole time, so every host shortcut keeps
// working while this panel is in use.
//
// The panel loses nothing by it: clicks and drags reach its views regardless
// (the style mask is already NonactivatingPanel, and the drags run off event
// monitors), and there is nothing there to type into. Primary editor panels
// explicitly opt in because their number fields, expressions and code editors
// need a field editor; the nonactivating style still keeps Final Cut active.
- (BOOL)canBecomeKeyWindow {
  return _allowsKeyWindow;
}

// Pick the screen that owns the largest portion of `frame`. This is more
// stable than `self.screen` while a window is between displays, and gives a
// deterministic home to a remembered frame after the display arrangement
// changes.
- (NSScreen *)_bestScreenForFrame:(NSRect)frame {
  NSScreen *best = nil;
  CGFloat bestArea = 0.0;
  for (NSScreen *screen in NSScreen.screens) {
    NSRect hit = NSIntersectionRect(frame, screen.visibleFrame);
    CGFloat area = NSWidth(hit) * NSHeight(hit);
    if (!best || area > bestArea) {
      best = screen;
      bestArea = area;
    }
  }
  return best ?: self.screen ?: NSScreen.mainScreen;
}

- (NSRect)_fullyVisibleFrame:(NSRect)frame {
  NSScreen *screen = [self _bestScreenForFrame:frame];
  if (!screen)
    return frame;
  NSRect visible = screen.visibleFrame;
  // Callers size editor content to the screen before it reaches the panel.
  // Still cap defensively so a malformed or stale remembered size cannot make
  // the window impossible to recover.
  frame.size.width = MIN(frame.size.width, NSWidth(visible));
  frame.size.height = MIN(frame.size.height, NSHeight(visible));
  frame.origin.x = MIN(MAX(frame.origin.x, NSMinX(visible)),
                       NSMaxX(visible) - NSWidth(frame));
  frame.origin.y = MIN(MAX(frame.origin.y, NSMinY(visible)),
                       NSMaxY(visible) - NSHeight(frame));
  return frame;
}

- (void)setContentSizeKeepingTopEdge:(NSSize)size {
  NSRect frame = self.frame;
  CGFloat top = NSMaxY(frame);
  frame.size = size;
  frame.origin.y = top - size.height;
  if (_keepsEntireFrameVisible)
    frame = [self _fullyVisibleFrame:frame];
  [self setFrame:frame display:self.isVisible];
}

- (void)_scheduleFullFrameClamp:(NSNotification *)note {
  if (!_keepsEntireFrameVisible || !self.isVisible || _screenClampScheduled)
    return;
  _screenClampScheduled = YES;
  __weak typeof(self) weak = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    __strong typeof(weak) self = weak;
    if (!self)
      return;
    self->_screenClampScheduled = NO;
    if (!self->_keepsEntireFrameVisible || !self.isVisible)
      return;
    NSRect current = self.frame;
    NSRect clamped = [self _fullyVisibleFrame:current];
    if (!NSEqualRects(current, clamped))
      [self setFrame:clamped display:YES];
  });
}

- (void)_installScreenSafetyObserversForParent:(NSWindow *)parent {
  NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
  [nc removeObserver:self name:NSWindowDidMoveNotification object:self];
  [nc removeObserver:self name:NSWindowDidMoveNotification object:parent];
  [nc removeObserver:self name:NSWindowDidResizeNotification object:parent];
  [nc removeObserver:self
                name:NSApplicationDidChangeScreenParametersNotification
              object:NSApp];
  if (!_keepsEntireFrameVisible)
    return;
  [nc addObserver:self
         selector:@selector(_scheduleFullFrameClamp:)
             name:NSWindowDidMoveNotification
           object:self];
  [nc addObserver:self
         selector:@selector(_scheduleFullFrameClamp:)
             name:NSWindowDidMoveNotification
           object:parent];
  [nc addObserver:self
         selector:@selector(_scheduleFullFrameClamp:)
             name:NSWindowDidResizeNotification
           object:parent];
  [nc addObserver:self
         selector:@selector(_scheduleFullFrameClamp:)
             name:NSApplicationDidChangeScreenParametersNotification
           object:NSApp];
}

// Resizable rounded-rect mask. The visual-effect view uses this both to clip
// its material AND to shape the window shadow, so the shadow follows the
// corners instead of the square backing - a plain layer cornerRadius leaves a
// rectangular shadow past them.
static NSImage *KKRoundedMaskImage(CGFloat radius) {
  CGFloat dim = radius * 2.0 + 1.0;
  NSImage *image =
      [NSImage imageWithSize:NSMakeSize(dim, dim)
                     flipped:NO
              drawingHandler:^BOOL(NSRect rect) {
                [NSColor.blackColor set];
                [[NSBezierPath bezierPathWithRoundedRect:rect
                                                 xRadius:radius
                                                 yRadius:radius] fill];
                return YES;
              }];
  image.capInsets = NSEdgeInsetsMake(radius, radius, radius, radius);
  image.resizingMode = NSImageResizingModeStretch;
  return image;
}

- (void)setPanelContentView:(NSView *)content {
  if (!content)
    return;
  content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  if (@available(macOS 26.0, *)) {
    NSGlassEffectView *glass =
        [[NSGlassEffectView alloc] initWithFrame:NSZeroRect];
    glass.cornerRadius = kCornerRadius;
    // An opaque inspector-matched fill under the glass, so the panel reads like
    // the popovers beside it rather than see-through. The glass still clips to
    // the corner radius, keeping the rounded shape and its shadow.
    content.wantsLayer = YES;
    content.layer.backgroundColor =
        [NSColor.inspectorBackground colorWithAlphaComponent:0.5].CGColor;
    glass.contentView = content;
    self.contentView = glass;
    return;
  }
  NSVisualEffectView *fx = [[NSVisualEffectView alloc]
      initWithFrame:NSMakeRect(0, 0, self.frame.size.width,
                               self.frame.size.height)];
  fx.material = NSVisualEffectMaterialContentBackground;
  fx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
  fx.state = NSVisualEffectStateActive;
  fx.wantsLayer = YES;
  fx.layer.borderColor = NSColor.separatorColor.CGColor;
  fx.layer.borderWidth = 1.0;
  fx.maskImage = KKRoundedMaskImage(kCornerRadius);
  content.frame = fx.bounds;
  [fx addSubview:content];
  self.contentView = fx;
}

- (NSPoint)_rememberedOrigin:(BOOL *)outFound {
  if (outFound)
    *outFound = NO;
  id stored = KKScopedDefaultRead(_positionKey, kPositionScope);
  if (![stored isKindOfClass:[NSArray class]] || [stored count] != 2)
    return NSZeroPoint;
  NSArray *pair = stored;
  if (![pair[0] respondsToSelector:@selector(doubleValue)] ||
      ![pair[1] respondsToSelector:@selector(doubleValue)])
    return NSZeroPoint;
  if (outFound)
    *outFound = YES;
  return NSMakePoint([pair[0] doubleValue], [pair[1] doubleValue]);
}

- (void)_rememberOrigin:(NSPoint)origin {
  KKScopedDefaultWrite(@[ @(origin.x), @(origin.y) ], _positionKey,
                       kPositionScope);
}

// A frame is restorable only if enough of it lands on a screen that is still
// attached. Checked against every screen's visibleFrame rather than the union,
// so a frame spanning a gap between two displays doesn't pass on arithmetic
// that no actual screen agrees with.
- (BOOL)_frameIsReachable:(NSRect)frame {
  for (NSScreen *screen in NSScreen.screens) {
    NSRect shown = NSIntersectionRect(frame, screen.visibleFrame);
    if (shown.size.width >= kMinVisibleWidth &&
        shown.size.height >= kMinVisibleHeight)
      return YES;
  }
  return NO;
}

- (NSRect)_frameBesideCard:(NSRect)card {
  NSRect frame = self.frame;
  frame.origin.y = NSMaxY(card) - frame.size.height;
  frame.origin.x = NSMaxX(card) + kCardGap;
  NSScreen *screen = nil;
  for (NSScreen *candidate in NSScreen.screens)
    if (NSIntersectsRect(card, candidate.frame)) {
      screen = candidate;
      break;
    }
  NSRect visible = (screen ?: NSScreen.mainScreen).visibleFrame;
  // No room on the right: flip to the left of the card rather than hanging off.
  if (NSMaxX(frame) > NSMaxX(visible))
    frame.origin.x = NSMinX(card) - kCardGap - frame.size.width;
  frame.origin.x = MAX(frame.origin.x, NSMinX(visible));
  frame.origin.y = MIN(frame.origin.y, NSMaxY(visible) - frame.size.height);
  frame.origin.y = MAX(frame.origin.y, NSMinY(visible));
  return frame;
}

- (void)showBesideCard:(NSRect)card ofWindow:(NSWindow *)parent {
  if (!parent)
    return;
  BOOL found = NO;
  NSPoint remembered = [self _rememberedOrigin:&found];
  NSRect frame = self.frame;
  frame.origin = remembered;
  if (!found || ![self _frameIsReachable:frame]) {
    if (found)
      KKLogInfo(@"[Panel] %@ remembered origin %@ is off-screen, replacing it",
                _positionKey, NSStringFromPoint(remembered));
    frame = [self _frameBesideCard:card];
  }
  if (_keepsEntireFrameVisible)
    frame = [self _fullyVisibleFrame:frame];
  [self setFrame:frame display:NO];
  if (self.parentWindow && self.parentWindow != parent)
    [self.parentWindow removeChildWindow:self];
  if (self.parentWindow != parent)
    [parent addChildWindow:self ordered:NSWindowAbove];
  [self _installScreenSafetyObserversForParent:parent];
  KKPopoverAddKeepAliveWindow(self);
}

- (void)hidePanel {
  _dragging = NO;
  [self _removeDragMonitors];
  KKPopoverRemoveKeepAliveWindow(self);
  [NSNotificationCenter.defaultCenter removeObserver:self];
  [self.parentWindow removeChildWindow:self];
  [self orderOut:nil];
}

// The drag runs on a local+global NSEvent monitor pair, the same mechanism as
// the mini viewer's OSC drags, value-field scrubbing and joyride gestures.
//
// Instrumented in FCP, the reason is delivery, not maths: after the mouseDown,
// the ViewBridge process gets almost NO mouseDragged events addressed to this
// window - one to three per gesture, coalesced, some synthesized with zero
// motion - so anything driven per delivered event crawls a pixel per drag.
// -performWindowDragWithEvent: does nothing at all, since the window server
// won't run a drag session from a forwarded/synthesized mouseDown. The drag
// stream still EXISTS in this process though - it is just addressed to other
// windows (or to none): exactly what NSEvent monitors are for, and why every
// other cross-window gesture here already uses them.
//
// Positioning is ABSOLUTE from the cursor's screen point (origin = cursor -
// grab offset), never integrated per event, so coalescing, duplicate delivery
// through both natural dispatch and the monitor, or a stale frame cannot
// accumulate error - each tick lands the panel where the cursor is.
// Whether a click on `view` belongs to the view rather than to the drag. A
// label is decorative and must NOT hold its own clicks: a title spanning the
// drag handle would otherwise leave only the few points above and below it
// grabbable, which is what a "hairline" drag region means.
static BOOL KKViewWantsItsOwnClicks(NSView *view) {
  if ([view isKindOfClass:[NSTextField class]]) {
    NSTextField *field = (NSTextField *)view;
    return field.isEditable || field.isSelectable;
  }
  return [view isKindOfClass:[NSControl class]] ||
         [view isKindOfClass:[NSTextView class]] ||
         [view isKindOfClass:[NSTableView class]] ||
         [view isKindOfClass:[NSScrollView class]];
}

- (BOOL)_shouldStartDragForEvent:(NSEvent *)event {
  if (!_userMovable)
    return NO;
  NSView *content = self.contentView;
  if (!content)
    return NO;
  NSPoint local = [content convertPoint:event.locationInWindow fromView:nil];
  // hitTest: returns the DEEPEST view under the point, so a handle with any
  // subview at all is never itself the hit - hence the descendant test.
  NSView *hit = [content hitTest:local];
  if (!hit)
    return NO;
  if (KKViewWantsItsOwnClicks(hit))
    return NO;
  if (self.dragHandleView)
    return hit == self.dragHandleView ||
           [hit isDescendantOf:self.dragHandleView];
  // No explicit handle: drag from anything that doesn't want the click itself.
  return YES;
}

// The cursor in AppKit screen coordinates, taken from the underlying CGEvent.
//
// NOT via `[event.window convertPointToScreen:event.locationInWindow]`: during
// a drag the event's window is often THIS panel, whose frame is what the drag
// is changing, so the conversion mixes a location measured against the old
// frame with the new one and the panel scatters across the screen.
// CGEventGetLocation is in global display space and owes nothing to any window,
// so it is immune - and unlike NSEvent's global-state queries it is carried by
// the event itself, which is what makes it usable inside a plugin's XPC
// process.
//
// Global display space has its origin at the TOP-left of the primary display
// and y grows downward, hence the flip into AppKit's bottom-left screen space.
static NSPoint KKCursorScreenPoint(NSEvent *event) {
  CGEventRef cg = event.CGEvent;
  if (cg) {
    CGPoint global = CGEventGetLocation(cg);
    NSScreen *primary = NSScreen.screens.firstObject;
    return NSMakePoint(global.x, NSMaxY(primary.frame) - global.y);
  }
  // No CGEvent backing (a fully synthesized NSEvent): fall back to the event's
  // own window, and to raw screen space for a global monitor's window-less one.
  return event.window
             ? [event.window convertPointToScreen:event.locationInWindow]
             : event.locationInWindow;
}

- (void)_dragTickAtScreenPoint:(NSPoint)screenPoint {
  if (!_dragging)
    return;
  NSRect frame = self.frame;
  frame.origin =
      NSMakePoint(screenPoint.x - _grabOffset.x, screenPoint.y - _grabOffset.y);
  if (_keepsEntireFrameVisible)
    frame = [self _fullyVisibleFrame:frame];
  [self setFrameOrigin:frame.origin];
}

- (void)_endDrag {
  if (!_dragging)
    return;
  _dragging = NO;
  [self _removeDragMonitors];
  [self _rememberOrigin:self.frame.origin];
  if (self.onUserMoved)
    self.onUserMoved(self.frame.origin);
}

- (void)_installDragMonitors {
  __weak KKFloatingPanel *weak = self;
  NSEventMask mask = NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp;
  if (!_dragGlobalMonitor)
    _dragGlobalMonitor = [NSEvent
        addGlobalMonitorForEventsMatchingMask:mask
                                      handler:^(NSEvent *e) {
                                        if (e.type == NSEventTypeLeftMouseUp)
                                          [weak _endDrag];
                                        else
                                          [weak _dragTickAtScreenPoint:
                                                    KKCursorScreenPoint(e)];
                                      }];
  if (!_dragLocalMonitor)
    _dragLocalMonitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:mask
                                     handler:^NSEvent *(NSEvent *e) {
                                       __strong KKFloatingPanel *s = weak;
                                       if (!s)
                                         return e;
                                       if (e.type == NSEventTypeLeftMouseUp) {
                                         [s _endDrag];
                                         return e;
                                       }
                                       [s _dragTickAtScreenPoint:
                                               KKCursorScreenPoint(e)];
                                       return e;
                                     }];
}

- (void)_removeDragMonitors {
  if (_dragGlobalMonitor) {
    [NSEvent removeMonitor:_dragGlobalMonitor];
    _dragGlobalMonitor = nil;
  }
  if (_dragLocalMonitor) {
    [NSEvent removeMonitor:_dragLocalMonitor];
    _dragLocalMonitor = nil;
  }
}

- (void)sendEvent:(NSEvent *)event {
  if (event.type == NSEventTypeLeftMouseDown &&
      [self _shouldStartDragForEvent:event]) {
    // The mouseDown DOES reach this window (forwarded by the kit's click
    // machinery), so it anchors the grab; everything after comes from the
    // monitors. A prior drag whose mouse-up never arrived - the known
    // ViewBridge hazard - ends here at the next press instead of sticking.
    [self _endDrag];
    // Same cursor source as every tick, so the two sides of the subtraction can
    // never disagree about which space they are in.
    NSPoint cursor = KKCursorScreenPoint(event);
    _grabOffset = NSMakePoint(cursor.x - self.frame.origin.x,
                              cursor.y - self.frame.origin.y);
    _dragging = YES;
    [self _installDragMonitors];
  }
  [super sendEvent:event];
}

@end
