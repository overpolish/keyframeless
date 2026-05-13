/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "RoundedInspectorView.h"
#import <KeyframelessKit/KKTokens.h>

static const CGFloat kInspectorHeight = 200.0;

@implementation RoundedInspectorView {
  id<PROAPIAccessing> _apiManager;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithFrame:NSMakeRect(0, 0, 0, kInspectorHeight)];
  if (self) {
    _apiManager = apiManager;
    self.autoresizingMask =
        NSViewWidthSizable | NSViewHeightSizable | NSViewMinYMargin;

    NSView *box = [[NSView alloc] init];
    box.translatesAutoresizingMaskIntoConstraints = NO;
    box.wantsLayer = YES;
    box.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.08].CGColor;
    box.layer.borderColor = NSColor.separatorColor.CGColor;
    box.layer.borderWidth = 1.0;
    box.layer.cornerRadius = 8.0;
    [self addSubview:box];

    CGFloat h = KKInspectorHorizontalInset;
    CGFloat v = KKPaddingLG;
    [NSLayoutConstraint activateConstraints:@[
      [box.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:h],
      [box.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                         constant:-h],
      [box.topAnchor constraintEqualToAnchor:self.topAnchor constant:v],
      [box.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-v],
    ]];
  }
  return self;
}

- (CGSize)intrinsicContentSize {
  return NSMakeSize(NSViewNoIntrinsicMetric, kInspectorHeight);
}

@end
