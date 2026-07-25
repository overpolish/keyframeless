/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimeline.h"

#import "KKBezierPath.h"
#import "KKEasing.h"
#import "KKLog.h"
#import "KKPathMorph.h"
#import <objc/runtime.h> // DEBUG field-descriptor completeness check

BOOL KKLaneKeyposeValuesEqual(KKLane *lane, KKKeyPose *a, KKKeyPose *b) {
  if (lane.oscEditedOnly)
    return KKMorphSnapshotSignature(a.geometrySnapshot) ==
           KKMorphSnapshotSignature(b.geometrySnapshot);
  NSArray<NSNumber *> *va = a.values, *vb = b.values;
  if (va.count != vb.count)
    return NO;
  for (NSUInteger i = 0; i < va.count; i++)
    if (fabs(va[i].doubleValue - vb[i].doubleValue) > 1.0e-4)
      return NO;
  return YES;
}

NSData *KKLaneGeometrySnapshotAtFraction(KKLane *lane, double frac) {
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  if (kps.count == 0)
    return nil;
  if (frac <= kps.firstObject.time)
    return kps.firstObject.geometrySnapshot;
  if (frac >= kps.lastObject.time)
    return kps.lastObject.geometrySnapshot;
  for (NSUInteger i = 0; i + 1 < kps.count; i++) {
    KKKeyPose *a = kps[i], *b = kps[i + 1];
    if (frac < a.time || frac > b.time)
      continue;
    NSData *sa = a.geometrySnapshot, *sb = b.geometrySnapshot;
    if (!sa || !sb)
      return sa ?: sb; // partial / un-snapshotted: fall back to the base shape
    double span = b.time - a.time;
    double t = span > 1e-9 ? (frac - a.time) / span : 0.0;
    double e = a.outgoing
                   ? KKApplyEasing(t, (KKEasingCurve)a.outgoing.curve,
                                   a.outgoing.intensity, a.outgoing.frequency)
                   : t;
    KKBezierPath *p = [[KKBezierPath alloc] init];
    KKMorphInterpolateApply(sa, sb, (float)e, p);
    return KKMorphSnapshotCapture(p);
  }
  return nil;
}

// ---------------------------------------------------------------------------
// KKInterval
// ---------------------------------------------------------------------------

@implementation KKInterval

- (instancetype)init {
  self = [super init];
  if (self) {
    _curve = KKIntervalCurveEaseInOut;
    // Midpoint defaults (the documented neutral per KKEasing.h) - not max, so a
    // freshly-picked easing / hold effect starts gentle and is dialed UP,
    // rather than maxed out and needing to be dialed down. Saved animations are
    // unaffected: the JSON always carries explicit values that override these.
    _intensity = 0.5;
    _frequency = 0.5;
    _modulation = KKIntervalModulationNone;
    _modulationIntensity = 0.5;
    _modulationFrequency = 0.5;
    _modulationLinked = YES;
    // Default unlinked: an interval freshly created in Advanced (new keypose /
    // property) starts unlinked. Basic explicitly links its Hold pair when it
    // builds the hold (see KKTimelineBasicView+Model `_rebuiltLane`).
    _endpointsLinked = NO;
  }
  return self;
}

- (id)copyWithZone:(NSZone *)zone {
  KKInterval *c = [[[self class] allocWithZone:zone] init];
  c.curve = _curve;
  c.intensity = _intensity;
  c.frequency = _frequency;
  c.modulation = _modulation;
  c.modulationIntensity = _modulationIntensity;
  c.modulationFrequency = _modulationFrequency;
  c.modulationSeed = _modulationSeed;
  c.modulationLinked = _modulationLinked;
  c.modulationComponents = [_modulationComponents copy];
  c.lockedSeconds = _lockedSeconds;
  c.endpointsLinked = _endpointsLinked;
  c.holdsFlat = _holdsFlat;
  c.pathData = _pathData;
  c.userProperties = [_userProperties copy];
  return c;
}

- (BOOL)userBoolForKey:(NSString *)key default:(BOOL)def {
  id v = _userProperties[key];
  return [v isKindOfClass:[NSNumber class]] ? [v boolValue] : def;
}

- (void)setUserBool:(BOOL)value forKey:(NSString *)key {
  [self setUserValue:@(value) forKey:key];
}

- (double)userDoubleForKey:(NSString *)key default:(double)def {
  id v = _userProperties[key];
  return [v isKindOfClass:[NSNumber class]] ? [v doubleValue] : def;
}

- (void)setUserDouble:(double)value forKey:(NSString *)key {
  [self setUserValue:@(value) forKey:key];
}

- (id)userValueForKey:(NSString *)key {
  return _userProperties[key];
}

- (void)setUserValue:(id)value forKey:(NSString *)key {
  NSMutableDictionary *m = _userProperties ? [_userProperties mutableCopy]
                                           : [NSMutableDictionary dictionary];
  if (value)
    m[key] = value;
  else
    [m removeObjectForKey:key];
  _userProperties = m.count ? [m copy] : nil;
}

