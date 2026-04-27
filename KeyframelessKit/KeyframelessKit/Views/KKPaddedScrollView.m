/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKPaddedScrollView.h"

@interface KKPaddedScrollFlippedClipView : NSClipView
@end

@implementation KKPaddedScrollFlippedClipView
- (BOOL)isFlipped {
  return YES;
}
@end

@implementation KKPaddedScrollView

- (instancetype)initWithDocumentView:(NSView *)documentView
                             padding:(CGFloat)padding {
  self = [super initWithFrame:NSZeroRect];
  if (!self)
    return nil;

  NSScrollView *scroll = [[NSScrollView alloc] init];
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  scroll.hasVerticalScroller = YES;
  scroll.hasHorizontalScroller = NO;
  scroll.drawsBackground = NO;
  scroll.borderType = NSNoBorder;

  KKPaddedScrollFlippedClipView *clip =
      [[KKPaddedScrollFlippedClipView alloc] init];
  clip.drawsBackground = NO;
  scroll.contentView = clip;
  [self addSubview:scroll];

  documentView.translatesAutoresizingMaskIntoConstraints = NO;
  scroll.documentView = documentView;

  [NSLayoutConstraint activateConstraints:@[
    [scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                         constant:padding],
    [scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                          constant:-padding],
    [scroll.topAnchor constraintEqualToAnchor:self.topAnchor constant:padding],
    [scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor
                                        constant:-padding],

    [documentView.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
    [documentView.trailingAnchor constraintEqualToAnchor:clip.trailingAnchor],
    [documentView.topAnchor constraintEqualToAnchor:clip.topAnchor],
    [documentView.widthAnchor constraintEqualToAnchor:clip.widthAnchor],
  ]];

  return self;
}

@end
