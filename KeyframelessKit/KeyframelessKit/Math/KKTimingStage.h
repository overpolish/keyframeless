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
@property(nonatomic) KKEasingCurve easing;
@property(nonatomic) double intensity;
@property(nonatomic) double frequency;

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

/// Serialize / deserialize a full set of lanes as JSON.
@interface KKTimingLane (Serialization)

+ (nullable NSString *)jsonFromLanes:(NSArray<KKTimingLane *> *)lanes;
+ (nullable NSArray<KKTimingLane *> *)lanesFromJSON:(NSString *)json;

@end

NS_ASSUME_NONNULL_END
