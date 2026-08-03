/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// The Mirage generator's lane catalog (Type pill + shared Core lanes + every
// Type's Mirage lanes + the colour swatches). Extracted from Plugin+CustomUI.m
// (which just returns MirageBuildAvailableLanes()). One function, cohesive.
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKEasing.h> // the Easing lane's curve set + names
#import <KeyframelessKit/KKSlotInstances.h>
#import <KeyframelessKit/KKSonarTicket.h>
#import <KeyframelessKit/KKSpectrogram.h>
#import <KeyframelessKit/KKTimeline.h>

#import "Constants.h"        // MirageCustomDefaultShaderSource
#import "KKGLSLFormatter.h"  // Format button (XPC-only includers)
#import "KKGLSLTranspiler.h" // live shader validation (XPC-only includers)
#import "MirageCategory.h"   // source-derived template classification
#import "MirageDirectiveCatalog.h" // directive + GLSL autocomplete
#import "MirageDirectiveVocab.h" // MirageDirectiveValueKeywords (highlight set)
#import "MirageDirectives.h"
#import "MirageLocalized.h"       // RLoc
#import "MirageRack.h"            // rack entries: ids, keys, display names
#import "MirageSchemaDoc.h"       // Copy Schema clipboard document
#import "MirageSlotBudget.h"      // `#slots` pool budget at max instances
#import "MirageSlotLanes.h"       // `#slots` prototype -> instance stamping
#import "MirageSurfaceResponse.h" // `#color-surface` ring validation
#import "Plugin.h" // MiragePlugin, for the bundle the schema markdown ships in

// --- Dynamic colour lanes ------------------------------------------------
// A shader declares colour properties by annotating standalone uniforms:
//     // #color                            uniform vec4 uBackground;
//     // #color label="Accent"             uniform vec4 uForeground;
//     // #color min=1 max=10 default=4      uniform vec4 uPalette[10];
// Each single-vec4 property is one colour lane; each array is a palette bar + a
// "<Label> Count" lane + "<Label> N" swatches. The kit palette machinery drives
// the arrays via paletteGeneratorBar / paletteLockable.

// NSNumbers n..maxCount, for a "<Label> Count >= n" visibility gate.
static inline NSArray<NSNumber *> *MirageCountAtLeast(NSInteger n,
                                                      NSInteger maxCount) {
  NSMutableArray<NSNumber *> *out = [NSMutableArray array];
  for (NSInteger c = n; c <= maxCount; c++)
    [out addObject:@(c)];
  return out;
}

static inline KKLane *MirageMakeColorLane(NSString *idLabel,
                                          NSString *displayLabel,
                                          NSString *group, const float *rgba) {
  KKLane *color = [KKLane laneWithKey:idLabel label:displayLabel];
  color.valueType = KKLaneValueTypeColor;
  color.componentMin = @[ @0.0, @0.0, @0.0, @0.0 ];
  color.componentMax = @[ @1.0, @1.0, @1.0, @1.0 ];
  color.animatable = YES;
  color.enabled = NO;
  color.paletteLockable = YES; // every colour joins the palette generator
  color.paletteGroup = group;  // ...but each property rerolls independently
  // Keypose-popover scope: a single colour is its own group; an array's
  // swatches share the array's group (so they co-edit), keeping unrelated
  // shader lanes out of each other's keypose popover.
  color.groupKey = group;
  color.categoryKey = kMirageColorCategory;
  color.categorySymbol = @"paintpalette";
  [color insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                         values:@[
                                           @(rgba[0]), @(rgba[1]), @(rgba[2]),
                                           @(rgba[3])
                                         ]]];
  return color;
}

// Put one colour lane in the group its directive named, or leave it in the
// shared Colours group when it named none. Applied to every lane a `#color`
// produces - the count lane and each swatch as well as a single colour - so a
// grouped array arrives whole rather than scattered across two groups.
static inline void MirageApplyColorGroup(KKLane *lane,
                                         const MirageColorProp *p) {
  NSString *grp = @(p->group);
  if (!grp.length)
    return; // the Colours group the lane was born in
  lane.categoryKey = grp;
  if (p->groupSymbol[0])
    lane.categorySymbol = @(p->groupSymbol);
}

// Append one lane group per `// #color` property the shader declares, under a
// single shared palette-generator bar (rerolls EVERY colour lane - both arrays'
// swatches and the single colours - since all are paletteLockable).
static inline void MirageAppendColorLanes(NSMutableArray<KKLane *> *lanes,
                                          NSString *source) {
  const float (*pal)[4] = kMirageDefaultPalette;
  const NSInteger kSliderCap =
      10; // slider tops out here; the field goes higher
  MirageShaderModel *model = [MirageShaderModel modelForSource:source];
  const MirageColorProp *props = model.colorProps;
  int nProps = model.colorCount;
  if (nProps == 0)
    return;
  // One palette-generator bar for the whole Colours group.
  KKLane *bar = [KKLane laneWithKey:@"Palette" label:@"Palette"];
  bar.paletteGeneratorBar = YES;
  bar.animatable = NO;
  bar.enabled = NO;
  bar.categoryKey = kMirageColorCategory;
  bar.categorySymbol = @"paintpalette";
  [lanes addObject:bar];

  for (int pi = 0; pi < nProps; pi++) {
    const MirageColorProp *p = &props[pi];
    // Identity = the uniform name (+ " N"/" Count" for arrays); display = the
    // label. The palette group is the uniform name so it stays stable too.
    NSString *name = @(p->name);
    NSString *label = @(p->label);
    if (!p->isArray) {
      // A single named colour - its own one-colour journey, distinct hue. The
      // author's `default="#hex"` wins over the built-in palette (and is what
      // Reset reverts to).
      const float *seed = p->hasDefColors ? p->defColors[0] : pal[pi % 10];
      KKLane *single = MirageMakeColorLane(name, label, name, seed);
      MirageApplyColorGroup(single, p);
      [lanes addObject:single];
      continue;
    }

    // `optionsby=<multiple choice>` turns a colour array into one stable
    // swatch per option. There is no count lane: option N always maps to array
    // slot N, while visibility follows that option's bit.
    const MirageScalarProp *optionsController = NULL;
    NSMutableArray<NSString *> *optionLabels = nil;
    if (p->optionsByName[0]) {
      const MirageScalarProp *scalarProps = model.scalarProps;
      for (int si = 0; si < model.scalarCount; si++)
        if (strcmp(scalarProps[si].name, p->optionsByName) == 0) {
          optionsController = &scalarProps[si];
          break;
        }
      if (optionsController) {
        optionLabels = [NSMutableArray array];
        for (NSString *option in
             [@(optionsController->options) componentsSeparatedByString:@","]) {
          NSString *trimmed = [option
              stringByTrimmingCharactersInSet:NSCharacterSet
                                                  .whitespaceCharacterSet];
          if (trimmed.length)
            [optionLabels addObject:trimmed];
        }
      }
    }

    BOOL optionsMapped = optionsController && optionsController->choiceMultiple;
    if (optionsMapped) {
      for (int i = 0; i < p->count && i < (int)optionLabels.count; i++) {
        const float *seed = (p->hasDefColors && i < p->defColorCount)
                                ? p->defColors[i]
                                : pal[i % 10];
        NSString *optionLabel = optionLabels[i];
        KKLane *color = MirageMakeColorLane(
            [NSString stringWithFormat:@"%@ %d", name, i + 1],
            [NSString stringWithFormat:@"%@ Colour", optionLabel], name, seed);
        color.visibleWhenKey = @(p->optionsByName);
        color.visibleWhenBitMask = (NSInteger)1 << i;
        MirageApplyColorGroup(color, p);
        [lanes addObject:color];
      }
      continue;
    }

    // A regular array: count lane + N swatches.
    NSString *countId = [NSString stringWithFormat:@"%@ Count", name];
    KKLane *count =
        [KKLane laneWithKey:countId
                      label:[NSString stringWithFormat:@"%@ Count", label]];
    count.animatable = NO;
    count.enabled = NO;
    count.integerValued = YES;
    count.scrubStep = 1.0;
    count.componentMin = @[ @(p->minCount) ];
    count.componentMax = @[ @(p->maxCount) ]; // field up to the directive max
    count.sliderMax = @(MIN((NSInteger)p->maxCount, kSliderCap));
    count.groupKey = name; // joins its array's keypose-popover group
    count.categoryKey = kMirageColorCategory;
    count.categorySymbol = @"paintpalette";
    MirageApplyColorGroup(count, p);
    [count insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                           values:@[ @(p->defaultCount) ]]];
    [lanes addObject:count];

    for (int i = 0; i < p->maxCount; i++) {
      NSInteger n = i + 1;
      // Author's `default="#hex,..."` swatch wins over the built-in palette for
      // the swatches it covers (and is what Reset reverts to).
      const float *seed = (p->hasDefColors && i < p->defColorCount)
                              ? p->defColors[i]
                              : pal[i % 10];
      KKLane *color = MirageMakeColorLane(
          [NSString stringWithFormat:@"%@ %ld", name, (long)n],
          [NSString stringWithFormat:@"%@ %ld", label, (long)n], name, seed);
      // "count >= n" via the absolute ceiling, so a swatch still reveals when
      // the stored count is transiently above a just-lowered max.
      color.visibleWhenKey = countId;
      color.visibleWhenValues = MirageCountAtLeast(n, KK_SHADER_MAX_COLORS);
      MirageApplyColorGroup(color, p);
      [lanes addObject:color];
    }
  }
}

// Append the shader's `// #float` (slider) and `// #choice` (int pill) props as
// lanes in their own "Mirage" params group (distinct from Core and Colours). A
// float lane is an animatable slider bounded by min/max; a choice lane is a
// structural (non-animatable, integer) radio pill from options=. Value flows to
// the shader via the pool tail (the model scalar fill), same as colours.
/// The standard 3D-axis inspector tint (matching KKRotationLaneWithLabel /
/// Motion / Blender): X=red, Y=green, Z=blue. Used so a rotate OSC lane's dials
/// and its KKRotationOSC rings agree.
static inline NSColor *MirageRotationAxisColor(char axis) {
  switch (axis) {
  case 'x':
    return [NSColor colorWithSRGBRed:0.95 green:0.35 blue:0.35 alpha:1.0];
  case 'y':
    return [NSColor colorWithSRGBRed:0.40 green:0.85 blue:0.45 alpha:1.0];
  default:
    return [NSColor colorWithSRGBRed:0.40 green:0.60 blue:0.95 alpha:1.0];
  }
}

static inline void MirageConfigureRotateLane(KKLane *lane,
                                             const MirageScalarProp *p,
                                             const MirageOSCBlock *blk) {
  // A rotation OSC lane: one euler-angle (degrees) component per active
  // axis, in CANONICAL X<Y<Z order (KKRotationOSC's contract - the gizmo
  // maps enabledAxes bits to components in that order). The braced order
  // (which axis drives which shader vec component) is applied later by the
  // transpiler swizzle, not here. Circular + unconstrained (accumulates
  // past 360), tinted red/green/blue by axis so the inspector dials and the
  // KKRotationOSC rings agree. A single-axis `#angle` gets one dial; a
  // vec2/vec3 `#multi` gets N. `default=` (parsed in braced order) is
  // permuted back to canonical order.
  lane.valueType = KKLaneValueTypeAngle;
  lane.animatable = YES;
  // NOT integer-valued: a ring drag lands on a fraction nearly every time, so
  // the field shows 2 decimals rather than rounding away what the control
  // produced. Scrubbing still steps 1 degree - that comes from the Angle value
  // type, not from this flag.
  lane.integerValued = NO;
  lane.componentMin = @[];
  lane.componentMax = @[];
  NSMutableArray<NSString *> *labels = [NSMutableArray array];
  NSMutableArray<NSString *> *units = [NSMutableArray array];
  NSMutableArray<NSColor *> *colors = [NSMutableArray array];
  NSMutableArray<NSNumber *> *defs = [NSMutableArray array];
  const char *canon = "xyz";
  for (int a = 0; a < 3; a++) {
    char axis = canon[a];
    // The braced-order slot this canonical axis occupies (its shader
    // component), or -1 if the axis isn't part of this control.
    char axes[3];
    int nAxes = MirageOSCBlockAxes(blk, axes);
    int slot = -1;
    for (int k = 0; k < nAxes; k++)
      if (axes[k] == axis) {
        slot = k;
        break;
      }
    if (slot < 0)
      continue;
    [labels addObject:[NSString stringWithFormat:@"%c", (char)toupper(axis)]];
    [units addObject:@"°"];
    [colors addObject:MirageRotationAxisColor(axis)];
    [defs addObject:@(p->isMulti ? p->mdef[slot] : p->fdefault)];
  }
  lane.componentLabels = labels;
  lane.componentUnits = units;
  lane.componentLabelColors = colors;
  lane.autoSizesComponentLabels = YES;
  [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:defs]];
}

