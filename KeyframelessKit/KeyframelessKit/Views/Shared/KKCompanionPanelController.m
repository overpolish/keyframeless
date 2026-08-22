/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKCompanionPanelController.h"

#import "KKLog.h"
#import "KKPopoverBackground.h"
#import "KKPopoverKeepAlive.h"
#import "NSColor+KKColors.h"

#import <QuartzCore/QuartzCore.h>

// Panel sits beside the popover card with a small gap, ordered behind the
// popover. Width is per-host; height matches the popover card.
static const CGFloat kPanelGap = 8.0;
// Corner radius of the macOS popover chrome we're matching.
static const CGFloat kPanelCornerRadius = 9.0;
// Hold off until the popover has nearly finished its own entrance, so the two
// don't animate on top of each other.
static const NSTimeInterval kShowDelay = 0.1;
static const NSTimeInterval kFadeDuration = 0.28;
static const CGFloat kSlideDistance = 12.0;

// Borderless panels can't become key by default, which blocks text editing
// (inline rename, search).
@interface _KKCompanionPanel : NSPanel
@end
@implementation _KKCompanionPanel
- (BOOL)canBecomeKeyWindow {
  return YES;
}
@end

@implementation KKCompanionPanelController {
  CGFloat _panelWidth;
  NSString *_logTag;
  NSPanel *_panel;
  __weak NSWindow *_parentWindow; // also the pending target during the delay
  __weak NSView *_popoverContentView; // re-align source when the popover flips
  BOOL _visible;
}

