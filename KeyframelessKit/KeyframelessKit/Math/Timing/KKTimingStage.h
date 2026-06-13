/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

@class NSColor;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, KKLaneValueType) {
  KKLaneValueTypeGeneric = 0,
  KKLaneValueTypeFloat = 1,
  KKLaneValueTypeNormalized = 2,
  KKLaneValueTypeCrop = 3,  // [width, height, x, y] normalized center offsets
  KKLaneValueTypeColor = 4, // [r, g, b, a] 0–1
  KKLaneValueTypeGradient = 5, // flat stop array: [position, r, g, b, midpoint,
                               // ...] × N stops; variable length
  KKLaneValueTypeAngle = 6,    // single value, degrees; row renders a circular
                               // knob + numeric field (unit "°") instead of
                               // the standard slider + field used for Float.
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

/// Spatial-curve annotation for 2D (Position) lanes. Default NO = the lane
/// travels in a straight line through this keypose (legacy behaviour - every
/// existing blob is unchanged). YES = the path curves: the evaluator bends the
/// Position segments on either side using a cubic bezier whose handles come
/// from inHandle/outHandle, or are auto-derived (Catmull-Rom) from the
/// neighbouring keyposes when those are nil. Ignored by non-2D lanes.
@property(nonatomic) BOOL spatialSmooth;

/// Manual tangent handles for the spatial curve, as [dx,dy] offsets from the
/// anchor (values[0],values[1]) in the lane's own units. nil = auto-derive
/// from the neighbours. inHandle shapes the incoming segment, outHandle the
/// outgoing one. Only meaningful when spatialSmooth is YES on a 2D lane.
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *inHandle;
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *outHandle;

+ (instancetype)keyposeAtTime:(double)time values:(NSArray<NSNumber *> *)values;

/// Returns a copy of the receiver with a new time, preserving everything else
/// (values, outgoing interval, and the spatial-curve fields spatialSmooth /
/// inHandle / outHandle). Use this when *moving* a keypose - rebuilding with
/// keyposeAtTime:values: silently drops the spatial-curve state, which is the
/// "all keyposes go back to linear after editing" class of bug.
- (instancetype)keyposeBySettingTime:(double)time;

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
/// Optional tint per component caption (e.g. red/green/blue X/Y/Z for
/// Rotation). nil entries within the array fall back to inspectorLabel.
/// nil array entirely = uniform inspectorLabel for all components.
@property(nonatomic, copy, nullable) NSArray<NSColor *> *componentLabelColors;
@property(nonatomic, copy) NSArray<KKKeyPose *> *keyposes; // ordered by time
@property(nonatomic) double lastKnownClipDuration; // 0 = not yet established

/// Basic-mode hold-shape annotation. `Auto` (default) means infer from KP
/// layout; any other value pins the In/Out interpretation regardless of
/// where the user has dragged the boundary keypose to.
@property(nonatomic) KKLaneHoldShape holdShape;

/// When YES this lane carries a 2D spatial path (Position): its keyposes can be
/// marked smooth (cubic-bezier spatial interpolation) and the value popover
/// shows a per-keypose linear/smooth toggle glyph on the row. Default NO.
/// Plugins set this on their Position lane; the kit never infers it.
@property(nonatomic) BOOL spatialCurvable;

/// When YES this lane's two components can be aspect-locked: the value popover
/// shows a link/unlink glyph (same slot as the smooth toggle), and while
/// `aspectLinked` is YES, editing one component scales the other by the same
/// factor to preserve their current ratio. Build-time metadata, like
/// `spatialCurvable`; the kit never infers it. Default NO. Intended for a
/// 2-component lane such as Scale.
@property(nonatomic) BOOL aspectLinkable;

/// Persisted state of the aspect lock (only meaningful when `aspectLinkable`).
/// One global toggle for the whole lane (not per-keypose). Default NO; a plugin
/// that wants it on by default sets it when building the lane.
@property(nonatomic) BOOL aspectLinked;

/// When YES the value-popover fields for this lane display and round to whole
/// numbers (no decimals) - e.g. Scale's percentage. Build-time metadata, like
/// `aspectLinkable`. Default NO.
@property(nonatomic) BOOL integerValued;

/// When YES the value-popover scales this lane's components by the media size
/// for DISPLAY only: even-index components (W/X-like) by media width,
/// odd-index (H/Y-like) by media height, with the inverse applied to typed
/// input. The stored and rendered value is always raw - scaling never reaches
/// the shader. Build-time metadata like `aspectLinkable`; default NO. Set this
/// on lanes whose stored value is a normalised 0..1 fraction the user should
/// see as pixels (Crop, Position, Anchor). The `componentUnits` string (e.g.
/// @"px") is purely cosmetic and does NOT drive this - a lane can show a "px"
/// suffix while storing/rendering absolute pixels (e.g. Glow's Radius).
@property(nonatomic) BOOL componentsScaleWithMedia;

/// Navigational category for the static-values popover (Constants + Keypose):
/// lanes sharing a `categoryKey` are shown together behind one icon pill, so a
/// plugin with many params can split them into pages (e.g. "Core", "Noise")
/// instead of one long list. Purely a popover view filter - it does NOT affect
/// the timeline, sequencer, or `groupKey` lane grouping. `categorySymbol` is
/// the pill's SF Symbol. nil categoryKey = uncategorised (always shown; no pill
/// row appears unless >1 distinct category exists). Build-time metadata.
@property(nonatomic, copy, nullable) NSString *categoryKey;
@property(nonatomic, copy, nullable) NSString *categorySymbol;

/// When NO the property can't be animated: it's left out of the Animated
/// dropdown and its "make animatable" button is hidden in Constants, so it
/// stays a value-only param (e.g. a noise seed). Default YES. Build-time
/// metadata.
@property(nonatomic) BOOL animatable;

/// When YES the value row presents a seed control (current value + re-roll,
/// the same `KKSeedView` the gap popover uses) instead of a slider - for a
/// random integer that isn't a meaningful range. Pair with `animatable = NO`
/// and `integerValued = YES`. Default NO. Build-time metadata.
@property(nonatomic) BOOL seedField;

/// When set (count >= 2) the value row presents a grouped radio pill (one
/// segment per label) instead of a number field, and the lane's single value is
/// the selected index (0-based). Labels are English identifiers, localized for
/// display via `KKLocalizedParamName`. Pair with `animatable = NO` and
/// `integerValued = YES` for a structural enum (e.g. a colour mode). nil/empty
/// = a normal numeric row. Build-time metadata.
@property(nonatomic, copy, nullable) NSArray<NSString *> *choiceLabels;

/// Conditional visibility (static-values / constants popover only): this lane's
/// row shows only when the lane named `visibleWhenLabel` has a component-0
/// value (rounded) listed in `visibleWhenValues`. Cascades: a lane is also
/// hidden when its controller is itself hidden (so chaining Angle -> Type ->
/// Mode works). A nil `visibleWhenLabel` = always visible. Build-time metadata;
/// serialized so a rebuilt display lane keeps the rule.
@property(nonatomic, copy, nullable) NSString *visibleWhenLabel;
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *visibleWhenValues;

/// For a KKLaneValueTypeGradient lane: when YES the row also shows an inline
/// radial/linear type toggle and (for linear) an angle knob, all in one row,
/// and the lane value is laid out as `[type, angleDegrees, <flat stops...>]`
/// instead of pure stops. Default NO (plain stops-only gradient, e.g. Canvas).
/// Build- time metadata.
@property(nonatomic) BOOL gradientShowsTypeAngle;

+ (instancetype)laneWithLabel:(NSString *)label;

/// Copy the param-picker build-time metadata (`categoryKey`, `categorySymbol`,
/// `animatable`, `seedField`, `choiceLabels`) from a plugin template lane onto
/// this one. Used
/// when display lanes are seeded/rebuilt from a persisted blob that predates
/// these fields. Leaves value/keyposes/enabled and other state untouched.
- (void)kkApplyPickerMetadataFrom:(KKLane *)tmpl;

- (void)insertKeypose:(KKKeyPose *)keypose; // inserts maintaining time order
- (void)removeKeyposeAtIndex:(NSUInteger)index;

@end

/// Display labels for a lane's value components, derived from its valueType.
/// Used in per-component selection UI (modulation popover's component pills).
/// Returns nil for single-component types (no UI shown). Generic multi-comp
/// lanes fall back to "1", "2", ... indices.
FOUNDATION_EXPORT
NSArray<NSString *> *_Nullable KKLaneComponentLabels(KKLane *lane);

/// Labels of the lanes currently visible under the `visibleWhen` cascade: a
/// lane with no rule is always visible; one with a rule shows only when its
/// controller lane's component-0 value is in `visibleWhenValues` AND the
/// controller is itself visible (cascades). A controller absent from `lanes`
/// can't gate, so the lane shows. `valuesByLabel` overrides a lane's current
/// component values (e.g. mid-edit); lanes absent from it fall back to their
/// first keypose. Pass nil to use first-keypose values throughout. Used to hide
/// mode-gated lanes uniformly across the timeline UI (graph, filter bar, param
/// order) and the constants/keypose popover.
FOUNDATION_EXPORT NSSet<NSString *> *KKConditionalVisibleLaneLabels(
    NSArray<KKLane *> *lanes,
    NSDictionary<NSString *, NSArray<NSNumber *> *> *_Nullable valuesByLabel);

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

/// User-defined display order of property labels (the inspector's drag-to-
/// reorder). Labels appear in this order; any label not listed falls back to
/// alphabetical after them. nil/empty == fully alphabetical (the default).
@property(nonatomic, copy, nullable) NSArray<NSString *> *paramOrder;

+ (instancetype)timeline;

@end

/// Rewrites keypose time fractions for a new clip duration, preserving
/// locked intervals' absolute durations where possible. Unlocked intervals
/// scale proportionally. Returns a new KKTimeline; input is not mutated.
FOUNDATION_EXPORT KKTimeline *KKTimelineRebalanced(KKTimeline *timeline,
                                                   double oldDuration,
                                                   double newDuration);

/// Returns a copy of `timeline` with `spatialSmooth` set to `on` on the
/// keypose nearest `frac` in the lane named `label`. Nearest-match (not exact)
/// so it is robust to a lane storing its endpoint a frame short of 0/1.
/// Returns nil when nothing changed (no such lane, empty lane, or the keypose
/// already has that state) so the caller can skip the commit + undo entry.
FOUNDATION_EXPORT KKTimeline *_Nullable KKTimelineSettingSpatialSmooth(
    KKTimeline *timeline, NSString *label, double frac, BOOL on);

/// Returns a copy of `timeline` with `aspectLinked` set to `on` on the lane
/// named `label` (a global, per-lane toggle - not per-keypose). Returns nil
/// when nothing changed (no such lane, or already in that state) so the caller
/// can skip the commit + undo entry.
FOUNDATION_EXPORT KKTimeline *_Nullable KKTimelineSettingAspectLinked(
    KKTimeline *timeline, NSString *label, BOOL on);

/// Returns a copy of `timeline` with the composite-gradient lane named `label`
/// set to gradient `type` (value index 0) on EVERY keypose - the type is a
/// single, non-animated property of the gradient, so it stays uniform across
/// the animation while angle/stops keyframe. Preserves each keypose's
/// angle/stops and other state. Returns nil when nothing changed (caller skips
/// the commit).
FOUNDATION_EXPORT KKTimeline *_Nullable KKTimelineSettingGradientType(
    KKTimeline *timeline, NSString *label, NSInteger type);

/// Index of the keypose whose time is nearest `frac`, or NSNotFound when the
/// lane has no keyposes. The shared "which keypose does this interaction edit"
/// helper - a drag edits the keypose nearest the playhead (or the grabbed one).
FOUNDATION_EXPORT NSInteger KKLaneNearestKeyposeIndex(KKLane *lane,
                                                      double frac);

/// Returns a copy of `lane` with the keypose at `index` set to `values`,
/// copy-preserving spatialSmooth / in-out handles / outgoing interval, and
/// propagating the new value to hold-linked neighbours (the linked chain on
/// either side). Out-of-range `index` returns an unchanged copy. Use this when
/// the caller already knows WHICH keypose to edit (e.g. a grabbed path-anchor
/// dot); the nearest-fraction variant below is for playhead-relative edits.
/// Input lane is not mutated.
FOUNDATION_EXPORT KKLane *
KKLaneBySettingValuesAtIndex(KKLane *lane, NSInteger index,
                             NSArray<NSNumber *> *values);

/// Returns a copy of `lane` with the keypose nearest `frac` set to `values`,
/// copy-preserving spatialSmooth / in-out handles / outgoing interval, and
/// propagating the new value to hold-linked neighbours. An empty lane gets a
/// single keypose at time 0. Input lane is not mutated.
FOUNDATION_EXPORT KKLane *
KKLaneBySettingValuesNearestFraction(KKLane *lane, double frac,
                                     NSArray<NSNumber *> *values);

/// Returns a copy of `timeline` with lane `label`'s keypose nearest `frac` set
/// to `values` (via KKLaneBySettingValuesNearestFraction). Returns nil when no
/// lane named `label` exists - the caller owns absent-lane creation, which is
/// lane-type specific (units / labels / value type). Unlike the Setting*
/// helpers above it never returns nil for "unchanged": a drag write always
/// commits.
FOUNDATION_EXPORT KKTimeline *_Nullable KKTimelineSettingValuesNearestFraction(
    KKTimeline *timeline, NSString *label, double frac,
    NSArray<NSNumber *> *values);

@interface KKTimeline (Serialization)

+ (nullable NSString *)jsonFromTimeline:(KKTimeline *)timeline;
+ (nullable KKTimeline *)timelineFromJSON:(NSString *)json;

@end

NS_ASSUME_NONNULL_END
