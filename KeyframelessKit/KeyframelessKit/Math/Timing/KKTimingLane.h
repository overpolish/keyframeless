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

typedef NS_ENUM(NSInteger, KKAnimatableParamKind) {
  KKAnimatableParamKindFloat = 0,
  KKAnimatableParamKindColor = 1,
  KKAnimatableParamKindGradient = 2,
  KKAnimatableParamKindPoint = 3,
  KKAnimatableParamKindBool = 4,
  KKAnimatableParamKindMorph = 5,
};

@interface KKTimingSegment : NSObject <NSCopying>

@property(nonatomic) KKSegmentType type;
@property(nonatomic) double start;
@property(nonatomic) double end;
@property(nonatomic, copy) NSArray<NSNumber *> *values;
@property(nonatomic) KKEasingCurve easing;
@property(nonatomic) KKHoldEffect holdEffect;
@property(nonatomic) double intensity;
@property(nonatomic) double frequency;
@property(nonatomic) uint32_t seed;
@property(nonatomic) BOOL linked;
@property(nonatomic) double lockedDurationSeconds;
@property(nonatomic, copy, nullable) NSData *pathData;
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

@interface KKTimingLane : NSObject <NSCopying>

@property(nonatomic, copy) NSString *propertyLabel;
@property(nonatomic, copy) NSArray<KKTimingSegment *> *segments;
@property(nonatomic) BOOL enabled;
@property(nonatomic) NSInteger selectedSegment;
@property(nonatomic) BOOL hasOSC;
@property(nonatomic) BOOL oscVisible;
@property(nonatomic) BOOL visibleInSequencer;
@property(nonatomic) BOOL pluginVisible;
@property(nonatomic) double lastKnownClipDuration;
@property(nonatomic, copy, nullable) NSString *groupKey;
@property(nonatomic, copy, nullable) NSString *groupLabel;
@property(nonatomic) BOOL groupCollapsed;
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *valueComponentKinds;
@property(nonatomic, readonly) BOOL effectivelyVisibleInSequencer;

+ (instancetype)laneWithLabel:(NSString *)label
                     segments:(NSArray<KKTimingSegment *> *)segments
                      enabled:(BOOL)enabled;

+ (instancetype)defaultLaneForLabel:(NSString *)label
                         baseValues:(NSArray<NSNumber *> *)baseValues;

- (void)insertSegment:(KKTimingSegment *)segment atIndex:(NSUInteger)index;
- (void)removeSegmentAtIndex:(NSUInteger)index;

@end

FOUNDATION_EXPORT BOOL
KKLaneIsHiddenByCollapsedGroup(NSArray<KKTimingLane *> *lanes, NSUInteger idx);

FOUNDATION_EXPORT NSArray<NSNumber *> *
KKTimingBoundaryBefore(NSUInteger idx, NSArray<KKTimingSegment *> *segments);
FOUNDATION_EXPORT NSArray<NSNumber *> *
KKTimingBoundaryAfter(NSUInteger idx, NSArray<KKTimingSegment *> *segments);

FOUNDATION_EXPORT NSArray<KKTimingSegment *> *
KKTimingRebalancedSegments(NSArray<KKTimingSegment *> *segments,
                           double oldDuration, double newDuration);

FOUNDATION_EXPORT NSArray<KKTimingLane *> *
KKTimingRebalancedLanes(NSArray<KKTimingLane *> *lanes, double currentDuration);

@interface KKTimingLane (Serialization)
+ (nullable NSString *)jsonFromLanes:(NSArray<KKTimingLane *> *)lanes;
+ (nullable NSArray<KKTimingLane *> *)lanesFromJSON:(NSString *)json;
@end

FOUNDATION_EXPORT BOOL KKIsHTHTransition(KKTimingLane *lane, NSInteger segIdx);

FOUNDATION_EXPORT void
KKApplyHTHNormalizationInPlace(NSMutableArray<KKTimingLane *> *lanes);

NS_ASSUME_NONNULL_END
