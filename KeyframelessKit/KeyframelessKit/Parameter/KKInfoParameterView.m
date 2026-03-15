/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKInfoParameterView.h"
#import "KKHostInfo.h"
#import "NSColor+KKColors.h"
#import <AppKit/AppKit.h>
#include <AppKit/NSView.h>
#import <CoreFoundation/CFCGTypes.h>
#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKLog.h>

static const CGFloat KKInfoParameterViewVerticalPadding = 6.0;
static const CGFloat KKInfoParameterViewHorizontalPadding = 21.0;

@implementation KKInfoParameterView {
  NSTextField *_label;
  KKLog *_log;
  NSView *_container;
}

// Note: parameter view height is determined by the child view, not the parent.
// Once set it cannot be changed, the space is preallocated.
//
// Width is also controlled by the child view, the parent resizes to match the
// overall inspector.

- (instancetype)initWithText:(NSString *)text {
  return [self initWithText:text color:[NSColor accent]];
}

- (instancetype)initWithText:(NSString *)text color:(NSColor *)color {
  self = [super initWithFrame:NSMakeRect(0, 0, 0.0, 46.0)]; // height of 2 rows
  _log = [KKLog loggerForPlugin:@"co.overpolish.keyframeless"];

  if (self) {
    _text = [text copy];
    _color = color;
    _label = [[NSTextField alloc] initWithFrame:self.bounds];
    _label.stringValue = _text;
    _label.textColor = _color;
    _label.backgroundColor = [NSColor clearColor];
    _label.font = [KKInfoParameterView labelFont];
    _label.lineBreakMode = NSLineBreakByWordWrapping;
    _label.maximumNumberOfLines = 2;
    _label.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _label.editable = NO;
    _label.selectable = NO;
    _label.bordered = NO;

    [self addSubview:_label];

    self.translatesAutoresizingMaskIntoConstraints = NO;
    _container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 0.0, 46.0)];
    _container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_container addSubview:self];

    [NSLayoutConstraint activateConstraints:@[
      [self.topAnchor
          constraintEqualToAnchor:_container.topAnchor
                         constant:KKInfoParameterViewVerticalPadding],
      [self.leadingAnchor
          constraintEqualToAnchor:_container.leadingAnchor
                         constant:KKInfoParameterViewHorizontalPadding],
      [self.bottomAnchor
          constraintEqualToAnchor:_container.bottomAnchor
                         constant:-KKInfoParameterViewVerticalPadding],
      [self.trailingAnchor
          constraintEqualToAnchor:_container.trailingAnchor
                         constant:-KKInfoParameterViewHorizontalPadding],
    ]];
  }
  return self;
}

- (NSView *)container {
  return _container;
}

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

- (void)setColor:(NSColor *)color {
  _color = color;
  _label.textColor = color;
}

@end
