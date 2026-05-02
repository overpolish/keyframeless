/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKEmptyLanesView.h"
#import "../../Style/NSColor+KKColors.h"

@implementation KKEmptyLanesView {
  NSImageView *_iconView;
  NSTextField *_label;
  NSString *_currentText;
  NSString *_currentIconName;
}

- (instancetype)init {
  self = [super initWithFrame:NSZeroRect];
  if (self) {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.wantsLayer = YES;
    self.layer.backgroundColor =
        [NSColor colorWithWhite:0.15 alpha:1.0].CGColor;

    _iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _iconView.symbolConfiguration = [NSImageSymbolConfiguration
        configurationWithPointSize:11.0
                            weight:NSFontWeightMedium];
    _iconView.contentTintColor =
        [[NSColor inspectorLabel] colorWithAlphaComponent:0.45];

    _label = [NSTextField labelWithString:@""];
    _label.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
    _label.textColor = [[NSColor inspectorLabel] colorWithAlphaComponent:0.45];
    _label.backgroundColor = [NSColor clearColor];
    _label.bordered = NO;
    _label.editable = NO;

    NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 6.0;
    [row addArrangedSubview:_iconView];
    [row addArrangedSubview:_label];
    [self addSubview:row];

    [NSLayoutConstraint activateConstraints:@[
      [row.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
      [row.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];

    [self setText:@"All lanes hidden" iconName:@"rectangle.on.rectangle.slash"];
  }
  return self;
}

- (void)setText:(NSString *)text iconName:(NSString *)iconName {
  if ([_currentText isEqualToString:text ?: @""] &&
      [_currentIconName isEqualToString:iconName ?: @""])
    return;
  _currentText = [text copy] ?: @"";
  _currentIconName = [iconName copy] ?: @"";
  _label.stringValue = _currentText;
  _iconView.image = iconName.length
                        ? [NSImage imageWithSystemSymbolName:iconName
                                    accessibilityDescription:nil]
                        : nil;
}

@end
