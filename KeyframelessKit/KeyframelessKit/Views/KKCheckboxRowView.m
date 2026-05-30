/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKCheckboxRowView.h"
#import "../Style/NSColor+KKColors.h"
#import "KKCheckboxView.h"

// Matches KKSegmentEditView's kLinkedHeight/kRowGap so a row dropped below an
// editor lines up visually with its internal Linked row.
static const CGFloat kRowHeight = 20.0;
static const CGFloat kCheckSize = 12.0;

@implementation KKCheckboxRowView {
  NSTextField *_label;
  KKCheckboxView *_check;
  BOOL (^_binding)(void);
  BOOL (^_disabledBinding)(void);
  void (^_onToggle)(BOOL);
}

- (instancetype)initWithTitle:(NSString *)title
                      tooltip:(NSString *)tooltip
                      binding:(BOOL (^)(void))binding
              disabledBinding:(BOOL (^)(void))disabledBinding
                     onToggle:(void (^)(BOOL))onToggle {
  self = [super initWithFrame:NSZeroRect];
  if (!self)
    return nil;
  _binding = [binding copy];
  _disabledBinding = [disabledBinding copy];
  _onToggle = [onToggle copy];

  _label = [NSTextField labelWithString:title];
  _label.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
  _label.textColor = [NSColor inspectorLabel];
  _label.translatesAutoresizingMaskIntoConstraints = NO;
  _label.toolTip = tooltip;
  [self addSubview:_label];

  _check = [[KKCheckboxView alloc] initWithFrame:NSZeroRect];
  _check.translatesAutoresizingMaskIntoConstraints = NO;
  _check.toolTip = tooltip;
  __weak typeof(self) weakSelf = self;
  _check.onToggle = ^(BOOL isOn) {
    __strong typeof(weakSelf) s = weakSelf;
    if (!s)
      return;
    if (s->_disabledBinding && s->_disabledBinding()) {
      // Disabled state: snap back. KKCheckboxView already toggled its own
      // _isChecked, so push the binding's current value back into it.
      s->_check.isChecked = s->_binding ? s->_binding() : NO;
      return;
    }
    if (s->_onToggle)
      s->_onToggle(isOn);
  };
  [self addSubview:_check];

  [NSLayoutConstraint activateConstraints:@[
    [_label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [_label.centerYAnchor constraintEqualToAnchor:_check.centerYAnchor],
    [_check.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [_check.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [_check.widthAnchor constraintEqualToConstant:kCheckSize],
    [_check.heightAnchor constraintEqualToConstant:kCheckSize],
    [self.heightAnchor constraintEqualToConstant:kRowHeight],
  ]];

  [self popoverDidRefresh];
  return self;
}

- (NSSize)intrinsicContentSize {
  return NSMakeSize(NSViewNoIntrinsicMetric, kRowHeight);
}

- (void)popoverDidRefresh {
  if (_binding)
    _check.isChecked = _binding();
  BOOL disabled = _disabledBinding ? _disabledBinding() : NO;
  self.alphaValue = disabled ? 0.4 : 1.0;
}

@end
