/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKEmptyLanesView.h"
#import "../../Style/NSColor+KKColors.h"

@implementation KKEmptyLanesView

- (instancetype)init {
  self = [super initWithFrame:NSZeroRect];
  if (self) {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    // Opaque fill matches the scroll view's background so hidden lanes
    // beneath are completely covered.
    self.wantsLayer = YES;
    self.layer.backgroundColor =
        [NSColor colorWithWhite:0.15 alpha:1.0].CGColor;

    NSImage *icon =
        [NSImage imageWithSystemSymbolName:@"rectangle.on.rectangle.slash"
                  accessibilityDescription:nil];
    NSImageView *iconView = [NSImageView imageViewWithImage:icon];
    iconView.symbolConfiguration = [NSImageSymbolConfiguration
        configurationWithPointSize:11.0
                            weight:NSFontWeightMedium];
    iconView.contentTintColor =
        [[NSColor inspectorLabel] colorWithAlphaComponent:0.45];

    NSTextField *label = [NSTextField labelWithString:@"All lanes hidden"];
    label.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
    label.textColor = [[NSColor inspectorLabel] colorWithAlphaComponent:0.45];
    label.backgroundColor = [NSColor clearColor];
    label.bordered = NO;
    label.editable = NO;

    NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 6.0;
    [row addArrangedSubview:iconView];
    [row addArrangedSubview:label];
    [self addSubview:row];

    [NSLayoutConstraint activateConstraints:@[
      [row.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
      [row.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
  }
  return self;
}

@end
