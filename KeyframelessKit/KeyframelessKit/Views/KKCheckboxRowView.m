/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKCheckboxRowView.h"
#import "KKCheckboxView.h"

static const CGFloat kCheckSize = 12.0;

@implementation KKCheckboxRowView {
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
  return [self initWithTitle:title
                     tooltip:tooltip
                   laneColor:nil
                     binding:binding
             disabledBinding:disabledBinding
                    onToggle:onToggle];
}

- (instancetype)initWithTitle:(NSString *)title
                      tooltip:(NSString *)tooltip
                    laneColor:(NSColor *)laneColor
                      binding:(BOOL (^)(void))binding
              disabledBinding:(BOOL (^)(void))disabledBinding
                     onToggle:(void (^)(BOOL))onToggle {
  self = [super initWithTitle:title tooltip:tooltip laneColor:laneColor];
  if (!self)
    return nil;
  _binding = [binding copy];
  _disabledBinding = [disabledBinding copy];
  _onToggle = [onToggle copy];

  _check = [[KKCheckboxView alloc] initWithFrame:NSZeroRect];
  _check.translatesAutoresizingMaskIntoConstraints = NO;
  _check.toolTip = tooltip;
  __weak typeof(self) weakSelf = self;
  _check.onToggle = ^(BOOL isOn) {
    __strong typeof(weakSelf) s = weakSelf;
    if (!s)
      return;
    if (s->_disabledBinding && s->_disabledBinding()) {
      // Snap back - KKCheckboxView already toggled its own _isChecked.
      s->_check.isChecked = s->_binding ? s->_binding() : NO;
      return;
    }
    if (s->_onToggle)
      s->_onToggle(isOn);
  };
  [self.controlContainer addSubview:_check];
  [NSLayoutConstraint activateConstraints:@[
    [_check.leadingAnchor
        constraintEqualToAnchor:self.controlContainer.leadingAnchor],
    [_check.trailingAnchor
        constraintEqualToAnchor:self.controlContainer.trailingAnchor],
    [_check.centerYAnchor
        constraintEqualToAnchor:self.controlContainer.centerYAnchor],
    [_check.widthAnchor constraintEqualToConstant:kCheckSize],
    [_check.heightAnchor constraintEqualToConstant:kCheckSize],
  ]];

  [self popoverDidRefresh];
  return self;
}

- (void)popoverDidRefresh {
  [super popoverDidRefresh];
  if (_binding)
    _check.isChecked = _binding();
  BOOL disabled = _disabledBinding ? _disabledBinding() : NO;
  self.alphaValue = disabled ? 0.4 : 1.0;
}

// The inner KKCheckboxView uses NSClickGestureRecognizer, which doesn't
// reliably fire inside FCP's ApplicationDefined popovers (the outside-click
// monitors and responder chain interact with the gesture machinery). Handle
// the click at the row level via mouseDown: instead - same approach as
// KKPillToggleRowView. Whole row is clickable (label too), which is also
// a UX win over a tiny 12pt hit target.
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

- (void)mouseDown:(NSEvent *)event {
  if (_disabledBinding && _disabledBinding())
    return;
  BOOL newState = !(_binding ? _binding() : _check.isChecked);
  _check.isChecked = newState;
  if (_onToggle)
    _onToggle(newState);
}

@end
