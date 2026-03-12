/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKLabelView.h"
#import "KKHostInfo.h"
#import "NSColor+KKColors.h"
#import <AppKit/AppKit.h>

static const CGFloat kLeadingMargin = 21.0;
static const CGFloat kMotionFontSize = 11.0;
static const CGFloat kFCPFontSize = 12.0;

@implementation KKLabelView {
  NSString *_text;
  NSTextField *_textField;
}

- (instancetype)initWithText:(NSString *)text {
  self = [super initWithFrame:NSZeroRect];
  if (self) {
    _text = [text copy] ?: @"Label";
    [self setupTextField];
  }
  return self;
}

- (void)setupTextField {
  _textField = [[NSTextField alloc] initWithFrame:self.bounds];
  _textField.stringValue = _text;
  _textField.backgroundColor = [NSColor clearColor];
  _textField.textColor = [NSColor inspectorLabel];
  _textField.font = [KKLabelView labelFont];
  _textField.editable = NO;
  _textField.selectable = NO;
  _textField.bordered = NO;
  _textField.translatesAutoresizingMaskIntoConstraints = NO;

  [self addSubview:_textField];

  [NSLayoutConstraint activateConstraints:@[
    [_textField.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                             constant:kLeadingMargin],
    [_textField.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]
  ]];
}

- (NSSize)intrinsicContentSize {
  NSSize textFieldSize = [_textField intrinsicContentSize];
  return NSMakeSize(NSViewNoIntrinsicMetric, textFieldSize.height);
}

+ (NSFont *)labelFont {
  static NSFont *font = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    font = [NSFont
        systemFontOfSize:[KKHostInfo isRunningInFinalCut] ? kFCPFontSize
                                                          : kMotionFontSize
                  weight:NSFontWeightLight];
  });
  return font;
}

@end
