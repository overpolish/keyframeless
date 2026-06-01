/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKGapPopoverTypes.h>
#import <KeyframelessKit/KKTimingStage.h>

NS_ASSUME_NONNULL_BEGIN

/// Plugin-agnostic Advanced-mode sequencer: one row per animatable lane,
/// each with its own keyposes and intervals. A projection of the same
/// KKTimeline blob Basic edits - Advanced is freeform (any number of
/// keyposes per lane, independent per-lane timing). Mutations are reported
/// through the callbacks; the host writes the blob.
///
/// Sibling of KKTimelineBasicView inside KKTimelineLanesView's centered
/// area; the active tab decides which is shown. Step 1: skeleton only -
/// renders empty lane rows with a placeholder strip; no keyposes / no
/// interactions yet.
@interface KKTimelineAdvancedView : NSView

- (instancetype)initWithAvailableLanes:(NSArray<KKLane *> *)availableLanes
                              timeline:(KKTimeline *)timeline
    NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/// Push an updated timeline from outside (e.g. parameterChanged:). Does not
/// fire onTimelineMutated.
- (void)applyTimeline:(KKTimeline *)timeline;

@property(nonatomic) double clipDurationSeconds;
@property(nonatomic) double frameDurationSeconds;
@property(nonatomic) double playheadFraction;

@property(nonatomic, copy, nullable) void (^onTimelineMutated)
    (KKTimeline *updated);
@property(nonatomic, copy, nullable) void (^onDragBegin)(void);
@property(nonatomic, copy, nullable) void (^onDragEnd)(void);
@property(nonatomic, copy, nullable) void (^onScrub)(double frac);

/// Fires when pinch-zoom or pan changes the view away from fit (YES) or
/// back to fit (NO). Lets the inspector tint its shared reset-zoom button.
@property(nonatomic, copy, nullable) void (^onZoomChanged)(BOOL zoomed);

/// Reset pinch-zoom/pan back to fit. No-op if already fit.
- (void)resetZoom;

/// Total selected items across pills + gap selections. Used by the
/// inspector's clear-selection button to toggle its enabled tint.
@property(nonatomic, readonly) NSInteger selectionCount;

/// Fires whenever pill or gap selection count changes - including via
/// `clearSelection`, mouse events, delete, marquee, applyTimeline reset.
@property(nonatomic, copy, nullable) void (^onSelectionChanged)(void);

/// Drop all pill + gap selections and redraw. No-op if nothing is selected.
- (void)clearSelection;

/// Opaque selection snapshot for mirroring across a detached inspector
/// copy. Keys are the internal pill ("label#kpIdx") and gap ("label#aIdx")
/// strings; format is private but stable across copies of the same blob.
@property(nonatomic, copy, readonly) NSSet<NSString *> *selectedPillKeys;
@property(nonatomic, copy, readonly) NSSet<NSString *> *selectedGapKeys;
/// Replace the current selection. No-op + no `onSelectionChanged` fire if
/// both sets equal the current state - safe to call from a peer's
/// onSelectionChanged callback without ping-pong.
- (void)applySelectionPillKeys:(NSSet<NSString *> *)pillKeys
                       gapKeys:(NSSet<NSString *> *)gapKeys;

/// When YES, mouse + tracking events are dropped (no hover highlight, no
/// click handling). Used while an overlay (e.g. the Basic-compat banner)
/// covers the lanes - without this the row hover keeps firing because
/// tracking areas don't respect overlay siblings.
@property(nonatomic) BOOL interactionsBlocked;

/// Label of the lane the most recent value popover is anchored to (the
/// lane whose pill was clicked, or the lane whose KP was selected via
/// requestValuePopoverAtFraction:). nil before the first pill click.
/// KKTimelineLanesView reads this to scope the popover's filmstrip cells
/// to *this* lane's keypose timeline - without it, opening a popover at
/// a time that happens to be shared with another lane would let that
/// other lane's unrelated KPs leak into the filmstrip.
@property(nonatomic, readonly, nullable, copy) NSString *primaryLaneLabel;

/// Pill click → request the mini-canvas value popover for that keypose.
/// `displayLanes` is one synthetic single-keypose lane carrying the click's
/// value (so the popover renders the right editor / mini-canvas handles);
/// `previewFraction` is the clicked KP's time (mini-canvas evaluates the
/// frame there). The host wires this to KKTimelineLanesView's existing
/// boundary-popover plumbing - same coalesced drag chain Basic uses.
@property(nonatomic, copy, nullable) void (^onValuePopover)
    (NSView *anchorView, NSArray<KKLane *> *displayLanes,
     double previewFraction, NSArray<NSString *> *excludedLabels,
     void (^onValue)(NSString *label, NSArray<NSNumber *> *values),
     void (^onAnimate)(NSString *label), void (^onRemove)(NSString *label),
     void (^onValueDragBegin)(void), void (^onValueDragEnd)(void));

/// Asked by the value popover when removing the last keypose at a time leaves
/// nothing left to edit there - the host closes the open popover.
@property(nonatomic, copy, nullable) void (^onRequestClosePopover)(void);