- (NSDictionary *)toDictionary {
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  d[@"curve"] = @(_curve);
  d[@"intensity"] = @(_intensity);
  d[@"frequency"] = @(_frequency);
  d[@"modulation"] = @(_modulation);
  d[@"modulation_intensity"] = @(_modulationIntensity);
  d[@"modulation_frequency"] = @(_modulationFrequency);
  d[@"modulation_seed"] = @(_modulationSeed);
  d[@"modulation_linked"] = @(_modulationLinked);
  if (_modulationComponents) {
    NSMutableArray<NSNumber *> *idx =
        [NSMutableArray arrayWithCapacity:_modulationComponents.count];
    [_modulationComponents
        enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
          [idx addObject:@(i)];
        }];
    d[@"modulation_components"] = idx;
  }
  d[@"locked_seconds"] = @(_lockedSeconds);
  d[@"endpoints_linked"] = @(_endpointsLinked);
  if (_holdsFlat)
    d[@"holds_flat"] = @(_holdsFlat);
  if (_pathData) {
    d[@"path_data"] = [_pathData base64EncodedStringWithOptions:0];
  }
  if (_userProperties.count)
    d[@"user_properties"] = _userProperties;
  return d;
}

+ (nullable instancetype)fromDictionary:(NSDictionary *)d {
  if (![d isKindOfClass:[NSDictionary class]])
    return nil;
  KKInterval *i = [[KKInterval alloc] init];
  if (d[@"curve"])
    i.curve = [d[@"curve"] integerValue];
  if (d[@"intensity"])
    i.intensity = [d[@"intensity"] doubleValue];
  if (d[@"frequency"])
    i.frequency = [d[@"frequency"] doubleValue];
  if (d[@"modulation"])
    i.modulation = [d[@"modulation"] integerValue];
  if (d[@"modulation_intensity"])
    i.modulationIntensity = [d[@"modulation_intensity"] doubleValue];
  if (d[@"modulation_frequency"])
    i.modulationFrequency = [d[@"modulation_frequency"] doubleValue];
  if (d[@"modulation_seed"])
    i.modulationSeed = [d[@"modulation_seed"] unsignedIntValue];
  if (d[@"modulation_linked"])
    i.modulationLinked = [d[@"modulation_linked"] boolValue];
  if ([d[@"modulation_components"] isKindOfClass:[NSArray class]]) {
    NSMutableIndexSet *set = [NSMutableIndexSet indexSet];
    for (NSNumber *n in d[@"modulation_components"])
      if ([n isKindOfClass:[NSNumber class]])
        [set addIndex:n.unsignedIntegerValue];
    i.modulationComponents = set;
  }
  if (d[@"locked_seconds"])
    i.lockedSeconds = [d[@"locked_seconds"] doubleValue];
  if (d[@"endpoints_linked"])
    i.endpointsLinked = [d[@"endpoints_linked"] boolValue];
  if (d[@"holds_flat"])
    i.holdsFlat = [d[@"holds_flat"] boolValue];
  NSString *b64 = d[@"path_data"];
  if (b64)
    i.pathData = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
  id up = d[@"user_properties"];
  if ([up isKindOfClass:[NSDictionary class]])
    i.userProperties = up;
  return i;
}

@end

// ---------------------------------------------------------------------------
// KKKeyPose
// ---------------------------------------------------------------------------

@implementation KKKeyPose

+ (instancetype)keyposeAtTime:(double)time
                       values:(NSArray<NSNumber *> *)values {
  KKKeyPose *kp = [[KKKeyPose alloc] init];
  kp.time = time;
  kp.values = values;
  kp.outgoing = [[KKInterval alloc] init];
  return kp;
}

- (id)copyWithZone:(NSZone *)zone {
  KKKeyPose *c = [[[self class] allocWithZone:zone] init];
  c.time = _time;
  c.values = [_values copy];
  c.outgoing = [_outgoing copy];
  c.spatialSmooth = _spatialSmooth;
  c.inHandle = [_inHandle copy];
  c.outHandle = [_outHandle copy];
  c.geometrySnapshot = [_geometrySnapshot copy];
  return c;
}

- (instancetype)keyposeBySettingTime:(double)time {
  KKKeyPose *c = [self copy];
  c.time = time;
  return c;
}

- (instancetype)keyposeBySettingValues:(NSArray<NSNumber *> *)values {
  KKKeyPose *c = [self copy];
  c.values = values;
  return c;
}

- (NSDictionary *)toDictionary {
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  d[@"time"] = @(_time);
  d[@"values"] = _values;
  if (_outgoing)
    d[@"outgoing"] = [_outgoing toDictionary];
  // Only serialise spatial-curve fields when set, so legacy blobs (and
  // straight-line lanes) stay byte-identical.
  if (_spatialSmooth)
    d[@"spatial_smooth"] = @YES;
  if (_inHandle)
    d[@"in_handle"] = _inHandle;
  if (_outHandle)
    d[@"out_handle"] = _outHandle;
  if (_geometrySnapshot)
    d[@"geom_snapshot"] = [_geometrySnapshot base64EncodedStringWithOptions:0];
  return d;
}

