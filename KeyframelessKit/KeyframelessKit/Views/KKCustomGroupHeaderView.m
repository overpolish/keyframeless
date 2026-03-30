/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKCustomGroupHeaderView.h"
#import "KKCheckboxView.h"
#import "KKChevronView.h"
#import "KKLabelView.h"
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKParameterRowView.h>

static const CGFloat kChevronMarginLeft = 10.0;
static const CGFloat kCheckboxTrailingMargin = 23.0;
static const CGFloat kStatusCheckboxGap = 8.0;
static const CGFloat kStatusTrailingMargin = 23.0;

@implementation KKCustomGroupHeaderView {
  KKChevronView *_chevron;
  KKCheckboxView *_checkbox;
  NSTextField *_statusLabel;
}

- (instancetype)initWithFrame:(NSRect)frameRect
                   apiManager:(id<PROAPIAccessing>)apiManager
                  parameterId:(UInt32)parameterId
                         text:(NSString *)text
                         icon:(NSImage *)icon
                showsCheckbox:(BOOL)showsCheckbox {
  self = [super initWithFrame:frameRect
                   apiManager:apiManager
                  parameterId:parameterId];
  if (self) {
    _isEnabled = NO;
    _isExpanded = NO;

    _chevron = [[KKChevronView alloc] initWithFrame:NSZeroRect];
    _chevron.translatesAutoresizingMaskIntoConstraints = NO;
    _chevron.isInteractive = NO;
    [self addSubview:_chevron];
    [NSLayoutConstraint activateConstraints:@[
      [_chevron.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                             constant:kChevronMarginLeft],
      [_chevron.topAnchor constraintEqualToAnchor:self.topAnchor],
      [_chevron.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
      [_chevron.widthAnchor constraintEqualToConstant:kChevronWidth]
    ]];

    __weak typeof(self) weakSelf = self;
    _chevron.onToggle = ^(BOOL isExpanded) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf)
        return;
      strongSelf->_isExpanded = isExpanded;
      if (strongSelf.onExpandedChanged) {
        strongSelf.onExpandedChanged(isExpanded);
      }
    };

    KKLabelView *label = [[KKLabelView alloc] initWithText:text icon:icon];
    self.leftView = label;

    NSView *rightContainer = [[NSView alloc] initWithFrame:NSZeroRect];

    _statusLabel = [NSTextField labelWithString:@""];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.font = [NSFont systemFontOfSize:10.0];
    _statusLabel.textColor = [NSColor tertiaryLabelColor];
    _statusLabel.hidden = YES;
    [rightContainer addSubview:_statusLabel];
    [_statusLabel.centerYAnchor
        constraintEqualToAnchor:rightContainer.centerYAnchor]
        .active = YES;

    if (showsCheckbox) {
      _checkbox = [[KKCheckboxView alloc] initWithFrame:NSZeroRect];
      _checkbox.translatesAutoresizingMaskIntoConstraints = NO;
      _checkbox.onToggle = ^(BOOL isChecked) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf)
          return;
        strongSelf->_isEnabled = isChecked;
        strongSelf->_chevron.isInteractive = isChecked;
        if (!isChecked && strongSelf->_isExpanded) {
          strongSelf->_isExpanded = NO;
          [strongSelf->_chevron setExpanded:NO animated:YES];
          if (strongSelf.onExpandedChanged) {
            strongSelf.onExpandedChanged(NO);
          }
        }
        if (strongSelf.onEnabledChanged) {
          strongSelf.onEnabledChanged(isChecked);
        }
      };

      [rightContainer addSubview:_checkbox];
      [NSLayoutConstraint activateConstraints:@[
        [_checkbox.trailingAnchor
            constraintEqualToAnchor:rightContainer.trailingAnchor
                           constant:-kCheckboxTrailingMargin],
        [_checkbox.centerYAnchor
            constraintEqualToAnchor:rightContainer.centerYAnchor],
        [_checkbox.widthAnchor constraintEqualToConstant:12.0],
        [_checkbox.heightAnchor constraintEqualToConstant:12.0],
        [_statusLabel.trailingAnchor
            constraintEqualToAnchor:_checkbox.leadingAnchor
                           constant:-kStatusCheckboxGap],
      ]];
    } else {
      [_statusLabel.trailingAnchor
          constraintEqualToAnchor:rightContainer.trailingAnchor
                         constant:-kStatusTrailingMargin]
          .active = YES;
    }

    self.rightView = rightContainer;
  }
  return self;
}

- (void)setIsEnabled:(BOOL)isEnabled {
  _isEnabled = isEnabled;
  _checkbox.isChecked = isEnabled;
  _chevron.isInteractive = isEnabled;
  if (!isEnabled && _isExpanded) {
    _isExpanded = NO;
    [_chevron setExpanded:NO animated:YES];
  }
}

- (void)setIsExpanded:(BOOL)isExpanded {
  _isExpanded = isExpanded;
  [_chevron setExpanded:isExpanded animated:NO];
}

- (void)setStatusText:(NSString *)statusText {
  _statusText = [statusText copy];
  _statusLabel.stringValue = statusText ?: @"";
  _statusLabel.hidden = (statusText.length == 0);
}

- (void)setStatusColor:(NSColor *)statusColor {
  _statusColor = statusColor;
  _statusLabel.textColor = statusColor ?: [NSColor tertiaryLabelColor];
}

@end