// The authored `units=` spellings for a control's first `n` components, or nil
// when it declared none. Free-form: `px` and `%` arrive here already normalised
// (and carry their own semantics), everything else is the author's own word and
// shows as a suffix on the value field, nothing more.
static inline NSArray<NSString *> *
MirageScalarUnitLabels(const MirageScalarProp *p, int n) {
  NSMutableArray<NSString *> *units = [NSMutableArray array];
  BOOL any = NO;
  for (int k = 0; k < n && k < 4; k++) {
    NSString *u = p->fieldUnitLabel[k][0] ? @(p->fieldUnitLabel[k]) : nil;
    [units addObject:u ?: @""];
    if (u.length)
      any = YES;
  }
  return any ? units : nil;
}

static inline void MirageAppendScalarLanes(NSMutableArray<KKLane *> *lanes,
                                           NSString *source) {
  MirageShaderModel *model = [MirageShaderModel modelForSource:source];
  const MirageScalarProp *props = model.scalarProps;
  int nProps = model.scalarCount;
  for (int pi = 0; pi < nProps; pi++) {
    const MirageScalarProp *p = &props[pi];
    // Identity = the GLSL uniform name (stable across rename/reorder); the
    // label is display-only. So the value/keyframes follow the uniform, not the
    // label.
    KKLane *lane = [KKLane laneWithKey:@(p->name) label:@(p->label)];
    lane.valueType = KKLaneValueTypeFloat;
    lane.enabled = NO;
    // Each scalar/point is independent: its own keypose-popover group, so a
    // point OSC's keypose popover doesn't list every other shader uniform.
    lane.groupKey = @(p->name);
    // The group is the shader's to name (`group={"Glow", "sparkles"}`), falling
    // back to the shared default. Groups are discovered first-seen from the
    // lane list, so declaration order in the source is inspector order. An
    // empty name carrying a symbol counts as unset: a bespoke icon on the
    // default group would dress it up as a declared one.
    NSString *grp = @(p->group);
    lane.categoryKey = grp.length ? grp : kMirageDefaultGroup;
    lane.categorySymbol = (grp.length && p->groupSymbol[0])
                              ? @(p->groupSymbol)
                              : kMirageDefaultGroupSymbol;
    if (p->visibleByName[0] && p->visibleByValueCount > 0) {
      lane.visibleWhenKey = @(p->visibleByName);
      NSMutableArray<NSNumber *> *visibleValues =
          [NSMutableArray arrayWithCapacity:p->visibleByValueCount];
      for (int i = 0; i < p->visibleByValueCount; i++)
        [visibleValues addObject:@(p->visibleByValues[i])];
      lane.visibleWhenValues = visibleValues;
    }
    switch (p->kind) {
    case MirageScalarKindChoice: {
      lane.integerValued = YES;
      lane.animatable = NO; // structural enum
      NSMutableArray<NSString *> *opts = [NSMutableArray array];
      for (NSString *o in [@(p->options) componentsSeparatedByString:@","]) {
        NSString *t =
            [o stringByTrimmingCharactersInSet:NSCharacterSet
                                                   .whitespaceCharacterSet];
        if (t.length)
          [opts addObject:t];
      }
      lane.choiceLabels = opts;
      lane.choiceUsesDropdown =
          p->choiceDropdown != 0 || p->choiceMultiple != 0;
      lane.choiceAllowsMultiple = p->choiceMultiple != 0;
      lane.componentMin = @[ @0.0 ];
      NSInteger maxValue =
          p->choiceMultiple
              ? (opts.count >= KK_SHADER_MAX_MULTIPLE_CHOICE_OPTIONS
                     ? 0x00FFFFFF
                     : (opts.count ? (1 << opts.count) - 1 : 0))
              : (opts.count ? (NSInteger)opts.count - 1 : 0);
      lane.componentMax = @[ @(maxValue) ];
      [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                            values:@[ @(p->cdefault) ]]];
      break;
    }
    case MirageScalarKindRandom: {
      lane.seedField = YES; // dice reroll
      lane.integerValued = YES;
      lane.animatable = NO; // structural like the core Seed
      lane.scrubStep = 1.0;
      lane.componentMin = @[ @(p->fmin) ];
      lane.componentMax = @[ @(p->fmax) ];
      [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                            values:@[ @(p->fdefault) ]]];
      break;
    }
    case MirageScalarKindPoint: {
      lane.animatable = YES;
      // A `osc=position` point is driven by its on-screen editable path, so it
      // isn't expression-referenceable (a link expression would fight the
      // drawn path). A bare `#point` (no osc) or `osc=point` stays
      // expression-eligible.
      lane.positionPathDriven = MirageOSCBlockPrimitiveIs(
          [model oscBlockForUniform:p->name], "position");
      // Allowed off-scene (negative / past full res), so no min/max - empty =
      // unconstrained.
      lane.componentMin = @[];
      lane.componentMax = @[];
      lane.componentUnits = @[ @"px", @"px" ];
      lane.componentLabels = @[ @"X", @"Y" ];
      // Stored normalized 0..1, displayed as pixels (X * media width, Y * media
      // height).
      lane.componentsScaleWithMedia = YES;
      [lane insertKeypose:[KKKeyPose
                              keyposeAtTime:0.0
                                     values:@[ @(p->pdefx), @(p->pdefy) ]]];
      break;
    }
    case MirageScalarKindBool: {
      lane.isToggle = YES;
      lane.integerValued = YES;
      lane.animatable = NO; // structural on/off
      lane.componentMin = @[ @0.0 ];
      lane.componentMax = @[ @1.0 ];
      [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                            values:@[ @(p->fdefault) ]]];
      break;
    }
    case MirageScalarKindAngle: {
      if (MirageOSCBlockIsRotate([model oscBlockForUniform:p->name])) {
        MirageConfigureRotateLane(lane, p, [model oscBlockForUniform:p->name]);
        break;
      }

      lane.valueType = KKLaneValueTypeAngle; // circular knob, whole degrees
      lane.animatable = YES;
      lane.integerValued = NO; // degrees show 2 decimals, as a drag produces
      // Unconstrained (accumulates past 360).
      lane.componentMin = @[];
      lane.componentMax = @[];
      // An authored `units=` shows only where the lane isn't already labelled:
      // a rotate OSC's dials come out of MirageConfigureRotateLane with their
      // own per-axis "°", and a redundant `units="°"` beside one must not turn
      // that into "°°".
      if (!lane.componentUnits.count) {
        NSArray<NSString *> *labels = MirageScalarUnitLabels(p, 1);
        if (labels)
          lane.componentUnits = labels;
      }
      [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                            values:@[ @(p->fdefault) ]]];
      break;
    }
    case MirageScalarKindMulti: {
      if (MirageOSCBlockIsRotate([model oscBlockForUniform:p->name])) {
        MirageConfigureRotateLane(lane, p, [model oscBlockForUniform:p->name]);
        break;
      }
      // An N-component numeric field (vec2/vec3): one lane, `fields={}` names
      // the components, `linked` makes them aspect-linkable. Unbounded unless
      // max=.
      lane.animatable = YES;
      NSMutableArray<NSString *> *fieldLabels = [NSMutableArray array];
      for (NSString *f in
           [@(p->fieldLabels) componentsSeparatedByString:@","]) {
        NSString *t =
            [f stringByTrimmingCharactersInSet:NSCharacterSet
                                                   .whitespaceCharacterSet];
        if (t.length)
          [fieldLabels addObject:t];
      }
      int n = p->fieldCount > 0 ? p->fieldCount : (int)fieldLabels.count;
      if (n < 1)
        n = 2;
      while ((int)fieldLabels.count < n)
        [fieldLabels
            addObject:[NSString
                          stringWithFormat:@"%d", (int)fieldLabels.count + 1]];
      lane.componentLabels = [fieldLabels subarrayWithRange:NSMakeRange(0, n)];
      NSMutableArray<NSNumber *> *mins = [NSMutableArray array];
      NSMutableArray<NSNumber *> *maxs = [NSMutableArray array];
      NSMutableArray<NSNumber *> *defs = [NSMutableArray array];
      for (int k = 0; k < n; k++) {
        // Per-component bounds (min={}/max={}); an unbounded component uses the
        // wide sentinel so the field accepts off-scene values.
        [mins addObject:p->mhasMin[k] ? @(p->mmin[k]) : @(-1000000.0)];
        [maxs addObject:p->mhasMax[k] ? @(p->mmax[k]) : @(1000000.0)];
        [defs addObject:@(p->mdef[k])];
      }
      lane.componentMin = mins;
      lane.componentMax = maxs;
      lane.sliderMin = @(p->sliderLo); // bound, nominal, or slidermin= override
      lane.sliderMax = @(p->sliderHi); // bound, nominal, or slidermax= override
      // Multi-word component captions (e.g. "Width"/"Height") size to fit
      // instead of the fixed one-char slot that truncates them to "Wi"/"Hi".
      lane.autoSizesComponentLabels = YES;
      lane.aspectLinkable = p->aspectLinked ? YES : NO;
      lane.aspectLinked = p->aspectLinked ? YES : NO;
      // Per-field units `units={%,px,...}` override the blanket percent/int:
      // each component can be a "%", a media "px", or raw. Any px component
      // puts the lane in media-scaled display; the popover's per-component
      // scale leaves "%" components literal (never media-scaled).
      int anyFieldUnit = 0, anyFieldPx = 0;
      for (int k = 0; k < n; k++) {
        if (p->fieldUnit[k])
          anyFieldUnit = 1;
        if (p->fieldUnit[k] == 'p')
          anyFieldPx = 1;
      }
      if (anyFieldUnit) {
        lane.componentUnits =
            MirageScalarUnitLabels(p, n) ?: lane.componentUnits;
        // A px field stores a normalised 0..1 fraction - integerValued would
        // round that storage to 0/1 (the "maxes at 0" bug). Media-scaling
        // already gives whole-PIXEL display; only round storage when there are
        // no px fields (a pure %/raw units lane).
        lane.componentsScaleWithMedia = anyFieldPx ? YES : NO;
        lane.integerValued = anyFieldPx ? NO : YES;
      } else if (p->isPercent) {
        // Whole-number % fields with a "%" unit, matching a single #percent
        // lane (one unit entry per component).
        NSMutableArray<NSString *> *units = [NSMutableArray array];
        for (int k = 0; k < n; k++)
          [units addObject:@"%"];
        lane.componentUnits = units;
        lane.integerValued = YES;
      } else if (p->isInt) {
        lane.integerValued = YES; // whole-number fields
        lane.scrubStep = 1.0;
      }
      // A units= spelling that is neither px nor % (`units={°,°}`) is a LABEL
      // and nothing else: it lands on the fields without claiming the rounding
      // or the media scaling that the px/% branch above carries with it.
      if (!anyFieldUnit) {
        NSArray<NSString *> *labels = MirageScalarUnitLabels(p, n);
        if (labels)
          lane.componentUnits = labels;
      }
      [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:defs]];
      break;
    }
    case MirageScalarKindFloat:
    case MirageScalarKindPercent:
    case MirageScalarKindProgress:
    case MirageScalarKindInt: {
      if (MirageOSCBlockIsRotate([model oscBlockForUniform:p->name])) {
        MirageConfigureRotateLane(lane, p, [model oscBlockForUniform:p->name]);
        break;
      }
      lane.animatable = YES;
      // Hard field bounds: the actual `min=`/`max=`, or an
      // effectively-unbounded cap when omitted (so the field accepts any
      // value).
      lane.componentMin = @[ p->hasMin ? @(p->fmin) : @(-1000000.0) ];
      lane.componentMax = @[ p->hasMax ? @(p->fmax) : @(1000000.0) ];
      // Slider span: the field bound, the nominal, or an explicit
      // slidermin=/slidermax= override.
      lane.sliderMin = @(p->sliderLo);
      lane.sliderMax = @(p->sliderHi);
      if (p->maxByName[0] && p->maxByValueCount > 0) {
        lane.maxControllerKey = @(p->maxByName);
        NSMutableArray<NSNumber *> *reactiveMaxes =
            [NSMutableArray arrayWithCapacity:p->maxByValueCount];
        for (int i = 0; i < p->maxByValueCount; i++)
          [reactiveMaxes addObject:@(p->maxByValues[i])];
        lane.componentMaxByControllerValue = reactiveMaxes;
      }
      if (p->isPercent) {
        // Match the canonical percentage lane (opacityLane): whole-number %
        // with a "%" unit, not a raw decimal float.
        lane.componentUnits = @[ @"%" ];
        lane.integerValued = YES;
      }
      if (p->fieldUnit[0] == 'p') {
        // Raw pixels: the "px" label WITHOUT componentsScaleWithMedia, so the
        // stored value is the pixel count the shader uses directly. Media
        // scaling would be wrong here anyway - it maps component 0 to media
        // WIDTH, and a thickness like this is usually measured off height.
        lane.componentUnits = @[ @"px" ];
        lane.integerValued = YES;
        lane.scrubStep = 1.0;
      } else if (p->fieldUnit[0] == '%') {
        lane.componentUnits = @[ @"%" ];
        lane.integerValued = YES;
      } else {
        // Any other spelling (`stops`, `dB/oct`, `°`, `×`) is the author's own
        // word for what the field measures. It rides on the value field as a
        // suffix and changes nothing else - the value stays exactly the float
        // the shader reads, so naming a unit can never quietly re-scale it.
        NSArray<NSString *> *labels = MirageScalarUnitLabels(p, 1);
        if (labels)
          lane.componentUnits = labels;
      }
      if (p->isInt) {
        lane.integerValued = YES; // whole-number slider
        lane.scrubStep = 1.0;
      }
      if (p->isProgress) {
        // The identity ramp, not a constant: 0% at the effect's start, 100% at
        // its end. Left alone this evaluates to the raw clip fraction, so a
        // `#progress` lane matches the built-in iProgress and a ported GL
        // transition runs linearly like its web reference. Shaping the curve is
        // then purely additive.
        //
        // The curve MUST be stated: KKInterval defaults to EaseInOut, which
        // would silently ease every transition that never asked to be eased.
        KKKeyPose *start = [KKKeyPose keyposeAtTime:0.0 values:@[ @0.0 ]];
        start.outgoing.curve = KKIntervalCurveLinear;
        [lane insertKeypose:start];
        [lane insertKeypose:[KKKeyPose keyposeAtTime:1.0 values:@[ @100.0 ]]];
      } else {
        [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                              values:@[ @(p->fdefault) ]]];
      }
      break;
    }
    }
    [lanes addObject:lane];
  }
}

