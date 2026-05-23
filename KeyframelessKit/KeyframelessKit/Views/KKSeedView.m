/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKSeedView.h"
#import "KKLocalized.h"

#import "../Style/NSColor+KKColors.h"
#import "KKValueTextField.h"

@interface KKSeedView () <NSTextFieldDelegate>
@end

@implementation KKSeedView {
  KKValueTextField *_field;
  NSButton *_button;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self) {
    [self buildUI];
  }
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

- (void)buildUI {
  NSStackView *stack = [NSStackView stackViewWithViews:@[]];
  stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  stack.spacing = 6.0;
  stack.translatesAutoresizingMaskIntoConstraints = NO;

  _field = [KKValueTextField valueField];
  _field.delegate = self;
  [_field.widthAnchor constraintGreaterThanOrEqualToConstant:72.0].active = YES;
  [stack addArrangedSubview:_field];

  _button = [NSButton
      buttonWithImage:[NSImage
                          imageWithSystemSymbolName:@"shuffle"
                           accessibilityDescription:
                               KKLoc(@"Randomize",
                                     @"Accessibility: randomize seed button.")]
               target:self
               action:@selector(rerollClicked:)];
  _button.bezelStyle = NSBezelStyleAccessoryBarAction;
  _button.bordered = NO;
  _button.translatesAutoresizingMaskIntoConstraints = NO;
  _button.contentTintColor = [NSColor accentMatchingHost];
  [_button.widthAnchor constraintEqualToConstant:22.0].active = YES;
  [_button.heightAnchor constraintEqualToConstant:22.0].active = YES;
  [stack addArrangedSubview:_button];

  [self addSubview:stack];
  [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor].active =
      YES;
  [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor].active = YES;

  [self updateField];
}

- (void)updateField {
  // Never write stringValue into a live field — it re-creates the field editor
  // and reselects, yanking focus back. The post-commit refresh is deferred to
  // after the field resigns (see controlTextDidEndEditing:).
  if (_field.kkEditing)
    return;
  if (_seed == 0) {
    _field.stringValue = @"";
    _field.placeholderString = @"0";
  } else {
    _field.stringValue = [NSString stringWithFormat:@"%u", _seed];
  }
}

- (void)setSeed:(uint32_t)seed {
  _seed = seed;
  [self updateField];
}

- (void)rerollClicked:(id)sender {
  if (_onReroll)
    _onReroll();
}

// Return commits and fully defocuses (suppressing AppKit's default reselect).
- (BOOL)control:(NSControl *)control
               textView:(NSTextView *)textView
    doCommandBySelector:(SEL)commandSelector {
  return KKValueFieldHandleReturnCommand(self.window, commandSelector);
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
  unsigned long long val = _field.stringValue.longLongValue;
  uint32_t newSeed = (uint32_t)(val & 0xFFFFFFFF);
  if (newSeed != _seed) {
    _seed = newSeed;
    if (_onSeedChanged)
      _onSeedChanged(newSeed);
  }
  // Normalize the displayed text (empty→placeholder, clamp to uint32) after the
  // field has fully resigned — updateField no-ops while it's still editing.
  __weak typeof(self) weak = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    [weak updateField];
  });
}

@end