+ (nullable instancetype)fromDictionary:(NSDictionary *)d {
  if (![d isKindOfClass:[NSDictionary class]])
    return nil;
  KKKeyPose *kp = [[KKKeyPose alloc] init];
  kp.time = [d[@"time"] doubleValue];
  kp.values = d[@"values"] ?: @[];
  NSDictionary *out = d[@"outgoing"];
  kp.outgoing = out ? [KKInterval fromDictionary:out] : nil;
  kp.spatialSmooth = [d[@"spatial_smooth"] boolValue];
  id ih = d[@"in_handle"];
  if ([ih isKindOfClass:[NSArray class]])
    kp.inHandle = ih;
  id oh = d[@"out_handle"];
  if ([oh isKindOfClass:[NSArray class]])
    kp.outHandle = oh;
  id gs = d[@"geom_snapshot"];
  if ([gs isKindOfClass:[NSString class]])
    kp.geometrySnapshot = [[NSData alloc] initWithBase64EncodedString:gs
                                                              options:0];
  return kp;
}

@end

// ---------------------------------------------------------------------------
// KKLane field descriptors
// ---------------------------------------------------------------------------

// How a serialized field maps into the timeline-JSON lane dictionary. The
// policies reproduce the historical hand-written toDictionary /
// fromDictionary EXACTLY - saved projects depend on the key set and the
// omit-if-default choices, so a new kind may be added but existing rows must
// not change meaning.
typedef NS_ENUM(NSUInteger, KKLaneFieldKind) {
  KKLaneFieldObject,       // copy-only field (object / block / scalar); kind is
                           // irrelevant unless the row is Serialized
  KKLaneFieldString,       // omit-if-nil NSString (read type-checked)
  KKLaneFieldArray,        // omit-if-nil NSArray (read type-checked)
  KKLaneFieldPairedArray,  // written iff the `paired` gate property is non-nil,
                           // as (value ?: @[]); read like Array
  KKLaneFieldBoolOmitNO,   // @YES written only when set; absent = NO
  KKLaneFieldBoolOmitYES,  // @NO written only when cleared; absent = YES
  KKLaneFieldBoolAlways,   // always written; absent (legacy data) = YES
  KKLaneFieldIntAlways,    // always written; left at init default when absent
  KKLaneFieldIntOmitZero,  // written only when != 0; only set when present
  KKLaneFieldDoubleAlways, // always written; absent = 0
  KKLaneFieldDoublePositive, // written only when > 0; absent = 0
};

typedef NS_OPTIONS(NSUInteger, KKLaneFieldRoles) {
  KKLaneFieldSerialized = 1 << 0, // participates in to/fromDictionary
  KKLaneFieldPickerMeta = 1 << 1, // carried by kkApplyPickerMetadataFrom
  // Template-defined build-time / static-config value that a persisted blob
  // must never override: kkApplyTemplateCanonicalFrom re-asserts these (plus
  // every PickerMeta row) from the plugin template after a blob load.
  KKLaneFieldTemplateCanonical = 1 << 2,
};

typedef struct {
  __unsafe_unretained NSString *prop;   // KVC property name (every row copies)
  __unsafe_unretained NSString *key;    // JSON key (Serialized rows only)
  __unsafe_unretained NSString *paired; // PairedArray rows: the gate property
  KKLaneFieldKind kind;
  KKLaneFieldRoles roles;
} KKLaneField;

_Static_assert(KKLaneHoldShapeAuto == 0,
               "hold_shape's IntOmitZero policy assumes Auto == 0");