// Append one lane per `// #gradient` property: a stop-editor row (the shared
// KKGradientControl - drag stops, midpoints, favourites, reverse, distribute).
//
// Stops-only, NOT the composite type/angle form: a gradient here is a colour
// ramp the shader samples by whatever position it likes (a radius, an audio
// level, a UV axis), so a linear/radial toggle and an angle knob would be
// controls the shader has no obligation to honour.
static inline void MirageAppendGradientLanes(NSMutableArray<KKLane *> *lanes,
                                             NSString *source) {
  MirageShaderModel *model = [MirageShaderModel modelForSource:source];
  const MirageGradientProp *props = model.gradientProps;
  for (int pi = 0; pi < model.gradientCount; pi++) {
    const MirageGradientProp *p = &props[pi];
    // Identity = the uniform name (stable across rename/reorder), like every
    // other directive lane; the label is display-only.
    KKLane *lane = [KKLane laneWithKey:@(p->name) label:@(p->label)];
    lane.valueType = KKLaneValueTypeGradient;
    lane.gradientShowsTypeAngle = NO;
    lane.animatable = YES;
    lane.enabled = NO;
    // Variable length (stops come and go), so no per-component bounds.
    lane.componentMin = @[];
    lane.componentMax = @[];
    lane.groupKey = @(p->name);
    lane.categoryKey = kMirageColorCategory;
    lane.categorySymbol = @"paintpalette";
    NSMutableArray<NSNumber *> *flat = [NSMutableArray array];
    for (int i = 0; i < p->defStopCount; i++)
      for (int k = 0; k < KK_GRADIENT_STOP_STRIDE; k++)
        [flat addObject:@(p->defStops[i][k])];
    [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:flat]];
    [lanes addObject:lane];
  }
}

// One of an `// #audio` property's animatable knobs (gate / release /
// smoothness). They differ only in name, unit, range and default - everything
// else has to agree or they'd scatter out of the Audio group and out of the
// uniform's keypose scope.
static inline KKLane *MirageMakeAudioControlLane(NSString *idLabel,
                                                 NSString *displayLabel,
                                                 NSString *units, double min,
                                                 double max, double def,
                                                 NSString *group) {
  KKLane *lane = [KKLane laneWithKey:idLabel label:displayLabel];
  lane.valueType = KKLaneValueTypeFloat;
  lane.componentUnits = @[ units ];
  lane.componentMin = @[ @(min) ];
  lane.componentMax = @[ @(max) ];
  lane.groupKey = group;
  lane.categoryKey = kMirageAudioCategory;
  lane.categorySymbol = kMirageAudioCategorySymbol;
  [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @(def) ]]];
  return lane;
}

// Append one lane per `// #audio` property: a dropdown of the analyses Sonar
// has published, read live from the manifest.
//
// The options are the published source NAMES, not anything the shader names -
// the directive only declares the slot. So a shader shared with someone whose
// Sonar has different sources still opens; they just pick their own.
//
// Structural (non-animatable): it selects which data feeds the shader, it isn't
// a value to keyframe. The audio itself is the animation.
// `tickets` is what this plugin instance remembers about the sources its
// `#audio` lanes are bound to (key -> KKSonarTicket), so a lane bound to
// something not published HERE can still name it. Passed in rather than read:
// tickets live in a parameter, and the param APIs resolve only inside an action
// scope - which a lane builder called from a code-commit callback isn't in.
static inline void
MirageAppendAudioLanes(NSMutableArray<KKLane *> *lanes, NSString *source,
                       NSDictionary<NSString *, id> *tickets) {
  MirageShaderModel *model = [MirageShaderModel modelForSource:source];
  const MirageAudioProp *props = model.audioProps;
  int nProps = model.audioCount;
  if (nProps == 0)
    return;

  NSArray<NSDictionary<NSString *, id> *> *published =
      KKSpectrogramPublishedSources();
  NSMutableArray<NSString *> *options = [NSMutableArray array];
  NSMutableArray<NSNumber *> *keys = [NSMutableArray array];
  // "None" first, so an unbound lane has a meaningful value and a shader with
  // no audio published still renders instead of silently picking something.
  [options addObject:RLoc(@"None", @"Mirage audio source: nothing bound.")];
  [keys addObject:@0];
  for (NSDictionary *entry in published) {
    NSString *name = entry[@"name"];
    if (![name isKindOfClass:NSString.class] || !name.length)
      continue;
    double key = KKSonarSourceKeyForSource(entry);
    if (lround(key) == 0)
      continue;
    // Always "<name> - <project>": Sonar only dedupes names within a project,
    // so two projects each publishing a "Dialogue" arrive here identically
    // named. Naming the project unconditionally also says what the analysis was
    // generated against, which is the thing you need to know when binding.
    NSString *project = entry[@"projectName"];
    NSString *label =
        ([project isKindOfClass:NSString.class] && project.length)
            ? [NSString stringWithFormat:@"%@ - %@", name, project]
            : name;
    [options addObject:label];
    [keys addObject:@(key)];
  }

  // What each remembered binding reads as when it names nothing published here.
  // Built in the SAME "<name> - <project>" shape as a live option above, so a
  // source that has gone missing still reads like the thing it is rather than
  // like some other kind of object.
  //
  // Every ticket goes in, not just the missing ones: the row consults this only
  // once a stored value has matched no option, so an entry for a source that IS
  // published is simply never read. Filtering here would mean deciding twice,
  // in two places, what "missing" means.
  NSMutableDictionary<NSNumber *, NSString *> *unknownLabels =
      [NSMutableDictionary dictionary];
  for (NSString *ticketKey in tickets) {
    NSDictionary *ticket = tickets[ticketKey];
    if (![ticket isKindOfClass:NSDictionary.class])
      continue;
    NSString *name = KKSonarTicketSourceName(ticket);
    if (!name.length)
      continue;
    NSString *project = KKSonarTicketProjectName(ticket);
    unknownLabels[@(KKSonarTicketKey(ticket))] =
        project.length ? [NSString stringWithFormat:@"%@ - %@", name, project]
                       : name;
  }

  for (int pi = 0; pi < nProps; pi++) {
    const MirageAudioProp *p = &props[pi];
    NSString *uniform = @(p->name);
    // Only one `#audio` in the shader: the group already says "Audio", so
    // "Noise Gate" needs no qualifying. With two, every lane says which source
    // it belongs to or the group is six anonymous rows.
    NSString *prefix =
        nProps > 1 ? [NSString stringWithFormat:@"%@ ", @(p->label)] : @"";

    // Identity = the uniform name (stable across rename/reorder), like every
    // other directive lane; the label is display-only.
    KKLane *lane = [KKLane laneWithKey:uniform label:@(p->label)];
    lane.valueType = KKLaneValueTypeFloat;
    lane.integerValued = YES;
    lane.animatable = NO;
    lane.enabled = NO;
    lane.choiceLabels = options;
    // Stores the source's stable key, NOT the pill index: the published set
    // changes between sessions, and an index would mean something different the
    // moment a source is deleted.
    lane.choiceValues = keys;
    // However many sources are published, plus "None". The set size isn't
    // knowable at build time and grows with every Publish, so this is the
    // open-ended case the dropdown exists for: wrapping pills grew the row
    // without limit, one line per few sources.
    lane.choiceUsesDropdown = YES;
    // What a binding to an unpublished source reads as. Without these the row
    // says "None" - indistinguishable from deliberately picking None, when in
    // fact the project knows exactly what it wants and just can't see it here.
    lane.choiceUnknownLabels = unknownLabels;
    lane.choiceUnknownBadge =
        unknownLabels.count
            ? RLoc(@"Republish required", @"Mirage audio: the bound source "
                                          @"isn't published on this Mac.")
            : nil;
    // Wide enough for any key: the stored value is a hash now, so clamping to
    // the choice count would destroy every binding.
    lane.componentMin = @[ @0.0 ];
    lane.componentMax = @[ @16777215.0 ];
    lane.groupKey = uniform;
    lane.categoryKey = kMirageAudioCategory;
    lane.categorySymbol = kMirageAudioCategorySymbol;
    [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0 ]]];
    [lanes addObject:lane];

    // Gate + smoothness are ANIMATABLE lanes rather than fixed directive
    // attributes: `gate=` / `smooth=` only seed their defaults. The right gate
    // depends on the mix, not on the shader, so it belongs to whoever is
    // cutting - and animating it (gate shut through a quiet section, open for
    // the drop) is worth more than any value baked into the source.
    //
    // Suffixed identities: a dot can't appear in a GLSL identifier, so these
    // can never collide with a uniform the author declared.
    // The gate's floor is well below any analysis window: at or under it
    // nothing is quieter than the gate, so the bottom of the range IS "off"
    // without needing a magic value or a separate switch.
    [lanes addObject:MirageMakeAudioControlLane(
                         MirageAudioGateLaneLabel(uniform),
                         [prefix stringByAppendingString:@"Noise Gate"], @"dB",
                         kMirageAudioGateOffDB, -10.0,
                         isnan(p->gateDB) ? kMirageAudioGateOffDB : p->gateDB,
                         uniform)];

    // Release sits next to the gate because it only means anything with one:
    // it's how long a bar takes to die after its band goes under, so the gate
    // reads as a sound stopping rather than as a switch.
    [lanes
        addObject:MirageMakeAudioControlLane(
                      MirageAudioReleaseLaneLabel(uniform),
                      [prefix stringByAppendingString:@"Release"], @"s", 0.0,
                      kMirageAudioReleaseMaxSec, p->releaseSeconds, uniform)];

    [lanes
        addObject:MirageMakeAudioControlLane(
                      MirageAudioSmoothLaneLabel(uniform),
                      [prefix stringByAppendingString:@"Smoothness"], @"s", 0.0,
                      kMirageAudioSmoothMaxSec, p->smoothSeconds, uniform)];

    if (p->wantsWaveform) {
      [lanes addObject:MirageMakeAudioControlLane(
                           MirageAudioWaveformWindowLaneLabel(uniform),
                           [prefix stringByAppendingString:@"Waveform Window"],
                           @"s", kMirageAudioWaveformWindowMinSec,
                           kMirageAudioWaveformWindowMaxSec,
                           p->waveformWindowSeconds, uniform)];
    }
  }
}

