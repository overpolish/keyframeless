/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "KKTimelineInspectorButtons.h"
#import "KKTimelineLanesView_Private.h"
#import <KeyframelessKit/KKTimelineLanesView.h>

@class KKTimelineBasicView;
@class KKTimelineAdvancedView;

NS_ASSUME_NONNULL_BEGIN

@interface KKTimelineLanesView () {
@protected
  NSArray<KKLane *> *_availableLanes;
  KKTimeline *_timeline;
  NSInteger _activeTab; // 0 = Basic, 1 = Advanced

  NSStackView *_laneStack;
  NSView *_centeredArea;
  KKTimelineBasicView *_basicGraph;
  KKTimelineAdvancedView *_advancedGraph;
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
  // display lanes) - its rows must NOT be clobbered by _refresh's
  // updateUnoptedLanes:, which is only for the constants popover.
  BOOL _openStaticIsBoundary;

  // Guide-only callbacks (set via KKTimelineLanesView+Guide). Fired
  // alongside the existing host plumbing so production behaviour is
  // unaffected; the basic-timing guide uses these to resolve a curve pill's
  // screen rect and advance on a curve pick.
  void (^_onGapPopoverWillOpen)(NSView *content, KKSegmentEditView *editor);
  void (^_onGapPopoverCurveChanged)(NSInteger curveType);

