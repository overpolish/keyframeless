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
@class KKLaneFilterBar;

NS_ASSUME_NONNULL_BEGIN

@interface KKTimelineLanesView () {
@protected
  NSArray<KKLane *> *_availableLanes;
  KKTimeline *_timeline;
  // Optional multi-owner (layer) timeline. When set, the Basic + Advanced
  // graphs render and edit THIS (all layers' animated lanes, uniquely tagged)
  // while _timeline stays the single selected owner that drives the Animated
  // dropdown + Constants. nil for single-owner plugins (graphs use _timeline).
  KKTimeline *_graphTimeline;
  // Host's selected layer (multi-owner), scopes the Basic keypose popover.
  NSString *_activeLayerKey;
  // Host hint (multi-owner): some layer has a constant param even if the
  // selected one doesn't, so the Constants button stays reachable.
  BOOL _ownerConstantsAvailable;
  NSInteger _activeTab; // 0 = Basic, 1 = Advanced

  NSStackView *_laneStack;
  NSView *_centeredArea;
  KKTimelineBasicView *_basicGraph;
  KKTimelineAdvancedView *_advancedGraph;
  NSTextField *_hintLabel;
  _KKDropdownTrigger *_dropdownTrigger;
  NSView *_footerRow;

  __weak _KKManagePopoverView *_openManageView;
  __weak NSPopover *_openManagePopover;
  // The reused popover shown via _showPopoverWithContent: (gap/hold/boundary).
  // STRONG + reused across opens: a ViewBridge XPC remote-hosts each NSPopover's
  // backing window and FCP never releases it until inspector teardown, so a NEW
  // popover per open leaks its CA layer-hosting IOSurfaces (~13 MB each) every
  // time. Reusing one instance reuses its backing window (and surfaces), bounding
  // it. Closed (not destroyed) before a new one opens.
  NSPopover *_openContentPopover;
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
  // Advanced-only non-linear display toggle, lazily created and surfaced in
  // accessoryButtons alongside _clearSelectionButton.
  KKDynamicButton *_dynamicButton;
  // Mini-viewer render mode (Off/Filmstrip/Onion). Drives the boundary
  // value popover's preview shape. The 3-way pill lives in the popover
  // header (KKTimelineLanesView+Helpers.m); the lanes view just owns the
  // persisted bit + cached boundary-popover state so a mid-popover mode
  // toggle can re-publish the boundary request without reopening.
  KKMiniViewerRenderMode _renderMode;
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
  // Live-interval reader for the hold-mod popover. _refresh re-reads
  // modulationLinked from it and pushes to the editor so the Linked
  // checkbox tracks cmd-Z (it lives in KKSegmentEditView, not extras, so
  // the KKPopoverExtraRow auto-refresh on _openExtraRows doesn't reach it).
  KKInterval *_Nullable (^_openHoldModIntervalReader)(void);
  // Same mechanism for the In/Out curve (gap) popover's plain participation
  // pills - kept in sync on cmd-Z without closing the popover.
  __weak KKSegmentEditView *_openGapEditor;
  NSArray<NSNumber *> * (^_openGapRebuilder)(void);
  // Live-interval reader for the gap popover. _refresh re-reads
  // curve/intensity/frequency from it and pushes to the editor so cmd-Z
  // lands in the visible pills/sliders. Same role as the hold-mod
  // reader (curve gap and hold-mod popovers are mutually exclusive).
  KKInterval *_Nullable (^_openGapIntervalReader)(void);
  // Set while re-opening the gap/modulation popover for a newly-selected layer:
  // the presenter then re-scopes the OPEN editor's checklist in place (no
  // close/reopen) instead of building a fresh popover.
  BOOL _rescopingGapPopover;
  // The open gap/modulation editor's + its container's height constraints, so
  // an in-place re-scope (different layer = different row count) resizes the
  // popover (and the container, else the header is pushed out) by the delta.
  NSLayoutConstraint *_openSegEditHeightConstraint;
  NSLayoutConstraint *_openSegContainerHeightConstraint;
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
  // Last category tab the user picked, so reopening the constants popover (or,
  // in Basic, a keypose/boundary popover) returns to that tab. Not used by the
  // Advanced keypose popover, which seeds from the clicked keypose's category.
  NSString *_rememberedCategory;
  // Lane-visibility filter bar above the Advanced timeline (hidden when fewer
  // than two opted-in lanes, or in Basic). Pushes its hidden set to the
  // Advanced graph; state is ephemeral (not serialized).
  KKLaneFilterBar *_laneFilterBar;
}

