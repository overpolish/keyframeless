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

@implementation KKCustomGroupHeaderView {
  KKChevronView *_chevron;
  KKCheckboxView *_checkbox;
}

- (instancetype)initWithFrame:(NSRect)frameRect
                   apiManager:(id<PROAPIAccessing>)apiManager
                  parameterId:(UInt32)parameterId
                         text:(NSString *)text
                         icon:(NSImage *)icon {
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

    NSView *rightContainer = [[NSView alloc] initWithFrame:NSZeroRect];
    [rightContainer addSubview:_checkbox];
    [NSLayoutConstraint activateConstraints:@[
      [_checkbox.trailingAnchor
          constraintEqualToAnchor:rightContainer.trailingAnchor
                         constant:-kCheckboxTrailingMargin],
      [_checkbox.centerYAnchor
          constraintEqualToAnchor:rightContainer.centerYAnchor],
      [_checkbox.widthAnchor constraintEqualToConstant:12.0],
      [_checkbox.heightAnchor constraintEqualToConstant:12.0],
    ]];
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

@end
