/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "KKTimelineLanesView_Private.h"
#import <KeyframelessKit/KKTimelineLanesView.h>

@class KKTimelineBasicView;

NS_ASSUME_NONNULL_BEGIN

@interface KKTimelineLanesView () {
@protected
  NSArray<KKLane *> *_availableLanes;
  KKTimeline *_timeline;

  NSStackView *_laneStack;
  NSView *_centeredArea;
  KKTimelineBasicView *_basicGraph;
  NSTextField *_hintLabel;
  _KKDropdownTrigger *_dropdownTrigger;
  NSView *_footerRow;

  NSMutableDictionary<NSString *, _KKLaneRow *> *_laneRows;
  __weak _KKManagePopoverView *_openManageView;
  __weak NSPopover *_openManagePopover;
  // The last popover shown via _showPopoverWithContent: (gap/hold/boundary).
  // Closed before a new one opens so clicking a second gap dismisses the
  // first (outside-click monitors alone don't, click-to-click).
  __weak NSPopover *_openContentPopover;
  __weak _KKStaticValuesPopoverView *_openStaticView;
  // YES when _openStaticView is a boundary-value popover (caller-supplied
  // display lanes) — its rows must NOT be clobbered by _refresh's
  // updateUnoptedLanes:, which is only for the constants popover.
  BOOL _openStaticIsBoundary;

  // Guide-only callbacks (set via KKTimelineLanesView+Guide). Fired
  // alongside the existing host plumbing so production behaviour is
  // unaffected; the basic-timing guide uses these to resolve a curve pill's
  // screen rect and advance on a curve pick.
  void (^_onGapPopoverWillOpen)(NSView *content, KKSegmentEditView *editor);
  void (^_onGapPopoverCurveChanged)(NSInteger curveType);
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
/// Boundary value popover (Basic step 27): reuses the static-values popover
/// machinery but with caller-supplied display lanes (one synthetic
/// single-keypose lane per animatable property = its value at the boundary),
/// the mini canvas evaluated at `fraction`, edits routed back via `onValue`
/// (coalesced through the drag blocks).
- (void)
    _presentBoundaryValuePopoverFromAnchor:(NSView *)anchor
                              displayLanes:(NSArray<KKLane *> *)lanes
                                  fraction:(double)fraction
                            excludedLabels:(NSArray<NSString *> *)excludedLabels
                                   onValue:
                                       (void (^)(NSString *label,
                                                 NSArray<NSNumber *> *values))
                                           onValue
                                 onAnimate:(void (^)(NSString *label))onAnimate
                               onDragBegin:(void (^)(void))onDragBegin
                                 onDragEnd:(void (^)(void))onDragEnd;
- (NSPopover *)_showPopoverWithContent:(NSView *)content
                              fromView:(NSView *)anchor
                               onClose:(void (^)(void))onClose;
/// In/Out gap easing popover (Basic step 28a): hosts a KKSegmentEditView
/// (Transition kind) seeded from the phase's shared curve/intensity/frequency.
/// `animateOut` mirrors the pills for the Out phase. A curve pick commits at
/// once; intensity/frequency slider drags coalesce via the drag blocks.
- (void)_presentGapPopoverFromAnchor:(NSView *)anchor
                          animateOut:(BOOL)animateOut
                               curve:(KKIntervalCurve)curve
                           intensity:(double)intensity
                           frequency:(double)frequency
                          partLabels:(NSArray<NSString *> *)partLabels
                          partStates:(NSArray<NSNumber *> *)partStates
                             onCurve:(void (^)(KKIntervalCurve curve))onCurve
                         onIntensity:(void (^)(double value))onIntensity
                         onFrequency:(void (^)(double value))onFrequency
                     onParticipation:(void (^)(NSInteger laneIndex,
                                               BOOL on))onParticipation
                         onDragBegin:(void (^)(void))onDragBegin
                           onDragEnd:(void (^)(void))onDragEnd;
/// Flat-Hold modulation popover (Basic step 28b): hosts a KKSegmentEditView
/// (Hold kind) seeded from the shared Hold interval's modulation. Maps the
/// KKHoldEffect pill index ↔ KKIntervalModulation per the evaluator. Type /
/// seed pick commits at once; intensity/frequency drags coalesce.
- (void)
    _presentHoldModulationPopoverFromAnchor:(NSView *)anchor
                                 modulation:(KKIntervalModulation)modulation
                                  intensity:(double)intensity
                                  frequency:(double)frequency
                                       seed:(uint32_t)seed
                                     linked:(BOOL)linked
                                showsLinked:(BOOL)showsLinked
                                 partLabels:(NSArray<NSString *> *)partLabels
                                 partStates:(NSArray<NSNumber *> *)partStates
                               onModulation:(void (^)(KKIntervalModulation m))
                                                onModulation
                                onIntensity:(void (^)(double v))onIntensity
                                onFrequency:(void (^)(double v))onFrequency
                                     onSeed:(void (^)(uint32_t s))onSeed
                                   onLinked:(void (^)(BOOL l))onLinked
                            onParticipation:(void (^)(NSInteger laneIndex,
                                                      BOOL on))onParticipation
                                onDragBegin:(void (^)(void))onDragBegin
                                  onDragEnd:(void (^)(void))onDragEnd;
@end

NS_ASSUME_NONNULL_END