// One rack entry's lanes, on BARE keys. `entryID` reaches only as far as the
// `#slots` registry (two entries running the same template mint their own
// instances); every key this build produces is the key the unracked plugin
// produced, and the rack prefix is applied afterwards by
// MirageBuildAvailableLanesForRack.
static inline NSArray<KKLane *> *
MirageBuildAvailableLanesForRackEntry(NSString *shaderSource,
                                      NSDictionary<NSString *, id> *tickets,
                                      KKTimeline *timeline, NSString *entryID) {
  // Lanes are BUILT in a convenient order and REORDERED by group at the end
  // (see the bucketing pass before the return, which is what actually decides
  // top-to-bottom order). Users can reorder further in the inspector.
  NSMutableArray<KKLane *> *lanes = [NSMutableArray array];
  // The built-ins are opt-in (`// #speed` / `// #seed` / `// #grain`): most
  // shaders drive their own motion and want no grain, so an always-present set
  // of them was four dead controls on top of every inspector. Declaring none
  // renders neutral (speed 1, offset 0, no grain) - see MirageBuiltinProps.h.
  MirageBuiltins builtins =
      [MirageShaderModel modelForSource:shaderSource].builtins;
  // Group per built-in, defaulting like any other control. They are emitted
  // ahead of the scalar lanes, so a group first named by a built-in leads the
  // inspector regardless of where it sits in the source.
  KKLane * (^applyBuiltinGroup)(KKLane *, const MirageBuiltinProp *) =
      ^KKLane *(KKLane *lane, const MirageBuiltinProp *p) {
        NSString *grp = @(p->group);
        lane.categoryKey = grp.length ? grp : kMirageDefaultGroup;
        lane.categorySymbol = (grp.length && p->groupSymbol[0])
                                  ? @(p->groupSymbol)
                                  : kMirageDefaultGroupSymbol;
        return lane;
      };

  // Transition shaders need an explicit coverage choice because FxPlug does
  // not tell a filter-based Motion template whether either side of a
  // transition is a real edit or an unpaired gap. The renderer turns the
  // selected missing side into transparent black before the shader samples it.
  if (KKLooksLikeTransitionShader(shaderSource)) {
    KKLane *mode = [KKLane laneWithKey:@"Transition Mode" label:@"Mode"];
    mode.valueType = KKLaneValueTypeFloat;
    mode.integerValued = YES;
    mode.animatable = NO;
    mode.enabled = NO;
    mode.choiceLabels = @[ @"Transition", @"In", @"Out" ];
    mode.componentMin = @[ @0.0 ];
    mode.componentMax = @[ @2.0 ];
    mode.groupKey = @"Transition Mode";
    mode.categoryKey = @"Transition";
    mode.categorySymbol = @"arrow.triangle.2.circlepath";
    [mode insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0.0 ]]];
    [lanes addObject:mode];

    // How the sweep is PACED. The curve is the timing engine's own
    // (KKEasingCurve / KKApplyEasing - the same set the timeline's segment
    // editor offers), applied host-side to the clip fraction before it becomes
    // iProgress, so a template needs no code to honour it and every transition
    // gets the option whether or not it was written with one in mind. Linear
    // is the identity, so an untouched lane renders the frac unchanged.
    //
    // `// #easing default="..."` moves only the STARTING curve, for a template
    // whose look has always been an eased one.
    _Static_assert((NSInteger)MirageEasingCurveLinear ==
                           (NSInteger)KKEasingCurveLinear &&
                       (NSInteger)MirageEasingCurveEaseIn ==
                           (NSInteger)KKEasingCurveEaseIn &&
                       (NSInteger)MirageEasingCurveEaseOut ==
                           (NSInteger)KKEasingCurveEaseOut &&
                       (NSInteger)MirageEasingCurveEaseInOut ==
                           (NSInteger)KKEasingCurveEaseInOut &&
                       (NSInteger)MirageEasingCurveElastic ==
                           (NSInteger)KKEasingCurveElastic &&
                       (NSInteger)MirageEasingCurveBounce ==
                           (NSInteger)KKEasingCurveBounce &&
                       KK_SHADER_EASING_CURVE_COUNT == KKEasingCurveCount,
                   "The #easing directive's curve indices ARE KKEasingCurve's; "
                   "they are restated only because the directive header "
                   "compiles without the kit.");
    KKLane *easing = [KKLane laneWithKey:@"Easing" label:@"Easing"];
    easing.valueType = KKLaneValueTypeFloat;
    easing.integerValued = YES;
    easing.animatable = NO;
    easing.enabled = NO;
    NSMutableArray<NSString *> *curveNames = [NSMutableArray array];
    for (NSInteger c = 0; c < KKEasingCurveCount; c++)
      [curveNames addObject:KKEasingCurveDisplayName((KKEasingCurve)c)];
    easing.choiceLabels = curveNames;
    // Six named curves is past where pills read - they wrap into a wall in the
    // inspector's width, and the Mode pill above is what a pill row is FOR
    // here (three words, always visible). This is a menu.
    easing.choiceUsesDropdown = YES;
    easing.componentMin = @[ @0.0 ];
    easing.componentMax = @[ @(KKEasingCurveCount - 1) ];
    easing.groupKey = @"Easing";
    easing.categoryKey = @"Transition";
    easing.categorySymbol = @"arrow.triangle.2.circlepath";
    [easing
        insertKeypose:[KKKeyPose
                          keyposeAtTime:0.0
                                 values:@[ @(MirageEasingDefaultCurveForSource(
                                            shaderSource, NULL)) ]]];
    [lanes addObject:easing];
  }

  // The plugin is Custom-only (GLSL). The Type pill and the built-in per-type
  // controls (Colors etc.) are removed for now - the built-in types will return
  // as GLSL community shaders once publish/submit is solid. The render defaults
  // to Custom when the Type lane is absent. Kept lanes below still declare a
  // `visibleWhen Type` gate; with Type absent they simply always show (an
  // absent controller can't gate), so they need no change.

  // Speed: shared motion-rate multiplier (`// #speed`).
  if (builtins.speed.present) {
    KKLane *speed = [KKLane laneWithKey:@"Speed" label:@"Speed"];
    speed.valueType = KKLaneValueTypeFloat;
    speed.componentMin = @[ @0.0 ];
    speed.componentMax = @[ @3.0 ];
    speed.animatable = YES;
    speed.enabled = NO;
    speed.visibleWhenKey = @"Type";
    speed.visibleWhenValues =
        @[ @0, @1, @2, @3, @4, @5, @6, @7, @8, @9, @10, @11, @12 ]; // + Custom
    double def = builtins.speed.hasDefault ? builtins.speed.fdefault
                                           : KK_SHADER_GRAD_DEFAULT_SPEED;
    [speed insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @(def) ]]];
    if (builtins.speed.label[0])
      speed.label = @(builtins.speed.label);
    [lanes addObject:applyBuiltinGroup(speed, &builtins.speed)];
  }

  // Seed: shared start-time offset (a "start frame"), non-animatable integer
  // with a dice field (`// #seed`). A per-shader random seed bound to a uniform
  // is `// #random`, a separate directive. Any value; the slider range is
  // nominal.
  if (builtins.seed.present) {
    KKLane *seed = [KKLane laneWithKey:@"Seed" label:@"Seed"];
    seed.valueType = KKLaneValueTypeFloat;
    seed.seedField = YES;
    seed.integerValued = YES;
    seed.componentMin = @[ @0.0 ];
    seed.componentMax = @[ @1000000.0 ];
    seed.animatable = NO;
    seed.enabled = NO;
    seed.visibleWhenKey = @"Type";
    seed.visibleWhenValues =
        @[ @0, @1, @2, @3, @4, @5, @6, @7, @8, @9, @10, @11, @12 ]; // + Custom
    double def = builtins.seed.hasDefault ? builtins.seed.fdefault
                                          : KK_SHADER_GRAD_DEFAULT_SEED;
    [seed insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @(def) ]]];
    if (builtins.seed.label[0])
      seed.label = @(builtins.seed.label);
    [lanes addObject:applyBuiltinGroup(seed, &builtins.seed)];
  }

  // Grain + Grain Size: the film-grain overlay (`// #grain`), applied in the
  // shader epilogue. One directive, two lanes - the amount and its cell size
  // are the same control to the author, so asking for the grain gives both.
  // `default=` seeds the amount, `size=` the cell size, and `min=`/`max=` bound
  // the amount the way they bound any other percentage. Opting in starts at a
  // subtle value that also breaks up 8-bit banding, and scales to stylistic.
  if (builtins.grain.present) {
    NSArray<NSNumber *> *allTypes = @[
      @0, @1, @2, @3, @4, @5, @6, @7, @8, @9, @10, @11, @12
    ]; // incl. Custom
    struct {
      NSString *label;
      double def, min, max;
      NSString *unit;
      BOOL integer;
    } coreGrain[] = {
        {@"Grain",
         builtins.grain.hasDefault ? builtins.grain.fdefault
                                   : KK_CORE_GRAIN_DEFAULT * 100.0,
         builtins.grain.hasMin ? builtins.grain.fmin : 0.0,
         builtins.grain.hasMax ? builtins.grain.fmax : 100.0, @"%", NO},
        {@"Grain Size",
         builtins.grain.hasSize ? builtins.grain.fsize
                                : KK_CORE_GRAINSIZE_DEFAULT,
         1.0, 12.0, @"px", YES},
    };
    for (unsigned s = 0; s < sizeof(coreGrain) / sizeof(coreGrain[0]); s++) {
      KKLane *lane = [KKLane laneWithKey:coreGrain[s].label
                                   label:coreGrain[s].label];
      lane.valueType = KKLaneValueTypeFloat;
      lane.componentMin = @[ @(coreGrain[s].min) ];
      lane.componentMax = @[ @(coreGrain[s].max) ];
      lane.componentUnits = @[ coreGrain[s].unit ];
      lane.integerValued = coreGrain[s].integer; // grain size is whole pixels
      lane.animatable = YES;
      lane.enabled = NO;
      lane.visibleWhenKey = @"Type";
      lane.visibleWhenValues = allTypes;
      [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                            values:@[ @(coreGrain[s].def) ]]];
      // `label=` renames the amount; the size lane keeps its own name, which
      // still reads correctly under a renamed amount ("Halation" / "Grain
      // Size").
      if (s == 0 && builtins.grain.label[0])
        lane.label = @(builtins.grain.label);
      [lanes addObject:applyBuiltinGroup(lane, &builtins.grain)];
    }
  }

  // Dynamic scalar params (`// #float` sliders, `// #choice` pills) declared by
  // the shader, in whatever group each one asks for.
  MirageAppendScalarLanes(lanes, shaderSource);

  // Except the ones the Color panel owns. A `preview=` control is SESSION
  // STATE - what you are looking at this minute - so it gets no row, no
  // keyframes and nothing in the blob, exactly like Before and Split. Dropped
  // here rather than never built, so the one rule lives beside the build it
  // qualifies instead of inside the scalar walk that knows nothing about the
  // panel.
  //
  // The uniform is still DECLARED, so it still has a pool slot: the shader
  // reads its own `default=` everywhere nobody is driving it (Final Cut's
  // viewer, always) and the panel's live override in the preview it is driving.
  // Unconditional - the prototype builds want this too, since "what controls
  // does this source offer the user" has the same answer with or without a
  // timeline.
  NSSet<NSString *> *panelOwned = MirageSurfacePreviewOwnedKeys(shaderSource);
  if (panelOwned.count) {
    NSMutableArray<KKLane *> *kept =
        [NSMutableArray arrayWithCapacity:lanes.count];
    for (KKLane *l in lanes)
      if (!l.key.length || ![panelOwned containsObject:l.key])
        [kept addObject:l];
    [lanes setArray:kept];
  }

  // Dynamic audio bindings (`// #audio`): a dropdown of Sonar's published
  // analyses per declared spectrum uniform.
  MirageAppendAudioLanes(lanes, shaderSource, tickets);

  // Custom shader source: a full-width code editor row at the bottom of Core.
  // Non-animatable; the text lives in the lane's codeString (not a keypose) and
  // flows through the timeline. Seeded with the baked default so the editor
  // opens on something runnable.
  // The KEY "Mirage" is the internal identity (matched all over as the code
  // lane); the code block is a GENERIC GLSL shader, so it SHOWS as "Shader" -
  // the brand name shouldn't leak onto the editor caption / save placeholder.
  KKLane *shader = [KKLane
      laneWithKey:kMirageCodeLaneLabel
            label:RLoc(@"Shader", @"Generic GLSL code lane display "
                                  @"name (the code editor's caption).")];
  shader.valueType = KKLaneValueTypeCode;
  shader.codeString = MirageCustomDefaultShaderSource();
  // Multi-pass: the editor starts on the single Image tab (codeString above)
  // and a "+" menu offers these extra sections on demand - Common (shared code
  // prepended to every pass) and Buffer A (an offscreen pass bound to
  // iChannel0). codeTabs stays empty until the user adds one = single-pass by
  // default.
  shader.codeTabCatalog =
      @[ @"Common", @"Buffer A", @"Buffer B", @"Buffer C", @"Buffer D" ];
  shader.codeSavable = YES; // show the save bar (name + Save) above the editor
  // No row heading: the lane sits alone in the "Shader" group, so a "Shader"
  // title under a "Shader" header said it twice. The editor takes the space.
  shader.codeHidesTitle = YES;
  shader.codeSaveNamePlaceholder =
      RLoc(@"Shader name", @"Save-shader name field placeholder.");
  // Template type is mandatory in the Image source (`// #template ...`), so
  // the save bar needs only the name and Save button.
  shader.codeSaveCategories = nil;
  shader.animatable = NO;
  shader.enabled = NO;
  // Its own group. "Core" is gone (its lanes are opt-in built-ins now, each
  // landing in whatever group its directive names), and the code editor is the
  // one row that is never a control, so it gets a group to itself.
  shader.categoryKey = kMirageShaderCategory;
  shader.categorySymbol = @"chevron.left.forwardslash.chevron.right";
  // Live validation in the editor: transpile on edit (memoised) and surface the
  // first glslang error as a bar + flagged line. Only compiled into the XPC
  // service (the sole includer of this catalog), where the transpiler is
  // linked.
  // Multi-pass composition (moved out of the generic editor): validate a tab
  // WITH the shared "Common" section prepended (so shared decls resolve,
  // mirroring the render), and validate the Common tab itself against a dummy
  // entry point so its own syntax is still checked. `outPrependLines` maps a
  // reported error back to the active tab (an error inside Common surfaces on
  // the Common tab).
  // The validator is handed only the ACTIVE section's code, but "is this
  // shader multi-pass" is a question about the whole tab SET. The composer runs
  // first (KKCodeEditorView -_runValidator) and does see every section, so it
  // records what it saw for the validator to read.
  __block BOOL sawFeedbackBuffer = NO;
  __block BOOL activeIsImage = YES;
  __block NSString *activeTemplateSource = @"";
  shader.codeValidationComposer =
      ^NSString *(NSString *activeName, NSString *activeCode,
                  NSArray<NSDictionary<NSString *, NSString *> *> *sections,
                  NSInteger *outPrependLines) {
        activeIsImage = ![activeName isEqualToString:@"Common"] &&
                        ![activeName hasPrefix:@"Buffer"];
        activeTemplateSource = activeIsImage ? activeCode : @"";
        NSString *commonCode = nil;
        for (NSDictionary<NSString *, NSString *> *s in sections)
          if ([s[@"name"] isEqualToString:@"Common"]) {
            commonCode = s[@"code"];
            break;
          }
        // FEEDBACK = a buffer reading itself or a LATER buffer, so its state is
        // a function of history. Same test the render path runs on the
        // transpiled channel mask, and the same reason: a feedback chain cannot
        // share one simulation across motion-blur sub-samples, while a plain
        // precompute chain can (it is a pure function of the current uniforms,
        // identical at every sample). Transpiles are memoized, so re-running
        // this per validation tick costs a dictionary hit once warm.
        sawFeedbackBuffer = NO;
        for (int k = 0; k < 4 && !sawFeedbackBuffer; k++) {
          NSString *want = [NSString stringWithFormat:@"Buffer %c", 'A' + k];
          for (NSDictionary<NSString *, NSString *> *sec in sections) {
            if (![sec[@"name"] isEqualToString:want] || !sec[@"code"].length)
              continue;
            NSString *src =
                commonCode.length
                    ? [NSString
                          stringWithFormat:@"%@\n%@", commonCode, sec[@"code"]]
                    : sec[@"code"];
            NSUInteger mask = KKTranspileGLSLBuffer(src).declaredChannelMask;
            for (int c = k; c < 4; c++)
              if (mask & (1u << c))
                sawFeedbackBuffer = YES;
            break;
          }
        }
        if ([activeName isEqualToString:@"Common"]) {
          if (outPrependLines)
            *outPrependLines = 0;
          return [activeCode
              stringByAppendingString:@"\nvoid mainImage(out vec4 kkO, in vec2 "
                                      @"kkC){ kkO = vec4(0.0); }\n"];
        }
        if (commonCode.length) {
          if (outPrependLines)
            *outPrependLines =
                (NSInteger)[commonCode componentsSeparatedByString:@"\n"].count;
          return [NSString stringWithFormat:@"%@\n%@", commonCode, activeCode];
        }
        if (outPrependLines)
          *outPrependLines = 0;
        return activeCode;
      };
  shader.codeValidator = ^NSString *(NSString *code, NSInteger *outLine) {
    // Only full Image/Buffer shaders validate standalone; an empty tab or the
    // Common shared-code fragment has no entry point, so skip it (no false
    // error bar). An entry point is either the image `mainImage` or a raw-GL
    // `main()` / `gl_FragColor` (which the transpiler's compat shim rewrites) -
    // validate both so a raw paste with an unmapped uniform surfaces its error
    // in the editor, not just as a render failure.
    NSString *trimmed = [code
        stringByTrimmingCharactersInSet:NSCharacterSet
                                            .whitespaceAndNewlineCharacterSet];
    BOOL hasEntry =
        [code rangeOfString:@"mainImage"].location != NSNotFound ||
        [code rangeOfString:@"gl_FragColor"].location != NSNotFound ||
        [code rangeOfString:@"gl_FragData"].location != NSNotFound ||
        [[NSRegularExpression
            regularExpressionWithPattern:
                // void main( / a gl-transitions entry (vec4 transition( -
                // KKShimGLTransition wraps it into a mainImage, so the
                // transpiler accepts it and the validator must too, or a
                // broken transition renders the red error shader with NO
                // message).
                @"\\bvoid\\s+main\\s*\\(|\\bvec4\\s+transition\\s*\\("
                                 options:0
                                   error:nil]
            firstMatchInString:code
                       options:0
                         range:NSMakeRange(0, code.length)] != nil;
    if (trimmed.length == 0 || !hasEntry)
      return nil;
    if (activeIsImage) {
      MirageTemplateDirectiveError templateError =
          MirageTemplateDirectiveErrorNone;
      MirageTemplateTypeForSource(activeTemplateSource, &templateError);
      if (templateError == MirageTemplateDirectiveErrorMissing)
        return RLoc(@"Add `// #template generator`, `filter`, `layout`, "
                    @"`transition`, or `color-transform` to the Image shader",
                    @"Mirage missing template-type directive error.");
      if (templateError == MirageTemplateDirectiveErrorMultiple)
        return RLoc(
            @"Use exactly one `#template` directive in the Image shader",
            @"Mirage duplicate template-type directive error.");
      if (templateError == MirageTemplateDirectiveErrorValue)
        return RLoc(@"`#template` must be generator, filter, layout, "
                    @"transition, or color-transform",
                    @"Mirage invalid template-type directive error.");
      // The Color panel's opt-in. Reported here rather than left to the panel:
      // a rejected `#color-surface` simply means no panel appears, which looks
      // exactly like never having typed it.
      MirageColorSurfaceError surfaceError = MirageColorSurfaceErrorNone;
      MirageColorSurfaceForSource(activeTemplateSource, NULL, &surfaceError);
      if (surfaceError == MirageColorSurfaceErrorMultiple)
        return RLoc(@"Use one `#color-surface`, or two with `ring=hue` and "
                    @"`ring=light`",
                    @"Mirage duplicate colour-surface directive error.");
      if (surfaceError == MirageColorSurfaceErrorValue)
        return RLoc(@"`#color-surface space=` must be linear-rec709",
                    @"Mirage invalid colour-surface space error.");
      // `// #frames`: the offsets are the BINDING ORDER of the iNeighbor
      // samplers, so anything ambiguous about the list is rejected rather than
      // repaired - a silently folded or renumbered list would leave the shader
      // reading a different frame than it was written against.
      MirageFramesDirectiveError framesError = MirageFramesDirectiveErrorNone;
      MirageFrameOffsetsForSource(code, &framesError);
      switch (framesError) {
      case MirageFramesDirectiveErrorNone:
        break;
      case MirageFramesDirectiveErrorMultiple:
        return RLoc(@"Use exactly one `#frames` directive in the Image shader",
                    @"Mirage duplicate frames directive error.");
      case MirageFramesDirectiveErrorMissing:
        return RLoc(@"`#frames` needs offsets=\"-1,+1\", a comma-separated "
                    @"list of whole frames",
                    @"Mirage frames directive missing-offsets error.");
      case MirageFramesDirectiveErrorValue:
        return RLoc(@"`#frames` offsets must be whole frames, like "
                    @"offsets=\"-2,-1,+1\"",
                    @"Mirage frames directive malformed-offset error.");
      case MirageFramesDirectiveErrorZero:
        return RLoc(@"`#frames` offset 0 is the current frame - read that from "
                    @"iChannel0",
                    @"Mirage frames directive zero-offset error.");
      case MirageFramesDirectiveErrorDuplicate:
        return RLoc(@"`#frames` lists the same offset twice - each offset "
                    @"binds its own iNeighbor slot",
                    @"Mirage frames directive duplicate-offset error.");
      case MirageFramesDirectiveErrorTooMany:
        return [NSString
            stringWithFormat:RLoc(@"`#frames` takes at most %d offsets - each "
                                  @"one is another full frame in memory",
                                  @"Mirage frames directive offset-count "
                                  @"error."),
                             KK_SHADER_MAX_FRAME_OFFSETS];
      }
      // `// #easing`: the starting curve of the transition's Easing lane. A
      // name the engine doesn't have is rejected rather than ignored - falling
      // back to Linear would look exactly like the template shipping uneased,
      // with nothing to say the line was misspelt.
      MirageEasingDirectiveError easingError = MirageEasingDirectiveErrorNone;
      MirageEasingDefaultCurveForSource(code, &easingError);
      switch (easingError) {
      case MirageEasingDirectiveErrorNone:
        break;
      case MirageEasingDirectiveErrorMultiple:
        return RLoc(@"Use exactly one `#easing` directive in the Image shader",
                    @"Mirage duplicate easing directive error.");
      case MirageEasingDirectiveErrorMissing:
        return RLoc(@"`#easing` needs default=\"ease-in-out\", the curve its "
                    @"Easing menu starts on",
                    @"Mirage easing directive missing-default error.");
      case MirageEasingDirectiveErrorValue:
        return RLoc(@"`#easing default=` must be linear, ease-in, ease-out, "
                    @"ease-in-out, elastic, or bounce",
                    @"Mirage invalid easing curve name error.");
      }
      MirageSurfaceRingBindingError bindingError =
          MirageSurfaceRingBindingErrorNone;
      NSString *badBinding =
          MirageFirstBadSurfaceRingBinding(activeTemplateSource, &bindingError);
      if (badBinding.length) {
        if (bindingError == MirageSurfaceRingBindingErrorUnnamed)
          return [NSString
              stringWithFormat:RLoc(@"Control \"%@\": with two rings declared, "
                                    @"`surface=` must start with `hue` or "
                                    @"`light`",
                                    @"Mirage unattached colour-surface "
                                    @"mapping error."),
                               badBinding];
        return [NSString
            stringWithFormat:RLoc(@"Control \"%@\": `surface=` names a ring "
                                  @"this shader doesn't declare",
                                  @"Mirage colour-surface mapping aimed at an "
                                  @"undeclared ring error."),
                             badBinding];
      }
      // `// #slots`: a group of controls the user instances at runtime. Every
      // rule here is about an instance being TELLABLE APART from its
      // neighbours - the group's name, the `{n}` in each control's label and
      // puck - because the failure otherwise is silent: two identical rows, or
      // one puck being dragged by two instances.
      MirageSlotsDirectiveError slotsError = MirageSlotsDirectiveErrorNone;
      NSString *slotsDetail = nil;
      MirageSlotGroupsForSource(activeTemplateSource, &slotsError,
                                &slotsDetail);
      switch (slotsError) {
      case MirageSlotsDirectiveErrorNone:
        break;
      case MirageSlotsDirectiveErrorUnclosed:
        return RLoc(@"`#slots` needs a `// #slots-end` to close the group",
                    @"Mirage unclosed slots block error.");
      case MirageSlotsDirectiveErrorUnopened:
        return RLoc(@"`#slots-end` has no `#slots` block to close",
                    @"Mirage unopened slots-end error.");
      case MirageSlotsDirectiveErrorNested:
        return RLoc(@"`#slots` blocks can't be nested - close one before "
                    @"opening the next",
                    @"Mirage nested slots block error.");
      case MirageSlotsDirectiveErrorName:
        return RLoc(@"`#slots` needs name=\"...\", using letters, numbers and "
                    @"spaces",
                    @"Mirage slots name error.");
      case MirageSlotsDirectiveErrorDuplicateName:
        return [NSString
            stringWithFormat:RLoc(@"Two `#slots` groups named \"%@\": give "
                                  @"each group its own name",
                                  @"Mirage duplicate slots name error."),
                             slotsDetail ?: @""];
      case MirageSlotsDirectiveErrorMax:
        return [NSString
            stringWithFormat:RLoc(@"`#slots` needs max=1 to %d, the most "
                                  @"instances a group can have",
                                  @"Mirage slots max error."),
                             KK_SHADER_MAX_SLOT_INSTANCES];
      case MirageSlotsDirectiveErrorCount:
        return [NSString
            stringWithFormat:RLoc(@"Slot group \"%@\": min= and default= must "
                                  @"be 0 to max=, and default can't be below "
                                  @"min=",
                                  @"Mirage slots count error."),
                             slotsDetail ?: @""];
      case MirageSlotsDirectiveErrorPlaceholder:
        return [NSString
            stringWithFormat:RLoc(@"Control \"%@\": a control inside `#slots` "
                                  @"needs {n} in its label and puck name",
                                  @"Mirage slots missing-placeholder error."),
                             slotsDetail ?: @""];
      case MirageSlotsDirectiveErrorPuckName:
        return [NSString
            stringWithFormat:RLoc(@"Control \"%@\": a puck inside `#slots` "
                                  @"needs a name with {n} in it",
                                  @"Mirage slots empty-puck-name error."),
                             slotsDetail ?: @""];
      case MirageSlotsDirectiveErrorStrayPlaceholder:
        return RLoc(@"`{n}` only means something inside a `#slots` block",
                    @"Mirage stray slots placeholder error.");
      }
      // What the pool can repeat at all. A ramp, an audio binding and an
      // arrayed colour are each one pool entry with a shape of their own, so an
      // instance of one is not a copy but a second name for the same value:
      // every row in the inspector would edit the one ramp. Rejected where it
      // is written rather than left to be discovered.
      MirageSlotRepeatKind repeatKind = MirageSlotRepeatKindNone;
      NSString *unrepeatable =
          MirageFirstUnrepeatableSlotControl(activeTemplateSource, &repeatKind);
      if (unrepeatable.length)
        return [NSString
            stringWithFormat:RLoc(@"Control \"%@\": #gradient, #audio and "
                                  @"colour arrays can't repeat - declare them "
                                  @"outside the #slots block",
                                  @"Mirage unrepeatable slots control error."),
                             unrepeatable];
      // The pool, counted with every group FULL. A group is `max=` real
      // controls the moment the user presses "+", so a shader that fits only
      // while its groups are small is one that breaks on a click - and the
      // break is silent, since the pool simply stops taking controls.
      int slotScalars = 0, slotColors = 0;
      switch (MirageSlotsControlBudget(activeTemplateSource, &slotScalars,
                                       &slotColors)) {
      case MirageSlotBudgetKindNone:
        break;
      case MirageSlotBudgetKindScalar:
        return [NSString
            stringWithFormat:RLoc(@"With every `#slots` group full this shader "
                                  @"asks for %d controls, and %d is the limit "
                                  @"- lower a max= or drop a control",
                                  @"Mirage slots scalar-pool budget error."),
                             slotScalars, KK_SHADER_MAX_SCALAR_PROPS];
      case MirageSlotBudgetKindColor:
        return [NSString
            stringWithFormat:RLoc(@"With every `#slots` group full this shader "
                                  @"asks for %d colours, and %d is the limit - "
                                  @"lower a max= or drop a colour",
                                  @"Mirage slots colour-pool budget error."),
                             slotColors, KK_SHADER_MAX_COLOR_PROPS];
      }
    }
    // Duplicate directive LABELS are allowed - the lane identity is the
    // uniform name, so two controls may share a display name (the link-bus
    // manifests disambiguate them as "Name (2)" where it matters). Only a
    // duplicate UNIFORM is a real error (identity collision + glslang
    // block-member clash).
    NSString *dupU = MirageFirstDuplicateUniform(code);
    if (dupU.length)
      return [NSString
          stringWithFormat:RLoc(
                               @"Duplicate uniform \"%@\": give each directive "
                               @"a unique uniform name",
                               @"Mirage duplicate-uniform validation error."),
                           dupU];
    int colorOptionsKind = MirageColorOptionsErrorArray;
    NSString *badColorOptions =
        MirageFirstInvalidColorOptions(code, &colorOptionsKind);
    if (badColorOptions.length) {
      if (colorOptionsKind == MirageColorOptionsErrorArray)
        return [NSString
            stringWithFormat:RLoc(@"Colour \"%@\": optionsby only works with a "
                                  @"vec4 array",
                                  @"Mirage color-options array error."),
                             badColorOptions];
      if (colorOptionsKind == MirageColorOptionsErrorController)
        return [NSString
            stringWithFormat:RLoc(
                                 @"optionsby references unknown control \"%@\"",
                                 @"Mirage color-options controller error."),
                             badColorOptions];
      if (colorOptionsKind == MirageColorOptionsErrorMultiple)
        return
            [NSString stringWithFormat:
                          RLoc(@"optionsby control \"%@\" must be a multiple "
                               @"#choice",
                               @"Mirage color-options multiple-choice error."),
                          badColorOptions];
      return [NSString
          stringWithFormat:RLoc(@"Colour array \"%@\" must have one slot per "
                                @"optionsby choice",
                                @"Mirage color-options count error."),
                           badColorOptions];
    }
    // `group=` on a directive that already has a group of its own. Audio
    // bindings and gradients are collected into dedicated groups, so a group
    // here would be silently dropped. (Colours are not on this list: `#color`
    // honours `group=` for real.)
    NSString *badGroup = MirageFirstMisplacedGroup(code);
    if (badGroup.length)
      return [NSString
          stringWithFormat:RLoc(@"`#%@` can't set a group: audio and gradients "
                                @"have their own",
                                @"Mirage group-on-dedicated-directive "
                                @"validation error."),
                           badGroup];
    MirageAudioWaveformErrorKind waveformKind = MirageAudioWaveformErrorValue;
    NSString *badWaveform =
        MirageFirstInvalidAudioWaveform(code, &waveformKind);
    if (badWaveform.length) {
      if (waveformKind == MirageAudioWaveformErrorRange)
        return [NSString
            stringWithFormat:RLoc(@"waveform must contain 4 to %d samples",
                                  @"Mirage audio waveform sample-count error."),
                             KK_SHADER_MAX_AUDIO_WAVE_SAMPLES];
      if (waveformKind == MirageAudioWaveformErrorWindowWithoutWaveform)
        return RLoc(@"wavewindow requires waveform=<samples>",
                    @"Mirage audio waveform-window dependency error.");
      if (waveformKind == MirageAudioWaveformErrorWindowValue)
        return RLoc(@"wavewindow must be a number of seconds",
                    @"Mirage audio waveform-window value error.");
      if (waveformKind == MirageAudioWaveformErrorWindowRange)
        return [NSString
            stringWithFormat:RLoc(@"wavewindow must be between %.3f and %.2f "
                                  @"seconds",
                                  @"Mirage audio waveform-window range error."),
                             kMirageAudioWaveformWindowMinSec,
                             kMirageAudioWaveformWindowMaxSec];
      return RLoc(@"waveform must be an integer sample count, for example "
                  @"waveform=128",
                  @"Mirage audio waveform value error.");
    }
    // A `group=` icon macOS doesn't know. Harmless to the render, but it draws
    // a blank placeholder, so the author sees a group with no icon and no
    // reason why.
    NSString *badSymbol = MirageUnknownGroupSymbol(code);
    if (badSymbol.length)
      return [NSString
          stringWithFormat:RLoc(@"\"%@\" isn't an SF Symbol on this Mac - "
                                @"check the name in the SF Symbols app",
                                @"Mirage unknown group-icon validation error."),
                           badSymbol];
    // More controls than there's room for - they'd otherwise just not appear.
    if (MirageHasTooManyControls(code))
      return [NSString
          stringWithFormat:RLoc(@"Too many controls: %d is the limit",
                                @"Mirage control-count validation error."),
                           KK_SHADER_MAX_SCALAR_PROPS];
    // More than 4 `fields={}` on a #multi: a vec4 is as wide as a uniform
    // gets, so the extras have nowhere to go.
    if (MirageFirstOverlongMulti(code).length)
      return RLoc(@"`#multi` takes at most 4 fields - split it into two "
                  @"controls",
                  @"Mirage too-many-multi-fields validation error.");
    // A `#bool` default written as a word that names neither state. It used to
    // read as off, so the control disagreed with the line declaring it and
    // nothing said why.
    NSString *badBoolDefault = MirageFirstInvalidBoolDefault(code);
    if (badBoolDefault)
      return [NSString
          stringWithFormat:RLoc(@"`#bool` default=%@ isn't on or off - write "
                                @"true/false, yes/no, on/off, or 1/0",
                                @"Mirage bool-default validation error."),
                           badBoolDefault];
    MirageMultipleChoiceErrorKind multipleKind = MirageMultipleChoiceErrorType;
    NSString *badMultiple =
        MirageFirstInvalidMultipleChoice(code, &multipleKind);
    if (badMultiple.length) {
      if (multipleKind == MirageMultipleChoiceErrorType)
        return RLoc(@"`multiple` only works on a `#choice` control",
                    @"Mirage multiple-choice type validation error.");
      if (multipleKind == MirageMultipleChoiceErrorDropdown)
        return RLoc(@"A multiple `#choice` must also use `dropdown`",
                    @"Mirage multiple-choice dropdown validation error.");
      if (multipleKind == MirageMultipleChoiceErrorOptions)
        return RLoc(@"A multiple `#choice` needs a non-empty options list",
                    @"Mirage multiple-choice options validation error.");
      if (multipleKind == MirageMultipleChoiceErrorTooManyOptions)
        return [NSString
            stringWithFormat:RLoc(@"A multiple `#choice` takes at most %d "
                                  @"options",
                                  @"Mirage multiple-choice count validation "
                                  @"error."),
                             KK_SHADER_MAX_MULTIPLE_CHOICE_OPTIONS];
      return [NSString
          stringWithFormat:RLoc(@"Multiple-choice default \"%@\" isn't in its "
                                @"options list",
                                @"Mirage multiple-choice default validation "
                                @"error."),
                           badMultiple];
    }
    int dynamicMaxKind = MirageDynamicMaxErrorPair;
    NSString *badDynamicMax =
        MirageFirstInvalidDynamicMax(code, &dynamicMaxKind);
    if (badDynamicMax.length) {
      if (dynamicMaxKind == MirageDynamicMaxErrorType)
        return [NSString
            stringWithFormat:RLoc(@"Control \"%@\": maxby/maxvalues only work "
                                  @"on float, percent or int controls",
                                  @"Mirage reactive-max type error."),
                             badDynamicMax];
      if (dynamicMaxKind == MirageDynamicMaxErrorController)
        return [NSString
            stringWithFormat:RLoc(@"maxby references unknown control \"%@\"",
                                  @"Mirage reactive-max controller error."),
                             badDynamicMax];
      if (dynamicMaxKind == MirageDynamicMaxErrorTooManyValues)
        return [NSString
            stringWithFormat:RLoc(@"maxvalues takes at most %d values",
                                  @"Mirage reactive-max value-count error."),
                             KK_SHADER_MAX_DYNAMIC_MAX_VALUES];
      if (dynamicMaxKind == MirageDynamicMaxErrorValues)
        return RLoc(@"maxvalues must be a non-empty comma-separated list of "
                    @"numbers",
                    @"Mirage reactive-max malformed-values error.");
      return [NSString
          stringWithFormat:RLoc(@"Control \"%@\": maxby and maxvalues must be "
                                @"used together",
                                @"Mirage reactive-max pair error."),
                           badDynamicMax];
    }
    int visibilityKind = MirageVisibilityErrorPair;
    NSString *badVisibility =
        MirageFirstInvalidVisibility(code, &visibilityKind);
    if (badVisibility.length) {
      if (visibilityKind == MirageVisibilityErrorController)
        return [NSString
            stringWithFormat:RLoc(
                                 @"visibleby references unknown control \"%@\"",
                                 @"Mirage conditional-visibility controller "
                                 @"error."),
                             badVisibility];
      if (visibilityKind == MirageVisibilityErrorTooManyValues)
        return [NSString
            stringWithFormat:RLoc(@"visiblevalues takes at most %d values",
                                  @"Mirage conditional-visibility value-count "
                                  @"error."),
                             KK_SHADER_MAX_VISIBILITY_VALUES];
      if (visibilityKind == MirageVisibilityErrorValues)
        return RLoc(@"visiblevalues must be a non-empty comma-separated list "
                    @"of numbers",
                    @"Mirage conditional-visibility malformed-values error.");
      return [NSString
          stringWithFormat:RLoc(@"Control \"%@\": visibleby and visiblevalues "
                                @"must be used together",
                                @"Mirage conditional-visibility pair error."),
                           badVisibility];
    }
    // An OSC opt-in on an incompatible uniform: osc=point needs a vec2, a
    // radial OSC (osc=ring / osc=box) needs a float/int slider or a vec2
    // #multi, a rotate osc={..} needs one distinct x/y/z axis per value
    // component (a radial extent / rotation has no meaning on anything else).
    int badKind = MirageOSCErrorPoint;
    NSString *badOSC = MirageFirstInvalidOSC(code, &badKind);
    if (badOSC.length) {
      NSString *fmt;
      if (badKind == MirageOSCErrorRadial)
        fmt =
            RLoc(@"Control \"%@\": osc=ring / osc=box needs a float, percent, "
                 @"int, or 2-field (vec2) #multi uniform",
                 @"Mirage radial-OSC type error.");
      else if (badKind == MirageOSCErrorRotate)
        fmt =
            RLoc(@"Control \"%@\": osc={..} needs one x/y/z axis per value: a "
                 @"#angle float, or a vec2/vec3 #multi with a matching axis "
                 @"count",
                 @"Mirage rotate-OSC type error.");
      else
        fmt = RLoc(@"Control \"%@\": osc=point needs a vec2 uniform",
                   @"Mirage point-OSC type error.");
      return [NSString stringWithFormat:fmt, badOSC];
    }
    // FEEDBACK + accumulate is a SILENT no-op: accumulate re-renders the image
    // pass at N sub-frame times, and a feedback buffer's state is a function of
    // history so it cannot be re-simulated per sub-sample - the plugin renders
    // once and the Motion Blur slider does nothing at all. No error, no blur,
    // just a dead control. Say so, and name the declarations that resolve it.
    //
    // A NON-feedback chain is fine and takes the fast path: its buffers are a
    // pure function of the current uniforms, so they are encoded ONCE and every
    // sub-sample reads them, and only the image pass re-runs. That is what lets
    // an expensive precompute (a source blur, say) sit in a buffer instead of
    // being recomputed inside every sample.
    if (activeIsImage && sawFeedbackBuffer &&
        MirageMotionBlurModeForSource(code) == MirageMotionBlurModeAccumulate)
      return RLoc(@"Feedback shaders can't use the default motion blur - add "
                  @"`// #motionblur native` to blur it yourself, or `// "
                  @"#motionblur off` to hide the control",
                  @"Mirage feedback motion-blur validation error.");
    KKGLSLTranspileResult *r = KKTranspileGLSL(code);
    if (r.msl)
      return nil; // compiled clean
    NSString *msg = nil;
    NSInteger line = 0;
    [r firstError:&msg line:&line];
    if (outLine)
      *outLine = line;
    if (!msg.length)
      return RLoc(@"Shader failed to compile",
                  @"Custom shader fallback error.");
    return line > 0
               ? [NSString stringWithFormat:RLoc(@"Line %ld: %@",
                                                 @"Mirage error with line."),
                                            (long)line, msg]
               : msg;
  };
  // Format button: reformat the section to the house style (astyle, the
  // SPIRV-Cross .clang-format translated). Pure and self-contained; leaves the
  // text unchanged if astyle errors.
  shader.codeFormatter = ^NSString *(NSString *code) {
    // astyle the GLSL, then align the `//` directive blocks on top.
    return MirageTidyDirectives(KKFormatGLSL(code));
  };
  // Copy Schema button: the directive reference (from the same AIKnowledge
  // markdown the built-in AI reads) on the clipboard, for authoring a template
  // with an outside assistant. Option-click hands `sections` in, and the
  // shader's own tabs are appended under a marked heading.
  shader.codeSchemaProvider =
      ^NSString *(NSArray<NSDictionary<NSString *, NSString *> *> *sections) {
        NSBundle *bundle = [NSBundle bundleForClass:[MiragePlugin class]];
        return MirageSchemaDocument(MirageSchemaReferenceURLInBundle(bundle),
                                    sections);
      };
  // Context-aware autocomplete: `//` directive kinds + attributes + `@osc`
  // fields/values + GLSL builtins + this shader's declared uniforms.
  shader.codeCompletionProvider =
      ^NSArray<NSDictionary<NSString *, NSString *> *> *(
          NSString *text, NSUInteger caret, NSRange *outReplace) {
    return MirageDirectiveCompletions(text, caret, outReplace);
  };
  // The value words the editor paints as keywords in `//` directive / `@osc`
  // comments (osc kinds, booleans, bare flags like skipsnapping).
  shader.codeDirectiveKeywords = MirageDirectiveValueKeywords();
  // The valid directive-header tokens so the highlighter greens only real
  // directives (`// #alpha`), not a half-typed `// #alp`.
  shader.codeDirectiveKinds = MirageDirectiveKindTokens();
  [lanes addObject:shader];

  // Dynamic colour group parsed from the shader's `// #color` directive, then
  // its `// #gradient` ramps in the same group.
  MirageAppendColorLanes(lanes, shaderSource);
  MirageAppendGradientLanes(lanes, shaderSource);

  // Every control inside a `// #slots` block built above is a prototype. Turn
  // each one into the instances this project actually has, before the grouping
  // pass - so the stamped rows are bucketed by their own group like any other
  // lane. A build with no timeline keeps the prototypes (see MirageStampSlot-
  // Lanes), and a source with no block never enters it at all.
  MirageStampSlotLanesForRackEntry(lanes, shaderSource, timeline, entryID);

  // Group order: the three groups that are not the shader's to name lead, in a
  // fixed order, then the shader's own groups in the order it declares them.
  // Groups are otherwise discovered first-seen from this array, which would
  // shuffle Colours and Audio around as directives were edited above them.
  // Bucketing rather than sorting keeps each group's rows in build order.
  NSMutableArray<NSString *> *order =
      [@[ kMirageShaderCategory, kMirageAudioCategory, kMirageColorCategory ]
          mutableCopy];
  for (KKLane *l in lanes)
    if (l.categoryKey.length && ![order containsObject:l.categoryKey])
      [order addObject:l.categoryKey];
  NSMutableArray<KKLane *> *ordered =
      [NSMutableArray arrayWithCapacity:lanes.count];
  for (NSString *cat in order)
    for (KKLane *l in lanes)
      if ([l.categoryKey isEqualToString:cat])
        [ordered addObject:l];
  for (KKLane *l in lanes)
    if (!l.categoryKey.length) // uncategorised (if any) sit at the end
      [ordered addObject:l];

  // One icon per group. Lanes in the same group can disagree about it - a
  // `group={"Motion", "wind"}` on one directive and a bare `group={"Motion"}`
  // on the next - and the header shows whichever lane it happens to read, so
  // the icon looked like it ignored the declaration. First lane that names a
  // symbol of its own wins for the whole group.
  NSMutableDictionary<NSString *, NSString *> *groupSymbols =
      [NSMutableDictionary dictionary];
  for (KKLane *l in ordered) {
    if (!l.categoryKey.length || !l.categorySymbol.length)
      continue;
    if ([l.categorySymbol isEqualToString:kMirageDefaultGroupSymbol])
      continue; // the fallback isn't a declaration, so it can't win
    if (!groupSymbols[l.categoryKey])
      groupSymbols[l.categoryKey] = l.categorySymbol;
  }
  for (KKLane *l in ordered) {
    NSString *sym = l.categoryKey.length ? groupSymbols[l.categoryKey] : nil;
    if (sym.length)
      l.categorySymbol = sym;
  }

  return ordered;
}

