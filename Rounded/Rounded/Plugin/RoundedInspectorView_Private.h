/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "RoundedInspectorButtons.h"
#import "RoundedInspectorView.h"
#import "RoundedMiniCanvasRenderer.h"
#import <KeyframelessKit/KKJoyrideController.h>
#import <KeyframelessKit/KKJoyrideOSCSegment.h>
#import <KeyframelessKit/KKPillToggleRowView.h>
#import <KeyframelessKit/KKTimelineLanesView.h>

NS_ASSUME_NONNULL_BEGIN

@class KKMiniCanvasGuideScroll;

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
  _RoundedDetachButton *_detachButton;
  NSView *_contentView;
  KKTimelineLanesView *_basicView;
  RoundedMiniCanvasRenderer *_miniCanvasRenderer;
  NSArray<KKLane *> *_availableLanes;
  BOOL _isDetachedCopy;
  BOOL _detachedAttached;
  __weak RoundedInspectorView *_detachedOwner;
  RoundedInspectorView *_detachedView;
  KKJoyrideController *_introGuide;
  KKTimeline *_savedIntroTimeline;
  KKJoyrideController *_oscGuide;
  KKTimeline *_savedOSCTimeline;
  KKJoyrideController *_fullGuide;
  KKTimeline *_savedFullTimeline;
  KKJoyrideOSCSegment *_oscSegment;
  KKJoyrideController *_constantsGuide;
  KKTimeline *_savedConstantsTimeline;
  KKMiniCanvasGuideScroll *_constantsScrollFwd;
}
@end

NS_ASSUME_NONNULL_END
