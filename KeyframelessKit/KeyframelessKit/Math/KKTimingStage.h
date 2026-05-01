/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

#import <KeyframelessKit/KKEasing.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, KKSegmentType) {
  KKSegmentTypeHold = 0,
  KKSegmentTypeTransition = 1,
};

/// Per-component kind hint stored on each lane in `valueComponentKinds`.
/// Tells the sequencer renderer and HTH normalization how many scalar
/// values each slot expands into and how to treat them across transitions.
typedef NS_ENUM(NSInteger, KKAnimatableParamKind) {
  /// 1 scalar; standard float-lerp across transitions.
  KKAnimatableParamKindFloat = 0,
  /// 3 scalars [R, G, B]; per-component float-lerp.
  KKAnimatableParamKindColor = 1,
  /// Variable-length flat `[pos, r, g, b, mid]` per stop. Stop counts can
  /// differ across a transition — interp falls back to LUT-lerp.
  KKAnimatableParamKindGradient = 2,
  /// 2 scalars [X, Y].
  KKAnimatableParamKindPoint = 3,
  /// 1 scalar (0/1). Step semantics: HTH normalization preserves the
  /// segment's own value rather than inheriting from the surrounding hold.
  KKAnimatableParamKindBool = 4,
};

/// A single segment in a multi-stage timing lane.
///
/// - **Hold segments** maintain constant values for their duration.
/// - **Transition segments** interpolate between the values of their
///   adjacent segments using the specified easing curve.
///
/// Positions are 0–1 fractions of the clip duration.
/// Empty regions before the first segment or after the last use the
/// property's base parameter values.
///
/// Each segment stores an array of values, one per native parameter
/// in the property's valueParamIDs. For single-param properties (like
/// Radius) this is a one-element array. For multi-param properties
/// (like Crop with top/bottom/left/right) it matches the param count.
@interface KKTimingSegment : NSObject <NSCopying>

@property(nonatomic) KKSegmentType type;
@property(nonatomic) double start;
@property(nonatomic) double end;
/// Absolute parameter values. One per native param in the property's
/// valueParamIDs array.
@property(nonatomic, copy) NSArray<NSNumber *> *values;
/// Easing curve used when `type == KKSegmentTypeTransition`.
@property(nonatomic) KKEasingCurve easing;
/// Hold effect used when `type == KKSegmentTypeHold`.
@property(nonatomic) KKHoldEffect holdEffect;
@property(nonatomic) double intensity;
@property(nonatomic) double frequency;
/// Hold-effect seed for randomising per-property variation.
@property(nonatomic) uint32_t seed;
/// For hold segments on multi-component lanes (e.g. Position, Radius X/Y):
/// when YES, the hold effect uses a single shared factor across components
/// so they modulate in lockstep (e.g. Radius maintains aspect). When NO,
/// each component gets an independent factor for more organic motion.
/// Has no effect on single-scalar lanes. Defaults to YES for back-compat
/// with single-factor behaviour.
@property(nonatomic) BOOL linked;
/// When > 0, this segment holds an absolute duration in seconds across clip
/// length changes. Unlocked (= 0) segments scale proportionally with the clip.
@property(nonatomic) double lockedDurationSeconds;

/// Optional plugin-specific binary blob persisted alongside the segment in
/// JSON (base64-encoded). Used by MagicMove to store the bezier path between
/// a transition's boundary endpoints; nil/empty means default behaviour
/// (linear interpolation). The timing engine itself does not interpret this.
@property(nonatomic, copy, nullable) NSData *pathData;

/// Convenience: first value (for single-param properties).
@property(nonatomic, readonly) double value;

+ (instancetype)holdWithValues:(NSArray<NSNumber *> *)values
                         start:(double)start
                           end:(double)end;

+ (instancetype)transitionWithStart:(double)start
                                end:(double)end
                             easing:(KKEasingCurve)easing
                          intensity:(double)intensity
                          frequency:(double)frequency
                             values:(NSArray<NSNumber *> *)values;

@end

@interface KKTimingSegment (Serialization)

- (NSDictionary *)toDictionary;
+ (nullable instancetype)segmentFromDictionary:(NSDictionary *)dict;

@end

/// An ordered list of segments for one animatable property.
///
/// Segments are contiguous and non-overlapping, ordered by start position.
/// A lane can be enabled/disabled — when disabled the property uses its
/// base value and the classic timing path applies.
@interface KKTimingLane : NSObject <NSCopying>

@property(nonatomic, copy) NSString *propertyLabel;
@property(nonatomic, copy) NSArray<KKTimingSegment *> *segments;
@property(nonatomic) BOOL enabled;
/// Index of the currently selected segment in this lane (-1 for none).
/// Persisted in JSON so selection survives view rebuilds.
@property(nonatomic) NSInteger selectedSegment;
/// Whether this lane has an associated on-screen control (OSC). Set by the
/// plugin at lane build time; not serialized.
@property(nonatomic) BOOL hasOSC;
/// Whether the lane's OSC should be rendered on canvas. Persisted in JSON
/// so visibility survives view rebuilds. Defaults to YES.
@property(nonatomic) BOOL oscVisible;
/// UI filter: whether this lane is shown in the sequencer and included in
/// bulk operations. Does not affect render-time evaluation. Persisted in
/// JSON. Defaults to YES.
@property(nonatomic) BOOL visibleInSequencer;
/// Clip duration (seconds) this lane's segment fractions were last authored
/// against. Used to decide when locked segments need rebalancing. Zero means
/// "not yet established" — the next read initialises it to the current clip
/// duration and persists it on the following write.
@property(nonatomic) double lastKnownClipDuration;

