/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKParameterRowView.h"
#import "../Plugin/KKHostInfo.h"
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>

static const CGFloat kControlsRegionWidth = 75.0;

@implementation KKParameterRowView {
  NSView *_backgroundView;
  NSView *_controlsRegion;
  NSLayoutConstraint *_leftViewWidthConstraint;
  NSMutableArray<NSLayoutConstraint *> *_sectionConstraints;
}

- (instancetype)initWithFrame:(NSRect)frameRect
                   apiManager:(id<PROAPIAccessing>)apiManager
                  parameterId:(UInt32)parameterId {
  self = [super initWithFrame:frameRect];
  if (self) {
    _apiManager = apiManager;
    _parameterId = parameterId;
    _sectionConstraints = [NSMutableArray array];
    self.autoresizingMask =
        NSViewWidthSizable | NSViewHeightSizable | NSViewMinYMargin;

    _backgroundView = [[NSView alloc] initWithFrame:NSZeroRect];
    _backgroundView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_backgroundView];

    _controlsRegion = [[NSView alloc] initWithFrame:NSZeroRect];
    _controlsRegion.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_controlsRegion];

    [NSLayoutConstraint activateConstraints:@[
      [_backgroundView.leadingAnchor
          constraintEqualToAnchor:self.leadingAnchor],
      [_backgroundView.topAnchor constraintEqualToAnchor:self.topAnchor],
      [_backgroundView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
      [_backgroundView.trailingAnchor
          constraintEqualToAnchor:_controlsRegion.leadingAnchor],

      [_controlsRegion.trailingAnchor
          constraintEqualToAnchor:self.trailingAnchor],
      [_controlsRegion.topAnchor constraintEqualToAnchor:self.topAnchor],
      [_controlsRegion.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
      [_controlsRegion.widthAnchor
          constraintEqualToConstant:kControlsRegionWidth],
    ]];
  }
  return self;
}

- (void)setLeftView:(NSView *)leftView {
  [_leftView removeFromSuperview];
  _leftView = leftView;
  if (_leftView) {
    _leftView.translatesAutoresizingMaskIntoConstraints = NO;
    [_backgroundView addSubview:_leftView];
  }
  [self updateSectionConstraints];
}

- (void)setRightView:(NSView *)rightView {
  [_rightView removeFromSuperview];
  _rightView = rightView;
  if (_rightView) {
    _rightView.translatesAutoresizingMaskIntoConstraints = NO;
    [_backgroundView addSubview:_rightView];
  }
  [self updateSectionConstraints];
}

- (void)updateSectionConstraints {
  [NSLayoutConstraint deactivateConstraints:_sectionConstraints];
  [_sectionConstraints removeAllObjects];
  _leftViewWidthConstraint = nil;

  if (_leftView && _rightView) {
    NSMutableArray *constraints = [NSMutableArray arrayWithArray:@[
      [_leftView.leadingAnchor
          constraintEqualToAnchor:_backgroundView.leadingAnchor],
      [_leftView.topAnchor constraintEqualToAnchor:_backgroundView.topAnchor],
      [_leftView.bottomAnchor
          constraintEqualToAnchor:_backgroundView.bottomAnchor],

      [_rightView.leadingAnchor
          constraintEqualToAnchor:_leftView.trailingAnchor],
      [_rightView.topAnchor constraintEqualToAnchor:_backgroundView.topAnchor],
      [_rightView.bottomAnchor
          constraintEqualToAnchor:_backgroundView.bottomAnchor],
      [_rightView.trailingAnchor
          constraintEqualToAnchor:_backgroundView.trailingAnchor],
    ]];

    if ([KKHostInfo isRunningInFinalCut]) {
      NSLayoutConstraint *leftMinWidth =
          [_leftView.widthAnchor constraintGreaterThanOrEqualToConstant:131.0];
      leftMinWidth.priority = NSLayoutPriorityRequired;

      NSLayoutConstraint *leftMaxWidth =
          [_leftView.widthAnchor constraintLessThanOrEqualToConstant:179.0];
      leftMaxWidth.priority = NSLayoutPriorityRequired;

      NSLayoutConstraint *rightMinWidth =
          [_rightView.widthAnchor constraintGreaterThanOrEqualToConstant:179.0];
      rightMinWidth.priority = NSLayoutPriorityRequired;

      [constraints
          addObjectsFromArray:@[ leftMinWidth, leftMaxWidth, rightMinWidth ]];

      [_leftView
          setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh
                                   forOrientation:
                                       NSLayoutConstraintOrientationHorizontal];
      [_rightView
          setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                   forOrientation:
                                       NSLayoutConstraintOrientationHorizontal];
      [_leftView
          setContentHuggingPriority:NSLayoutPriorityDefaultLow
                     forOrientation:NSLayoutConstraintOrientationHorizontal];
      [_rightView
          setContentHuggingPriority:NSLayoutPriorityDefaultLow
                     forOrientation:NSLayoutConstraintOrientationHorizontal];
    } else {
      _leftViewWidthConstraint =
          [_leftView.widthAnchor constraintEqualToConstant:100];
      _leftViewWidthConstraint.priority = NSLayoutPriorityDefaultHigh;
      [constraints addObject:_leftViewWidthConstraint];
    }

    [_sectionConstraints addObjectsFromArray:constraints];
    [NSLayoutConstraint activateConstraints:constraints];
  } else if (_leftView) {
    NSArray *constraints = @[
      [_leftView.leadingAnchor
          constraintEqualToAnchor:_backgroundView.leadingAnchor],
      [_leftView.topAnchor constraintEqualToAnchor:_backgroundView.topAnchor],
      [_leftView.bottomAnchor
          constraintEqualToAnchor:_backgroundView.bottomAnchor],
      [_leftView.trailingAnchor
          constraintEqualToAnchor:_backgroundView.trailingAnchor],
    ];

    [_sectionConstraints addObjectsFromArray:constraints];
    [NSLayoutConstraint activateConstraints:constraints];
  } else if (_rightView) {
    NSArray *constraints = @[
      [_rightView.leadingAnchor
          constraintEqualToAnchor:_backgroundView.leadingAnchor],
      [_rightView.topAnchor constraintEqualToAnchor:_backgroundView.topAnchor],
      [_rightView.bottomAnchor
          constraintEqualToAnchor:_backgroundView.bottomAnchor],
      [_rightView.trailingAnchor
          constraintEqualToAnchor:_backgroundView.trailingAnchor],
    ];
    [_sectionConstraints addObjectsFromArray:constraints];
    [NSLayoutConstraint activateConstraints:constraints];
  }
}

- (void)layout {
  [super layout];

  if (![KKHostInfo isRunningInFinalCut] && _leftViewWidthConstraint) {
    CGFloat totalWidth = NSWidth(self.bounds);
    CGFloat leftWidth;

    if (totalWidth < 475) {
      leftWidth = totalWidth * 0.3670886076 - 11.860759;
    } else {
      leftWidth = totalWidth * 0.3176696611 + 10.848616;
    }

    leftWidth = round(leftWidth * 2.0) / 2.0;
    _leftViewWidthConstraint.constant = leftWidth;
  }
}

@end