// The unracked spelling: one source, the sentinel entry's bare keys. What every
// caller answering "what does this source offer, against this project" has
// always asked for.
static inline NSArray<KKLane *> *
MirageBuildAvailableLanesForSourceStamped(NSString *shaderSource,
                                          NSDictionary<NSString *, id> *tickets,
                                          KKTimeline *timeline) {
  return MirageBuildAvailableLanesForRackEntry(shaderSource, tickets, timeline,
                                               kMirageRackSentinelEntryID);
}

// Prototypes-only entry: what a piece of GLSL DECLARES, with every `#slots`
// block left as the one prototype set it is written as. For every caller
// answering a question about the source rather than about a project - the
// editor's validator, the autocomplete, the OSC block sync.
static inline NSArray<KKLane *> *
MirageBuildAvailableLanesForSource(NSString *shaderSource,
                                   NSDictionary<NSString *, id> *tickets) {
  return MirageBuildAvailableLanesForSourceStamped(shaderSource, tickets, nil);
}

// Back-compat entry: the default-shader lane set. Source-specific dynamic lanes
// only appear when the default shader itself declares a directive.
static inline NSArray<KKLane *> *MirageBuildAvailableLanes(void) {
  return MirageBuildAvailableLanesForSource(MirageCustomDefaultShaderSource(),
                                            nil);
}

