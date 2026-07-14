/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// The Shader generator's lane catalog (Type pill + shared Core lanes + every
// Type's Shader lanes + the colour swatches). Extracted from Plugin+CustomUI.m
// (which just returns ShaderBuildAvailableLanes()). One function, cohesive.
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKTimingStage.h>

#import "Constants.h"        // ShaderCustomDefaultShaderSource
#import "KKGLSLFormatter.h"  // Format button (XPC-only includers)
#import "KKGLSLTranspiler.h" // live shader validation (XPC-only includers)
#import "ShaderColorSpace.h"
#import "ShaderLocalized.h" // RLoc

// --- Dynamic colour lanes ------------------------------------------------
// A shader declares colour properties by annotating standalone uniforms:
//     // #color                            uniform vec4 uBackground;
//     // #color label="Accent"             uniform vec4 uForeground;
//     // #color min=1 max=10 default=4      uniform vec4 uPalette[10];
// Each single-vec4 property is one colour lane; each array is a palette bar + a
// "<Label> Count" lane + "<Label> N" swatches. The kit palette machinery drives
// the arrays via paletteGeneratorBar / paletteLockable.

// NSNumbers n..maxCount, for a "<Label> Count >= n" visibility gate.
static inline NSArray<NSNumber *> *ShaderCountAtLeast(NSInteger n,
                                                      NSInteger maxCount) {
  NSMutableArray<NSNumber *> *out = [NSMutableArray array];
  for (NSInteger c = n; c <= maxCount; c++)
    [out addObject:@(c)];
  return out;
}

static inline KKLane *ShaderMakeColorLane(NSString *idLabel,
                                          NSString *displayLabel,
                                          NSString *group, const float *rgba) {
  KKLane *color = [KKLane laneWithLabel:idLabel];
  color.displayLabel = displayLabel;
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
  color.categoryKey = @"Colors";
  color.categorySymbol = @"paintpalette";
  [color insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                         values:@[
                                           @(rgba[0]), @(rgba[1]), @(rgba[2]),
                                           @(rgba[3])
                                         ]]];
  return color;
}

// Append one lane group per `// #color` property the shader declares, under a
// single shared palette-generator bar (rerolls EVERY colour lane - both arrays'
// swatches and the single colours - since all are paletteLockable).
static inline void ShaderAppendColorLanes(NSMutableArray<KKLane *> *lanes,
                                          NSString *source) {
  const float (*pal)[4] = kShaderDefaultPalette;
  const NSInteger kSliderCap =
      10; // slider tops out here; the field goes higher
  ShaderColorProp props[KK_SHADER_MAX_COLOR_PROPS];
  int poolCount = 0;
  int nProps = ShaderParseColorProps(source, props, KK_SHADER_MAX_COLOR_PROPS,
                                     &poolCount);
  if (nProps == 0)
    return;
  // One palette-generator bar for the whole Colours group.
  KKLane *bar = [KKLane laneWithLabel:@"Palette"];
  bar.paletteGeneratorBar = YES;
  bar.animatable = NO;
  bar.enabled = NO;
  bar.categoryKey = @"Colors";
  bar.categorySymbol = @"paintpalette";
  [lanes addObject:bar];

  for (int pi = 0; pi < nProps; pi++) {
    ShaderColorProp *p = &props[pi];
    // Identity = the uniform name (+ " N"/" Count" for arrays); display = the
    // label. The palette group is the uniform name so it stays stable too.
    NSString *name = @(p->name);
    NSString *label = @(p->label);
    if (!p->isArray) {
      // A single named colour - its own one-colour journey, distinct hue.
      [lanes addObject:ShaderMakeColorLane(name, label, name, pal[pi % 10])];
      continue;
    }
    // An array: count lane + N swatches (the shared bar above rerolls them).
    NSString *countId = [NSString stringWithFormat:@"%@ Count", name];
    KKLane *count = [KKLane laneWithLabel:countId];
    count.displayLabel = [NSString stringWithFormat:@"%@ Count", label];
    count.animatable = NO;
    count.enabled = NO;
    count.integerValued = YES;
    count.scrubStep = 1.0;
    count.componentMin = @[ @(p->minCount) ];
    count.componentMax = @[ @(p->maxCount) ]; // field up to the directive max
    count.sliderMax = @(MIN((NSInteger)p->maxCount, kSliderCap));
    count.groupKey = name; // joins its array's keypose-popover group
    count.categoryKey = @"Colors";
    count.categorySymbol = @"paintpalette";
    [count insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                           values:@[ @(p->defaultCount) ]]];
    [lanes addObject:count];

    for (int i = 0; i < p->maxCount; i++) {
      NSInteger n = i + 1;
      KKLane *color = ShaderMakeColorLane(
          [NSString stringWithFormat:@"%@ %ld", name, (long)n],
          [NSString stringWithFormat:@"%@ %ld", label, (long)n], name,
          pal[i % 10]);
      // "count >= n" via the absolute ceiling, so a swatch still reveals when
      // the stored count is transiently above a just-lowered max.
      color.visibleWhenLabel = countId;
      color.visibleWhenValues = ShaderCountAtLeast(n, KK_SHADER_MAX_COLORS);
      [lanes addObject:color];
    }
  }
}

