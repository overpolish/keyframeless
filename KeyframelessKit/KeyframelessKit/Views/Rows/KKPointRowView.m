/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPointRowView.h"
#import "KKValueTextField.h"
#import "NSColor+KKColors.h"

static const CGFloat kFieldWidth = 44.0;
static const CGFloat kFieldHeight = 18.0;
static const CGFloat kFieldGap = 4.0;
static const CGFloat kCompLabelGap = 2.0;

@interface KKPointRowView () <NSTextFieldDelegate>
@end

@implementation KKPointRowView {
  NSArray<KKValueTextField *> *_fields;
  NSArray<NSString *> *_componentLabels;
  NSArray<NSNumber *> * (^_binding)(void);
  void (^_onValue)(NSArray<NSNumber *> *);
  void (^_onDragBegin)(void);
  void (^_onDragEnd)(void);
}

- (instancetype)initWithTitle:(NSString *)title
                      tooltip:(NSString *)tooltip
                    laneColor:(NSColor *)laneColor
              componentLabels:(NSArray<NSString *> *)componentLabels
                      binding:(NSArray<NSNumber *> * (^)(void))binding
                      onValue:(void (^)(NSArray<NSNumber *> *))onValue
                  onDragBegin:(void (^)(void))onDragBegin
                    onDragEnd:(void (^)(void))onDragEnd {
  self = [super initWithTitle:title tooltip:tooltip laneColor:laneColor];
  if (!self)
    return nil;
  _componentLabels = [componentLabels copy];
  _binding = [binding copy];
  _onValue = [onValue copy];
  _onDragBegin = [onDragBegin copy];
  _onDragEnd = [onDragEnd copy];

  NSMutableArray<KKValueTextField *> *fields = [NSMutableArray array];
  NSMutableArray<NSLayoutConstraint *> *cs = [NSMutableArray array];
  NSView *prev = nil;
  for (NSString *compName in _componentLabels) {
    NSTextField *cap = [NSTextField labelWithString:compName];
    cap.font = [NSFont systemFontOfSize:10.0];
    cap.textColor = [NSColor secondaryLabelColor];
    cap.translatesAutoresizingMaskIntoConstraints = NO;
    [self.controlContainer addSubview:cap];

    KKValueTextField *field = [KKValueTextField valueField];
    field.delegate = self;
    field.target = self;
    field.action = @selector(_fieldChanged:);
    field.translatesAutoresizingMaskIntoConstraints = NO;
    [self.controlContainer addSubview:field];
    [fields addObject:field];

    if (prev) {
      [cs addObject:[cap.leadingAnchor
                        constraintEqualToAnchor:prev.trailingAnchor
                                       constant:kFieldGap]];
    } else {
      [cs addObject:[cap.leadingAnchor
                        constraintEqualToAnchor:self.controlContainer
                                                    .leadingAnchor]];
    }
    [cs addObjectsFromArray:@[
      [cap.centerYAnchor
          constraintEqualToAnchor:self.controlContainer.centerYAnchor],
      [field.leadingAnchor constraintEqualToAnchor:cap.trailingAnchor
                                          constant:kCompLabelGap],
      [field.centerYAnchor
          constraintEqualToAnchor:self.controlContainer.centerYAnchor],
      [field.widthAnchor constraintEqualToConstant:kFieldWidth],
      [field.heightAnchor constraintEqualToConstant:kFieldHeight],
    ]];
    prev = field;
  }
  if (prev)
    [cs addObject:[prev.trailingAnchor
                      constraintEqualToAnchor:self.controlContainer
                                                  .trailingAnchor]];
  [NSLayoutConstraint activateConstraints:cs];

  _fields = [fields copy];
  [self popoverDidRefresh];
  return self;
}

- (void)popoverDidRefresh {
  [super popoverDidRefresh];
  if (!_binding)
    return;
  NSArray<NSNumber *> *vals = _binding();
  for (NSUInteger i = 0; i < _fields.count; i++) {
    KKValueTextField *f = _fields[i];
    if (f.kkEditing)
      continue; // don't clobber an in-progress edit
    double v = (i < vals.count) ? vals[i].doubleValue : 0.0;
    f.stringValue = [NSString stringWithFormat:@"%g", v];
  }
}

- (void)_fieldChanged:(KKValueTextField *)sender {
  if (!_onValue)
    return;
  if (_onDragBegin)
    _onDragBegin();
  NSMutableArray<NSNumber *> *vals =
      [NSMutableArray arrayWithCapacity:_fields.count];
  for (KKValueTextField *f in _fields)
    [vals addObject:@(f.doubleValue)];
  _onValue(vals);
  if (_onDragEnd)
    _onDragEnd();
}

- (BOOL)control:(NSControl *)control
               textView:(NSTextView *)textView
    doCommandBySelector:(SEL)commandSelector {
  if (KKValueFieldHandleReturnCommand(self.window, commandSelector))
    return YES;
  return KKValueFieldHandleTabCommand((NSTextField *)control, commandSelector);
}

@end
