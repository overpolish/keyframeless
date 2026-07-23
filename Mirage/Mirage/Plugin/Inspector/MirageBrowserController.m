/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageBrowserController.h"
#import "MirageBrowserView.h"
#import <KeyframelessKit/KKPopoverKeepAlive.h>
#import <KeyframelessKit/KKTimeline.h>
#import <KeyframelessKit/NSColor+KKColors.h>
#import <QuartzCore/QuartzCore.h>

static const CGFloat kPanelWidth = 300.0;
static const CGFloat kPanelGap = 8.0;
static const CGFloat kPanelCornerRadius = 9.0;
static const NSTimeInterval kShowDelay = 0.1;
static const NSTimeInterval kFadeDuration = 0.28;
static const CGFloat kSlideDistance = 12.0;

@interface _MirageBrowserPanel : NSPanel
@end
@implementation _MirageBrowserPanel
- (BOOL)canBecomeKeyWindow {
  return YES;
}
@end

@implementation MirageBrowserController {
  NSPanel *_panel;
  MirageBrowserView *_browser;
  NSWindow *_parentWindow;
  NSView *_popoverContentView;
  BOOL _visible;
}

- (instancetype)initWithLanesView:(KKTimelineLanesView *)lanesView {
  if ((self = [super init])) {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self
           selector:@selector(_popoverDidOpen:)
               name:KKStaticValuesPopoverDidOpenNotification
             object:lanesView];
    [nc addObserver:self
           selector:@selector(_popoverDidClose:)
               name:KKStaticValuesPopoverDidCloseNotification
             object:lanesView];
  }
  return self;
}

- (void)invalidate {
  [NSNotificationCenter.defaultCenter removeObserver:self];
  self.onSelectEntry = nil;
  self.onPublishEntry = nil;
  self.onDeleteEntry = nil;
  [self _hide];
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)reload {
  [_browser reload];
}

- (void)refreshLocal {
  [_browser refreshLocal];
}

// Resizable rounded-rect mask. NSVisualEffectView uses this both to clip the
// vibrancy AND to shape the window shadow, so the shadow follows the corners
// instead of the window's square backing (a plain layer cornerRadius leaves the
// hasShadow shadow rectangular - the "blocky shadow"). Mirrors the Canvas layer
// list panel.
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
  NSPanel *p = [[_MirageBrowserPanel alloc]
      initWithContentRect:NSMakeRect(0, 0, kPanelWidth, 300)
                styleMask:NSWindowStyleMaskBorderless |
                          NSWindowStyleMaskNonactivatingPanel
                  backing:NSBackingStoreBuffered
                    defer:YES];
  p.becomesKeyOnlyIfNeeded = NO;
  p.hasShadow = YES;
  p.releasedWhenClosed = NO;
  p.backgroundColor = NSColor.clearColor;
  p.opaque = NO;
  p.animationBehavior = NSWindowAnimationBehaviorNone;

  MirageBrowserView *content =
      [[MirageBrowserView alloc] initWithFrame:NSZeroRect];
  content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  __weak typeof(self) weak = self;
  content.onSelectEntry = ^(MirageCatalogEntry *e) {
    __strong typeof(weak) s = weak;
    if (s.onSelectEntry)
      s.onSelectEntry(e);
  };
  content.onPublishEntry = ^(MirageCatalogEntry *e) {
    __strong typeof(weak) s = weak;
    if (s.onPublishEntry)
      s.onPublishEntry(e);
  };
  content.onDeleteEntry = ^(MirageCatalogEntry *e) {
    __strong typeof(weak) s = weak;
    if (s.onDeleteEntry)
      s.onDeleteEntry(e);
  };
  content.onRenameEntry = ^(MirageCatalogEntry *e, NSString *name) {
    __strong typeof(weak) s = weak;
    if (s.onRenameEntry)
      s.onRenameEntry(e, name);
  };
  _browser = content;

  if (@available(macOS 26.0, *)) {
    NSGlassEffectView *glass =
        [[NSGlassEffectView alloc] initWithFrame:NSZeroRect];
    glass.cornerRadius = kPanelCornerRadius;
    // Opaque inspector-matched fill so the template browser reads like the
    // popovers beside it, not see-through liquid glass. The glass clips it to
    // the corner radius, so the panel keeps its rounded shape and shadow.
    content.wantsLayer = YES;
    content.layer.backgroundColor =
        [NSColor.inspectorBackground colorWithAlphaComponent:0.5].CGColor;
    glass.contentView = content;
    p.contentView = glass;
  } else {
    NSVisualEffectView *fx =
        [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    fx.material = NSVisualEffectMaterialContentBackground;
    fx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    fx.state = NSVisualEffectStateActive;
    fx.wantsLayer = YES;
    fx.layer.borderColor = NSColor.separatorColor.CGColor;
    fx.layer.borderWidth = 1.0;
    // Round via a mask image (not layer cornerRadius): the mask shapes the
    // window shadow too, so hasShadow follows the corners instead of drawing a
    // square shadow past them. The hairline border is clipped to the same
    // shape.
    fx.maskImage = [MirageBrowserController
        _roundedMaskImageWithRadius:kPanelCornerRadius];
    content.frame = fx.bounds;
    [fx addSubview:content];
    p.contentView = fx;
  }
  _panel = p;
  return _panel;
}