// Append the shader's `// #float` (slider) and `// #choice` (int pill) props as
// lanes in their own "Shader" params group (distinct from Core and Colours). A
// float lane is an animatable slider bounded by min/max; a choice lane is a
// structural (non-animatable, integer) radio pill from options=. Value flows to
// the shader via the pool tail (ShaderFillScalarPool), same as colours.
static inline void ShaderAppendScalarLanes(NSMutableArray<KKLane *> *lanes,
                                           NSString *source) {
  ShaderScalarProp props[KK_SHADER_MAX_SCALAR_PROPS];
  int used = 0;
  int nProps = ShaderParseScalarProps(source, props, KK_SHADER_MAX_SCALAR_PROPS,
                                      0, &used);
  for (int pi = 0; pi < nProps; pi++) {
    ShaderScalarProp *p = &props[pi];
    // Identity = the GLSL uniform name (stable across rename/reorder); the
    // label is display-only. So the value/keyframes follow the uniform, not the
    // label.
    KKLane *lane = [KKLane laneWithLabel:@(p->name)];
    lane.displayLabel = @(p->label);
    lane.valueType = KKLaneValueTypeFloat;
    lane.enabled = NO;
    // Each scalar/point is independent: its own keypose-popover group, so a
    // point OSC's keypose popover doesn't list every other shader uniform.
    lane.groupKey = @(p->name);
    lane.categoryKey = @"Shader";
    lane.categorySymbol = @"slider.horizontal.3";
    if (p->isChoice) {
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
      lane.componentMin = @[ @0.0 ];
      lane.componentMax = @[ @(opts.count ? (NSInteger)opts.count - 1 : 0) ];
      [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                            values:@[ @(p->cdefault) ]]];
    } else if (p->isSeed) {
      lane.seedField = YES; // dice reroll
      lane.integerValued = YES;
      lane.animatable = NO; // structural like the core Seed
      lane.scrubStep = 1.0;
      lane.componentMin = @[ @(p->fmin) ];
      lane.componentMax = @[ @(p->fmax) ];
      [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                            values:@[ @(p->fdefault) ]]];
    } else if (p->isPoint) {
      lane.animatable = YES;
      // Allowed off-scene (negative / past full res), so no min/max - empty =
      // unconstrained, the same as Position in Canvas/MagicMove.
      lane.componentMin = @[];
      lane.componentMax = @[];
      lane.componentUnits = @[ @"px", @"px" ];
      lane.componentLabels = @[ @"X", @"Y" ];
      // Stored normalized 0..1, displayed as pixels (X * media width, Y * media
      // height) - the same as Position/Anchor in Canvas/MagicMove.
      lane.componentsScaleWithMedia = YES;
      [lane insertKeypose:[KKKeyPose
                              keyposeAtTime:0.0
                                     values:@[ @(p->pdefx), @(p->pdefy) ]]];
    } else if (p->isBool) {
      lane.isToggle = YES;
      lane.integerValued = YES;
      lane.animatable = NO; // structural on/off
      lane.componentMin = @[ @0.0 ];
      lane.componentMax = @[ @1.0 ];
      [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                            values:@[ @(p->fdefault) ]]];
    } else if (p->isAngle) {
      lane.valueType = KKLaneValueTypeAngle; // circular knob, degrees
      lane.animatable = YES;
      // Unconstrained (accumulates past 360), like MagicMove's Rotation.
      lane.componentMin = @[];
      lane.componentMax = @[];
      [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                            values:@[ @(p->fdefault) ]]];
    } else {
      lane.animatable = YES;
      lane.componentMin = @[ @(p->fmin) ];
      if (p->hasMax) {
        lane.componentMax = @[ @(p->fmax) ]; // field + slider cap at max
      } else {
        // No max=: the field is unbounded (large cap so line-625 clamp is a
        // no-op in practice) while the slider keeps the nominal range.
        lane.componentMax = @[ @1000000.0 ];
        lane.sliderMax = @(p->fmax);
      }
      if (p->isPercent) {
        // Match the canonical percentage lane (opacityLane): whole-number %
        // with a "%" unit, not a raw decimal float.
        lane.componentUnits = @[ @"%" ];
        lane.integerValued = YES;
      }
      if (p->isInt) {
        lane.integerValued = YES; // whole-number slider
        lane.scrubStep = 1.0;
      }
      [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                            values:@[ @(p->fdefault) ]]];
    }
    [lanes addObject:lane];
  }
}

