/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKGapPopoverTypes.h>
#import <KeyframelessKit/KKTimingStage.h>

NS_ASSUME_NONNULL_BEGIN

/// Plugin-agnostic Basic-mode motion graph: one normalized in/hold/out motion
/// curve over the shared timeline, four boundary diamonds (the endpoints are
/// time-locked, the two middle ones drive the global In/Out duration), and
/// In/Out enable checkboxes. A projection of the same KKTimeline blob the
/// Advanced sequencer edits - Basic just constrains where keyposes land.
/// Mutations are reported through the callbacks; the host writes the blob.
@interface KKTimelineBasicView : NSView

- (instancetype)initWithAvailableLanes:(NSArray<KKLane *> *)availableLanes
                              timeline:(KKTimeline *)timeline
    NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/// Push an updated timeline from outside (e.g. parameterChanged:). Does not
/// fire onTimelineMutated.
- (void)applyTimeline:(KKTimeline *)timeline;

/// Live clip duration in seconds, pushed from the render tick (a clip trim
/// never fires parameterChanged:). When > 0 it takes precedence over the
/// blob-stamped `lane.lastKnownClipDuration` cold-start fallback.
@property(nonatomic) double clipDurationSeconds;

/// Single frame duration in seconds, pushed from the render tick. Used to
/// clamp the scrubber so the playhead can't land on the unreachable clip-
/// end position (FCP stops at the last *frame*, not the clip end).
@property(nonatomic) double frameDurationSeconds;

/// Live playhead position as a clip fraction (0–1), pushed from the render
/// tick. < 0 hides it (not playing / no timing yet). Drawn on the warped
/// (log) axis like everything else.
@property(nonatomic) double playheadFraction;

/// Reset pinch-zoom/pan back to fit (zoom 1, no pan).
- (void)resetZoom;

/// Re-open the most-recently-opened gap / modulation popover against the
/// current timeline (a multi-layer host calls this after switching the selected
/// layer so the open "Applies to" popover re-scopes to the new layer). No-op if
/// the new layer's section can't open (e.g. it lacks that phase).
- (void)reopenLastGapPopover;

/// Fired whenever zoom/pan changes; YES = currently zoomed/panned in (not
/// at fit). Drives the reset button's enabled/accent state.
@property(nonatomic, copy, nullable) void (^onZoomChanged)(BOOL zoomed);

/// Fired on every timeline mutation triggered by user interaction (boundary
/// drag, phase toggle). Host serializes + writes the blob.
@property(nonatomic, copy, nullable) void (^onTimelineMutated)
    (KKTimeline *updated);

/// Multi-owner timelines: the host's selected layer, so the keypose popover
/// scopes its params to that layer (nil => first animated layer).
@property(nonatomic, copy, nullable) NSString *activeLayerKey;
/// Fired when a keypose popover resolves its scope to a layer, so the host can
/// highlight that layer in its layer list.
@property(nonatomic, copy, nullable) void (^onKeyposeLayerActivated)
    (NSString *layerKey);

/// Bracket a continuous boundary drag so the host coalesces the burst of
/// onTimelineMutated writes into one undo group.
@property(nonatomic, copy, nullable) void (^onDragBegin)(void);
@property(nonatomic, copy, nullable) void (^onDragEnd)(void);

/// Fired while the user drags the playhead handle to scrub. The host moves
/// the host playhead to that clip fraction (host-aware time space).
@property(nonatomic, copy, nullable) void (^onScrub)(double frac);

/// Diamond click → request the mini-viewer value popover for that boundary.
/// The host (KKTimelineLanesView) builds the popover from `displayLanes`
/// (one synthetic single-keypose lane per animatable property holding its
/// value at the boundary), evaluates the mini viewer at `previewFraction`,
/// and routes edits back through `onValue` (coalesced via the drag blocks).
/// `excludedLabels` are animatable properties that do NOT participate in
/// this boundary's phase (e.g. clicking In-start while a property has In
/// off) - shown as a message row with an "Animate" button that calls
/// `onAnimate(label)` to opt that property back into the phase.
/// `onRemove(label)` (In/Out boundaries only; nil for Hold) removes that
/// property from this phase's "applies to" - same as unticking it in the gap
/// popover. Removing the last participant turns the phase off (the projection
/// derives In/Out enabled from participation) and closes the popover.
@property(nonatomic, copy, nullable) void (^onBoundaryValuePopover)
    (NSView *anchorView, NSArray<KKLane *> *displayLanes,
     double previewFraction, NSArray<NSString *> *excludedLabels,
     void (^onValue)(NSString *label, NSArray<NSNumber *> *values),
     void (^onAnimate)(NSString *label), void (^onRemove)(NSString *label),
     void (^onValueDragBegin)(void), void (^onValueDragEnd)(void));

