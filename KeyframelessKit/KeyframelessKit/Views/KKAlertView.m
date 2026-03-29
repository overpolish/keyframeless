/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKAlertView.h"
#import "../Style/KKFonts.h"
#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
#import "KKHostInfo.h"
#import <AppKit/AppKit.h>
#import <AppKit/NSView.h>
#import <CoreFoundation/CFCGTypes.h>
#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKLog.h>
#import <objc/objc.h>

static const CGFloat KKAlertViewHeight = KKInspectorRowHeight * 2;

@implementation KKAlertView {
  NSTextField *_label;
  NSImageView *_iconView;
  NSView *_contentView;
  NSLayoutConstraint *_labelTrailing;
  KKLog *_log;
}

- (instancetype)initWithText:(NSString *)text {
  return [self initWithText:text color:[NSColor accent]];
}

- (instancetype)initWithAttributedText:(NSAttributedString *)text {
  return [self initWithAttributedText:text color:[NSColor accent]];
}

- (instancetype)initWithAttributedText:(NSAttributedString *)text
                                 color:(NSColor *)color {
  self = [self initWithText:@"" color:color];
  if (self) {
    _label.attributedStringValue = text;
  }
  return self;
}

- (instancetype)initWithText:(NSString *)text color:(NSColor *)color {
  self = [super initWithFrame:NSMakeRect(0, 0, 0.0, KKAlertViewHeight)];
  _log = [KKLog loggerForPlugin:@"co.overpolish.keyframeless"];

  if (self) {
    _text = [text copy];
    _color = color;

    // Container to enforce padding - needed to prevent hiding of the chevron
    // for publishing parameters
    self.autoresizingMask =
        NSViewWidthSizable | NSViewHeightSizable | NSViewMinYMargin;

    _contentView = [[NSView alloc] init];
    _contentView.translatesAutoresizingMaskIntoConstraints = NO;
    _contentView.wantsLayer = YES;
    _contentView.layer.backgroundColor =
        [[_color colorWithAlphaComponent:0.1] CGColor];
    _contentView.layer.cornerRadius = KKRadiusMD;
    _contentView.layer.masksToBounds = YES;
    [self addSubview:_contentView];

    _iconView = [[NSImageView alloc] init];
    _iconView.hidden = YES;
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    _iconView.contentTintColor = _color;
    [_contentView addSubview:_iconView];

    _label = [NSTextField wrappingLabelWithString:_text];
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    _label.selectable = NO;
    _label.textColor = _color;
    _label.backgroundColor = [NSColor clearColor];
    _label.font = [KKFonts inspectorLabelFont];
    _label.lineBreakMode = NSLineBreakByWordWrapping;
    _label.maximumNumberOfLines = 2;
    [_contentView addSubview:_label];

    _labelTrailing = [_label.trailingAnchor
        constraintEqualToAnchor:_contentView.trailingAnchor
                       constant:-KKSpacingMD];

    [NSLayoutConstraint activateConstraints:@[
      [_contentView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [_contentView.leadingAnchor
          constraintEqualToAnchor:self.leadingAnchor
                         constant:KKInspectorHorizontalInset],
      [_contentView.trailingAnchor
          constraintEqualToAnchor:self.trailingAnchor
                         constant:-KKInspectorHorizontalInset],

      [_iconView.widthAnchor
          constraintEqualToConstant:[KKFonts inspectorIconSize]],
      [_iconView.heightAnchor
          constraintEqualToConstant:[KKFonts inspectorIconSize]],
      [_iconView.leadingAnchor
          constraintEqualToAnchor:_contentView.leadingAnchor
                         constant:KKSpacingMD * 1.5],
      [_iconView.topAnchor constraintEqualToAnchor:_contentView.topAnchor
                                          constant:KKSpacingMD + 1.0],

      [_label.topAnchor constraintEqualToAnchor:_contentView.topAnchor
                                       constant:KKSpacingMD],
      [_label.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor
                                           constant:KKSpacingMD],
      [_label.bottomAnchor constraintEqualToAnchor:_contentView.bottomAnchor
                                          constant:-KKSpacingMD],
      _labelTrailing,
    ]];
  }

  return self;
}

- (void)setText:(NSString *)text {
  _text = [text copy];
  _label.stringValue = text;
  [self setFrameSize:NSMakeSize(self.frame.size.width, 0)];
}

- (void)setIcon:(NSImage *)icon {
  _icon = icon;
  _iconView.image = icon;
  _iconView.hidden = (icon == nil);
}

- (void)setAccessoryView:(NSView *)accessoryView {
  [_accessoryView removeFromSuperview];
  _accessoryView = accessoryView;
  if (!accessoryView) {
    _labelTrailing.active = NO;
    _labelTrailing = [_label.trailingAnchor
        constraintEqualToAnchor:_contentView.trailingAnchor
                       constant:-KKSpacingMD];
    _labelTrailing.active = YES;
    return;
  }
  accessoryView.translatesAutoresizingMaskIntoConstraints = NO;
  [_contentView addSubview:accessoryView];
  _labelTrailing.active = NO;
  _labelTrailing = [_label.trailingAnchor
      constraintLessThanOrEqualToAnchor:accessoryView.leadingAnchor
                               constant:-KKSpacingMD];
  _labelTrailing.active = YES;
  [NSLayoutConstraint activateConstraints:@[
    [accessoryView.trailingAnchor
        constraintEqualToAnchor:_contentView.trailingAnchor
                       constant:-KKSpacingSM],
    [accessoryView.centerYAnchor
        constraintEqualToAnchor:_contentView.centerYAnchor],
  ]];
}

- (void)setColor:(NSColor *)color {
  _color = color;
  _label.textColor = color;
  _iconView.contentTintColor = color;
}

@end
