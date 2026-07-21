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
  KKLaneValueTypeColorPoint =
      7, // leading numeric fields + a trailing RGBA
         // swatch on one row: [<field comps...>, r,g,b,a]
         // (last 4 are the swatch). componentLabels
         // count = the number of leading fields.
  KKLaneValueTypeCode =
      8, // a non-numeric lane whose row hosts a multi-line code editor
         // (KKCodeEditorView). The text is NOT a keypose value - it is held in
         // `lane.codeString` and flows through the timeline like any lane. Used
         // for a user-supplied shader source.
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

/// Opaque per-keypose geometry payload for OSC-edited geometry lanes (e.g. a
/// path's Points): the shape AT this keypose, captured via KKMorphSnapshot. The
/// renderer interpolates between adjacent keyposes' snapshots. Storing it on
/// the keypose means it travels with the keypose through copy / move / remove,
/// so no parallel array needs syncing. nil for ordinary scalar lanes. Default
/// nil.
@property(nonatomic, copy, nullable) NSData *geometrySnapshot;

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
/// Optional user-facing name shown INSTEAD of `label` (which stays the stable
/// identity used for value lookup / OSC / persistence). Lets a dynamic plugin
/// key a lane on something stable (e.g. a shader's GLSL uniform name) while the
/// UI shows a free-to-rename label - so renaming or reordering never rebinds
/// values. nil = show `label` (localized). Mirrors `layerLabel` for the layer
/// level. Build-time metadata; re-asserted via `kkApplyPickerMetadataFrom:`.
@property(nonatomic, copy, nullable) NSString *displayLabel;
/// The name to SHOW for this lane: `displayLabel` when set, else the localized
/// `label`. Every lane-name render site uses this so identity vs display stay
/// separate.
- (NSString *)displayName;
@property(nonatomic, copy, nullable) NSString *groupKey;
@property(nonatomic) BOOL enabled;
@property(nonatomic) KKLaneValueType valueType; // default: Generic
/// For a `KKLaneValueTypeCode` lane only: the multi-line source the editor row
/// shows and edits. Held on the lane (not a keypose) and serialized with the
/// timeline, so it travels the same path as every other lane's data.
@property(nonatomic, copy, nullable) NSString *codeString;
/// For a `KKLaneValueTypeCode` lane: an optional validator the editor runs
/// (debounced) to surface an error bar + flagged line. Return an error message
/// or nil; set `*outLine` to the 1-based line to flag (0 = none). Not
/// serialized (a block can't be), so it is carried template->reconciled in
/// -seededFrom: like a piece of static config, not clip data.
@property(nonatomic, copy, nullable) NSString *_Nullable (^codeValidator)
    (NSString *code, NSInteger *outLine);
/// For a `KKLaneValueTypeCode` lane: optional pre-pass composing the source
/// that `codeValidator` sees from the section set (e.g. prepending a shared
/// "Common" section, or appending a stub entry point when validating that
/// section itself). Return the composed source + `*outPrependLines` for
/// error-line mapping; nil validates the active section as-is. Keeps
/// language-specific composition in the plugin. Not serialized (a block),
/// carried template->reconciled like `codeValidator`.
@property(nonatomic, copy, nullable)
    NSString *_Nullable (^codeValidationComposer)
        (NSString *activeSectionName, NSString *activeCode,
         NSArray<NSDictionary<NSString *, NSString *> *> *sections,
         NSInteger *outPrependLines);
/// For a `KKLaneValueTypeCode` lane: optional formatter powering a "Format"
/// button in the editor's tab strip. Given a section's text, return the
/// reformatted text (nil / unchanged = no-op). Not serialized (a block), so it
/// is carried template->reconciled in -seededFrom: like `codeValidator`.
@property(nonatomic, copy, nullable) NSString *_Nullable (^codeFormatter)
    (NSString *code);
/// For a `KKLaneValueTypeCode` lane: optional autocomplete provider (GLSL mode)
/// wired to the editor's `completionProvider` - given the text + caret, returns
/// the context-filtered candidate items + the range a pick replaces. Keeps the
/// language vocabulary in the plugin (a shader's `//` directives, GLSL
/// builtins, its declared uniforms). Not serialized (a block), carried
/// template->reconciled like `codeValidator`.
@property(nonatomic, copy, nullable)
    NSArray<NSDictionary<NSString *, NSString *> *> *_Nullable (
        ^codeCompletionProvider)
        (NSString *text, NSUInteger caret, NSRange *outReplaceRange);