// Model + refresh helpers implemented in the primary @implementation; the
// Popovers category calls these as the popover toggles opt lanes in/out.
- (nullable KKLane *)_laneForLabel:(NSString *)label;
- (NSSet<NSString *> *)_optedInLabelsSet;
- (NSArray<KKLane *> *)_unoptedLanes;
// `_availableLanes` scoped to the CURRENT owner: only the templates whose label
// is present in `_timeline.lanes` (which a multi-owner plugin scopes per layer,
// dropping owner-inapplicable lanes like a path's Points/Stroke for an image).
// Single-owner plugins seed every available lane into `_timeline`, so this is
// the full `_availableLanes` for them.
- (NSArray<KKLane *> *)_ownerScopedAvailableLanes;
- (nullable KKLane *)_templateForLabel:(NSString *)label;
- (BOOL)_isAnimatableLabel:(NSString *)label;
- (void)_refresh;
- (KKTimeline *)_graphTimeline;
- (void)_graphDidMutateTimeline:(KKTimeline *)updated;
@end

/// Lane add/remove/animatable mutations. Declared in a named category so the
/// primary @implementation isn't expected to provide them; implemented in
/// KKTimelineLanesView+LaneMutation.m.
@interface KKTimelineLanesView (LaneMutation)
- (NSArray<NSNumber *> *)_defaultValuesForLabel:(NSString *)label;
- (void)_setLaneAnimatable:(BOOL)animatable forLabel:(NSString *)label;
- (void)_setLaneValues:(NSArray<NSNumber *> *)values forLabel:(NSString *)label;
- (void)_setLaneAspectLinked:(BOOL)on forLabel:(NSString *)label;
@end

/// Internal popover plumbing - the manage-popover presenter and the generic
/// popover-with-outside-click-monitors helper. The public popover entry
/// points (closeManagePopover / showStaticValuesPopoverFromView:) are on the
/// (Popovers) category in KKTimelineLanesView.h. Both are implemented in
/// KKTimelineLanesView+Popovers.m.
@interface KKTimelineLanesView (PopoversInternal)
- (void)_showManagePopoverFromView:(NSView *)anchorView;
/// The owner-scoped, mode-gated lane set the Animated dropdown shows; re-pulled
/// on refresh so a companion-panel layer switch re-scopes the open dropdown.
- (NSArray<KKLane *> *)_manageVisibleLanes;
/// Boundary value popover (Basic step 27): reuses the static-values popover
/// machinery but with caller-supplied display lanes (one synthetic
/// single-keypose lane per animatable property = its value at the boundary),
/// the mini viewer evaluated at `fraction`, edits routed back via `onValue`
/// (coalesced through the drag blocks).
- (void)
    _presentBoundaryValuePopoverFromAnchor:(NSView *)anchor
                              displayLanes:(NSArray<KKLane *> *)lanes
                                  fraction:(double)fraction
                            excludedLabels:(NSArray<NSString *> *)excludedLabels
                           initialCategory:(nullable NSString *)initialCategory
                         remembersCategory:(BOOL)remembersCategory
                                   onValue:
                                       (void (^)(NSString *label,
                                                 NSArray<NSNumber *> *values))
                                           onValue
                                 onAnimate:(void (^)(NSString *label))onAnimate
                                  onRemove:(void (^)(NSString *label))onRemove
                               onDragBegin:(void (^)(void))onDragBegin
                                 onDragEnd:(void (^)(void))onDragEnd;

- (NSPopover *)_showPopoverWithContent:(NSView *)content
                              fromView:(NSView *)anchor
                         preferredEdge:(NSRectEdge)preferredEdge
                               onClose:(void (^)(void))onClose;