// THE field list. Every KKLane property except laneID / keyposes /
// displayName (computed) has exactly one row here; -copyWithZone: transfers
// every row via KVC (the `copy` property setters supply the copy semantics),
// toDictionary/fromDictionary use the Serialized rows, and
// kkApplyPickerMetadataFrom applies the PickerMeta rows. The DEBUG
// completeness check in +initialize flags any property added to the class but
// missing here, so a new field can't be silently dropped from copies or the
// param round-trip again.
//
// PickerMeta notes carried from the hand-written list: slider-only bounds are
// display metadata (a rebuilt keypose/boundary lane without them falls back
// to the wide componentMin/Max range), and componentsScaleWithMedia +
// componentUnits must ride along or a normalised spatial lane shows raw
// fractions instead of pixels.
static const KKLaneField kKKLaneFields[] = {
    // label: serialized explicitly; template-canonical so a stale persisted
    // display name is re-asserted from the template on rebuild (renames
    // propagate; identity is `key`, never this).
    {@"label", nil, nil, KKLaneFieldObject, KKLaneFieldTemplateCanonical},
    {@"key", nil, nil, KKLaneFieldObject, 0}, // serialized explicitly
    {@"groupKey", @"group_key", nil, KKLaneFieldString, KKLaneFieldSerialized},
    {@"enabled", @"enabled", nil, KKLaneFieldBoolAlways, KKLaneFieldSerialized},
    {@"valueType", @"value_type", nil, KKLaneFieldIntAlways,
     KKLaneFieldSerialized | KKLaneFieldTemplateCanonical},
    {@"codeString", @"code_string", nil, KKLaneFieldString,
     KKLaneFieldSerialized},
    {@"codeSaveName", @"code_save_name", nil, KKLaneFieldString,
     KKLaneFieldSerialized},
    {@"codeTabs", @"code_tabs", nil, KKLaneFieldArray, KKLaneFieldSerialized},
    {@"codeTabCatalog", nil, nil, KKLaneFieldObject,
     KKLaneFieldTemplateCanonical}, // static config
    {@"codeValidator", nil, nil, KKLaneFieldObject,
     KKLaneFieldTemplateCanonical}, // block
    {@"codeValidationComposer", nil, nil, KKLaneFieldObject,
     KKLaneFieldTemplateCanonical}, // block
    {@"codeFormatter", nil, nil, KKLaneFieldObject,
     KKLaneFieldTemplateCanonical}, // block
    {@"codeCompletionProvider", nil, nil, KKLaneFieldObject,
     KKLaneFieldTemplateCanonical}, // block
    {@"codeDirectiveKeywords", nil, nil, KKLaneFieldObject,
     KKLaneFieldTemplateCanonical},
    {@"codeDirectiveKinds", nil, nil, KKLaneFieldObject,
     KKLaneFieldTemplateCanonical},
    {@"codeSavable", nil, nil, KKLaneFieldObject, KKLaneFieldTemplateCanonical},
    {@"codeHidesTitle", nil, nil, KKLaneFieldObject,
     KKLaneFieldTemplateCanonical},
    {@"codeSaveCategories", nil, nil, KKLaneFieldObject,
     KKLaneFieldTemplateCanonical},
    {@"codeSaveNamePlaceholder", nil, nil, KKLaneFieldObject,
     KKLaneFieldTemplateCanonical},
    {@"componentMin", @"component_min", nil, KKLaneFieldArray,
     KKLaneFieldSerialized | KKLaneFieldTemplateCanonical},
    {@"componentMax", @"component_max", nil, KKLaneFieldArray,
     KKLaneFieldSerialized | KKLaneFieldTemplateCanonical},
    {@"sliderMax", nil, nil, KKLaneFieldObject, KKLaneFieldPickerMeta},
    {@"sliderMin", nil, nil, KKLaneFieldObject, KKLaneFieldPickerMeta},
    {@"componentUnits", @"component_units", nil, KKLaneFieldArray,
     KKLaneFieldSerialized | KKLaneFieldPickerMeta},
    {@"componentLabels", @"component_labels", nil, KKLaneFieldArray,
     KKLaneFieldSerialized | KKLaneFieldTemplateCanonical},
    {@"componentLabelColors", nil, nil, KKLaneFieldObject,
     KKLaneFieldTemplateCanonical},
    {@"lastKnownClipDuration", @"last_known_clip_duration", nil,
     KKLaneFieldDoubleAlways, KKLaneFieldSerialized},
    {@"holdShape", @"hold_shape", nil, KKLaneFieldIntOmitZero,
     KKLaneFieldSerialized},
    {@"spatialCurvable", @"spatial_curvable", nil, KKLaneFieldBoolOmitNO,
     KKLaneFieldSerialized | KKLaneFieldTemplateCanonical},
    {@"aspectLinkable", @"aspect_linkable", nil, KKLaneFieldBoolOmitNO,
     KKLaneFieldSerialized | KKLaneFieldTemplateCanonical},
    {@"aspectLinked", @"aspect_linked", nil, KKLaneFieldBoolOmitNO,
     KKLaneFieldSerialized},
    {@"integerValued", @"integer_valued", nil, KKLaneFieldBoolOmitNO,
     KKLaneFieldSerialized | KKLaneFieldTemplateCanonical},
    {@"scrubStep", @"scrub_step", nil, KKLaneFieldDoublePositive,
     KKLaneFieldSerialized | KKLaneFieldPickerMeta},
    {@"componentsScaleWithMedia", @"components_scale_with_media", nil,
     KKLaneFieldBoolOmitNO, KKLaneFieldSerialized | KKLaneFieldPickerMeta},
    {@"categoryKey", @"category_key", nil, KKLaneFieldString,
     KKLaneFieldSerialized | KKLaneFieldPickerMeta},
    {@"categorySymbol", @"category_symbol", nil, KKLaneFieldString,
     KKLaneFieldSerialized | KKLaneFieldPickerMeta},
    {@"layerKey", @"layer_key", nil, KKLaneFieldString, KKLaneFieldSerialized},
    {@"layerLabel", @"layer_label", nil, KKLaneFieldString,
     KKLaneFieldSerialized},
    {@"layerSymbol", @"layer_symbol", nil, KKLaneFieldString,
     KKLaneFieldSerialized},
    {@"locked", nil, nil, KKLaneFieldObject, 0},
    {@"animatable", @"animatable", nil, KKLaneFieldBoolOmitYES,
     KKLaneFieldSerialized | KKLaneFieldPickerMeta},
    {@"seedField", @"seed_field", nil, KKLaneFieldBoolOmitNO,
     KKLaneFieldSerialized | KKLaneFieldPickerMeta},
    {@"oscEditedOnly", @"osc_edited_only", nil, KKLaneFieldBoolOmitNO,
     KKLaneFieldSerialized | KKLaneFieldPickerMeta},
    {@"positionPathDriven", nil, nil, KKLaneFieldObject, KKLaneFieldPickerMeta},
    {@"ownerScoped", @"owner_scoped", nil, KKLaneFieldBoolOmitNO,
     KKLaneFieldSerialized | KKLaneFieldPickerMeta},
    {@"choiceLabels", @"choice_labels", nil, KKLaneFieldArray,
     KKLaneFieldSerialized | KKLaneFieldPickerMeta},
    {@"choiceIcons", nil, nil, KKLaneFieldObject, KKLaneFieldPickerMeta},
    {@"choiceValues", nil, nil, KKLaneFieldObject, KKLaneFieldPickerMeta},
    {@"wrapsChoicePills", nil, nil, KKLaneFieldObject, KKLaneFieldPickerMeta},
    {@"choiceUsesDropdown", nil, nil, KKLaneFieldObject, KKLaneFieldPickerMeta},
    {@"choiceUnknownLabels", nil, nil, KKLaneFieldObject,
     KKLaneFieldPickerMeta},
    {@"choiceUnknownBadge", nil, nil, KKLaneFieldObject, KKLaneFieldPickerMeta},
    {@"isToggle", @"is_toggle", nil, KKLaneFieldBoolOmitNO,
     KKLaneFieldSerialized | KKLaneFieldPickerMeta},
    {@"autoSizesComponentLabels", @"autosize_component_labels", nil,
     KKLaneFieldBoolOmitNO, KKLaneFieldSerialized | KKLaneFieldPickerMeta},
    {@"visibleWhenKey", @"visible_when_key", nil, KKLaneFieldString,
     KKLaneFieldSerialized | KKLaneFieldPickerMeta},
    {@"visibleWhenValues", @"visible_when_values", @"visibleWhenKey",
     KKLaneFieldPairedArray, KKLaneFieldSerialized | KKLaneFieldPickerMeta},
    {@"visibleWhenOrKey", @"visible_when_or_key", nil, KKLaneFieldString,
     KKLaneFieldSerialized | KKLaneFieldPickerMeta},
    {@"visibleWhenOrValues", @"visible_when_or_values", @"visibleWhenOrKey",
     KKLaneFieldPairedArray, KKLaneFieldSerialized | KKLaneFieldPickerMeta},
    {@"visibleWhenAndKey", @"visible_when_and_key", nil, KKLaneFieldString,
     KKLaneFieldSerialized | KKLaneFieldPickerMeta},
    {@"visibleWhenAndValues", @"visible_when_and_values", @"visibleWhenAndKey",
     KKLaneFieldPairedArray, KKLaneFieldSerialized | KKLaneFieldPickerMeta},
    {@"maxControllerKey", @"max_controller_key", nil, KKLaneFieldString,
     KKLaneFieldSerialized | KKLaneFieldPickerMeta},
    {@"componentMaxByControllerValue", @"max_by_controller_value",
     @"maxControllerKey", KKLaneFieldPairedArray,
     KKLaneFieldSerialized | KKLaneFieldPickerMeta},
    {@"gradientShowsTypeAngle", @"gradient_type_angle", nil,
     KKLaneFieldBoolOmitNO, KKLaneFieldSerialized | KKLaneFieldPickerMeta},
    {@"paletteLockable", nil, nil, KKLaneFieldObject, KKLaneFieldPickerMeta},
    {@"paletteGeneratorBar", nil, nil, KKLaneFieldObject,
     KKLaneFieldPickerMeta},
    {@"paletteGroup", nil, nil, KKLaneFieldObject, KKLaneFieldPickerMeta},
    // Serialized even when EMPTY (present-but-empty passthrough), so a lane
    // whose editor the user cleared keeps it open across the param
    // round-trip; nil = truly no expression and is left out.
    {@"linkExpression", @"link_expr", nil, KKLaneFieldString,
     KKLaneFieldSerialized},
    {@"templateScopeMask", nil, nil, KKLaneFieldObject,
     KKLaneFieldTemplateCanonical},
    {@"templateSeedProvider", nil, nil, KKLaneFieldObject,
     KKLaneFieldTemplateCanonical}, // block
};
static const size_t kKKLaneFieldCount =
    sizeof(kKKLaneFields) / sizeof(kKKLaneFields[0]);