/// Asked when removing the last participant from a phase leaves the boundary
/// gone - the host closes the open popover.
@property(nonatomic, copy, nullable) void (^onRequestClosePopover)(void);

/// In/Out gap click → request the shared easing popover for that phase. The
/// host builds a KKSegmentEditView (Transition kind), seeds it from `curve` /
/// `intensity` / `frequency`, mirrors the pills for the Out phase
/// (`animateOut`), and routes edits back through the write blocks. A curve
/// pick commits immediately (its own undo); intensity / frequency slider
/// drags coalesce via `onDragBegin` / `onDragEnd`.
/// `participantLabels` / `participantStates` are the animatable properties
/// and whether each currently participates in this phase; `onParticipation`
/// toggles one lane's participation. The drag blocks bracket curve / slider
/// AND participation edits into one undo group.
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
     NSString *_Nullable representativeLaneLabel,
     KKInterval *_Nonnull representativeInterval,
     KKGapIntervalReader _Nonnull intervalReader,
     KKGapIntervalMutator _Nonnull intervalMutator);

/// Flat Hold gap click → request the modulation editor for the shared Hold
/// interval. The host builds a KKSegmentEditView (Hold kind) seeded from the
/// passed modulation state and routes edits back through the write blocks. A
/// type/seed pick commits immediately (its own undo); intensity / frequency
/// slider drags coalesce via `onDragBegin` / `onDragEnd`. (A drift Hold uses
/// `onGapPopover` instead - it's a real tween.)
/// `participantLabels` / `participantStates` are the animatable properties
/// and whether the Hold modulation currently applies to each (its Hold
/// interval modulation != None); `onParticipation` toggles one lane on/off.
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

/// Public popover entry points. Declared as a category so the primary
/// @implementation isn't expected to provide them (silences
/// -Wincomplete-implementation while keeping them public); implemented in
/// KKTimelineBasicView+BoundaryPopover.m.
@interface KKTimelineBasicView (BoundaryPopover)
/// Programmatic re-open of the boundary value popover at the diamond
/// closest to `fraction`. Used by the onion-skin filmstrip - clicking an
/// inactive cell swaps the popover to the corresponding boundary diamond
/// (Basic's filmstrip cells correspond to the 4 boundary times).
- (void)requestValuePopoverAtFraction:(double)fraction;
/// As above, but `fireActivation` NO suppresses the onKeyposeLayerActivated
/// callback - pass NO for selection-driven re-drives (retarget / timeline
/// re-feed) so the popover re-scope doesn't drive selection back (ping-pong).
- (void)requestValuePopoverAtFraction:(double)fraction
                       fireActivation:(BOOL)fireActivation;
/// Re-point an OPEN keypose popover at a different layer (host's layer-list
/// selection). No-op if that layer has no animated lane.
- (void)retargetKeyposePopoverToLayerKey:(NSString *)layerKey;
/// Flip the Position keypose nearest `frac` between corner and smooth (bezier)
/// spatial interpolation. Routed from the keypose popover's curve toggle.
- (void)writeSpatialSmoothForLabel:(NSString *)label
                            atFrac:(double)frac
                              isOn:(BOOL)on;
/// Flip the global aspect lock on the lane named `label`. Routed from the value
/// popover's link toggle.
- (void)writeAspectLinkedForLabel:(NSString *)label isOn:(BOOL)on;
- (void)writeGradientTypeForLabel:(NSString *)label type:(NSInteger)type;
/// Clear the active keypose / gap highlight in the graph. Called when the
/// popover switches to a non-keypose mode (constants) in place, which doesn't
/// fire the close notification the highlight otherwise clears on.
- (void)clearPopoverHighlights;
@end

NS_ASSUME_NONNULL_END