- (void)_popoverDidOpen:(NSNotification *)note {
  // The browser is a shader SWITCHER, only useful beside the constants / code
  // editor popover. Skip the animated-dropdown ("manage") and lane-filter
  // ("filter") popovers - single-owner, nothing to switch there (Canvas
  // attaches its layer list to those because it is per-layer; Mirage is not).
  NSString *kind = note.userInfo[@"kind"];
  if ([kind isEqualToString:@"manage"] || [kind isEqualToString:@"filter"] ||
      [kind isEqualToString:@"osc"] || [kind isEqualToString:@"appliesTo"])
    return;
  NSWindow *popoverWindow = note.userInfo[@"window"];
  if (![popoverWindow isKindOfClass:[NSWindow class]])
    return;
  NSValue *cardVal = note.userInfo[@"contentRect"];
  NSRect card = cardVal ? cardVal.rectValue : popoverWindow.frame;
  _popoverContentView = note.userInfo[@"contentView"];
  _parentWindow = popoverWindow;

  __weak typeof(self) weak = self;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kShowDelay * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        __strong typeof(weak) s = weak;
        if (!s || s->_parentWindow != popoverWindow || !popoverWindow.isVisible)
          return;
        [s _showBesideCard:card ofWindow:popoverWindow];
      });
}

- (void)_showBesideCard:(NSRect)card ofWindow:(NSWindow *)popoverWindow {
  if (_visible)
    [self _hide];
  NSPanel *panel = [self _ensurePanel];
  panel.appearance = popoverWindow.appearance;

  NSView *cv = _popoverContentView;
  if (cv.window) {
    NSRect live = [cv.window convertRectToScreen:[cv convertRect:cv.bounds
                                                          toView:nil]];
    if (!NSIsEmptyRect(live))
      card = live;
  }
  NSRect finalFrame = [self _panelFrameForCard:card];
  NSRect startFrame = finalFrame;
  BOOL panelOnLeft = NSMidX(finalFrame) < NSMidX(card);
  startFrame.origin.x += panelOnLeft ? kSlideDistance : -kSlideDistance;

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

  panel.alphaValue = 1.0;
  panel.contentView.alphaValue = 0.0;
  [panel setFrame:startFrame display:NO];
  _parentWindow = popoverWindow;
  [popoverWindow addChildWindow:panel ordered:NSWindowBelow];
  KKPopoverAddKeepAliveWindow(panel);
  [_browser reload];
  _visible = YES;

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

- (NSRect)_panelFrameForCard:(NSRect)card {
  NSRect vis = [self _screenVisibleFrameForCard:card];
  CGFloat left = card.origin.x - kPanelWidth - kPanelGap;
  CGFloat right = NSMaxX(card) + kPanelGap;
  CGFloat x = left;
  if (left < NSMinX(vis) && right + kPanelWidth <= NSMaxX(vis))
    x = right;
  x = MAX(NSMinX(vis), MIN(x, NSMaxX(vis) - kPanelWidth));
  return NSMakeRect(x, card.origin.y, kPanelWidth, card.size.height);
}

- (NSRect)_screenVisibleFrameForCard:(NSRect)card {
  NSPoint center = NSMakePoint(NSMidX(card), NSMidY(card));
  for (NSScreen *s in NSScreen.screens)
    if (NSPointInRect(center, s.frame))
      return s.visibleFrame;
  NSScreen *fallback = _popoverContentView.window.screen ?: NSScreen.mainScreen;
  return fallback.visibleFrame;
}

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

- (void)_popoverDidClose:(NSNotification *)note {
  [self _hide];
}

- (void)_hide {
  NSWindow *parent = _parentWindow;
  _parentWindow = nil;
  if (!_visible)
    return;
  _visible = NO;
  _popoverContentView = nil;
  NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
  [nc removeObserver:self name:NSWindowDidMoveNotification object:nil];
  [nc removeObserver:self name:NSWindowDidResizeNotification object:nil];
  KKPopoverRemoveKeepAliveWindow(_panel);
  [parent removeChildWindow:_panel];
  [_panel orderOut:nil];
}

@end
