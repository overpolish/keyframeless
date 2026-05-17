/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "RoundedInspectorButtons.h"
#import "RoundedInspectorView.h"
#import <KeyframelessKit/KKJoyrideController.h>
#import <KeyframelessKit/KKJoyrideOSCSegment.h>
#import <KeyframelessKit/KKPillToggleRowView.h>
#import <KeyframelessKit/KKTimelineLanesView.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, RoundedTab) {
  RoundedTabBasic = 0,
  RoundedTabAdvanced = 1,
};

@interface RoundedInspectorView () {
@protected
  id<PROAPIAccessing> _apiManager;
  RoundedTab _selectedTab;
  KKPillToggleRowView *_tabBar;
  _RoundedLoopButton *_loopButton;
  _RoundedConstantsButton *_constantsButton;
  NSView *_contentView;
  KKTimelineLanesView *_basicView;
  KKJoyrideController *_introGuide;
  KKTimeline *_savedIntroTimeline;
  KKJoyrideController *_oscGuide;
  KKTimeline *_savedOSCTimeline;
  KKJoyrideController *_fullGuide;
  KKTimeline *_savedFullTimeline;
  KKJoyrideOSCSegment *_oscSegment;
}
@end

NS_ASSUME_NONNULL_END
