/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKGradientControl.h"
#import "KKGradientBarView.h"
#import "KKGradientFavoritesPopover.h"
#import "KKTokens.h"
#import "NSColor+KKColors.h"

@implementation KKGradientControl {
  KKGradientBarView *_bar;
  KKGradientFavoritesPopover *_favPopover;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  CGFloat rowH = 36.0;
  NSRect frame = NSMakeRect(frameRect.origin.x, frameRect.origin.y,
                            frameRect.size.width, rowH);
  self = [super initWithFrame:frame];
  if (!self)
    return nil;

  self.autoresizingMask = NSViewWidthSizable;

  _bar = [[KKGradientBarView alloc] initWithFrame:NSZeroRect];
  _bar.translatesAutoresizingMaskIntoConstraints = NO;
  _favPopover = [[KKGradientFavoritesPopover alloc] init];

  NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration
      configurationWithPointSize:10.0
                          weight:NSFontWeightRegular];
  NSColor *tint = [NSColor.inspectorLabel colorWithAlphaComponent:0.5];

  NSButton *star = [self iconButtonNamed:@"star" config:cfg tint:tint];
  NSButton *reverse = [self iconButtonNamed:@"arrow.left.and.right"
                                     config:cfg
                                       tint:tint];
  NSButton *distribute = [self iconButtonNamed:@"rectangle.split.3x1"
                                        config:cfg
                                          tint:tint];

  [self addSubview:_bar];
  [self addSubview:star];
  [self addSubview:reverse];
  [self addSubview:distribute];

  [NSLayoutConstraint activateConstraints:@[
    [star.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [star.topAnchor constraintEqualToAnchor:_bar.topAnchor constant:5.0],
    [star.widthAnchor constraintEqualToConstant:16.0],
    [star.heightAnchor constraintEqualToConstant:16.0],

    [_bar.leadingAnchor constraintEqualToAnchor:star.trailingAnchor
                                       constant:KKSpacingSM],
    [_bar.trailingAnchor constraintEqualToAnchor:reverse.leadingAnchor
                                        constant:-KKSpacingSM],
    [_bar.topAnchor constraintEqualToAnchor:self.topAnchor],
    [_bar.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

    [reverse.trailingAnchor constraintEqualToAnchor:distribute.leadingAnchor
                                           constant:-KKSpacingSM],
    [reverse.topAnchor constraintEqualToAnchor:_bar.topAnchor constant:5.0],
    [reverse.widthAnchor constraintEqualToConstant:16.0],
    [reverse.heightAnchor constraintEqualToConstant:16.0],

    [distribute.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [distribute.topAnchor constraintEqualToAnchor:_bar.topAnchor constant:5.0],
    [distribute.widthAnchor constraintEqualToConstant:16.0],
    [distribute.heightAnchor constraintEqualToConstant:16.0],
  ]];

  star.target = self;
  star.action = @selector(_kkStarTapped:);
  reverse.target = self;
  reverse.action = @selector(_kkReverseTapped:);
  distribute.target = self;
  distribute.action = @selector(_kkDistributeTapped:);

  __weak typeof(self) weakSelf = self;
  _bar.onStopsChanged = ^(NSArray<KKGradientStop *> *newStops) {
    [weakSelf _kkEmitChange:newStops];
  };
  _bar.onDragBegin = ^{
    __strong typeof(weakSelf) s = weakSelf;
    if (s.onDragBegin)
      s.onDragBegin();
  };
  _bar.onDragEnd = ^{
    __strong typeof(weakSelf) s = weakSelf;
    if (s.onDragEnd)
      s.onDragEnd();
  };
  _favPopover.onApplyFavorite = ^(NSArray<KKGradientStop *> *newStops) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    strongSelf->_bar.stops = newStops;
    [strongSelf _kkEmitChange:newStops];
  };

  return self;
}

- (NSButton *)iconButtonNamed:(NSString *)name
                       config:(NSImageSymbolConfiguration *)cfg
                         tint:(NSColor *)tint {
  NSImage *img = [[NSImage imageWithSystemSymbolName:name
                            accessibilityDescription:nil]
      imageWithSymbolConfiguration:cfg];
  NSButton *btn = [NSButton buttonWithImage:img target:nil action:nil];
  btn.bordered = NO;
  btn.contentTintColor = tint;
  btn.translatesAutoresizingMaskIntoConstraints = NO;
  return btn;
}

- (void)_kkEmitChange:(NSArray<KKGradientStop *> *)newStops {
  _favPopover.currentStops = newStops;
  if (_onStopsChanged)
    _onStopsChanged(newStops);
}

- (void)_kkStarTapped:(NSButton *)sender {
  [_favPopover showRelativeToRect:sender.bounds ofView:sender];
}

- (void)_kkReverseTapped:(NSButton *)sender {
  [_bar reverseStops];
}

- (void)_kkDistributeTapped:(NSButton *)sender {
  [_bar distributeStopsEvenly];
}

- (NSArray<KKGradientStop *> *)stops {
  return _bar.stops;
}

- (void)setStops:(NSArray<KKGradientStop *> *)stops {
  _bar.stops = stops;
  _favPopover.currentStops = stops;
}

@end