// ---------------------------------------------------------------------------
// KKLane
// ---------------------------------------------------------------------------

@interface KKLane ()
@property(nonatomic, readwrite) NSUUID *laneID;
@end

@implementation KKLane

- (instancetype)init {
  self = [super init];
  if (self)
    _animatable = YES; // default: every lane can be animated
  return self;
}

+ (instancetype)laneWithKey:(NSString *)key label:(NSString *)label {
  KKLane *l = [[KKLane alloc] init];
  l.laneID = [NSUUID UUID];
  l.key = key;
  l.label = label;
  l.enabled = YES;
  l.keyposes = @[];
  return l;
}

// The raw name to show (display sites still run it through
// KKLocalizedParamName). Identity stays on `key`.
- (NSString *)displayName {
  return _label;
}

+ (instancetype)opacityLane {
  // Standard FCP-style opacity: one whole-percentage component, 0..100 (no
  // overshoot), identity 100 = fully opaque. Shared by every plugin that has an
  // opacity property (the render multiplies premultiplied RGBA by value/100).
  // The owning plugin sets category / enabled etc. after as needed.
  KKLane *opacity = [self laneWithKey:@"Opacity" label:@"Opacity"];
  opacity.valueType = KKLaneValueTypeFloat;
  opacity.componentMin = @[ @0.0 ];
  opacity.componentMax = @[ @100.0 ];
  opacity.componentUnits = @[ @"%" ];
  opacity.integerValued = YES;
  [opacity insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @100.0 ]]];
  return opacity;
}

