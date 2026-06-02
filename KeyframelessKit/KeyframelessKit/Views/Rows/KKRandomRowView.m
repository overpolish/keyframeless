/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKRandomRowView.h"
#import "KKSeedView.h"

@implementation KKRandomRowView {
  KKSeedView *_seedView;
  uint32_t (^_binding)(void);
  void (^_onSeed)(uint32_t);
}

- (instancetype)initWithTitle:(NSString *)title
                      tooltip:(NSString *)tooltip
                    laneColor:(NSColor *)laneColor
                      binding:(uint32_t (^)(void))binding
                       onSeed:(void (^)(uint32_t))onSeed {
  self = [super initWithTitle:title tooltip:tooltip laneColor:laneColor];
  if (!self)
    return nil;
  _binding = [binding copy];
  _onSeed = [onSeed copy];

  _seedView = [[KKSeedView alloc] initWithFrame:NSMakeRect(0, 0, 110, 22)];
  _seedView.translatesAutoresizingMaskIntoConstraints = NO;
  __weak typeof(self) weakSelf = self;
  _seedView.onSeedChanged = ^(uint32_t s) {
    __strong typeof(weakSelf) self = weakSelf;
    if (self && self->_onSeed)
      self->_onSeed(s);
  };
  _seedView.onReroll = ^{
    __strong typeof(weakSelf) self = weakSelf;
    if (!self)
      return;
    uint32_t s = arc4random();
    self->_seedView.seed = s;
    if (self->_onSeed)
      self->_onSeed(s);
  };
  [self.controlContainer addSubview:_seedView];

  [NSLayoutConstraint activateConstraints:@[
    [_seedView.leadingAnchor
        constraintEqualToAnchor:self.controlContainer.leadingAnchor],
    [_seedView.trailingAnchor
        constraintEqualToAnchor:self.controlContainer.trailingAnchor],
    [_seedView.centerYAnchor
        constraintEqualToAnchor:self.controlContainer.centerYAnchor],
    [_seedView.widthAnchor constraintEqualToConstant:110.0],
    [_seedView.heightAnchor constraintEqualToConstant:22.0],
  ]];

  [self popoverDidRefresh];
  return self;
}

- (void)popoverDidRefresh {
  [super popoverDidRefresh];
  if (_binding)
    _seedView.seed = _binding();
}

@end