/// Optional grouping key. When non-nil, the sequencer renders a header row
/// above each contiguous run of lanes sharing the same `groupKey` and groups
/// the lanes underneath. Plugins use this when several lanes belong to the
/// same conceptual instance — e.g. Canvas keys lanes by `path.pathID` so
/// each layer's properties cluster under one collapsible header. Lanes
/// without a `groupKey` render flat (legacy behaviour).
@property(nonatomic, copy, nullable) NSString *groupKey;

/// Display label for the group header. Read from the **first lane of each
/// group** only — siblings' values are ignored. Persisted.
@property(nonatomic, copy, nullable) NSString *groupLabel;

/// Whether the group is collapsed in the sequencer. Read from the first
/// lane of each group only. When YES, every lane sharing the same
/// `groupKey` is hidden from the row plan (still evaluated at render time).
/// Persisted.
@property(nonatomic) BOOL groupCollapsed;

/// Per-scalar render hints. One `KKAnimatableParamKind` (boxed as
/// `NSNumber`) per slot in the property's natural shape — e.g. a single
/// scalar lane has `@[ @(Float) ]`, a Color lane has `@[ @(Color) ]`, a
/// Position+Bool lane has `@[ @(Point), @(Bool) ]`. The sequencer uses this
/// to decide rendering (color strip vs scalar graph) and the eval function
/// uses it to skip Bool components during transitions. Length is the number
/// of native slots, NOT the number of scalars in `segment.values` —
/// expansion to per-scalar entries (Color → 3, Point → 2) happens inside
/// the consumer. Nil falls back to "treat every component as a Float".
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *valueComponentKinds;

+ (instancetype)laneWithLabel:(NSString *)label
                     segments:(NSArray<KKTimingSegment *> *)segments
                      enabled:(BOOL)enabled;

/// Default lane: [transition 0→baseValues] [hold baseValues] [transition
/// baseValues→0]
+ (instancetype)defaultLaneForLabel:(NSString *)label
                         baseValues:(NSArray<NSNumber *> *)baseValues;

/// Insert a segment at the given index.
- (void)insertSegment:(KKTimingSegment *)segment atIndex:(NSUInteger)index;

/// Remove a segment by index.
- (void)removeSegmentAtIndex:(NSUInteger)index;

@end

/// Boundary resolution: between each pair of segments there is a single
/// shared value that both sides agree on. Holds dictate their own boundaries.
/// When two transitions meet, the "right" segment's own value wins.
FOUNDATION_EXPORT NSArray<NSNumber *> *
KKTimingBoundaryBefore(NSUInteger idx, NSArray<KKTimingSegment *> *segments);
FOUNDATION_EXPORT NSArray<NSNumber *> *
KKTimingBoundaryAfter(NSUInteger idx, NSArray<KKTimingSegment *> *segments);

/// Rewrites segment start/end fractions for a new clip duration, preserving
/// locked segments' absolute durations where possible.
///
/// - Locked segments retain `lockedDurationSeconds` when there's room.
/// - Unlocked segments absorb the clip-duration delta proportionally to
///   their current seconds.
/// - If locked segments can't all fit in the new range, every segment
///   shrinks proportionally to current seconds. `lockedDurationSeconds` is
///   not mutated, so the lock restores if the clip grows back.
///
/// The first segment's start and last segment's end stay invariant — empty
/// head/tail space keeps its fraction of the clip.
FOUNDATION_EXPORT NSArray<KKTimingSegment *> *
KKTimingRebalancedSegments(NSArray<KKTimingSegment *> *segments,
                           double oldDuration, double newDuration);

/// Returns a new lanes array rebalanced for the current clip duration. Each
/// lane's segments are rewritten through `KKTimingRebalancedSegments` and
/// `lastKnownClipDuration` is updated. Lanes with a lastKnownClipDuration of
/// zero (never established) are implicitly initialised to `currentDuration`.
/// Safe to call unconditionally — returns equivalent data when no rebalance
/// is required.
FOUNDATION_EXPORT NSArray<KKTimingLane *> *
KKTimingRebalancedLanes(NSArray<KKTimingLane *> *lanes, double currentDuration);

/// Serialize / deserialize a full set of lanes as JSON.
@interface KKTimingLane (Serialization)

+ (nullable NSString *)jsonFromLanes:(NSArray<KKTimingLane *> *)lanes;
+ (nullable NSArray<KKTimingLane *> *)lanesFromJSON:(NSString *)json;

@end

/// Returns YES when `segIdx` is a transition segment that has a hold on both
/// sides (Hold-Transition-Hold). Edge transitions (TH, HT, THT) don't count.
FOUNDATION_EXPORT BOOL KKIsHTHTransition(KKTimingLane *lane, NSInteger segIdx);

/// In-place normalization: every HTH transition has its `values` array
/// rewritten to match the preceding hold's values. Call before serializing so
/// transitions sandwiched between holds keep stable, derivable state. Bool
/// scalars (per `lane.valueComponentKinds`) are preserved so per-segment
/// step toggles like "rotate with motion" survive across writes.
FOUNDATION_EXPORT void
KKApplyHTHNormalizationInPlace(NSMutableArray<KKTimingLane *> *lanes);

NS_ASSUME_NONNULL_END
