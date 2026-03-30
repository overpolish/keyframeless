/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKCustomGroupHeaderView.h"
#import "KKChevronView.h"
#import "KKLabelView.h"
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKParameterRowView.h>

static const CGFloat kChevronMarginLeft = 10.0;

@implementation KKCustomGroupHeaderView

- (instancetype)initWithFrame:(NSRect)frameRect
                   apiManager:(id<PROAPIAccessing>)apiManager
                  parameterId:(UInt32)parameterId {
  self = [super initWithFrame:frameRect
                   apiManager:apiManager
                  parameterId:parameterId];
  if (self) {
    KKChevronView *chevron = [[KKChevronView alloc] initWithFrame:NSZeroRect];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:chevron];
    [NSLayoutConstraint activateConstraints:@[
      [chevron.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                            constant:kChevronMarginLeft],
      [chevron.topAnchor constraintEqualToAnchor:self.topAnchor],
      [chevron.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
      [chevron.widthAnchor constraintEqualToConstant:kChevronWidth]
    ]];

    KKLabelView *label = [[KKLabelView alloc] initWithText:@"Point A"];
    self.leftView = label;
  }
  return self;
}

@end
