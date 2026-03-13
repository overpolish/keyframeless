/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKCustomGroupHeaderView.h"
#import "KKChevronView.h"
#import "KKLabelView.h"
#import "KKLog.h"
#import "KKNumberField.h"
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKParameterRowView.h>

static const CGFloat kChevronMarginLeft = 10.0;

@implementation KKCustomGroupHeaderView {
  KKLog *_log;
}

- (instancetype)initWithFrame:(NSRect)frameRect
                   apiManager:(id<PROAPIAccessing>)apiManager
                  parameterId:(UInt32)parameterId {
  self = [super initWithFrame:frameRect
                   apiManager:apiManager
                  parameterId:parameterId];
  if (self) {
    _log = [KKLog loggerForPlugin:@"co.overpolish.keyframeless"];

    KKChevronView *chevron = [[KKChevronView alloc] initWithFrame:NSZeroRect];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    chevron.onToggle = ^(BOOL isExpanded) {
      [self->_log debug:@"clicked chevron"];
    };
    [self addSubview:chevron];
    [NSLayoutConstraint activateConstraints:@[
      [chevron.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                            constant:kChevronMarginLeft],
      [chevron.topAnchor constraintEqualToAnchor:self.topAnchor],
      [chevron.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
      [chevron.widthAnchor constraintEqualToConstant:kChevronWidth]
    ]];

    KKLabelView *label = [[KKLabelView alloc] initWithText:@"Radius"];
    self.leftView = label;

    KKNumberField *numberField =
        [[KKNumberField alloc] initWithFrame:NSZeroRect apiManager:apiManager];
    numberField.parameterId = parameterId;
    self.rightView = numberField;
  }
  return self;
}

@end