// Rewrite every key field of one entry's lane into the rack's namespace.
//
// The full set, mirroring MirageSlotStampedLane's: the lane's own `key`, its
// keypose-popover scope (`groupKey`), its palette group, and the three
// visibility gates plus the reactive-max controller - every field on KKLane
// whose value is another lane's key. `linkExpression` is deliberately NOT here:
// it is the user's, not the build's, and it names lanes across plugins.
//
// Unconditional within the entry, unlike the slot stamping's sibling test: an
// entry's lanes are built from one source and every key they name belongs to
// that same source, so a gate pointing at a lane this build did not produce
// (`visibleWhenKey = @"Type"`, which no longer exists) is absent before the
// rewrite and absent after it - and an absent controller can't gate.
static inline void MirageRackScopeLaneKeys(KKLane *lane, NSString *entryID) {
  lane.key = MirageRackLaneKey(entryID, lane.key);
  if (lane.groupKey.length)
    lane.groupKey = MirageRackLaneKey(entryID, lane.groupKey);
  if (lane.paletteGroup.length)
    lane.paletteGroup = MirageRackLaneKey(entryID, lane.paletteGroup);
  if (lane.visibleWhenKey.length)
    lane.visibleWhenKey = MirageRackLaneKey(entryID, lane.visibleWhenKey);
  if (lane.visibleWhenOrKey.length)
    lane.visibleWhenOrKey = MirageRackLaneKey(entryID, lane.visibleWhenOrKey);
  if (lane.visibleWhenAndKey.length)
    lane.visibleWhenAndKey = MirageRackLaneKey(entryID, lane.visibleWhenAndKey);
  if (lane.maxControllerKey.length)
    lane.maxControllerKey = MirageRackLaneKey(entryID, lane.maxControllerKey);
}

