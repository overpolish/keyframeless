/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPopupSelectView.h"
#import "../Style/KKTokens.h"

@implementation KKPopupSelectView

- (instancetype)initWithTitles:(NSArray<NSString *> *)titles {
  self = [super initWithFrame:NSZeroRect];
  if (self) {
    _popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_popup addItemsWithTitles:titles];
    _popup.bordered = NO;
    _popup.font = [NSFont systemFontOfSize:11.0];
    ((NSPopUpButtonCell *)_popup.cell).arrowPosition = NSPopUpNoArrow;
    _popup.translatesAutoresizingMaskIntoConstraints = NO;
    _popup.target = self;
    _popup.action = @selector(_popupChanged:);

    NSColor *chevronColor = [NSColor colorWithRed:0xAB / 255.0
                                            green:0xAB / 255.0
                                             blue:0xAA / 255.0
                                            alpha:1.0];
    NSImageSymbolConfiguration *chevronCfg = [NSImageSymbolConfiguration
        configurationWithPointSize:11.0
                            weight:NSFontWeightSemibold];
    CGFloat chevronW = 11.0 - 3.0;

    NSImage *upImg = [[NSImage imageWithSystemSymbolName:@"chevron.up"
                                accessibilityDescription:nil]
        imageWithSymbolConfiguration:chevronCfg];
    NSImageView *upChevron = [[NSImageView alloc] init];
    upChevron.image = upImg;
    upChevron.contentTintColor = chevronColor;
    upChevron.imageScaling = NSImageScaleAxesIndependently;
    upChevron.translatesAutoresizingMaskIntoConstraints = NO;

    NSImage *downImg = [[NSImage imageWithSystemSymbolName:@"chevron.down"
                                  accessibilityDescription:nil]
        imageWithSymbolConfiguration:chevronCfg];
    NSImageView *downChevron = [[NSImageView alloc] init];
    downChevron.image = downImg;
    downChevron.contentTintColor = chevronColor;
    downChevron.imageScaling = NSImageScaleAxesIndependently;
    downChevron.translatesAutoresizingMaskIntoConstraints = NO;

    [self addSubview:_popup];
    [self addSubview:upChevron];
    [self addSubview:downChevron];

    [NSLayoutConstraint activateConstraints:@[
      [_popup.trailingAnchor constraintEqualToAnchor:upChevron.leadingAnchor],
      [_popup.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],

      [upChevron.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                               constant:-KKSpacingLG],
      [upChevron.widthAnchor constraintEqualToConstant:chevronW],
      [upChevron.heightAnchor constraintEqualToConstant:6.0],
      [upChevron.bottomAnchor constraintEqualToAnchor:self.centerYAnchor
                                             constant:0.0],

      [downChevron.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                 constant:-KKSpacingLG],
      [downChevron.widthAnchor constraintEqualToConstant:chevronW],
      [downChevron.heightAnchor constraintEqualToConstant:6.0],
      [downChevron.topAnchor constraintEqualToAnchor:self.centerYAnchor
                                            constant:0.0],
    ]];
  }
  return self;
}

- (void)selectIndex:(NSInteger)index {
  if (index >= 0 && index < _popup.numberOfItems)
    [_popup selectItemAtIndex:index];
}

- (void)_popupChanged:(NSPopUpButton *)sender {
  if (self.onSelectionChanged)
    self.onSelectionChanged(sender.indexOfSelectedItem);
}

@end
