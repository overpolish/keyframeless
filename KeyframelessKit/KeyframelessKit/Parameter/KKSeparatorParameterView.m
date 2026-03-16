/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKSeparatorParameterView.h"
#import "../Icons/KKIcon.h"
#import "../KKFonts.h"
#import "../KKTokens.h"
#import "KKHostInfo.h"
#import "NSColor+KKColors.h"
#import <AppKit/AppKit.h>

static const CGFloat KKSeparatorParameterViewHeight = KKInspectorRowHeight;
static const CGFloat KKSeparatorLineHeight = 1.0;

@implementation KKSeparatorParameterView {
  NSView *_leftLine;
  NSView *_rightLine;
  KKIcon *_iconView;
  NSTextField *_label;
  // Stack holding icon + label; collapses to zero width when both are hidden
  NSStackView *_contentStack;
}

- (instancetype)init {
  return [self initWithText:nil icon:nil];
}

- (instancetype)initWithText:(NSString *)text icon:(NSBezierPath *)icon {
  self = [super
      initWithFrame:NSMakeRect(0, 0, 0.0, KKSeparatorParameterViewHeight)];
  if (self) {
    _text = [text copy];
    _icon = icon;
    _color = [[NSColor inspectorLabel] colorWithAlphaComponent:0.3];
    NSColor *labelColor = [NSColor inspectorLabel];

    self.autoresizingMask =
        NSViewWidthSizable | NSViewHeightSizable | NSViewMinYMargin;

    // Container inset from edges to avoid chevron overlap
    NSView *contentView = [[NSView alloc] init];
    contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:contentView];

    [NSLayoutConstraint activateConstraints:@[
      [contentView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [contentView.leadingAnchor
          constraintEqualToAnchor:self.leadingAnchor
                         constant:KKInspectorHorizontalInset],
      [contentView.trailingAnchor
          constraintEqualToAnchor:self.trailingAnchor
                         constant:-KKInspectorHorizontalInset],
      [contentView.heightAnchor
          constraintEqualToConstant:KKSeparatorParameterViewHeight],
    ]];

    _leftLine = [self _makeLine];
    [contentView addSubview:_leftLine];

    _rightLine = [self _makeLine];
    [contentView addSubview:_rightLine];

    _iconView = [[KKIcon alloc] initWithPath:nil strokeColor:labelColor];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
      [_iconView.widthAnchor
          constraintEqualToConstant:[KKFonts inspectorIconSize]],
      [_iconView.heightAnchor
          constraintEqualToConstant:[KKFonts inspectorIconSize]],
    ]];

    _label = [NSTextField labelWithString:@""];
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    _label.selectable = NO;
    _label.textColor = labelColor;
    _label.backgroundColor = [NSColor clearColor];
    _label.font = [KKFonts inspectorLabelFont];
    _label.lineBreakMode = NSLineBreakByClipping;
    _label.maximumNumberOfLines = 1;

    // Stack: icon + label, collapses detached hidden views to zero width
    _contentStack = [NSStackView stackViewWithViews:@[ _iconView, _label ]];
    _contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    _contentStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    _contentStack.alignment = NSLayoutAttributeCenterY;
    _contentStack.spacing = KKSpacingSM;
    _contentStack.detachesHiddenViews = YES;
    [contentView addSubview:_contentStack];

    // Layout: leftLine — [contentStack] — rightLine, equal widths = centred
    [NSLayoutConstraint activateConstraints:@[
      [_leftLine.leadingAnchor
          constraintEqualToAnchor:contentView.leadingAnchor],
      [_leftLine.centerYAnchor
          constraintEqualToAnchor:contentView.centerYAnchor],
      [_leftLine.heightAnchor constraintEqualToConstant:KKSeparatorLineHeight],
      [_leftLine.trailingAnchor
          constraintEqualToAnchor:_contentStack.leadingAnchor
                         constant:-KKSpacingMD],

      [_contentStack.centerXAnchor
          constraintEqualToAnchor:contentView.centerXAnchor],
      [_contentStack.centerYAnchor
          constraintEqualToAnchor:contentView.centerYAnchor],

      [_rightLine.leadingAnchor
          constraintEqualToAnchor:_contentStack.trailingAnchor
                         constant:KKSpacingMD],
      [_rightLine.trailingAnchor
          constraintEqualToAnchor:contentView.trailingAnchor],
      [_rightLine.centerYAnchor
          constraintEqualToAnchor:contentView.centerYAnchor],
      [_rightLine.heightAnchor constraintEqualToConstant:KKSeparatorLineHeight],

      // Equal widths keep the content centred
      [_leftLine.widthAnchor constraintEqualToAnchor:_rightLine.widthAnchor],
    ]];

    // Apply initial values — triggers detach logic via hidden=YES
    _iconView.hidden = (icon == nil);
    if (icon) {
      _iconView.path = icon;
    }

    _label.hidden = (text.length == 0);
    if (text.length > 0) {
      _label.stringValue = text;
    }
  }
  return self;
}

- (NSView *)_makeLine {
  NSView *line = [[NSView alloc] init];
  line.translatesAutoresizingMaskIntoConstraints = NO;
  line.wantsLayer = YES;
  line.layer.backgroundColor = [_color CGColor];
  line.layer.cornerRadius = KKSeparatorLineHeight / 2.0;
  line.layer.masksToBounds = YES;
  return line;
}

#pragma mark - Property setters

- (void)setText:(NSString *)text {
  _text = [text copy];
  _label.stringValue = text ?: @"";
  _label.hidden = (text.length == 0);
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
  CGColorRef lineColor = [[color colorWithAlphaComponent:0.3] CGColor];
  _leftLine.layer.backgroundColor = lineColor;
  _rightLine.layer.backgroundColor = lineColor;
  [_iconView setNeedsDisplay:YES];
}

@end