// One entry's on/off lane. New with the rack, so it is prefixed for every entry
// including the sentinel (MirageRackEnabledLaneKey's note), and animatable -
// switching an entry out mid-clip is a cut, and a cut is a keyframe.
static inline KKLane *MirageRackEnabledLane(NSString *entryID) {
  KKLane *lane =
      [KKLane laneWithKey:MirageRackEnabledLaneKey(entryID)
                    label:RLoc(@"Enabled", @"Mirage rack entry on/off lane.")];
  lane.valueType = KKLaneValueTypeFloat;
  lane.isToggle = YES;
  lane.integerValued = YES;
  lane.animatable = YES;
  lane.enabled = NO;
  lane.componentMin = @[ @0.0 ];
  lane.componentMax = @[ @1.0 ];
  lane.groupKey = lane.key;
  // With the code lane, at the head of the entry: the two rows that are about
  // the ENTRY rather than about anything the shader declared. The category is
  // the BARE name for every entry - see the note in
  // MirageBuildAvailableLanesForRack on why it is never rack-scoped.
  lane.categoryKey = (NSString *)kMirageShaderCategory;
  lane.categorySymbol = @"chevron.left.forwardslash.chevron.right";
  [lane insertKeypose:[KKKeyPose
                          keyposeAtTime:0.0
                                 values:@[
                                   @(MirageRackEntryEnabledDefault ? 1.0 : 0.0)
                                 ]]];
  return lane;
}

