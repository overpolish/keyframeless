/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerListController.h"
#import "CanvasLayerListView.h"
#import <KeyframelessKit/KKPopoverKeepAlive.h>
#import <KeyframelessKit/KKTokens.h>
#import <QuartzCore/QuartzCore.h>

// Panel sits to the left of the popover card with a small gap, ordered behind
// the popover. Width is fixed for now; height matches the popover card.
static const CGFloat kPanelWidth = 200.0;
static const CGFloat kPanelGap = 8.0;
// Corner radius of the macOS popover chrome we're matching (tweak to taste).
static const CGFloat kPanelCornerRadius = 9.0;
// Hold off until the popover has nearly finished its own entrance, so the two
// don't animate on top of each other.
static const NSTimeInterval kShowDelay = 0.1;
static const NSTimeInterval kFadeDuration = 0.28;
static const CGFloat kSlideDistance = 12.0;

@implementation CanvasLayerListController {
  NSPanel *_panel;
  __weak NSWindow *_parentWindow; // also the pending target during the delay
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
  [self _hide];
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

// Resizable rounded-rect mask. NSVisualEffectView uses this both to clip the
// vibrancy AND to shape the window shadow, so the shadow follows the corners.
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
  NSPanel *p =
      [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, kPanelWidth, 300)
                                 styleMask:NSWindowStyleMaskBorderless |
                                           NSWindowStyleMaskNonactivatingPanel
                                   backing:NSBackingStoreBuffered
                                     defer:YES];
  p.hasShadow = YES;
  p.releasedWhenClosed = NO;
  p.backgroundColor = NSColor.clearColor;
  p.opaque = NO;
  // We drive the fade ourselves; suppress AppKit's default order-in animation.
  p.animationBehavior = NSWindowAnimationBehaviorNone;

  // The Layers panel content (header + scrollable well + empty state). Fills
  // the panel; its own internal padding matches the popover's content inset.
  CanvasLayerListView *content =
      [[CanvasLayerListView alloc] initWithFrame:NSZeroRect];
  content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

  if (@available(macOS 26.0, *)) {
    // Match the popover: it's drawn with the new Liquid Glass material
    // (NSGlassEffectView). cornerRadius gives a soft glass edge - no hard
    // outline, no maskImage seam. Appearance is copied from the popover at
    // show time so the tint matches.
    NSGlassEffectView *glass =
        [[NSGlassEffectView alloc] initWithFrame:NSZeroRect];
    glass.cornerRadius = kPanelCornerRadius;
    glass.contentView = content;
    p.contentView = glass;
  } else {
    // Pre-26 fallback: flat vibrancy + rounded mask (mask drives the shadow,
    // so it stays rounded). No layer border.
    NSVisualEffectView *fx =
        [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    fx.material = NSVisualEffectMaterialContentBackground;
    fx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    fx.state = NSVisualEffectStateActive;
    fx.maskImage = [CanvasLayerListController
        _roundedMaskImageWithRadius:kPanelCornerRadius];
    content.frame = fx.bounds;
    [fx addSubview:content];
    p.contentView = fx;
  }

  _panel = p;
  return _panel;
}

- (void)_popoverDidOpen:(NSNotification *)note {
  NSWindow *popoverWindow = note.userInfo[@"window"];
  if (![popoverWindow isKindOfClass:[NSWindow class]])
    return;

  // Align to the visible popover card (the window frame includes shadow +
  // arrow padding, so it's taller/wider than the card).
  NSValue *cardVal = note.userInfo[@"contentRect"];
  NSRect card = cardVal ? cardVal.rectValue : popoverWindow.frame;

  // Mark this popover as the pending target, then show after a delay so the
  // popover's own entrance plays first.
  _parentWindow = popoverWindow;
  __weak typeof(self) weakSelf = self;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kShowDelay * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || s->_parentWindow != popoverWindow || !popoverWindow.isVisible)
          return; // popover closed (or replaced) during the delay
        [s _showBesideCard:card ofWindow:popoverWindow];
      });
}

- (void)_showBesideCard:(NSRect)card ofWindow:(NSWindow *)popoverWindow {
  if (_visible)
    [self _hide];

  NSPanel *panel = [self _ensurePanel];
  // Inherit the popover's appearance (FCP's NOXInspector) so the glass tints
  // the same instead of rendering under the default system appearance.
  panel.appearance = popoverWindow.appearance;
  NSRect finalFrame = NSMakeRect(card.origin.x - kPanelWidth - kPanelGap,
                                 card.origin.y, kPanelWidth, card.size.height);
  NSRect startFrame = finalFrame;
  startFrame.origin.x += kSlideDistance; // slide in toward the popover

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

- (void)_popoverDidClose:(NSNotification *)note {
  [self _hide];
}

- (void)_hide {
  NSWindow *parent = _parentWindow;
  _parentWindow = nil;
  if (!_visible)
    return;
  _visible = NO;
  KKPopoverRemoveKeepAliveWindow(_panel);
  [parent removeChildWindow:_panel];
  [_panel orderOut:nil];
}

@end