/// For a `KKLaneValueTypeCode` lane: optional extra named code sections beyond
/// `codeString` (the primary/Image section), presented as tabs in the editor.
/// Each entry is @{ @"name": display, @"code": source }. nil/empty = a single
/// section (no tab bar). Serialized with the timeline like `codeString`, so the
/// sections travel the same path as every other lane's data.
@property(nonatomic, copy, nullable)
    NSArray<NSDictionary<NSString *, NSString *> *> *codeTabs;
/// For a `KKLaneValueTypeCode` lane: the ordered catalog of EXTRA section names
/// a user can add via the editor's "+" menu (e.g. @[@"Common", @"Buffer A"]).
/// Static template config (not user data) - carried template->reconciled like
/// `codeValidator`, never serialized. `codeTabs` holds the ones actually added.
@property(nonatomic, copy, nullable) NSArray<NSString *> *codeTabCatalog;
/// For a `KKLaneValueTypeCode` lane: when YES the editor shows a save bar (name
/// field + Save button) under the code. Save posts
/// `KKCodeEditorSaveRequestedNotification` for a host to persist / publish the
/// code. Static template config (not serialized), carried template->reconciled
/// like `codeValidator`. Default NO.
@property(nonatomic) BOOL codeSavable;
/// For a `codeSavable` lane: labels for an optional single-select picker in the
/// save bar, between the name field and Save. Already localized, and opaque to
/// the timeline - the save notification reports the picked INDEX into this
/// array (`KKCodeEditorSaveCategoryIndexKey`) and the host maps it back to
/// whatever it means. Empty / nil = no picker. Static template config (not
/// serialized), carried template->reconciled like `codeSavable`.
@property(nonatomic, copy, nullable) NSArray<NSString *> *codeSaveCategories;
/// For a `codeSavable` lane: the save-bar name field placeholder (already
/// localized). nil = the editor's generic "Name". Static template config (not
/// serialized), carried template->reconciled like `codeSavable`.
@property(nonatomic, copy, nullable) NSString *codeSaveNamePlaceholder;
@property(nonatomic, copy) NSArray<NSNumber *>
    *componentMin; // one per component, empty = unconstrained
@property(nonatomic, copy) NSArray<NSNumber *>
    *componentMax; // one per component, empty = unconstrained
/// Optional upper bound for the single-component SLIDER only, decoupled from
/// the value clamp (`componentMax`). When set, the slider tops out here while
/// the field still accepts (and clamps to) the larger `componentMax` - so a
/// value can be typed past the slider's end. nil = slider uses componentMax.
/// Used for the marker width (slider 0..500 %, field pushable further).
/// Build-time.
@property(nonatomic, copy, nullable) NSNumber *sliderMax;
/// Optional lower bound for the single-component SLIDER only, decoupled from
/// the value clamp (`componentMin`). When set, the slider stops here while the
/// field still accepts (and clamps to) the wider `componentMin` - so a value
/// can be typed past the slider's start. nil = slider uses componentMin (or 0).
/// Used for the draw-on Offset (slider 0..100 %, field unbounded so it can spin
/// the reveal round and round). Build-time.
@property(nonatomic, copy, nullable) NSNumber *sliderMin;
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

/// Plain (no-modifier) increment for one drag-step when scrubbing this lane's
/// value fields (Shift/Option then scale it x10 / x0.1). Build-time metadata.
/// Default 0, which means "auto": the row picks 1.0 for whole-number fields
/// (integer / media-pixel) and 0.01 for raw 2-decimal fields. Set this when the
/// auto guess is wrong - e.g. Glow's Radius is a raw 0..500 px value shown with
/// decimals, so it wants 1.0 rather than the 0.01 the auto rule would choose.
@property(nonatomic) double scrubStep;

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

/// Optional OUTER grouping level above `categoryKey`, for plugins (e.g. Canvas)
/// whose timeline holds lanes from several owners - one "layer" per owner. When
/// set, the Advanced view draws a layer header strip above the category
/// header(s), giving a layer > category > lane tree; `layerLabel` is the
/// displayed name and `layerSymbol` an optional SF Symbol. nil (the default for
/// every other plugin) = no layer level, so their timeline renders unchanged.
/// Build-time / assembly metadata; the kit never infers it.
@property(nonatomic, copy, nullable) NSString *layerKey;
@property(nonatomic, copy, nullable) NSString *layerLabel;
@property(nonatomic, copy, nullable) NSString *layerSymbol;