// The whole rack's lane set: every entry's lanes, in rack order, each entry's
// keys scoped to it.
//
// PROVABLY INERT for a project that has never been racked. Its entry list is
// the synthesized `@[sentinel]`, and every transform below is a no-op on the
// sentinel by construction - `MirageRackLaneKey` passes its key through, the
// category is not prefixed, and the layer/Enabled additions are gated on the
// registry being explicitly present. So the array is the one
// `MirageBuildAvailableLanesForSourceStamped` returned before the rack existed,
// element for element and field for field (asserted in the harness, not just
// claimed here).
//
// `overrideSource` is ONE entry's source when non-empty - mid-edit code from
// the editor, which has not been committed to a code lane yet - while every
// other entry contributes from its own stored code. `overrideEntryID` says
// which entry it belongs to: the rack strip's selected entry, since that is
// the entry the code editor is bound to. Empty/nil means the sentinel, which
// is both the pre-selection answer and the only entry an unracked project has.
static inline NSArray<KKLane *> *MirageBuildAvailableLanesForRack(
    KKTimeline *timeline, NSDictionary<NSString *, id> *tickets,
    NSString *overrideSource, NSString *overrideEntryID) {
  NSString *overrideOwner =
      overrideEntryID.length ? overrideEntryID : kMirageRackSentinelEntryID;
  NSArray<NSString *> *entryIDs = MirageRackEntryIDs(timeline);
  // Explicitly racked, as against the implied single entry a pre-rack project
  // carries. The gate on everything the rack ADDS to a lane set, so a legacy
  // project gains no lane and no layer level it never had.
  BOOL racked =
      KKTimelineSlotInstanceIDs(timeline, kMirageRackGroupName).count > 0;

  NSString *fallbackName =
      RLoc(@"Shader", @"Generic GLSL code lane display "
                      @"name (the code editor's caption).");
  NSMutableArray<NSString *> *names =
      [NSMutableArray arrayWithCapacity:entryIDs.count];
  for (NSString *entryID in entryIDs)
    [names addObject:MirageRackEntryDisplayName(timeline, entryID,
                                                kMirageCodeLaneLabel,
                                                fallbackName)];
  NSArray<NSString *> *displayNames = MirageRackDedupedDisplayNames(names);

  NSMutableArray<KKLane *> *out = [NSMutableArray array];
  for (NSUInteger i = 0; i < entryIDs.count; i++) {
    NSString *entryID = entryIDs[i];
    BOOL sentinel = [entryID isEqualToString:kMirageRackSentinelEntryID];
    NSString *stored =
        MirageRackCodeLaneForEntry(timeline, entryID, kMirageCodeLaneLabel)
            .codeString;
    NSString *source =
        (overrideSource.length && [entryID isEqualToString:overrideOwner])
            ? overrideSource
            : stored;
    NSArray<KKLane *> *entryLanes = MirageBuildAvailableLanesForRackEntry(
        source.length ? source : MirageCustomDefaultShaderSource(), tickets,
        timeline, entryID);
    NSMutableArray<KKLane *> *ofEntry = [NSMutableArray array];
    // The Enabled lane's key is minted in the rack's namespace already, so it
    // joins AFTER the scoping pass, not before it.
    // `categoryKey` is deliberately NOT scoped. Unlike every field
    // MirageRackScopeLaneKeys rewrites, it is not another lane's key - it is a
    // group NAME the user reads, on the Advanced view's category header and on
    // the constants popover's category pill, and a scoped one showed there
    // verbatim as "~Rack#7f3a01.Options". Per-entry collapse independence -
    // the one thing scoping bought - is already provided by the kit, which
    // scopes a category's collapse identity by its owning layer
    // (-_categoryCollapseKeyForLayer:category:), and the layer IS the entry.
    if (!sentinel)
      for (KKLane *lane in entryLanes)
        MirageRackScopeLaneKeys(lane, entryID);
    if (racked)
      [ofEntry addObject:MirageRackEnabledLane(entryID)];
    [ofEntry addObjectsFromArray:entryLanes];
    if (racked)
      for (KKLane *lane in ofEntry) {
        lane.layerKey = entryID;
        lane.layerLabel = displayNames[i];
      }
    [out addObjectsFromArray:ofEntry];
  }
  return out;
}

/// The prototype lanes of one `#slots` group, in build order.
///
/// What the panel hands the kit to stamp a new instance from. Derived from the
/// prototypes-only lane set rather than from a second parse of the source, so
/// an instance is by construction a copy of exactly the lanes the group would
/// have built - defaults, bounds, units and all.
static inline NSArray<KKLane *> *
MirageSlotPrototypeLanesForGroup(NSString *shaderSource, NSString *groupName,
                                 NSDictionary<NSString *, id> *tickets) {
  NSMutableArray<KKLane *> *out = [NSMutableArray array];
  if (!shaderSource.length || !groupName.length)
    return out;
  NSArray<NSValue *> *groups =
      MirageSlotGroupsForSource(shaderSource, NULL, NULL);
  NSInteger wanted = -1;
  for (NSUInteger i = 0; i < groups.count; i++)
    if ([@(MirageSlotsGroupValue(groups[i]).name) isEqualToString:groupName])
      wanted = (NSInteger)i;
  if (wanted < 0)
    return out;
  NSDictionary<NSString *, NSNumber *> *byUniform =
      MirageSlotGroupIndexByUniform(shaderSource);
  for (KKLane *lane in MirageBuildAvailableLanesForSource(shaderSource,
                                                          tickets)) {
    NSNumber *owner = MirageSlotGroupIndexForLaneKey(lane.key, byUniform, NULL);
    if (owner && owner.integerValue == wanted)
      [out addObject:lane];
  }
  return out;
}