- (instancetype)initWithPanelWidth:(CGFloat)panelWidth
                            logTag:(NSString *)logTag {
  if ((self = [super init])) {
    _panelWidth = panelWidth;
    _logTag = [logTag copy];
  }
  return self;
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (NSPanel *)panel {
  return _panel;
}

- (BOOL)visible {
  return _visible;
}

// Resizable rounded-rect mask. NSVisualEffectView uses this both to clip the
// vibrancy AND to shape the window shadow, so the shadow follows the corners
// instead of the window's square backing (a plain layer cornerRadius leaves the
// hasShadow shadow rectangular - the "blocky shadow").
+ (NSImage *)_roundedMaskImageWithRadius:(CGFloat)radius {
  CGFloat dim = radius * 2.0 + 1.0;
  NSImage *image =
      [NSImage imageWithSize:NSMakeSize(dim, dim)
                     flipped:NO
              drawingHandler:^BOOL(NSRect rect) {
                [[NSColor blackColor] set];
                [[NSBezierPath bezierPathWithRoundedRect:rect
                                                 xRadius:radius
                                                 yRadius:radius] fill];
                return YES;
              }];
  image.capInsets = NSEdgeInsetsMake(radius, radius, radius, radius);
  image.resizingMode = NSImageResizingModeStretch;
  return image;
}

- (NSPanel *)_ensurePanel {
  if (_panel)
    return _panel;
  NSView *content = self.contentBuilder ? self.contentBuilder() : nil;
  if (!content)
    return nil;

  NSPanel *p = [[_KKCompanionPanel alloc]
      initWithContentRect:NSMakeRect(0, 0, _panelWidth, 300)
                styleMask:NSWindowStyleMaskBorderless |
                          NSWindowStyleMaskNonactivatingPanel
                  backing:NSBackingStoreBuffered
                    defer:YES];
  // Key on a click, as before. Withholding it was an attempt to keep the
  // popover's shortcut monitors alive (Mirage's B / S / M compare keys) and it
  // works the wrong way round: those monitors are LOCAL, so they need SOME
  // window of this process to hold the keyboard in order to consume the letter
  // at all - a panel that refuses key can leave the process with no key window
  // and the letter goes to Final Cut, which has its own bindings for all three.
  // A panel holding key is fine; the shortcut handlers don't care WHICH of our
  // windows is key, only that a text object isn't editing. Nonactivating means
  // taking key still doesn't activate our XPC process / deactivate FCP.
  p.becomesKeyOnlyIfNeeded = NO;
  p.hasShadow = YES;
  p.releasedWhenClosed = NO;
  // NSPanel defaults this to YES. In a ViewBridge process activation churns
  // constantly (and most of all while the first popover is still being built),
  // and each deactivation ordered the panel out - which ALSO drops the
  // parent/child link, orphaning it for good. The panel then never came back
  // until the popover was closed and reopened: no close notification, no
  // -hide, parent window still alive and visible.
  p.hidesOnDeactivate = NO;
  p.backgroundColor = NSColor.clearColor;
  p.opaque = NO;
  // We drive the fade ourselves; suppress AppKit's default order-in animation.
  p.animationBehavior = NSWindowAnimationBehaviorNone;

  content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

  if (@available(macOS 26.0, *)) {
    // Match the popover: it's drawn with the new Liquid Glass material
    // (NSGlassEffectView). cornerRadius gives a soft glass edge - no hard
    // outline, no maskImage seam. Appearance is copied from the popover at
    // show time so the tint matches.
    NSGlassEffectView *glass =
        [[NSGlassEffectView alloc] initWithFrame:NSZeroRect];
    glass.cornerRadius = kPanelCornerRadius;
    // Opaque inspector-matched fill so the panel reads like the popovers
    // beside it, not see-through liquid glass. The glass clips it to the corner
    // radius, so the panel keeps its rounded shape and shadow.
    content.wantsLayer = YES;
    content.layer.backgroundColor = KKPanelBackingFill().CGColor;
    glass.contentView = content;
    p.contentView = glass;
  } else {
    // Pre-26 fallback: flat vibrancy + rounded mask (mask drives the shadow,
    // so it stays rounded). The mask alone doesn't stroke an outline, so on
    // Sequoia the panel edge melts into the background - add a hairline border
    // (clipped to the same rounded shape by the mask) to give it the same
    // defined edge the Tahoe glass path and system windows have.
    NSVisualEffectView *fx =
        [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    fx.material = NSVisualEffectMaterialContentBackground;
    fx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    fx.state = NSVisualEffectStateActive;
    fx.wantsLayer = YES;
    fx.layer.cornerRadius = kPanelCornerRadius;
    fx.layer.borderColor = NSColor.separatorColor.CGColor;
    fx.layer.borderWidth = 1.0;
    fx.maskImage = [KKCompanionPanelController
        _roundedMaskImageWithRadius:kPanelCornerRadius];
    content.frame = fx.bounds;
    content.wantsLayer = YES;
    content.layer.backgroundColor = KKPanelBackingFill().CGColor;
    [fx addSubview:content];
    p.contentView = fx;
  }
  // What DID cost the shortcuts is the free first responder AppKit hands out:
  // a window whose initialFirstResponder is nil picks the first view in its key
  // loop the first time it becomes key - here the browser's search field - so
  // merely clicking a template card put a caret in Search, and every bare
  // letter after it read as typing rather than as a compare shortcut. Point it
  // at the content view, which does not accept first responder, and the panel
  // comes up with the keyboard unclaimed: a field is only ever editing because
  // the user clicked into it.
  p.initialFirstResponder = p.contentView;

  _panel = p;
  return _panel;
}

- (void)openBesideCard:(NSRect)card
         popoverWindow:(NSWindow *)popoverWindow
    popoverContentView:(NSView *)contentView {
  _popoverContentView = contentView;
  _parentWindow = popoverWindow;
  [self _showWhenVisibleWithCard:card attempt:0];
}

// Wait for the popover window to actually be on screen, RETRYING rather than
// checking once.
//
// The first time a popover opens its views are built from scratch, so on a cold
// FCP boot it is routinely still invisible when a single fixed delay elapses.
// The old one-shot check just returned, and the companion then never appeared
// until the popover was closed and reopened - by which point the window was
// warm and made the deadline, which is why it only ever looked broken on the
// first try. Bounded, so a popover that never appears stops the chain instead
// of polling forever.
//
// The window is re-read from the CONTENT VIEW on every attempt: at cold boot
// the notification can carry a window that is not the one the view ends up in,
// and holding the original meant waiting on a window that would never show.
- (void)_showWhenVisibleWithCard:(NSRect)card attempt:(NSInteger)attempt {
  static const NSInteger kMaxAttempts = 100; // ~10s at kShowDelay
  NSView *pending = _popoverContentView;
  NSWindow *window = pending.window ?: _parentWindow;
  if (window && window.isVisible) {
    _parentWindow = window;
    [self _showBesideCard:card ofWindow:window];
    return;
  }
  if (attempt + 1 >= kMaxAttempts) {
    KKLogWarn(@"[%@] popover never became visible, no panel", _logTag);
    return;
  }
  __weak typeof(self) weak = self;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kShowDelay * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        __strong typeof(weak) s = weak;
        // A different popover took over, or this one closed.
        if (!s || s->_popoverContentView != pending)
          return;
        [s _showWhenVisibleWithCard:card attempt:attempt + 1];
      });
}

