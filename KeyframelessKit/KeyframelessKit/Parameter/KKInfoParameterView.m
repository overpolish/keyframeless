/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKInfoParameterView.h"
#import "../Icons/KKIcon.h"
#import "../Icons/KKIcons.h"
#import "KKHostInfo.h"
#import "NSColor+KKColors.h"
#import <AppKit/AppKit.h>
#include <AppKit/NSView.h>
#import <CoreFoundation/CFCGTypes.h>
#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKLog.h>
#include <objc/objc.h>

static const CGFloat KKInfoParameterViewHeight = 46.0; // Size of 2 rows;
static const CGFloat KKInfoParameterViewVerticalPadding = 6.0;

// TODO this is layout match to motion, rename, move to layout constants
static const CGFloat KKInfoParameterViewHorizontalPadding = 21.0;

// TODO move into layout constants - under spacing enum or something?
static const CGFloat Padding = 6.0;

static const CGFloat KKInfoParameterViewIconSize = 12.0;
static const CGFloat KKInfoParameterViewIconGap = 6.0;

@implementation KKInfoParameterView {
  NSTextField *_label;
  KKIcon *_iconView;
  KKLog *_log;
}

- (instancetype)initWithText:(NSString *)text {
  return [self initWithText:text color:[NSColor accent]];
}

- (instancetype)initWithText:(NSString *)text color:(NSColor *)color {
  // TODO pull out 23 as row height into layout constants
  self = [super initWithFrame:NSMakeRect(0, 0, 0.0, 46.0)];
  _log = [KKLog loggerForPlugin:@"co.overpolish.keyframeless"];

  if (self) {
    _text = [text copy];
    _color = color;

    // Container to enforce padding - needed to prevent hiding of the chevron
    // for publishing parameters
    self.autoresizingMask =
        NSViewWidthSizable | NSViewHeightSizable | NSViewMinYMargin;

    NSView *contentView = [[NSView alloc] init];
    contentView.translatesAutoresizingMaskIntoConstraints = NO;
    contentView.wantsLayer = YES;
    contentView.layer.backgroundColor =
        [[_color colorWithAlphaComponent:0.1] CGColor];
    // TODO pull out into layout constants
    contentView.layer.cornerRadius = 8.0;
    contentView.layer.masksToBounds = YES;
    [self addSubview:contentView];

    _iconView = [[KKIcon alloc] initWithPath:Nil strokeColor:_color];
    _iconView.hidden = YES;
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:_iconView];

    _label = [NSTextField wrappingLabelWithString:_text];
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    _label.textColor = _color;
    _label.backgroundColor = [NSColor clearColor];
    _label.font = [KKInfoParameterView labelFont];
    _label.lineBreakMode = NSLineBreakByWordWrapping;
    _label.maximumNumberOfLines = 2;
    [contentView addSubview:_label];

    [NSLayoutConstraint activateConstraints:@[
      [contentView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [contentView.leadingAnchor
          constraintEqualToAnchor:self.leadingAnchor
                         constant:KKInfoParameterViewHorizontalPadding],
      [contentView.trailingAnchor
          constraintEqualToAnchor:self.trailingAnchor
                         constant:-KKInfoParameterViewHorizontalPadding],

      [_iconView.widthAnchor
          constraintEqualToConstant:KKInfoParameterViewIconSize],
      [_iconView.heightAnchor
          constraintEqualToConstant:KKInfoParameterViewIconSize],
      [_iconView.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor
                                              constant:Padding * 1.5],
      [_iconView.topAnchor constraintEqualToAnchor:contentView.topAnchor
                                          constant:Padding + 1.0],

      [_label.topAnchor constraintEqualToAnchor:contentView.topAnchor
                                       constant:Padding],
      [_label.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor
                                           constant:KKInfoParameterViewIconGap],
      [_label.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor
                                          constant:-Padding],
      [_label.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor
                                            constant:-Padding],
    ]];
  }

  return self;
}

// TODO pull into layout consts?
+ (NSFont *)labelFont {
  static NSFont *font = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]
                             weight:NSFontWeightLight];
  });
  return font;
}

- (void)setText:(NSString *)text {
  _text = [text copy];
  _label.stringValue = text;
  [self setFrameSize:NSMakeSize(self.frame.size.width, 0)];
}

- (void)setIcon:(NSBezierPath *)icon {
  _icon = icon;
  _iconView.path = icon;
  _iconView.hidden = (icon == nil);
  [_iconView setNeedsDisplay:YES];
}

- (void)setColor:(NSColor *)color {
  _color = color;
  _label.textColor = color;
  _iconView.strokeColor = color;
  [_iconView setNeedsDisplay:YES];
}

@end
