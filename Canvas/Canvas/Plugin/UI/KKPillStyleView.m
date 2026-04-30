/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPillStyleView.h"
#import <KeyframelessKit/KeyframelessKit.h>

static const CGFloat kPillSpacing = 2.0;
static const CGFloat kPillCorner = 3.0;
static const CGFloat kPillSize = 22.0;

@implementation KKPillStyleView {
  NSArray<NSButton *> *_buttons;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self) {
    _selectedIndex = 0;
    [self buildButtons];
  }
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

- (NSInteger)pillCount {
  return 0;
}

- (NSImage *)imageForIndex:(NSInteger)index active:(BOOL)active {
  return [[NSImage alloc] initWithSize:NSMakeSize(kPillSize, kPillSize)];
}

- (void)buildButtons {
  NSMutableArray<NSButton *> *btns = [NSMutableArray array];

  NSStackView *stack = [NSStackView stackViewWithViews:@[]];
  stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  stack.spacing = kPillSpacing;
  stack.translatesAutoresizingMaskIntoConstraints = NO;

  for (NSInteger i = 0; i < [self pillCount]; i++) {
    BOOL active = (i == _selectedIndex);
    NSButton *btn = [NSButton buttonWithImage:[self imageForIndex:i
                                                           active:active]
                                       target:self
                                       action:@selector(pillClicked:)];
    btn.bezelStyle = NSBezelStyleSmallSquare;
    btn.bordered = NO;
    btn.tag = i;
    btn.wantsLayer = YES;
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    [btn.widthAnchor constraintEqualToConstant:kPillSize].active = YES;
    [btn.heightAnchor constraintEqualToConstant:kPillSize].active = YES;
    [stack addArrangedSubview:btn];
    [btns addObject:btn];
  }

  [self addSubview:stack];
  [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor].active =
      YES;
  [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor].active = YES;

  _buttons = [btns copy];
  [self updateButtonAppearance];
}

- (void)updateButtonAppearance {
  for (NSInteger i = 0; i < (NSInteger)_buttons.count; i++) {
    NSButton *btn = _buttons[i];
    BOOL active = (i == _selectedIndex);
    btn.image = [self imageForIndex:i active:active];
    btn.layer.cornerRadius = kPillCorner;
    if (active) {
      btn.layer.backgroundColor = [NSColor inspectorBackground].CGColor;
      btn.layer.borderColor = [NSColor accentMatchingHost].CGColor;
      btn.layer.borderWidth = 1.0;
    } else {
      btn.layer.backgroundColor =
          [[NSColor inspectorLabel] colorWithAlphaComponent:0.06].CGColor;
      btn.layer.borderColor = [NSColor clearColor].CGColor;
      btn.layer.borderWidth = 0.0;
    }
  }
}

- (void)rebuildImages {
  [self updateButtonAppearance];
}

- (void)pillClicked:(NSButton *)sender {
  _selectedIndex = sender.tag;
  [self updateButtonAppearance];
  if (_onSelectionChanged)
    _onSelectionChanged(_selectedIndex);
}

- (void)setSelectedIndex:(NSInteger)selectedIndex {
  _selectedIndex = selectedIndex;
  [self updateButtonAppearance];
}

@end