/// Transient (never serialized) marker: this lane is a synthetic HEADER row in
/// the Advanced graph (drawn as a name + collapse glyph, no keyposes). Set by
/// the view when it injects per-layer / per-category header rows; not part of
/// any plugin's timeline. `categoryHeader` (below) discriminates the two kinds.
@property(nonatomic) BOOL headerPlaceholder;

/// Transient (never serialized) marker: when paired with `headerPlaceholder`,
/// this header row is a CATEGORY header (drawn from `categoryKey` /
/// `categorySymbol`, collapses the lanes of that category) rather than a layer
/// header. Set by the view when it injects per-category header rows.
@property(nonatomic) BOOL categoryHeader;

/// Transient (never serialized) marker: this lane is READ-ONLY in the timeline
/// (e.g. it belongs to a locked layer). The graphs draw it dimmed and reject
/// interaction; set by a multi-owner host when building its merged timeline.
@property(nonatomic) BOOL locked;

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

/// When YES the property is edited only via an on-screen control (no numeric
/// fields): the value / keypose / constants popover shows a message row
/// ("Edit on canvas") instead of value fields. The lane still animates
/// (keyposes drive timing) and appears in the timeline; only the inline value
/// editor is replaced. Use for geometry-style properties (e.g. a path's
/// points). Default NO. Build-time metadata.
@property(nonatomic) BOOL oscEditedOnly;

/// When YES this property applies to SOME owners only (multi-owner plugins):
/// the plugin includes the lane in the applied timeline just for the layers
/// that support it (e.g. a vector path's stroke, not an image / group). The kit
/// must NOT re-seed it as a constant default when the applied timeline omits it
/// - otherwise its whole category shows (greyed) for every owner. Same
/// per-owner opt-in the geometry lanes get for free via `oscEditedOnly`, but
/// without that flag's OSC-only editing behaviour. Default NO. Build-time
/// metadata.
@property(nonatomic) BOOL ownerScoped;

/// When set (count >= 2) the value row presents a grouped radio pill (one
/// segment per label) instead of a number field, and the lane's single value is
/// the selected index (0-based). Labels are English identifiers, localized for
/// display via `KKLocalizedParamName`. Pair with `animatable = NO` and
/// `integerValued = YES` for a structural enum (e.g. a colour mode). nil/empty
/// = a normal numeric row. Build-time metadata.
@property(nonatomic, copy, nullable) NSArray<NSString *> *choiceLabels;

/// Optional per-choice GLYPH icons (one NSImage per `choiceLabels` entry). When
/// set, the radio pill shows these icons instead of text (the labels stay as
/// accessibility/tooltip names). Build-time DISPLAY metadata - NOT serialized
/// (NSImage isn't codable), so a per-layer timeline builder must re-assert it
/// from the template (carried by `kkApplyPickerMetadataFrom:`), like
/// `componentLabelColors`. Use for icon enums (e.g. stroke Line Cap / Join).
@property(nonatomic, copy, nullable) NSArray<NSImage *> *choiceIcons;

/// When YES a choice-pill row lets its pills WRAP onto multiple right-aligned
/// lines if they don't fit the row width (and the row grows in height), instead
/// of overflowing. Use for a wide glyph set like the 6 stroke-marker types; a
/// short set (Line Cap / Join) leaves it NO and stays single-line. Build-time
/// metadata; re-asserted via `kkApplyPickerMetadataFrom:`.
@property(nonatomic) BOOL wrapsChoicePills;

/// When YES a choice row is a searchable single-select DROPDOWN instead of a
/// pill group: the row shows the current pick and expands a list in place.
///
/// Pills are better while they fit - every option visible, one click to switch
/// - so this is the escape hatch for a set that is long (pills wrap into a
/// wall) or open-ended (a shader author's `#choice ... dropdown`, whose options
/// this code has never seen). Build-time metadata; re-asserted via
/// `kkApplyPickerMetadataFrom:`.
@property(nonatomic) BOOL choiceUsesDropdown;

/// What to SHOW for a stored value that names none of `choiceValues`, keyed by
/// that stored value.
///
/// Without this, a lane bound to a since-vanished option reads "None" - the
/// same thing it says when the user deliberately picked None. The two are not
/// the same, and only the owner knows the difference: Shader's `#audio` lane
/// binds to a Sonar source that may simply not be published on this Mac, and
/// the plugin remembers what it was even when the option list can't.
///
/// A map rather than one string because the answer depends on WHICH value is
/// stored, and a lane template is built before any of its rows know theirs.
/// Build-time metadata; re-asserted via `kkApplyPickerMetadataFrom:`.
@property(nonatomic, copy, nullable)
    NSDictionary<NSNumber *, NSString *> *choiceUnknownLabels;

