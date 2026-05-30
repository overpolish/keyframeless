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
/// time. Anything else is authoritative - set by Basic's rebuild path
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
/// Stored on KKKeyPose.outgoing - nil on the last keypose in a lane.
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
/// lanes (Crop, Color) wiggle just one axis - e.g. oscillate X horizontally
/// without disturbing W/H/Y. Indices match the lane's `values` array order.
@property(nonatomic, copy, nullable) NSIndexSet *modulationComponents;

@property(nonatomic) double lockedSeconds; // 0 = scale proportionally

/// When YES, the two keyposes bordering this gap share one value: editing
/// either endpoint mirrors to the other (a true "Hold"). When NO they move
/// independently (a "Drift"). Toggled by cmd-clicking the gap. Default YES.
@property(nonatomic) BOOL endpointsLinked;

/// When YES this interval contributes no motion - the lane holds flat across
/// it at its Hold-side value, while BOTH keyposes (and their stored values)
/// are preserved. Used by Basic's per-property "applies to": turning a phase
/// off for one property flattens that property's In/Out interval without
/// destroying its keypose, so toggling it back on restores the exact value.
/// The evaluator holds at the END value for the first interval (In→Hold) and
/// the START value for the last interval (Hold→Out) - i.e. the Hold side.
/// Default NO (animates normally).
@property(nonatomic) BOOL holdsFlat;

@property(nonatomic, copy, nullable)
    NSData *pathData; // plugin blob (MagicMove bezier)

/// Plugin-specific per-interval flags / values, serialized into the
/// interval JSON. Use the `userBool…` / `userNumber…` helpers below rather
/// than mutating this dictionary directly so the copy semantics stay sane.
/// Values must be JSON-serializable (string, number, bool, nested
/// dict/array of the same).
@property(nonatomic, copy, nullable)
    NSDictionary<NSString *, id> *userProperties;

- (BOOL)userBoolForKey:(NSString *)key default:(BOOL)def;
- (void)setUserBool:(BOOL)value forKey:(NSString *)key;
- (double)userDoubleForKey:(NSString *)key default:(double)def;
- (void)setUserDouble:(double)value forKey:(NSString *)key;
- (nullable id)userValueForKey:(NSString *)key;
- (void)setUserValue:(nullable id)value forKey:(NSString *)key;

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
/// laneID is stable for the lifetime of the lane - label is display only.
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
@property(nonatomic, copy) NSArray<NSString *>
    *componentUnits; // one per component (e.g. @"px", @"%"); empty = unitless
/// Plugin-supplied display captions for each component (e.g. @[@"X",@"Y",@"Z"])
/// shown in the value-field row. nil = fall back to value-type defaults
/// (W/H/X/Y for Crop, R/G/B/A for Color, 1/2/3... for generic). One per
/// component; rendered by `KKLaneComponentLabels` and the multi-field row.
@property(nonatomic, copy, nullable) NSArray<NSString *> *componentLabels;
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
