/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKPaddedScrollView.h"
#import <QuartzCore/QuartzCore.h>

@interface KKPaddedScrollFlippedClipView : NSClipView
@end

@implementation KKPaddedScrollFlippedClipView
- (BOOL)isFlipped {
  return YES;
}
@end

@interface KKPaddedScrollShadowView : NSView
@end

@implementation KKPaddedScrollShadowView
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return NO;
}
- (NSView *)hitTest:(NSPoint)point {
  return nil;
}
@end

static const CGFloat KKPaddedScrollShadowH = 16.0;

@implementation KKPaddedScrollView {
  NSScrollView *_scroll;
  KKPaddedScrollShadowView *_topShadow;
  KKPaddedScrollShadowView *_bottomShadow;
  id _boundsObserver;
}

- (instancetype)initWithDocumentView:(NSView *)documentView
                             padding:(CGFloat)padding {
  self = [super initWithFrame:NSZeroRect];
  if (!self)
    return nil;

  _scroll = [[NSScrollView alloc] init];
  _scroll.translatesAutoresizingMaskIntoConstraints = NO;
  _scroll.hasVerticalScroller = YES;
  _scroll.hasHorizontalScroller = NO;
  _scroll.drawsBackground = NO;
  _scroll.borderType = NSNoBorder;

  KKPaddedScrollFlippedClipView *clip =
      [[KKPaddedScrollFlippedClipView alloc] init];
  clip.drawsBackground = NO;
  clip.postsBoundsChangedNotifications = YES;
  _scroll.contentView = clip;
  [self addSubview:_scroll];

  documentView.translatesAutoresizingMaskIntoConstraints = NO;
  _scroll.documentView = documentView;

  // Top + bottom fade overlays. Their alpha tracks scroll position so the
  // top fade reveals as the user scrolls down and the bottom fade hides
  // when the document is scrolled to the very end.
  _topShadow = [[KKPaddedScrollShadowView alloc] initWithFrame:NSZeroRect];
  _topShadow.translatesAutoresizingMaskIntoConstraints = NO;
  _topShadow.wantsLayer = YES;
  CAGradientLayer *topGrad = [CAGradientLayer layer];
  topGrad.colors = @[
    (__bridge id)[NSColor colorWithWhite:0 alpha:0.35].CGColor,
    (__bridge id)[NSColor clearColor].CGColor,
  ];
  topGrad.startPoint = CGPointMake(0.5, 1.0);
  topGrad.endPoint = CGPointMake(0.5, 0.0);
  _topShadow.layer = topGrad;
  _topShadow.alphaValue = 0.0;
  [self addSubview:_topShadow];

  _bottomShadow = [[KKPaddedScrollShadowView alloc] initWithFrame:NSZeroRect];
  _bottomShadow.translatesAutoresizingMaskIntoConstraints = NO;
  _bottomShadow.wantsLayer = YES;
  CAGradientLayer *botGrad = [CAGradientLayer layer];
  botGrad.colors = @[
    (__bridge id)[NSColor clearColor].CGColor,
    (__bridge id)[NSColor colorWithWhite:0 alpha:0.35].CGColor,
  ];
  botGrad.startPoint = CGPointMake(0.5, 1.0);
  botGrad.endPoint = CGPointMake(0.5, 0.0);
  _bottomShadow.layer = botGrad;
  _bottomShadow.alphaValue = 0.0;
  [self addSubview:_bottomShadow];

  [NSLayoutConstraint activateConstraints:@[
    [_scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                          constant:padding],
    [_scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                           constant:-padding],
    [_scroll.topAnchor constraintEqualToAnchor:self.topAnchor constant:padding],
    [_scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor
                                         constant:-padding],

    [documentView.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
    [documentView.trailingAnchor constraintEqualToAnchor:clip.trailingAnchor],
    [documentView.topAnchor constraintEqualToAnchor:clip.topAnchor],
    [documentView.widthAnchor constraintEqualToAnchor:clip.widthAnchor],

    [_topShadow.leadingAnchor constraintEqualToAnchor:_scroll.leadingAnchor],
    [_topShadow.trailingAnchor constraintEqualToAnchor:_scroll.trailingAnchor],
    [_topShadow.topAnchor constraintEqualToAnchor:_scroll.topAnchor],
    [_topShadow.heightAnchor constraintEqualToConstant:KKPaddedScrollShadowH],

    [_bottomShadow.leadingAnchor constraintEqualToAnchor:_scroll.leadingAnchor],
    [_bottomShadow.trailingAnchor
        constraintEqualToAnchor:_scroll.trailingAnchor],
    [_bottomShadow.bottomAnchor constraintEqualToAnchor:_scroll.bottomAnchor],
    [_bottomShadow.heightAnchor
        constraintEqualToConstant:KKPaddedScrollShadowH],
  ]];

  __weak typeof(self) weakSelf = self;
  _boundsObserver = [[NSNotificationCenter defaultCenter]
      addObserverForName:NSViewBoundsDidChangeNotification
                  object:clip
                   queue:nil
              usingBlock:^(NSNotification *_) {
                [weakSelf _updateShadows];
              }];
  // Initial pass once layout settles.
  dispatch_async(dispatch_get_main_queue(), ^{
    [weakSelf _updateShadows];
  });

  return self;
}

- (void)dealloc {
  if (_boundsObserver)
    [[NSNotificationCenter defaultCenter] removeObserver:_boundsObserver];
}

- (void)_updateShadows {
  NSRect vr = _scroll.documentVisibleRect;
  NSRect cr = [(NSView *)_scroll.documentView bounds];
  CGFloat scrollable = cr.size.height - vr.size.height;
  if (scrollable <= 0.5) {
    _topShadow.alphaValue = 0.0;
    _bottomShadow.alphaValue = 0.0;
    return;
  }
  // documentVisibleRect is reported in the documentView's natural coords
  // (origin bottom-left for non-flipped stacks), so the fraction we want —
  // "how far the top edge of the visible window has been scrolled down
  // from the top of the document" — is the inverse of vr.origin.y.
  CGFloat fromTop =
      (cr.origin.y + cr.size.height) - (vr.origin.y + vr.size.height);
  CGFloat percent = fromTop / scrollable;
  percent = MAX(0.0, MIN(1.0, percent));
  _topShadow.alphaValue = percent;
  _bottomShadow.alphaValue = 1.0 - percent;
}

@end
