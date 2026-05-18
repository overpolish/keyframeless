/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "KKTimelineLanesView.h"
#import "KKTimelineLanesView_Private.h"

NS_ASSUME_NONNULL_BEGIN

@interface KKTimelineLanesView () {
@protected
  NSArray<KKLane *> *_availableLanes;
  KKTimeline *_timeline;

  NSStackView *_laneStack;
  NSView *_centeredArea;
  NSTextField *_hintLabel;
  _KKDropdownTrigger *_dropdownTrigger;
  NSView *_footerRow;

  NSMutableDictionary<NSString *, _KKLaneRow *> *_laneRows;
  __weak _KKManagePopoverView *_openManageView;
  __weak NSPopover *_openManagePopover;
  __weak _KKStaticValuesPopoverView *_openStaticView;
}

// Model + refresh helpers implemented in the primary @implementation; the
// Popovers category calls these as the popover toggles opt lanes in/out.
- (nullable KKLane *)_laneForLabel:(NSString *)label;
- (NSSet<NSString *> *)_optedInLabelsSet;
- (NSArray<KKLane *> *)_unoptedLanes;
- (NSArray<NSNumber *> *)_defaultValuesForLabel:(NSString *)label;
- (BOOL)_isAnimatableLabel:(NSString *)label;
- (void)_setLaneAnimatable:(BOOL)animatable forLabel:(NSString *)label;
- (void)_setLaneValues:(NSArray<NSNumber *> *)values forLabel:(NSString *)label;
- (void)_refresh;
@end

/// Internal popover plumbing — the manage-popover presenter and the generic
/// popover-with-outside-click-monitors helper. The public popover entry
/// points (closeManagePopover / showStaticValuesPopoverFromView:) are on the
/// (Popovers) category in KKTimelineLanesView.h. Both are implemented in
/// KKTimelineLanesView+Popovers.m.
@interface KKTimelineLanesView (PopoversInternal)
- (void)_showManagePopoverFromView:(NSView *)anchorView;
- (NSPopover *)_showPopoverWithContent:(NSView *)content
                              fromView:(NSView *)anchor
                               onClose:(void (^)(void))onClose;
@end

NS_ASSUME_NONNULL_END