static inline NSArray<KKLane *> *
ShaderBuildAvailableLanesForSource(NSString *shaderSource) {
  // Lane order (top-to-bottom default): the Core lanes, then the dynamic colour
  // swatches last (parsed from the shader). Users can reorder in the inspector.
  NSMutableArray<KKLane *> *lanes = [NSMutableArray array];

  // The plugin is Custom-only (GLSL). The Type pill and the built-in per-type
  // controls (Colors etc.) are removed for now - the built-in types will return
  // as GLSL community shaders once publish/submit is solid. The render defaults
  // to Custom when the Type lane is absent. Kept lanes below still declare a
  // `visibleWhen Type` gate; with Type absent they simply always show (an
  // absent controller can't gate), so they need no change.

  // Speed: shared motion-rate multiplier.
  KKLane *speed = [KKLane laneWithLabel:@"Speed"];
  speed.valueType = KKLaneValueTypeFloat;
  speed.componentMin = @[ @0.0 ];
  speed.componentMax = @[ @3.0 ];
  speed.animatable = YES;
  speed.enabled = NO;
  speed.categoryKey = @"Core";
  speed.categorySymbol = @"circle.dotted";
  speed.visibleWhenLabel = @"Type";
  speed.visibleWhenValues =
      @[ @0, @1, @2, @3, @4, @5, @6, @7, @8, @9, @10, @11, @12 ]; // + Custom
  [speed insertKeypose:[KKKeyPose
                           keyposeAtTime:0.0
                                  values:@[ @(KK_SHADER_GRAD_DEFAULT_SPEED) ]]];
  [lanes addObject:speed];

  // Seed: shared start-time offset (a "start frame"), non-animatable integer
  // with a dice field. Any value; the slider range is nominal.
  KKLane *seed = [KKLane laneWithLabel:@"Seed"];
  seed.valueType = KKLaneValueTypeFloat;
  seed.seedField = YES;
  seed.integerValued = YES;
  seed.componentMin = @[ @0.0 ];
  seed.componentMax = @[ @1000000.0 ];
  seed.animatable = NO;
  seed.enabled = NO;
  seed.categoryKey = @"Core";
  seed.categorySymbol = @"circle.dotted";
  seed.visibleWhenLabel = @"Type";
  seed.visibleWhenValues =
      @[ @0, @1, @2, @3, @4, @5, @6, @7, @8, @9, @10, @11, @12 ]; // + Custom
  [seed insertKeypose:[KKKeyPose
                          keyposeAtTime:0.0
                                 values:@[ @(KK_SHADER_GRAD_DEFAULT_SEED) ]]];
  [lanes addObject:seed];

  // Grain + Grain Size: the core film-grain overlay, shared by every type. A
  // subtle nonzero default breaks 8-bit banding out of the box and scales up to
  // stylistic grain; applied in the shader epilogue with a per-type multiplier
  // (Grainy reads grainier by default).
  NSArray<NSNumber *> *allTypes = @[
    @0, @1, @2, @3, @4, @5, @6, @7, @8, @9, @10, @11, @12
  ]; // incl. Custom
  struct {
    NSString *label;
    double def, min, max;
    NSString *unit;
    BOOL integer;
  } coreGrain[] = {
      {@"Grain", KK_CORE_GRAIN_DEFAULT * 100.0, 0.0, 100.0, @"%", NO},
      {@"Grain Size", KK_CORE_GRAINSIZE_DEFAULT, 1.0, 12.0, @"px", YES},
  };
  for (unsigned s = 0; s < sizeof(coreGrain) / sizeof(coreGrain[0]); s++) {
    KKLane *lane = [KKLane laneWithLabel:coreGrain[s].label];
    lane.valueType = KKLaneValueTypeFloat;
    lane.componentMin = @[ @(coreGrain[s].min) ];
    lane.componentMax = @[ @(coreGrain[s].max) ];
    lane.componentUnits = @[ coreGrain[s].unit ];
    lane.integerValued = coreGrain[s].integer; // grain size is whole pixels
    lane.animatable = YES;
    lane.enabled = NO;
    lane.categoryKey = @"Core";
    lane.categorySymbol = @"circle.dotted";
    lane.visibleWhenLabel = @"Type";
    lane.visibleWhenValues = allTypes;
    [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                          values:@[ @(coreGrain[s].def) ]]];
    [lanes addObject:lane];
  }

  // Dynamic scalar params (`// #float` sliders, `// #choice` pills) declared by
  // the shader, in their own "Shader" group (distinct from Core).
  ShaderAppendScalarLanes(lanes, shaderSource);

  // Custom shader source: a full-width code editor row at the bottom of Core.
  // Non-animatable; the text lives in the lane's codeString (not a keypose) and
  // flows through the timeline. Seeded with the baked default so the editor
  // opens on something runnable.
  KKLane *shader = [KKLane laneWithLabel:@"Shader"];
  shader.valueType = KKLaneValueTypeCode;
  shader.codeString = ShaderCustomDefaultShaderSource();
  // Multi-pass: the editor starts on the single Image tab (codeString above)
  // and a "+" menu offers these extra sections on demand - Common (shared code
  // prepended to every pass) and Buffer A (an offscreen pass bound to
  // iChannel0). codeTabs stays empty until the user adds one = single-pass by
  // default.
  shader.codeTabCatalog =
      @[ @"Common", @"Buffer A", @"Buffer B", @"Buffer C", @"Buffer D" ];
  shader.codeSavable = YES; // show the save bar (name + Save) under the editor
  shader.animatable = NO;
  shader.enabled = NO;
  shader.categoryKey = @"Core";
  shader.categorySymbol = @"chevron.left.forwardslash.chevron.right";
  // Live validation in the editor: transpile on edit (memoised) and surface the
  // first glslang error as a bar + flagged line. Only compiled into the XPC
  // service (the sole includer of this catalog), where the transpiler is
  // linked.
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
            regularExpressionWithPattern:@"\\bvoid\\s+main\\s*\\("
                                 options:0
                                   error:nil]
            firstMatchInString:code
                       options:0
                         range:NSMakeRange(0, code.length)] != nil;
    if (trimmed.length == 0 || !hasEntry)
      return nil;
    // Two directives sharing a label would collapse into one lane (the label is
    // the identity key), so reject it: the user must give each a unique label.
    NSString *dup = ShaderFirstDuplicateLabel(code);
    if (dup.length)
      return [NSString
          stringWithFormat:RLoc(
                               @"Duplicate control \"%@\": give each directive "
                               @"a unique label",
                               @"Shader duplicate-label validation error."),
                           dup];
    NSString *dupU = ShaderFirstDuplicateUniform(code);
    if (dupU.length)
      return [NSString
          stringWithFormat:RLoc(
                               @"Duplicate uniform \"%@\": give each directive "
                               @"a unique uniform name",
                               @"Shader duplicate-uniform validation error."),
                           dupU];
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
                                                 @"Shader error with line."),
                                            (long)line, msg]
               : msg;
  };
  // Format button: reformat the section to the house style (astyle, the
  // SPIRV-Cross .clang-format translated). Pure and self-contained; leaves the
  // text unchanged if astyle errors.
  shader.codeFormatter = ^NSString *(NSString *code) {
    return KKFormatGLSL(code);
  };
  [lanes addObject:shader];

  // Dynamic colour group parsed from the shader's `// #color` directive.
  ShaderAppendColorLanes(lanes, shaderSource);

  return lanes;
}

// Back-compat entry: the default-shader lane set. Source-specific dynamic lanes
// only appear when the default shader itself declares a directive.
static inline NSArray<KKLane *> *ShaderBuildAvailableLanes(void) {
  return ShaderBuildAvailableLanesForSource(ShaderCustomDefaultShaderSource());
}
