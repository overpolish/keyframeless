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

/// Explicit hold-shape annotation for Basic-mode lanes. Auto = legacy
/// blobs without this field; `KKShapeOfLane` infers from KP count + middle
/// time. Anything else is authoritative — set by Basic's rebuild path
/// every time In/Out is toggled, so the projection doesn't have to guess
/// from keypose times (and so dragging the boundary past 0.5 doesn't flip
/// the interpretation mid-drag).
typedef NS_ENUM(NSInteger, KKLaneHoldShape) {
  KKLaneHoldShapeAuto = 0,
  KKLaneHoldShapeNone = 1,
  KKLaneHoldShapeInOnly = 2,
  KKLaneHoldShapeOutOnly = 3,
  KKLaneHoldShapeBoth = 4,
};

typedef NS_ENUM(NSInteger, KKIntervalModulation) {
  KKIntervalModulationNone = 0,
  KKIntervalModulationWiggle = 1,
  KKIntervalModulationOscillate = 2,
  KKIntervalModulationHandheld = 3, // low-frequency fBm (analogue camera)
};

/// The character of the gap between two adjacent keyposes.
/// Stored on KKKeyPose.outgoing — nil on the last keypose in a lane.
@interface KKInterval : NSObject <NSCopying>

@property(nonatomic) KKIntervalCurve curve; // default: EaseInOut
@property(nonatomic) double intensity;      // default: 1.0
@property(nonatomic) double frequency;      // default: 0.5 (Elastic/Bounce)

@property(nonatomic) KKIntervalModulation modulation; // default: None
@property(nonatomic) double modulationIntensity;      // default: 1.0
@property(nonatomic) double modulationFrequency;      // default: 1.0
@property(nonatomic) uint32_t modulationSeed;         // default: 0
@property(nonatomic) BOOL modulationLinked;           // default: YES

/// Subset of the lane's value components the modulation envelope multiplies
/// against. nil = all components (default / legacy). Lets multi-component
/// lanes (Crop, Color) wiggle just one axis — e.g. oscillate X horizontally
/// without disturbing W/H/Y. Indices match the lane's `values` array order.
@property(nonatomic, copy, nullable) NSIndexSet *modulationComponents;

@property(nonatomic) double lockedSeconds; // 0 = scale proportionally

/// When YES, the two keyposes bordering this gap share one value: editing
/// either endpoint mirrors to the other (a true "Hold"). When NO they move
/// independently (a "Drift"). Toggled by cmd-clicking the gap. Default YES.
@property(nonatomic) BOOL endpointsLinked;

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

/// Basic-mode hold-shape annotation. `Auto` (default) means infer from KP
/// layout; any other value pins the In/Out interpretation regardless of
/// where the user has dragged the boundary keypose to.
@property(nonatomic) KKLaneHoldShape holdShape;

+ (instancetype)laneWithLabel:(NSString *)label;

- (void)insertKeypose:(KKKeyPose *)keypose; // inserts maintaining time order
- (void)removeKeyposeAtIndex:(NSUInteger)index;

@end

/// Display labels for a lane's value components, derived from its valueType.
/// Used in per-component selection UI (modulation popover's component pills).
/// Returns nil for single-component types (no UI shown). Generic multi-comp
/// lanes fall back to "1", "2", ... indices.
FOUNDATION_EXPORT
    NSArray<NSString *> *_Nullable KKLaneComponentLabels(KKLane *lane);

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
