/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPopoverHeaderView.h"
#import "../Style/NSColor+KKColors.h"

static const CGFloat kHeaderHeight = 18.0;
static const CGFloat kHeaderFontSize = 14.0;
static const CGFloat kHeaderDetailFontSize = 10.5; // subscript-style time
static const CGFloat kHeaderAlpha = 0.55;
static const CGFloat kHeaderIconGap = 4.0;

@implementation KKPopoverHeaderView {
  NSImageView *_iconView;
  NSTextField *_titleLabel;
  NSTextField *_detailLabel;
  NSImageView *_trailingIconView;
  NSColor *_dimColor;
}

+ (NSImage *)iconImageForSymbolName:(NSString *)symbolName {
  NSImage *icon = [[NSImage imageWithSystemSymbolName:symbolName
                             accessibilityDescription:symbolName]
      imageWithSymbolConfiguration:
          [NSImageSymbolConfiguration
              configurationWithPointSize:kHeaderFontSize
                                  weight:NSFontWeightMedium]];
  return icon ?: [[NSImage alloc] init];
}

- (instancetype)initWithTitle:(NSString *)title
                   symbolName:(NSString *)symbolName {
  return [self initWithTitle:title detail:nil symbolName:symbolName];
}

- (instancetype)initWithTitle:(NSString *)title
                       detail:(NSString *)detail
                   symbolName:(NSString *)symbolName {
  NSImage *icon = symbolName.length
                      ? [[self class] iconImageForSymbolName:symbolName]
                      : nil;
  return [self initWithTitle:title detail:detail icon:icon];
}

- (instancetype)initWithTitle:(NSString *)title
                       detail:(NSString *)detail
                         icon:(NSImage *)icon {
  self = [super initWithFrame:NSZeroRect];
  if (!self)
    return nil;
  self.translatesAutoresizingMaskIntoConstraints = NO;
  _title = [title copy];
  _detail = [detail copy];

  NSColor *color =
      [[NSColor inspectorLabel] colorWithAlphaComponent:kHeaderAlpha];
  _dimColor = color;

  NSLayoutXAxisAnchor *titleLeading = self.leadingAnchor;
  CGFloat titleLeadingInset = 0.0;
  if (icon) {
    _iconView = [NSImageView imageViewWithImage:icon];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.contentTintColor = color;
    [self addSubview:_iconView];
    [NSLayoutConstraint activateConstraints:@[
      [_iconView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [_iconView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
    titleLeading = _iconView.trailingAnchor;
    titleLeadingInset = kHeaderIconGap;
  }

  _titleLabel = [NSTextField labelWithString:_title ?: @""];
  _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
  _titleLabel.font = [NSFont systemFontOfSize:kHeaderFontSize
                                       weight:NSFontWeightSemibold];
  _titleLabel.textColor = color;
  [self addSubview:_titleLabel];

  // Smaller, subscript-style detail on the same baseline as the title.
  _detailLabel = [NSTextField labelWithString:_detail ?: @""];
  _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
  _detailLabel.font = [NSFont systemFontOfSize:kHeaderDetailFontSize
                                        weight:NSFontWeightRegular];
  _detailLabel.textColor = color;
  _detailLabel.hidden = (_detail.length == 0);
  [self addSubview:_detailLabel];

  // Trailing accessory (e.g. link chain). Hidden until a symbol is set.
  _trailingIconView = [NSImageView imageViewWithImage:[[NSImage alloc] init]];
  _trailingIconView.translatesAutoresizingMaskIntoConstraints = NO;
  _trailingIconView.contentTintColor = color;
  _trailingIconView.hidden = YES;
  [self addSubview:_trailingIconView];

  [NSLayoutConstraint activateConstraints:@[
    [_titleLabel.leadingAnchor constraintEqualToAnchor:titleLeading
                                              constant:titleLeadingInset],
    [_titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],

    [_detailLabel.leadingAnchor
        constraintEqualToAnchor:_titleLabel.trailingAnchor
                       constant:kHeaderIconGap],
    [_detailLabel.firstBaselineAnchor
        constraintEqualToAnchor:_titleLabel.firstBaselineAnchor],

    [_trailingIconView.leadingAnchor
        constraintEqualToAnchor:_detailLabel.trailingAnchor
                       constant:kHeaderIconGap],
    [_trailingIconView.centerYAnchor
        constraintEqualToAnchor:self.centerYAnchor],
    [_trailingIconView.trailingAnchor
        constraintLessThanOrEqualToAnchor:self.trailingAnchor],

    [self.heightAnchor constraintEqualToConstant:kHeaderHeight],
  ]];
  return self;
}

- (void)setTitle:(NSString *)title {
  _title = [title copy];
  _titleLabel.stringValue = title ?: @"";
}

- (void)setDetail:(NSString *)detail {
  _detail = [detail copy];
  _detailLabel.stringValue = detail ?: @"";
  _detailLabel.hidden = (detail.length == 0);
}

- (void)setTrailingSymbolName:(NSString *)symbolName {
  if (!symbolName.length) {
    _trailingIconView.hidden = YES;
    _trailingIconView.image = [[NSImage alloc] init];
    return;
  }
  NSImage *icon = [[NSImage imageWithSystemSymbolName:symbolName
                             accessibilityDescription:symbolName]
      imageWithSymbolConfiguration:
          [NSImageSymbolConfiguration
              configurationWithPointSize:kHeaderFontSize - 4.0
                                  weight:NSFontWeightRegular]];
  _trailingIconView.image = icon ?: [[NSImage alloc] init];
  _trailingIconView.contentTintColor = _dimColor;
  _trailingIconView.hidden = NO;
}

+ (CGFloat)height {
  return kHeaderHeight;
}

@end
