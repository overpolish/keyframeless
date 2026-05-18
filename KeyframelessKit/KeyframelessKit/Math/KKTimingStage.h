/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, KKLaneValueType) {
  KKLaneValueTypeGeneric = 0,
  KKLaneValueTypeFloat = 1,
  KKLaneValueTypeNormalized = 2,
  KKLaneValueTypeCrop = 3,  // [width, height, x, y] normalized center offsets
  KKLaneValueTypeColor = 4, // [r, g, b, a] 0–1
  KKLaneValueTypeGradient = 5, // flat stop array: [position, r, g, b, midpoint,
                               // ...] × N stops; variable length
};

typedef NS_ENUM(NSInteger, KKIntervalCurve) {
  KKIntervalCurveLinear = 0,
  KKIntervalCurveEaseIn = 1,
  KKIntervalCurveEaseOut = 2,
  KKIntervalCurveEaseInOut = 3,
  KKIntervalCurveElastic = 4,
  KKIntervalCurveBounce = 5,
};

typedef NS_ENUM(NSInteger, KKIntervalModulation) {
  KKIntervalModulationNone = 0,
  KKIntervalModulationWiggle = 1,
  KKIntervalModulationOscillate = 2,
};

/// The character of the gap between two adjacent keyposes.
/// Stored on KKKeyPose.outgoing — nil on the last keypose in a lane.
@interface KKInterval : NSObject <NSCopying>

@property(nonatomic) KKIntervalCurve curve; // default: EaseInOut
@property(nonatomic) double intensity;      // default: 1.0

@property(nonatomic) KKIntervalModulation modulation; // default: None
@property(nonatomic) double modulationIntensity;      // default: 1.0
@property(nonatomic) double modulationFrequency;      // default: 1.0
@property(nonatomic) uint32_t modulationSeed;         // default: 0
@property(nonatomic) BOOL modulationLinked;           // default: YES

@property(nonatomic) double lockedSeconds; // 0 = scale proportionally

@property(nonatomic, copy, nullable)
    NSData *pathData; // plugin blob (MagicMove bezier)

@end

/// A single time-point with a value. The atomic unit of the data model.
@interface KKKeyPose : NSObject <NSCopying>

@property(nonatomic) double time; // 0–1 fraction of clip
@property(nonatomic, copy)
    NSArray<NSNumber *> *values; // absolute, one per component
@property(nonatomic, copy, nullable)
    KKInterval *outgoing; // nil on last keypose

+ (instancetype)keyposeAtTime:(double)time values:(NSArray<NSNumber *> *)values;

@end

/// An ordered sequence of keyposes for one animatable property.
/// laneID is stable for the lifetime of the lane — label is display only.
/// UI state (selection, visibility, collapsed) lives in KKSequencerViewState,
/// not here.
@interface KKLane : NSObject <NSCopying>

@property(nonatomic, readonly) NSUUID *laneID;
@property(nonatomic, copy) NSString *label;
@property(nonatomic, copy, nullable) NSString *groupKey;
@property(nonatomic) BOOL enabled;
@property(nonatomic) KKLaneValueType valueType; // default: Generic
@property(nonatomic, copy) NSArray<NSNumber *>
    *componentMin; // one per component, empty = unconstrained
@property(nonatomic, copy) NSArray<NSNumber *>
    *componentMax; // one per component, empty = unconstrained
@property(nonatomic, copy) NSArray<KKKeyPose *> *keyposes; // ordered by time
@property(nonatomic) double lastKnownClipDuration; // 0 = not yet established

+ (instancetype)laneWithLabel:(NSString *)label;

- (void)insertKeypose:(KKKeyPose *)keypose; // inserts maintaining time order
- (void)removeKeyposeAtIndex:(NSUInteger)index;

@end

/// Metadata for a group header in the sequencer.
/// Lanes reference groupKey only; group display state lives in
/// KKSequencerViewState, not here.
@interface KKLaneGroup : NSObject <NSCopying>

@property(nonatomic, copy) NSString *key;
@property(nonatomic, copy) NSString *label;

+ (instancetype)groupWithKey:(NSString *)key label:(NSString *)label;

@end

/// Top-level container serialized into the single blob param.
@interface KKTimeline : NSObject <NSCopying>

@property(nonatomic, copy) NSArray<KKLane *> *lanes;
@property(nonatomic, copy) NSArray<KKLaneGroup *> *groups;

+ (instancetype)timeline;

@end

/// Rewrites keypose time fractions for a new clip duration, preserving
/// locked intervals' absolute durations where possible. Unlocked intervals
/// scale proportionally. Returns a new KKTimeline; input is not mutated.
FOUNDATION_EXPORT KKTimeline *KKTimelineRebalanced(KKTimeline *timeline,
                                                   double oldDuration,
                                                   double newDuration);

@interface KKTimeline (Serialization)

+ (nullable NSString *)jsonFromTimeline:(KKTimeline *)timeline;
+ (nullable KKTimeline *)timelineFromJSON:(NSString *)json;

@end

NS_ASSUME_NONNULL_END