- (void)kkApplyPickerMetadataFrom:(KKLane *)tmpl {
  if (!tmpl)
    return;
  for (size_t i = 0; i < kKKLaneFieldCount; i++) {
    const KKLaneField *f = &kKKLaneFields[i];
    if (f->roles & KKLaneFieldPickerMeta)
      [self setValue:[tmpl valueForKey:f->prop] forKey:f->prop];
  }
}

- (void)kkApplyTemplateCanonicalFrom:(KKLane *)tmpl {
  if (!tmpl)
    return;
  for (size_t i = 0; i < kKKLaneFieldCount; i++) {
    const KKLaneField *f = &kKKLaneFields[i];
    if (f->roles & (KKLaneFieldTemplateCanonical | KKLaneFieldPickerMeta))
      [self setValue:[tmpl valueForKey:f->prop] forKey:f->prop];
  }
}

- (void)insertKeypose:(KKKeyPose *)keypose {
  NSMutableArray *kps = [_keyposes mutableCopy];
  NSUInteger idx = [kps
      indexOfObjectPassingTest:^BOOL(KKKeyPose *kp, NSUInteger i, BOOL *stop) {
        return kp.time > keypose.time;
      }];
  if (idx == NSNotFound) {
    [kps addObject:keypose];
  } else {
    [kps insertObject:keypose atIndex:idx];
  }
  self.keyposes = kps;
}

- (void)removeKeyposeAtIndex:(NSUInteger)index {
  NSMutableArray *kps = [_keyposes mutableCopy];
  [kps removeObjectAtIndex:index];
  self.keyposes = kps;
}

- (id)copyWithZone:(NSZone *)zone {
  KKLane *c = [[[self class] allocWithZone:zone] init];
  c.laneID = _laneID;
  // Every descriptor row transfers via KVC; the `copy` property setters
  // supply the copy semantics (blocks included), so this is a faithful
  // field-for-field copy of everything but the deep-copied keyposes.
  for (size_t i = 0; i < kKKLaneFieldCount; i++)
    [c setValue:[self valueForKey:kKKLaneFields[i].prop]
         forKey:kKKLaneFields[i].prop];
  c.keyposes = [[NSArray alloc] initWithArray:_keyposes copyItems:YES];
  return c;
}

- (NSDictionary *)toDictionary {
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  d[@"id"] = _laneID.UUIDString;
  d[@"label"] = _label;
  // Identity is first-class: always written. (Reading a legacy blob without
  // one seeds key = label - the single migration path.)
  d[@"key"] = _key.length ? _key : _label;
  d[@"keyposes"] = [_keyposes valueForKey:@"toDictionary"];
  for (size_t i = 0; i < kKKLaneFieldCount; i++) {
    const KKLaneField *f = &kKKLaneFields[i];
    if (!(f->roles & KKLaneFieldSerialized))
      continue;
    id v = [self valueForKey:f->prop];
    switch (f->kind) {
    case KKLaneFieldString:
    case KKLaneFieldArray:
      if (v)
        d[f->key] = v;
      break;
    case KKLaneFieldPairedArray:
      if ([self valueForKey:f->paired])
        d[f->key] = v ?: @[];
      break;
    case KKLaneFieldBoolOmitNO:
      if ([v boolValue])
        d[f->key] = @YES;
      break;
    case KKLaneFieldBoolOmitYES:
      if (![v boolValue])
        d[f->key] = @NO;
      break;
    case KKLaneFieldBoolAlways:
      d[f->key] = @([v boolValue]);
      break;
    case KKLaneFieldIntAlways:
      d[f->key] = @([v integerValue]);
      break;
    case KKLaneFieldIntOmitZero:
      if ([v integerValue] != 0)
        d[f->key] = @([v integerValue]);
      break;
    case KKLaneFieldDoubleAlways:
      d[f->key] = @([v doubleValue]);
      break;
    case KKLaneFieldDoublePositive:
      if ([v doubleValue] > 0)
        d[f->key] = @([v doubleValue]);
      break;
    case KKLaneFieldObject:
      break;
    }
  }
  return d;
}

