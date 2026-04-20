/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "SeedView.h"
#import <KeyframelessKit/KeyframelessKit.h>

@interface KKSeedTextField : NSTextField
@end

@implementation KKSeedTextField

- (BOOL)performKeyEquivalent:(NSEvent *)event {
  if (self.currentEditor) {
    [self.currentEditor keyDown:event];
    return YES;
  }
  return [super performKeyEquivalent:event];
}

- (BOOL)becomeFirstResponder {
  BOOL ok = [super becomeFirstResponder];
  if (ok) {
    NSTextView *editor = (NSTextView *)self.currentEditor;
    NSColor *accent = [NSColor accent];
    editor.insertionPointColor = accent;
    editor.selectedTextAttributes = @{
      NSBackgroundColorAttributeName : [accent colorWithAlphaComponent:0.3],
      NSForegroundColorAttributeName : [NSColor labelColor],
    };
  }
  return ok;
}

@end

@interface KKSeedView () <NSTextFieldDelegate>
@end

@implementation KKSeedView {
  NSTextField *_field;
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

  _field = [[KKSeedTextField alloc] init];
  _field.font = [NSFont monospacedDigitSystemFontOfSize:11.0
                                                 weight:NSFontWeightRegular];
  _field.alignment = NSTextAlignmentRight;
  _field.textColor = [NSColor inspectorLabel];
  _field.backgroundColor = [NSColor clearColor];
  _field.bordered = NO;
  _field.editable = YES;
  _field.selectable = YES;
  _field.focusRingType = NSFocusRingTypeNone;
  _field.delegate = self;
  _field.translatesAutoresizingMaskIntoConstraints = NO;
  [_field.widthAnchor constraintGreaterThanOrEqualToConstant:60.0].active = YES;
  [stack addArrangedSubview:_field];

  _button =
      [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"shuffle"
                                          accessibilityDescription:@"Randomize"]
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

- (void)controlTextDidEndEditing:(NSNotification *)notification {
  unsigned long long val = _field.stringValue.longLongValue;
  uint32_t newSeed = (uint32_t)(val & 0xFFFFFFFF);
  if (newSeed != _seed) {
    _seed = newSeed;
    [self updateField];
    if (_onSeedChanged)
      _onSeedChanged(newSeed);
  }
}

@end