/// Single-click on the gap between two pills in a lane row → request the
/// per-interval curve/intensity/frequency popover for that one interval.
/// Same shape as Basic's onGapPopover so the host can route both through
/// `_presentGapPopoverFromAnchor:`. Advanced is per-lane so participation
/// labels are always empty.
@property(nonatomic, copy, nullable) void (^onGapPopover)
    (NSView *anchorView, BOOL animateOut, double startFraction,
     double endFraction, KKIntervalCurve curve, double intensity,
     double frequency, NSArray<NSString *> *participantLabels,
     NSArray<NSNumber *> *participantStates,
     NSArray<NSNumber *> * (^_Nullable participantRebuilder)(void),
     void (^onCurve)(KKIntervalCurve curve), void (^onIntensity)(double value),
     void (^onFrequency)(double value),
     void (^onParticipation)(NSInteger laneIndex, BOOL on),
     void (^onDragBegin)(void), void (^onDragEnd)(void),
     NSString *_Nonnull laneLabel, KKInterval *_Nonnull representativeInterval,
     KKGapIntervalReader _Nonnull intervalReader,
     KKGapIntervalMutator _Nonnull intervalMutator);

/// Flat-Hold gap click → modulation editor (accent-tinted pills, intensity
/// + frequency + seed). Same shape as Basic's onHoldModulationPopover so
/// Lanes can route both through `_presentHoldModulationPopoverFromAnchor:`.
/// Advanced is per-lane so participation arrays are empty and `showsLinked`
/// is NO (link in Advanced is toggled by ctrl+click on the gap, not from
/// inside the popover).
@property(nonatomic, copy, nullable) void (^onHoldModulationPopover)
    (NSView *anchorView, double startFraction, double endFraction,
     KKIntervalModulation modulation, double intensity, double frequency,
     uint32_t seed, BOOL linked, BOOL showsLinked,
     NSArray<NSArray<NSString *> *> *participantCompoundLabels,
     NSArray<NSArray<NSNumber *> *> *participantCompoundStates,
     NSArray<NSArray<NSNumber *> *> *_Nullable (^participantStateRebuilder)
         (void),
     void (^onModulation)(KKIntervalModulation modulation),
     void (^onIntensity)(double value), void (^onFrequency)(double value),
     void (^onSeed)(uint32_t seed), void (^onLinked)(BOOL linked),
     void (^onParticipation)(NSInteger flatIndex, BOOL on),
     void (^onDragBegin)(void), void (^onDragEnd)(void),
     NSString *_Nonnull laneLabel, KKInterval *_Nonnull representativeInterval,
     KKGapIntervalReader _Nonnull intervalReader,
     KKGapIntervalMutator _Nonnull intervalMutator);

@end

/// Popover entry points implemented in KKTimelineAdvancedView+Popovers.m.
/// Declared in a category (not the primary interface) so the primary
/// @implementation isn't expected to provide them - silences
/// -Wincomplete-implementation while the methods stay part of the public API.
@interface KKTimelineAdvancedView (Popovers)

/// Programmatic re-open of the value popover at a different keypose time.
/// Used by the onion-skin filmstrip when the user clicks an inactive cell -
/// the popover swaps to that KP. Prefers the lane the popover was last
/// opened against; falls back to any animatable lane that has a KP at
/// `fraction`. No-op if no matching KP exists.
- (void)requestValuePopoverAtFraction:(double)fraction;
/// Flip the Position keypose nearest `frac` between corner and smooth (bezier)
/// spatial interpolation. Routed from the keypose popover's curve toggle.
- (void)writeSpatialSmoothForLabel:(NSString *)label
                            atFrac:(double)frac
                              isOn:(BOOL)on;

@end

/// Joyride guide hooks implemented in KKTimelineAdvancedView+Guide.m.
/// Declared as a category for the same reason as +Popovers above.
@interface KKTimelineAdvancedView (Guide)

/// Screen rect of the full lane row for `label` (background area, not just
/// the keyposes). `NSZeroRect` if the lane isn't animatable / not visible.
/// Used to cutout / target the row in joyride steps.
- (NSRect)guideLaneRowScreenRectForLabel:(NSString *)label;

/// Screen rect of the keypose pill at `kpIdx` within the lane for `label`.
/// `NSZeroRect` if the lane is missing / kpIdx out of range / not in window.
- (NSRect)guideKeyposeScreenRectForLabel:(NSString *)label
                                 atIndex:(NSInteger)kpIdx;

/// Screen rect at the lane row's `frac` time (used as a target glow for
/// "drag the keypose to here" steps).
- (NSRect)guideKeyposeScreenRectForLabel:(NSString *)label
                              atFraction:(double)frac;

/// Current time fraction of keypose `kpIdx` in `label`'s lane (used to
/// hit-test "drag completed near target" in the joyride drag step). NAN if
/// out of range.
- (double)guideKeyposeFractionForLabel:(NSString *)label
                               atIndex:(NSInteger)kpIdx;

/// Drive a keypose pill drag from a guide's spotlightMouseDown/Dragged/Up
/// (the joyride panel intercepts the click, so the regular mouseDown:/
/// Dragged:/Up: path never sees the press - these mirror Basic's
/// guideBeginDragDiamondAtIndex: family). Returns NO if the lane is missing
/// or the kpIdx is out of range.
- (BOOL)guideBeginPillDragForLabel:(NSString *)label
                           atIndex:(NSInteger)kpIdx
                     atScreenPoint:(NSPoint)screenPoint;

- (void)guideDragPillToScreenPoint:(NSPoint)screenPoint;

- (void)guideEndPillDrag;

@end

NS_ASSUME_NONNULL_END
