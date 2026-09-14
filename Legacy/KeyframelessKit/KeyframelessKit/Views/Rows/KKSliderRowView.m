/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKSliderRowView.h"
#import "KKSliderView.h"
#import "KKValueTextField.h"

static const CGFloat kFieldWidth = 56.0;
static const CGFloat kFieldHeight = 18.0;
static const CGFloat kSliderHeight = 20.0;
static const CGFloat kSliderToFieldGap = 6.0;

@interface KKSliderRowView () <NSTextFieldDelegate>
@end

@implementation KKSliderRowView {
  KKSliderView *_slider;
  KKValueTextField *_field;
  NSTextField *_unitLabel;
  double (^_binding)(void);
  void (^_onValue)(double);
  NSString *_unit;
}

- (instancetype)initWithTitle:(NSString *)title
                      tooltip:(NSString *)tooltip
                    laneColor:(NSColor *)laneColor
                     minValue:(double)minValue
                     maxValue:(double)maxValue
                         unit:(NSString *)unit
                      binding:(double (^)(void))binding
                      onValue:(void (^)(double))onValue
                  onDragBegin:(void (^)(void))onDragBegin
                    onDragEnd:(void (^)(void))onDragEnd {
  self = [super initWithTitle:title tooltip:tooltip laneColor:laneColor];
  if (!self)
    return nil;
  _binding = [binding copy];
  _onValue = [onValue copy];
  _unit = [unit copy];

  _slider = [[KKSliderView alloc] initWithFrame:NSZeroRect];
  _slider.translatesAutoresizingMaskIntoConstraints = NO;
  _slider.minValue = minValue;
  _slider.maxValue = maxValue;
  _slider.continuous = YES;
  __weak typeof(self) weakSelf = self;
  _slider.onDragBegin = onDragBegin;
  _slider.onDragEnd = onDragEnd;
  _slider.target = self;
  _slider.action = @selector(_sliderChanged:);
  [self.controlContainer addSubview:_slider];

  _field = [KKValueTextField valueField];
  _field.delegate = self;
  _field.target = self;
  _field.action = @selector(_fieldChanged:);
  // Scrub the whole range in ~200 plain steps; Shift/Option adjust at drag
  // time.
  double span = maxValue - minValue;
  _field.scrubStep = span > 0 ? span / 200.0 : 1.0;
  _field.onScrubBegin = onDragBegin;
  _field.onScrubEnd = onDragEnd;
  _field.translatesAutoresizingMaskIntoConstraints = NO;
  [self.controlContainer addSubview:_field];

  if (unit.length) {
    _unitLabel = [NSTextField labelWithString:unit];
    _unitLabel.font = [NSFont systemFontOfSize:10.0];
    _unitLabel.textColor = [NSColor secondaryLabelColor];
    _unitLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.controlContainer addSubview:_unitLabel];
  }

  NSMutableArray<NSLayoutConstraint *> *cs = [@[
    [_slider.leadingAnchor
        constraintEqualToAnchor:self.controlContainer.leadingAnchor],
    [_slider.centerYAnchor
        constraintEqualToAnchor:self.controlContainer.centerYAnchor],
    [_slider.heightAnchor constraintEqualToConstant:kSliderHeight],
    [_slider.trailingAnchor constraintEqualToAnchor:_field.leadingAnchor
                                           constant:-kSliderToFieldGap],
    [_field.centerYAnchor
        constraintEqualToAnchor:self.controlContainer.centerYAnchor],
    [_field.widthAnchor constraintEqualToConstant:kFieldWidth],
    [_field.heightAnchor constraintEqualToConstant:kFieldHeight],
  ] mutableCopy];
  if (_unitLabel) {
    [cs addObjectsFromArray:@[
      [_field.trailingAnchor constraintEqualToAnchor:_unitLabel.leadingAnchor
                                            constant:-2.0],
      [_unitLabel.centerYAnchor
          constraintEqualToAnchor:self.controlContainer.centerYAnchor],
      [_unitLabel.trailingAnchor
          constraintEqualToAnchor:self.controlContainer.trailingAnchor],
    ]];
  } else {
    [cs addObject:[_field.trailingAnchor
                      constraintEqualToAnchor:self.controlContainer
                                                  .trailingAnchor]];
  }
  [NSLayoutConstraint activateConstraints:cs];

  [self popoverDidRefresh];
  (void)weakSelf;
  return self;
}

- (void)popoverDidRefresh {
  [super popoverDidRefresh];
  if (!_binding)
    return;
  double v = _binding();
  _slider.doubleValue = v;
  if (!_field.kkEditing)
    _field.stringValue = [NSString stringWithFormat:@"%g", v];
}

- (void)_sliderChanged:(KKSliderView *)sender {
  if (_onValue)
    _onValue(sender.doubleValue);
  if (!_field.kkEditing)
    _field.stringValue = [NSString stringWithFormat:@"%g", sender.doubleValue];
}

- (void)_fieldChanged:(KKValueTextField *)sender {
  double v = sender.doubleValue;
  if (v < _slider.minValue)
    v = _slider.minValue;
  if (v > _slider.maxValue)
    v = _slider.maxValue;
  _slider.doubleValue = v;
  if (_onValue)
    _onValue(v);
}

- (BOOL)control:(NSControl *)control
               textView:(NSTextView *)textView
    doCommandBySelector:(SEL)commandSelector {
  if (KKValueFieldHandleReturnCommand(self.window, commandSelector))
    return YES;
  return KKValueFieldHandleTabCommand((NSTextField *)control, commandSelector);
}

@end