+ (nullable instancetype)fromDictionary:(NSDictionary *)d {
  if (![d isKindOfClass:[NSDictionary class]])
    return nil;
  KKLane *l = [[KKLane alloc] init];
  NSString *uuidStr = d[@"id"];
  l.laneID =
      uuidStr ? [[NSUUID alloc] initWithUUIDString:uuidStr] : [NSUUID UUID];
  l.label = [d[@"label"] isKindOfClass:[NSString class]] ? d[@"label"] : @"";
  l.key = [d[@"key"] isKindOfClass:[NSString class]] ? d[@"key"] : l.label;
  for (size_t i = 0; i < kKKLaneFieldCount; i++) {
    const KKLaneField *f = &kKKLaneFields[i];
    if (!(f->roles & KKLaneFieldSerialized))
      continue;
    id raw = d[f->key];
    switch (f->kind) {
    case KKLaneFieldString:
      if ([raw isKindOfClass:[NSString class]])
        [l setValue:raw forKey:f->prop];
      break;
    case KKLaneFieldArray:
    case KKLaneFieldPairedArray:
      if ([raw isKindOfClass:[NSArray class]])
        [l setValue:raw forKey:f->prop];
      break;
    case KKLaneFieldBoolOmitNO:
      [l setValue:@([raw boolValue]) forKey:f->prop];
      break;
    case KKLaneFieldBoolOmitYES:
    case KKLaneFieldBoolAlways:
      [l setValue:@(raw ? [raw boolValue] : YES) forKey:f->prop];
      break;
    case KKLaneFieldIntAlways:
    case KKLaneFieldIntOmitZero:
      if (raw)
        [l setValue:@([raw integerValue]) forKey:f->prop];
      break;
    case KKLaneFieldDoubleAlways:
    case KKLaneFieldDoublePositive:
      [l setValue:@([raw doubleValue]) forKey:f->prop];
      break;
    case KKLaneFieldObject:
      break;
    }
  }
  NSArray *rawKps = d[@"keyposes"];
  if ([rawKps isKindOfClass:[NSArray class]]) {
    NSMutableArray *kps = [NSMutableArray arrayWithCapacity:rawKps.count];
    for (NSDictionary *kpd in rawKps) {
      KKKeyPose *kp = [KKKeyPose fromDictionary:kpd];
      if (kp)
        [kps addObject:kp];
    }
    l.keyposes = kps;
  } else {
    l.keyposes = @[];
  }
  return l;
}

#if DEBUG
// Completeness net: every property of KKLane must have a descriptor row (or
// be a listed exception), so a newly added field can't be silently dropped
// from copies / the param round-trip / picker metadata again.
+ (void)initialize {
  if (self != [KKLane class])
    return;
  NSMutableSet<NSString *> *covered =
      [NSMutableSet setWithObjects:@"laneID", @"keyposes", @"displayName", nil];
  for (size_t i = 0; i < kKKLaneFieldCount; i++)
    [covered addObject:kKKLaneFields[i].prop];
  unsigned n = 0;
  objc_property_t *props = class_copyPropertyList(self, &n);
  for (unsigned i = 0; i < n; i++) {
    NSString *name = @(property_getName(props[i]));
    if (![covered containsObject:name])
      KKLogError(@"KKLane property '%@' has no kKKLaneFields row - it will be "
                 @"DROPPED by copy/serialize/picker-metadata",
                 name);
  }
  free(props);
}
#endif

@end

// ---------------------------------------------------------------------------
// KKLaneGroup
// ---------------------------------------------------------------------------

@implementation KKLaneGroup

+ (instancetype)groupWithKey:(NSString *)key label:(NSString *)label {
  KKLaneGroup *g = [[KKLaneGroup alloc] init];
  g.key = key;
  g.label = label;
  return g;
}

- (id)copyWithZone:(NSZone *)zone {
  KKLaneGroup *c = [[[self class] allocWithZone:zone] init];
  c.key = [_key copy];
  c.label = [_label copy];
  return c;
}

- (NSDictionary *)toDictionary {
  return @{@"key" : _key, @"label" : _label};
}

