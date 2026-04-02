/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKLabelView.h"
#import "../Plugin/KKHostInfo.h"
#import "../Style/NSColor+KKColors.h"
#import <AppKit/AppKit.h>

static const CGFloat kLeadingMargin = 21.0;
static const CGFloat kIconSize = 11.0;
static const CGFloat kIconTextSpacing = 4.0;
static const CGFloat kMotionFontSize = 11.0;
static const CGFloat kFCPFontSize = 12.0;

@implementation KKLabelView {
  NSString *_text;
  NSImageView *_iconView;
  NSTextField *_textField;
  NSLayoutConstraint *_iconWidthConstraint;
  NSLayoutConstraint *_textLeadingConstraint;
}

- (instancetype)initWithText:(NSString *)text {
  return [self initWithText:text icon:nil];
}

- (instancetype)initWithText:(NSString *)text icon:(NSImage *)icon {
  self = [super initWithFrame:NSZeroRect];
  if (self) {
    _text = [text copy] ?: @"Label";
    _icon = icon;
    [self setupViews];
    [self updateIconLayout];
  }
  return self;
}

- (void)setupViews {
  _iconView = [[NSImageView alloc] init];
  _iconView.translatesAutoresizingMaskIntoConstraints = NO;
  _iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
  _iconView.contentTintColor = [NSColor inspectorLabel];
  [self addSubview:_iconView];

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

  _iconWidthConstraint =
      [_iconView.widthAnchor constraintEqualToConstant:kIconSize];
  _textLeadingConstraint =
      [_textField.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor
                                               constant:kIconTextSpacing];

  [NSLayoutConstraint activateConstraints:@[
    [_iconView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                            constant:kLeadingMargin],
    [_iconView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    _iconWidthConstraint,
    [_iconView.heightAnchor constraintEqualToConstant:kIconSize],
    _textLeadingConstraint,
    [_textField.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
  ]];
}

- (void)updateIconLayout {
  BOOL hasIcon = (_icon != nil);
  _iconView.image = _icon;
  _iconView.hidden = !hasIcon;
  _iconWidthConstraint.constant = hasIcon ? kIconSize : 0;
  _textLeadingConstraint.constant = hasIcon ? kIconTextSpacing : 0;
}

- (void)setIcon:(NSImage *)icon {
  _icon = icon;
  [self updateIconLayout];
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