// Defined in +Popovers.m (PopoversInternal @implementation); called back from
// the +BoundaryNav navigation methods.
- (double)_kpDedupEps;
- (NSString *)_timeStringForFraction:(double)frac;
- (BOOL)_anyLinkedKeyposeAtFraction:(double)frac;
@end

/// Gap / Hold-modulation segment popovers. Implemented in
/// KKTimelineLanesView+SegmentPopovers.m.
@interface KKTimelineLanesView (SegmentPopovers)
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

FOUNDATION_EXPORT NSInteger KKModulationToPill(KKIntervalModulation m);

// Boundary-request statics (defined in +Popovers.m) + the per-frame boundary
// navigation methods (defined in +BoundaryNav.m), shared across both.
@class KKMiniViewerView;
FOUNDATION_EXPORT void KKSetBoundaryEditing(id delegate, BOOL on,
                                            double fraction);
// `labels` nil clears all suppression (popover-close cleanup).
FOUNDATION_EXPORT void
KKSetSuppressedHandles(id delegate, NSArray<NSString *> *_Nullable labels);
FOUNDATION_EXPORT void KKWriteBoundaryRequest(NSString *path, double frac,
                                              BOOL active);
FOUNDATION_EXPORT void KKWriteBoundaryRequestMulti(NSString *path,
                                                   NSArray<NSNumber *> *fracs,
                                                   BOOL active);
FOUNDATION_EXPORT KKMiniViewerView *KKFindMiniViewer(NSView *root);
FOUNDATION_EXPORT BOOL _kkBoundaryValuesEqual(NSArray<NSNumber *> *a,
                                              NSArray<NSNumber *> *b);

@interface KKTimelineLanesView (BoundaryNav)
- (void)_publishBoundaryRequestForFraction:(double)fraction;
- (NSArray<NSNumber *> *)_animatableKPFractions;
- (void)_refreshBoundaryPopoverNavEnabled;
- (void)_navigateBoundaryPopoverDirection:(NSInteger)direction;
- (void)_renderModeDidChange:(KKMiniViewerRenderMode)mode;
- (void)_miniViewerSizeDidChange:(NSInteger)sizeIndex;
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
@end

// Config + presenter for the unified static-values popover (the constants
// editor AND the boundary value editor). Implemented in +StaticValuesPresent.m.
@interface _KKStaticValuesPopoverConfig : NSObject
@property(nonatomic, strong) NSArray<KKLane *> *lanes;
@property(nonatomic, copy) NSString *headerTitle;
@property(nonatomic, copy, nullable) NSString *headerDetail;
@property(nonatomic, strong, nullable) NSImage *headerIcon;
@property(nonatomic) KKMiniViewerRenderMode renderMode;
@property(nonatomic) BOOL isBoundary;
@property(nonatomic) double fraction;
@property(nonatomic, copy, nullable) NSArray<NSString *> *excludedLabels;
@property(nonatomic, copy, nullable) void (^onValue)
    (NSString *label, NSArray<NSNumber *> *values);
@property(nonatomic, copy, nullable) void (^onAnimate)(NSString *label);
@property(nonatomic, copy, nullable) void (^onRemove)(NSString *label);
@property(nonatomic, copy, nullable) void (^onAddToAnimated)(NSString *label);
@property(nonatomic, copy, nullable) void (^onDragBegin)(void);
@property(nonatomic, copy, nullable) void (^onDragEnd)(void);
@property(nonatomic, copy, nullable) void (^onNavigate)(NSInteger dir);
@property(nonatomic, copy, nullable) void (^onModeChanged)
    (KKMiniViewerRenderMode mode);
// Category pill pre-selection: the keypose popover seeds this with the clicked
// keypose's category so it opens on the right tab; the constants popover seeds
// it with the remembered last category and updates it via onCategoryChanged.
@property(nonatomic, copy, nullable) NSString *initialCategory;
@property(nonatomic, copy, nullable) void (^onCategoryChanged)
    (NSString *category);
@end

@interface KKTimelineLanesView (StaticValuesPresent)
- (void)_presentStaticValuesPopoverFromAnchor:(NSView *)anchor
                                       config:
                                           (_KKStaticValuesPopoverConfig *)cfg;
@end

NS_ASSUME_NONNULL_END