/// Short warning shown beside a choice whose stored value is unknown, e.g.
/// "Republish required". nil = no warning.
///
/// Deliberately terse: it sits in the gap between the lane's name and its
/// value control, which is ~145pt at the default popover width. The full
/// explanation belongs in `choiceUnknownLabels`, which has the whole value
/// column to render in. Build-time metadata; re-asserted via
/// `kkApplyPickerMetadataFrom:`.
@property(nonatomic, copy, nullable) NSString *choiceUnknownBadge;

/// Optional per-choice STORED VALUES, parallel to `choiceLabels`. When set, the
/// lane stores `choiceValues[i]` instead of the selected index `i`.
///
/// For a set whose MEMBERSHIP CHANGES between sessions - Shader's `#audio` lane
/// lists whatever Sonar has published - an index is not a reference: delete one
/// source and every lane pointing past it silently means something else. A
/// stable id per choice survives insertion and deletion, and a stored value
/// with no matching choice reads as "the thing I pointed at is gone" rather
/// than quietly becoming its neighbour.
///
/// Values must be whole numbers exactly representable in a float (|v| < 2^24),
/// since lane values travel as floats. nil = the value IS the index (the normal
/// case, where the choices are fixed by the code).
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *choiceValues;

/// When YES the value row presents a single right-aligned CHECKBOX instead of a
/// number field; the lane's single value is 0 (off) or 1 (on). Pair with
/// `animatable = NO` + `integerValued = YES` for a structural on/off (e.g. a
/// Stroke "enabled" toggle). A plugin can gate its other lanes (lock/grey) on
/// this value. nil/NO = a normal numeric row. Build-time metadata.
@property(nonatomic) BOOL isToggle;

/// When YES the per-component prefix caption (e.g. "Start" / "End") sizes to
/// fit its text instead of the fixed one-character slot. Use for multi-word
/// component labels (single-char W/H/X/Y keep the default fixed slot so columns
/// align across rows). Widens the row, so opt in only where needed. Default NO.
/// Build-time metadata.
@property(nonatomic) BOOL autoSizesComponentLabels;

/// Conditional visibility (static-values / constants popover only): this lane's
/// row shows only when the lane named `visibleWhenLabel` has a component-0
/// value (rounded) listed in `visibleWhenValues`. Cascades: a lane is also
/// hidden when its controller is itself hidden (so chaining Angle -> Type ->
/// Mode works). A nil `visibleWhenLabel` = always visible. Build-time metadata;
/// serialized so a rebuilt display lane keeps the rule.
@property(nonatomic, copy, nullable) NSString *visibleWhenLabel;
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *visibleWhenValues;

/// Optional OR alternative to `visibleWhenLabel`: when set, the lane is visible
/// if EITHER the primary rule (visibleWhenLabel/Values) OR this one holds (the
/// named lane's component-0 value is in `visibleWhenOrValues`). With this set,
/// an ABSENT controller counts as that side being false (not "always visible"),
/// so a lane gated on "A OR B" hides when only one of A/B is present and off.
/// Used for Sketch (visible when Stroke OR Fill is enabled). Serialized.
@property(nonatomic, copy, nullable) NSString *visibleWhenOrLabel;
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *visibleWhenOrValues;

/// Optional second AND condition, combined with the primary rule: when set, the
/// lane is visible only if the primary rule (or the primary-OR pair, if that is
/// used) holds AND this named lane's component-0 value (rounded) is in
/// `visibleWhenAndValues`. An absent controller counts as this side being false
/// (the lane hides). Used for Mesh's dynamic colour swatches, which show only
/// when both the Type supports swatch N AND the colour-count lane is >= N.
/// Serialized.
@property(nonatomic, copy, nullable) NSString *visibleWhenAndLabel;
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *visibleWhenAndValues;

/// Optional dynamic upper bound for the value slider: when set, the row's max
/// (componentMax[0]) is looked up from `componentMaxByControllerValue` using
/// the rounded component-0 value of the lane named `maxControllerLabel` as the
/// index
/// - so the slider's range reacts to another lane (e.g. Mesh's Type caps the
/// colour count, keeping one easy slider whose max tracks the Type). Falls back
/// to the static `componentMax` when unset / out of range. Serialized.
@property(nonatomic, copy, nullable) NSString *maxControllerLabel;
@property(nonatomic, copy, nullable)
    NSArray<NSNumber *> *componentMaxByControllerValue;