+ (nullable instancetype)fromDictionary:(NSDictionary *)d {
  if (![d isKindOfClass:[NSDictionary class]])
    return nil;
  return [KKLaneGroup groupWithKey:d[@"key"] ?: @"" label:d[@"label"] ?: @""];
}

@end

// ---------------------------------------------------------------------------
// KKTimeline
// ---------------------------------------------------------------------------

@implementation KKTimeline

+ (instancetype)timeline {
  KKTimeline *t = [[KKTimeline alloc] init];
  t.lanes = @[];
  t.groups = @[];
  return t;
}

- (id)copyWithZone:(NSZone *)zone {
  KKTimeline *c = [[[self class] allocWithZone:zone] init];
  c.lanes = [[NSArray alloc] initWithArray:_lanes copyItems:YES];
  c.groups = [[NSArray alloc] initWithArray:_groups copyItems:YES];
  c.paramOrder = _paramOrder;
  return c;
}

@end

// ---------------------------------------------------------------------------
// KKTimelineRebalanced
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Serialization
// ---------------------------------------------------------------------------

const NSInteger kKKTimelineJSONVersion = 1;

/// One step of the load-time upgrade chain: rewrites a version-`from` root
/// dictionary into version-`from + 1` form. Every kKKTimelineJSONVersion bump
/// adds exactly one case; timelineFromJSON: applies the steps in sequence so
/// a blob of any shipped version reaches current shape before parsing.
static NSDictionary *KKTimelineUpgradeRootFromVersion(NSDictionary *root,
                                                      NSInteger from) {
  switch (from) {
  default:
    return root;
  }
}

@implementation KKTimeline (Serialization)

+ (nullable NSString *)jsonFromTimeline:(KKTimeline *)timeline {
  NSMutableArray *lanesArr =
      [NSMutableArray arrayWithCapacity:timeline.lanes.count];
  for (KKLane *lane in timeline.lanes) {
    [lanesArr addObject:[lane toDictionary]];
  }
  NSMutableArray *groupsArr =
      [NSMutableArray arrayWithCapacity:timeline.groups.count];
  for (KKLaneGroup *group in timeline.groups) {
    [groupsArr addObject:[group toDictionary]];
  }
  NSMutableDictionary *root = [@{
    @"version" : @(kKKTimelineJSONVersion),
    @"lanes" : lanesArr,
    @"groups" : groupsArr,
  } mutableCopy];
  if (timeline.paramOrder.count)
    root[@"paramOrder"] = timeline.paramOrder;
  NSError *err;
  NSData *data = [NSJSONSerialization dataWithJSONObject:root
                                                 options:0
                                                   error:&err];
  if (!data)
    return nil;
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

+ (nullable KKTimeline *)timelineFromJSON:(NSString *)json {
  NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
  if (!data)
    return nil;
  NSError *err;
  NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data
                                                       options:0
                                                         error:&err];
  if (![root isKindOfClass:[NSDictionary class]])
    return nil;

  // Blobs written before the stamp existed carry no version key; treat as v1.
  NSInteger version = [root[@"version"] isKindOfClass:[NSNumber class]]
                          ? [root[@"version"] integerValue]
                          : 1;
  if (version > kKKTimelineJSONVersion) {
    KKLogWarn(@"Timeline blob version %ld is newer than this build's %ld; "
              @"parsing best-effort",
              (long)version, (long)kKKTimelineJSONVersion);
  }
  for (NSInteger v = version; v < kKKTimelineJSONVersion; v++)
    root = KKTimelineUpgradeRootFromVersion(root, v);

  KKTimeline *timeline = [KKTimeline timeline];

  NSArray *lanesArr = root[@"lanes"];
  if ([lanesArr isKindOfClass:[NSArray class]]) {
    NSMutableArray *lanes = [NSMutableArray arrayWithCapacity:lanesArr.count];
    for (NSDictionary *d in lanesArr) {
      KKLane *lane = [KKLane fromDictionary:d];
      if (lane)
        [lanes addObject:lane];
    }
    timeline.lanes = lanes;
  }

  NSArray *groupsArr = root[@"groups"];
  if ([groupsArr isKindOfClass:[NSArray class]]) {
    NSMutableArray *groups = [NSMutableArray arrayWithCapacity:groupsArr.count];
    for (NSDictionary *d in groupsArr) {
      KKLaneGroup *group = [KKLaneGroup fromDictionary:d];
      if (group)
        [groups addObject:group];
    }
    timeline.groups = groups;
  }

  NSArray *orderArr = root[@"paramOrder"];
  if ([orderArr isKindOfClass:[NSArray class]]) {
    NSMutableArray<NSString *> *order =
        [NSMutableArray arrayWithCapacity:orderArr.count];
    for (id label in orderArr)
      if ([label isKindOfClass:[NSString class]])
        [order addObject:label];
    timeline.paramOrder = order;
  }

  return timeline;
}

@end
