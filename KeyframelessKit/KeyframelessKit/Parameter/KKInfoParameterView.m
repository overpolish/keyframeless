/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKInfoParameterView.h"

static const CGFloat KKInfoParameterViewVerticalPadding = 6.0;

@implementation KKInfoParameterView {
  NSTextField *_label;
}

- (instancetype)initWithText:(NSString *)text {
  self = [super initWithFrame:NSMakeRect(0, 0, 300, 28)];
  if (self) {
    _text = [text copy];

    _label = [NSTextField labelWithString:text];
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    _label.textColor = NSColor.secondaryLabelColor;
    _label.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _label.lineBreakMode = NSLineBreakByWordWrapping;
    _label.maximumNumberOfLines = 0;
    [self addSubview:_label];

    [NSLayoutConstraint activateConstraints:@[
      [_label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [_label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [_label.topAnchor
          constraintEqualToAnchor:self.topAnchor
                         constant:KKInfoParameterViewVerticalPadding],
      [_label.bottomAnchor
          constraintEqualToAnchor:self.bottomAnchor
                         constant:-KKInfoParameterViewVerticalPadding],
    ]];
  }
  return self;
}

- (void)setText:(NSString *)text {
  _text = [text copy];
  _label.stringValue = text;
}

@end