  // Tab-specific accessory buttons surfaced to the inspector's header row.
  // _clearSelectionButton is lazily created and only included in the
  // accessoryButtons list while the Advanced tab is active.
  KKClearSelectionButton *_clearSelectionButton;
  // Mini-canvas render mode (Off/Filmstrip/Onion). Drives the boundary
  // value popover's preview shape. The 3-way pill lives in the popover
  // header (KKTimelineLanesView+Helpers.m); the lanes view just owns the
  // persisted bit + cached boundary-popover state so a mid-popover mode
  // toggle can re-publish the boundary request without reopening.
  KKMiniCanvasRenderMode _renderMode;
  double _openStaticBoundaryFraction;
  NSArray<KKLane *> *_openStaticBoundaryLanes;
  NSArray<NSString *> *_openStaticBoundaryExcluded;
  // Suppress the _refresh-driven boundary-popover re-drive briefly after a
  // popover-originated edit, so the host's echo write doesn't rebuild rows
  // mid-interaction (add/remove already refresh themselves). External changes
  // (cmd-Z) land outside the window → they refresh.
  NSTimeInterval _boundaryRedriveSuppressUntil;
  // Open hold-modulation popover plumbing: weak editor + a rebuilder
  // closure supplied by the host (Basic/Advanced) so external timeline
  // changes (e.g. cmd-Z) can push fresh participation states into the
  // live pill row without closing the popover.
  __weak KKSegmentEditView *_openHoldModEditor;
  NSArray<NSArray<NSNumber *> *> * (^_openHoldModRebuilder)(void);
  // Same mechanism for the In/Out curve (gap) popover's plain participation
  // pills - kept in sync on cmd-Z without closing the popover.
  __weak KKSegmentEditView *_openGapEditor;
  NSArray<NSNumber *> * (^_openGapRebuilder)(void);
  // Extras rows currently shown below the gap-popover segment editor. Held
  // strong while the popover is open so -popoverDidRefresh can fire on
  // cmd-Z without the rows being deallocated mid-flight. Cleared in the
  // popover's onClose. Plumbing for the hold-modulation popover uses the
  // same ivar - only one of the two popovers is ever open at a time.
  NSArray<NSView *> *_openExtraRows;
  // Per-tab last-reported zoom state. The toolbar button only reflects the
  // active tab, so we cache each side's state here and re-fire on tab
  // switch / when the active side changes.
  BOOL _basicZoomed;
  BOOL _advancedZoomed;
  // Cached live clip duration (seconds) so the keypose/curve popover headers
  // can show times. Forwarded from setClipDurationSeconds:.
  double _clipDurationSeconds;
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

/// Internal popover plumbing - the manage-popover presenter and the generic
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
                                  onRemove:(void (^)(NSString *label))onRemove
                               onDragBegin:(void (^)(void))onDragBegin
                                 onDragEnd:(void (^)(void))onDragEnd;

/// In-place re-bind for an already-open boundary popover. Used by the
/// onion-skin filmstrip when the user clicks an inactive cell - the popover
/// stays open (no close/reopen blink), the value rows re-display the new
/// KP's values, and the boundary state (editing fraction, request file)
/// re-publishes. The graph is responsible for updating any closure-captured
/// state (e.g. a `_currentPopoverFrac` ivar) BEFORE calling this so the
/// existing onValue/onAnimate closures write to the right KP. No-op if no
/// boundary popover is open.
- (void)_updateBoundaryPopoverInPlaceWithLanes:(NSArray<KKLane *> *)lanes
                                      fraction:(double)fraction
                                excludedLabels:
                                    (NSArray<NSString *> *)excludedLabels;
/// A structural edit (e.g. unlink) while a boundary popover is open changes the
/// tied-hold-collapsed KP set the filmstrip / onion shows - re-publish so it
/// updates live instead of waiting for a close/reopen or a nav. No-op when no
/// boundary popover is open or render mode is Off.
- (void)_republishBoundaryRequestIfOpen;
- (NSPopover *)_showPopoverWithContent:(NSView *)content
                              fromView:(NSView *)anchor
                               onClose:(void (^)(void))onClose;
/// In/Out gap easing popover (Basic step 28a): hosts a KKSegmentEditView
/// (Transition kind) seeded from the phase's shared curve/intensity/frequency.
/// `animateOut` mirrors the pills for the Out phase. A curve pick commits at
/// once; intensity/frequency slider drags coalesce via the drag blocks.
- (void)_presentGapPopoverFromAnchor:(NSView *)anchor
                          animateOut:(BOOL)animateOut
                       startFraction:(double)startFraction
                         endFraction:(double)endFraction
                               curve:(KKIntervalCurve)curve
                           intensity:(double)intensity
                           frequency:(double)frequency
                          partLabels:(NSArray<NSString *> *)partLabels
                          partStates:(NSArray<NSNumber *> *)partStates
                       partRebuilder:
                           (NSArray<NSNumber *> * (^)(void))partRebuilder
                             onCurve:(void (^)(KKIntervalCurve curve))onCurve
                         onIntensity:(void (^)(double value))onIntensity
                         onFrequency:(void (^)(double value))onFrequency
                     onParticipation:(void (^)(NSInteger laneIndex,
                                               BOOL on))onParticipation
                         onDragBegin:(void (^)(void))onDragBegin
                           onDragEnd:(void (^)(void))onDragEnd
                               phase:(KKGapPopoverPhase)phase
                           laneLabel:(nullable NSString *)laneLabel
                      representative:(KKInterval *)representativeInterval
                      intervalReader:(KKGapIntervalReader)intervalReader
                     intervalMutator:(KKGapIntervalMutator)intervalMutator;
/// Flat-Hold modulation popover (Basic step 28b): hosts a KKSegmentEditView
/// (Hold kind) seeded from the shared Hold interval's modulation. Maps the
/// KKHoldEffect pill index ↔ KKIntervalModulation per the evaluator. Type /
/// seed pick commits at once; intensity/frequency drags coalesce.
- (void)
    _presentHoldModulationPopoverFromAnchor:(NSView *)anchor
                              startFraction:(double)startFraction
                                endFraction:(double)endFraction
                                 modulation:(KKIntervalModulation)modulation
                                  intensity:(double)intensity
                                  frequency:(double)frequency
                                       seed:(uint32_t)seed
                                     linked:(BOOL)linked
                                showsLinked:(BOOL)showsLinked
                                 partLabels:(NSArray<NSArray<NSString *> *> *)
                                                partCompoundLabels
                                 partStates:(NSArray<NSArray<NSNumber *> *> *)
                                                partCompoundStates
                              partRebuilder:
                                  (NSArray<NSArray<NSNumber *> *> *_Nullable (
                                      ^_Nullable)(void))partRebuilder
                               onModulation:(void (^)(KKIntervalModulation m))
                                                onModulation
                                onIntensity:(void (^)(double v))onIntensity
                                onFrequency:(void (^)(double v))onFrequency
                                     onSeed:(void (^)(uint32_t s))onSeed
                                   onLinked:(void (^)(BOOL l))onLinked
                            onParticipation:(void (^)(NSInteger laneIndex,
                                                      BOOL on))onParticipation
                                onDragBegin:(void (^)(void))onDragBegin
                                  onDragEnd:(void (^)(void))onDragEnd
                                      phase:(KKGapPopoverPhase)phase
                                  laneLabel:(NSString *)laneLabel
                             representative:(KKInterval *)representativeInterval
                             intervalReader:(KKGapIntervalReader)intervalReader
                            intervalMutator:
                                (KKGapIntervalMutator)intervalMutator;
@end

NS_ASSUME_NONNULL_END
