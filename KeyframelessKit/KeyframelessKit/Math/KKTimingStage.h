/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Foundation/Foundation.h>

#import <KeyframelessKit/KKEasing.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, KKSegmentType) {
  KKSegmentTypeHold = 0,
  KKSegmentTypeTransition = 1,
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
/// When > 0, this segment holds an absolute duration in seconds across clip
/// length changes. Unlocked (= 0) segments scale proportionally with the clip.
@property(nonatomic) double lockedDurationSeconds;

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
/// Clip duration (seconds) this lane's segment fractions were last authored
/// against. Used to decide when locked segments need rebalancing. Zero means
/// "not yet established" — the next read initialises it to the current clip
/// duration and persists it on the following write.
@property(nonatomic) double lastKnownClipDuration;

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

NS_ASSUME_NONNULL_END