- (void)_showBesideCard:(NSRect)card ofWindow:(NSWindow *)popoverWindow {
  // -hide clears the tracked content view (it is what cancels a pending poll),
  // so a re-show over a live panel has to put it back - it is the source the
  // live card and every later re-align are read from.
  NSView *tracked = _popoverContentView;
  if (_visible)
    [self hide];
  _popoverContentView = tracked;

  NSPanel *panel = [self _ensurePanel];
  if (!panel)
    return;
  // Inherit the popover's appearance (FCP's NOXInspector) so the glass tints
  // the same instead of rendering under the default system appearance.
  panel.appearance = popoverWindow.appearance;
  // Prefer the LIVE card over the open-time snapshot: the popover may have
  // settled or flipped edge during the show delay (before our move/resize
  // observers existed), which would otherwise leave the panel at the wrong
  // height/position.
  NSView *cv = _popoverContentView;
  if (cv.window) {
    NSRect live = [cv.window convertRectToScreen:[cv convertRect:cv.bounds
                                                          toView:nil]];
    if (!NSIsEmptyRect(live))
      card = live;
  }
  NSRect finalFrame = [self _panelFrameForCard:card];
  NSRect startFrame = finalFrame;
  // Emerge from UNDER the popover: a left-placed panel starts to its right (the
  // popover side) and slides left into place; a right-placed panel mirrors it.
  BOOL panelOnLeft = NSMidX(finalFrame) < NSMidX(card);
  startFrame.origin.x += panelOnLeft ? kSlideDistance : -kSlideDistance;

  // Follow the popover if it later resizes or flips edge (e.g. switching layers
  // retargets the popover above<->below the anchor). The card is recomputed
  // from the live content view, so the height always excludes the arrow.
  NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
  [nc removeObserver:self name:NSWindowDidMoveNotification object:nil];
  [nc removeObserver:self name:NSWindowDidResizeNotification object:nil];
  [nc addObserver:self
         selector:@selector(_popoverFrameChanged:)
             name:NSWindowDidMoveNotification
           object:popoverWindow];
  [nc addObserver:self
         selector:@selector(_popoverFrameChanged:)
             name:NSWindowDidResizeNotification
           object:popoverWindow];

  // Fade the CONTENT view, not the window: window alphaValue doesn't animate
  // for a ViewBridge child window (only the frame does), and the glass material
  // ignores it too. View-level alpha (layer opacity) animates reliably.
  panel.alphaValue = 1.0;
  panel.contentView.alphaValue = 0.0;
  [panel setFrame:startFrame display:NO];

  // Child window ordered BELOW the popover (tucks under it, no seam) but still
  // above FCP; keep-alive so a click inside it doesn't trip the popover's
  // outside-click dismissal.
  _parentWindow = popoverWindow;
  [popoverWindow addChildWindow:panel ordered:NSWindowBelow];
  KKPopoverAddKeepAliveWindow(panel);
  if (self.onDidAttach)
    self.onDidAttach();
  _visible = YES;

  // Animate on the next runloop tick - once the window is actually on screen,
  // so the alpha tween isn't dropped (animating it in the same callstack as
  // orderFront only slid the frame, never faded).
  dispatch_async(dispatch_get_main_queue(), ^{
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
      ctx.duration = kFadeDuration;
      ctx.timingFunction = [CAMediaTimingFunction
          functionWithName:kCAMediaTimingFunctionEaseOut];
      panel.contentView.animator.alphaValue = 1.0;
      [panel.animator setFrame:finalFrame display:YES];
    }];
  });
}