/// For a KKLaneValueTypeGradient lane: when YES the row also shows an inline
/// radial/linear type toggle and (for linear) an angle knob, all in one row,
/// and the lane value is laid out as `[type, angleDegrees, <flat stops...>]`
/// instead of pure stops. Default NO (plain stops-only gradient, e.g. Canvas).
/// Build- time metadata.
@property(nonatomic) BOOL gradientShowsTypeAngle;

/// When YES a `KKLaneValueTypeColor` row shows a small lock toggle beside its
/// swatch. A palette generator (see `KKPaletteGenerator`) skips locked colours
/// when it rerolls, so the user can pin one or more swatches and regenerate the
/// rest. Default NO, so existing colour lanes are unaffected. The lock STATE is
/// transient UI (held by the constants popover), not stored on the lane; this
/// flag only opts the row into showing the control. Build-time metadata.
@property(nonatomic) BOOL paletteLockable;

/// When YES the row is not a value editor but a palette-generator bar: a set of
/// momentary mode buttons (Bright / Dull / Shades / Chaotic / Golden). Tapping
/// one rerolls the visible `paletteLockable` colour lanes via
/// `KKPaletteGenerator`, keeping any locked swatches. The lane carries no value
/// (valueType Generic, not animatable). Place it first in the colour category
/// so it sits above the swatches. Build-time metadata.
@property(nonatomic) BOOL paletteGeneratorBar;

/// Palette-generator scope: `paletteLockable` colour lanes sharing a non-nil
/// `paletteGroup` reroll together as ONE independent palette journey; different
/// groups are unrelated. Lanes with a nil group all reroll as a single shared
/// journey (the legacy behaviour). Used by a host that exposes several distinct
/// colour properties (e.g. a shader's separate `// #color` arrays + singles) so
/// each stays its own cohesive palette. Build-time metadata.
@property(nonatomic, copy, nullable) NSString *paletteGroup;

/// Parameter-link binding (cross-effect linking - see KKLinkBus). Model-level
/// so EVERY plugin's lanes carry it; serialized with the timeline, read by the
/// shared resolver. The kit never infers it.
///
/// `linkExpression`: the transform code for this lane (see KKLinkExpr). `value`
/// = this lane's own value; `${name}` = another source, resolved recursively at
/// the current timeline time. nil / empty / bare "value" = plain passthrough
/// (own value). This is the source of truth: a lane is expression-driven or it
/// isn't.
@property(nonatomic, copy, nullable) NSString *linkExpression;

+ (instancetype)laneWithLabel:(NSString *)label;

/// Standard FCP-style opacity lane (one whole-percentage component 0..100,
/// identity 100). Shared so every plugin with an opacity property uses one
/// definition; the owning plugin sets category / enabled after.
+ (instancetype)opacityLane;

/// Copy the param-picker build-time metadata (`categoryKey`, `categorySymbol`,
/// `animatable`, `seedField`, `choiceLabels`) from a plugin template lane onto
/// this one. Used
/// when display lanes are seeded/rebuilt from a persisted blob that predates
/// these fields. Leaves value/keyposes/enabled and other state untouched.
- (void)kkApplyPickerMetadataFrom:(KKLane *)tmpl;

- (void)insertKeypose:(KKKeyPose *)keypose; // inserts maintaining time order
- (void)removeKeyposeAtIndex:(NSUInteger)index;

@end

/// Posted (by the code editor) when a `codeSavable` lane's save bar Save button
/// is pressed. `object` is the KKCodeEditorView; userInfo has
/// `KKCodeEditorSaveNameKey` (NSString) + `KKCodeEditorSaveSectionsKey`
/// (NSArray of @{@"name",@"code"}). Declared in this public header so a plugin
/// host can observe it (the editor view's own header is framework-internal).
FOUNDATION_EXPORT NSNotificationName const
    KKCodeEditorSaveRequestedNotification;
FOUNDATION_EXPORT NSString *const KKCodeEditorSaveNameKey;
FOUNDATION_EXPORT NSString *const KKCodeEditorSaveSectionsKey;
/// Also in userInfo when the host set `saveCategoryLabels`: an NSNumber index
/// into that array (absent when the host set no labels).
///
/// An INDEX, not a name: the labels are the host's own localized strings, so
/// the editor has no idea what they mean and shouldn't pretend to - it hands
/// back the row that was picked and lets the host map it to whatever it models.
FOUNDATION_EXPORT NSString *const KKCodeEditorSaveCategoryIndexKey;

