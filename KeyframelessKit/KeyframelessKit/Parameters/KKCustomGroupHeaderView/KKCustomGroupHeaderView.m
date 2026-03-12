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

    NSView *right = [[NSView alloc] initWithFrame:NSZeroRect];
    right.wantsLayer = YES;
    right.layer.backgroundColor = [[NSColor greenColor] CGColor];
    self.rightView = right;
  }
  return self;
}

// - (instancetype)initWithFrame:(NSRect)frame
//                    apiManager:(id<PROAPIAccessing>)apiManager
//                   parameterId:(UInt32)parameterId
//                         {
//   self = [super initWithFrame:frame];
//   if (self) {
//     self.apiManager = apiManager;
//     // self.currentChevronRotation = 90.0;
//     log = [KKLog loggerForPlugin:@"co.overpolish.keyframeless"];

//     // [self addSubview:self.chevronButton];

//     // self.customView = customView;
//     // if (customView) {
//     //   customView.translatesAutoresizingMaskIntoConstraints = NO;
//     //   [self addSubview:customView];

//     //   CGFloat nfWidth = [KKNumberField preferredWidth];
//     //   CGFloat nfHeight = [KKNumberField preferredHeight];
//     //   self.numberField = [[KKNumberField alloc]
//     //       initWithFrame:NSMakeRect(0, 0, nfWidth, nfHeight)
//     //          apiManager:apiManager];
//     //   self.numberField.translatesAutoresizingMaskIntoConstraints = NO;
//     //   [self addSubview:self.numberField];
//     //   // Set the initial frame now; setFrameSize: keeps it updated from
//     here
//     //   on. [self positionNumberFieldForSize:frame.size];
//     // }

//     // [self setupConstraints];
//   }
//   return self;
// }

// TODO clean?
// - (void)positionNumberFieldForSize:(NSSize)size {
//   if (!self.numberField)
//     return;
//   [NSAnimationContext beginGrouping];
//   [NSAnimationContext currentContext].duration = 0;
//   CGFloat nfWidth = [KKNumberField preferredWidth];
//   CGFloat nfHeight = [KKNumberField preferredHeight];
//   self.numberField.frame =
//       NSMakeRect(size.width - kRightMargin,
//                  round((size.height - nfHeight) / 2.0), nfWidth, nfHeight);
//   [NSAnimationContext endGrouping];
// }

@end
