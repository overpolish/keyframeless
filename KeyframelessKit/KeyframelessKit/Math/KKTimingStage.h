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
/// - **Hold segments** maintain a constant value for their duration.
///   The `value` property stores the absolute parameter value.
/// - **Transition segments** interpolate between the values of their
///   adjacent hold segments using the specified easing curve.
///
/// Positions are 0–1 fractions of the clip duration.
/// Empty regions before the first segment or after the last use the
/// property's base parameter value.
@interface KKTimingSegment : NSObject <NSCopying>

@property(nonatomic) KKSegmentType type;
@property(nonatomic) double start;
@property(nonatomic) double end;
/// Absolute parameter value. Used by hold segments.
/// Transition segments derive their values from adjacent holds.
@property(nonatomic) double value;
@property(nonatomic) KKEasingCurve easing;
@property(nonatomic) double intensity;
@property(nonatomic) double frequency;

+ (instancetype)holdWithValue:(double)value start:(double)start end:(double)end;

+ (instancetype)transitionWithStart:(double)start
                                end:(double)end
                             easing:(KKEasingCurve)easing
                          intensity:(double)intensity
                          frequency:(double)frequency;

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

+ (instancetype)laneWithLabel:(NSString *)label
                     segments:(NSArray<KKTimingSegment *> *)segments
                      enabled:(BOOL)enabled;

/// Default lane matching classic in/out behaviour:
/// [transition 0→baseValue] [hold baseValue] [transition baseValue→0]
+ (instancetype)defaultLaneForLabel:(NSString *)label
                          baseValue:(double)baseValue;

/// Insert a segment at the given index.
- (void)insertSegment:(KKTimingSegment *)segment atIndex:(NSUInteger)index;

/// Remove a segment by index.
- (void)removeSegmentAtIndex:(NSUInteger)index;

/// Returns the hold value for the segment at index, resolving transitions
/// by looking at adjacent holds. Returns baseValue for empty regions.
- (double)resolvedValueAtIndex:(NSUInteger)index baseValue:(double)baseValue;

@end

/// Serialize / deserialize a full set of lanes as JSON.
@interface KKTimingLane (Serialization)

+ (nullable NSString *)jsonFromLanes:(NSArray<KKTimingLane *> *)lanes;
+ (nullable NSArray<KKTimingLane *> *)lanesFromJSON:(NSString *)json;

@end

NS_ASSUME_NONNULL_END