/// Post this to make an open savable code editor reload its sections (e.g.
/// after a host loads a different shader). userInfo:
/// `KKCodeEditorSaveSectionsKey` (NSArray of @{@"name",@"code"}). Only
/// `savable` editors respond.
FOUNDATION_EXPORT NSNotificationName const KKCodeEditorReloadNotification;

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

/// "Maintain Timing" bake: rewrites each keypose's time fraction so its
/// ABSOLUTE source-media position is preserved when the clip's source range
/// changes from (`fromSrcIn`, `fromDur`) to (`toSrcIn`, `toDur`) - i.e. a
/// trim/grow/split. A keypose at fraction `f` sits at media time
/// `fromSrcIn + f*fromDur`; its new fraction is `(media - toSrcIn) / toDur`.
/// Keyposes pushed off an edge are COALESCED (not piled up): of the head run
/// (f<=0) only the last survives at 0, of the tail run (f>=1) only the first
/// survives at 1, so no keyposes ever overlap. Interior keyposes (0<f<1) keep
/// their remapped time. Lanes with < 2 keyposes (constants) are left untouched.
/// Preserves handles/intervals/smoothing. Returns a new KKTimeline; input is
/// not mutated.
///
/// `sampler` (optional) evaluates the ORIGINAL lane at a 0-1 fraction; when
/// given, a SYNTHESIZED edge keypose takes the INTERPOLATED value at the clip
/// boundary (original fraction `(toSrcIn - fromSrcIn)/fromDur` for the head,
/// `(toSrcIn + toDur - fromSrcIn)/fromDur` for the tail) instead of its own raw
/// value. This makes a SPLIT continuous: both halves sample the same media
/// fraction at the cut, so their boundary values match. Pass nil to keep raw
/// values (no evaluator dependency).
///
/// `edgeEps` is the near-edge tolerance (a 0-1 fraction, ~half a frame). A real
/// keypose within `edgeEps` of an edge - e.g. a split landing AT a keypose -
/// is snapped to that edge (keeping its own value + easing) rather than being
/// kept as a separate interior keypose alongside a synthesized boundary, which
/// would leave two coincident keyposes. 0 disables it.
typedef NSArray<NSNumber *> *_Nullable (^KKLaneFractionSampler)(KKLane *lane,
                                                                double frac);
FOUNDATION_EXPORT KKTimeline *KKTimelineRetimedForMediaAnchor(
    KKTimeline *timeline, double fromSrcIn, double fromDur, double toSrcIn,
    double toDur, KKLaneFractionSampler _Nullable sampler, double edgeEps);

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

/// Returns a copy of `timeline` with the lane named `label`'s link EXPRESSION
/// set to `expr`. A nil `expr` clears the binding; an empty string is kept as a
/// present-but-empty passthrough (so a cleared editor stays open). Returns nil
/// when unchanged.
FOUNDATION_EXPORT KKTimeline *_Nullable KKTimelineSettingLinkExpression(
    KKTimeline *timeline, NSString *label, NSString *_Nullable expr);

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

/// Geometry-aware keypose "value" equality. For an OSC-edited geometry lane
/// (`oscEditedOnly`) the keyposes carry no scalar - their value IS the shape -
/// so this compares their morph-snapshot hashes; for any other lane it compares
/// the scalar `values`. Use it wherever the timeline asks "do these two
/// keyposes hold the same value?" (drift / transition detection) so geometry
/// lanes are handled correctly instead of always reading equal (empty values).
FOUNDATION_EXPORT BOOL KKLaneKeyposeValuesEqual(KKLane *lane, KKKeyPose *a,
                                                KKKeyPose *b);

/// The geometry snapshot a geometry lane (`oscEditedOnly`) DISPLAYS at `frac`:
/// the surrounding keyposes' snapshots interpolated with the segment's easing
/// curve (mirrors the renderer). Use it when inserting a keypose so the new one
/// captures the shape currently shown - otherwise splitting a hold gives the
/// new keypose no snapshot, it falls back to the base shape, and the segment
/// reads as a transition. Returns nil when the surrounding keyposes have no
/// usable snapshots (so the new keypose falls back to the base, like them).
FOUNDATION_EXPORT NSData *_Nullable KKLaneGeometrySnapshotAtFraction(
    KKLane *lane, double frac);

NS_ASSUME_NONNULL_END
