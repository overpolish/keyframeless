/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLaneRowView.h"
#import "NSColor+KKColors.h"

// Shared token-style constants. Change here, every subclass updates.
static const CGFloat kRowHeight = 22.0;
static const CGFloat kStripeWidth = 3.0;
static const CGFloat kStripeRadius = 1.5;
static const CGFloat kStripeToLabelGap = 8.0;

@implementation KKLaneRowView {
  NSView *_stripe;
}

- (instancetype)initWithTitle:(NSString *)title
                      tooltip:(NSString *)tooltip
                    laneColor:(NSColor *)laneColor {
  self = [super initWithFrame:NSZeroRect];
  if (!self)
    return nil;
  self.translatesAutoresizingMaskIntoConstraints = NO;

  if (laneColor) {
    _stripe = [[NSView alloc] initWithFrame:NSZeroRect];
    _stripe.translatesAutoresizingMaskIntoConstraints = NO;
    _stripe.wantsLayer = YES;
    _stripe.layer.backgroundColor = laneColor.CGColor;
    _stripe.layer.cornerRadius = kStripeRadius;
    [self addSubview:_stripe];
  }

  _titleLabel = [NSTextField labelWithString:title];
  _titleLabel.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
  _titleLabel.textColor = [NSColor inspectorLabel];
  _titleLabel.toolTip = tooltip;
  _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:_titleLabel];

  _controlContainer = [[NSView alloc] initWithFrame:NSZeroRect];
  _controlContainer.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:_controlContainer];

  NSMutableArray<NSLayoutConstraint *> *cs = [NSMutableArray array];
  if (_stripe) {
    [cs addObjectsFromArray:@[
      [_stripe.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [_stripe.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [_stripe.widthAnchor constraintEqualToConstant:kStripeWidth],
      [_stripe.heightAnchor constraintEqualToConstant:kRowHeight - 6.0],
      [_titleLabel.leadingAnchor constraintEqualToAnchor:_stripe.trailingAnchor
                                                constant:kStripeToLabelGap],
    ]];
  } else {
    [cs addObject:[_titleLabel.leadingAnchor
                      constraintEqualToAnchor:self.leadingAnchor]];
  }
  [cs addObjectsFromArray:@[
    [_titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [_controlContainer.trailingAnchor
        constraintEqualToAnchor:self.trailingAnchor],
    [_controlContainer.centerYAnchor
        constraintEqualToAnchor:self.centerYAnchor],
    [_controlContainer.leadingAnchor
        constraintGreaterThanOrEqualToAnchor:_titleLabel.trailingAnchor
                                    constant:8.0],
    [self.heightAnchor constraintEqualToConstant:kRowHeight],
  ]];
  [NSLayoutConstraint activateConstraints:cs];
  return self;
}

- (NSSize)intrinsicContentSize {
  return NSMakeSize(NSViewNoIntrinsicMetric, kRowHeight);
}

- (void)popoverDidRefresh {
  // Subclass hook.
}

@end