// Panel frame for a popover card: pinned beside the card, matching its top and
// height (so the arrow above/below is excluded). Prefers the LEFT of the card,
// but flips to the RIGHT when the left placement would run off the screen (a
// narrow FCP window puts the popover near the left edge, so the companion would
// otherwise clip). Clamps into the visible frame as a last resort.
- (NSRect)_panelFrameForCard:(NSRect)card {
  NSRect vis = [self _screenVisibleFrameForCard:card];
  CGFloat left = card.origin.x - _panelWidth - kPanelGap;
  CGFloat right = NSMaxX(card) + kPanelGap;
  CGFloat x = left;
  if (left < NSMinX(vis) && right + _panelWidth <= NSMaxX(vis))
    x = right; // left clips but the right side has room - flip beside the card
  x = MAX(NSMinX(vis), MIN(x, NSMaxX(vis) - _panelWidth)); // last-resort clamp
  return NSMakeRect(x, card.origin.y, _panelWidth, card.size.height);
}

// Visible frame of the screen the popover card sits on (so flip/clamp respects
// the Dock/menu-bar insets). Falls back to the main screen.
- (NSRect)_screenVisibleFrameForCard:(NSRect)card {
  NSPoint center = NSMakePoint(NSMidX(card), NSMidY(card));
  for (NSScreen *s in NSScreen.screens)
    if (NSPointInRect(center, s.frame))
      return s.visibleFrame;
  NSScreen *fallback = _popoverContentView.window.screen ?: NSScreen.mainScreen;
  return fallback.visibleFrame;
}

// Snap the panel to the popover's current card (live content view -> screen, so
// the arrow is always excluded whichever edge it's on).
- (void)_alignPanelToPopover {
  NSView *cv = _popoverContentView;
  if (!_visible || !cv.window)
    return;
  NSRect card = [cv.window convertRectToScreen:[cv convertRect:cv.bounds
                                                        toView:nil]];
  if (NSIsEmptyRect(card))
    return;
  [_panel setFrame:[self _panelFrameForCard:card] display:YES];
}

// The popover moved or resized (incl. flipping above<->below when re-anchoring
// to the new layer's keypose row). DEFER the re-align: AppKit applies the
// parent->child move as a delta to our panel AFTER this notification, and the
// popover's reposition may still be settling, so aligning synchronously here
// gets overwritten by exactly the popover's move distance (the symptom: the
// panel ends up offset by an amount that tracks the keypose row). A
// next-runloop snap runs after the delta + layout land, and a short settle pass
// catches an animated reposition.
- (void)_popoverFrameChanged:(NSNotification *)note {
  if (!_visible)
    return;
  __weak typeof(self) weak = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    [weak _alignPanelToPopover];
  });
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [weak _alignPanelToPopover];
      });
}

// The popover is a nonactivating panel too, so keying it costs FCP nothing -
// the same makeKeyWindow the mini-viewer overlay uses to reclaim the keyboard
// after a click. Also ends any field editing here first, or the field editor
// would still be first responder in a window that no longer has the keyboard.
//
// Run whenever the popover ISN'T key, not just when the panel is: the panel
// having declined key is exactly the case where the keyboard can have left the
// process entirely, and that is the case worth repairing.
- (void)returnKeyFocusToPopover {
  NSWindow *popover = _parentWindow;
  if (!popover || popover.isKeyWindow)
    return;
  [_panel makeFirstResponder:nil];
  [popover makeKeyWindow];
}

- (void)hide {
  NSWindow *parent = _parentWindow;
  _parentWindow = nil;
  if (self.onPrepareHide)
    self.onPrepareHide();
  if (!_visible)
    return;
  _visible = NO;
  _popoverContentView = nil;
  NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
  [nc removeObserver:self name:NSWindowDidMoveNotification object:nil];
  [nc removeObserver:self name:NSWindowDidResizeNotification object:nil];
  if (self.onDidHide)
    self.onDidHide();
  KKPopoverRemoveKeepAliveWindow(_panel);
  [parent removeChildWindow:_panel];
  [_panel orderOut:nil];
}

@end
