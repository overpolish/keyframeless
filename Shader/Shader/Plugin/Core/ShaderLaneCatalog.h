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

static inline KKLane *ShaderMakeColorLane(NSString *label, NSString *group,
                                          const float *rgba) {
  KKLane *color = [KKLane laneWithLabel:label];
  color.valueType = KKLaneValueTypeColor;
  color.componentMin = @[ @0.0, @0.0, @0.0, @0.0 ];
  color.componentMax = @[ @1.0, @1.0, @1.0, @1.0 ];
  color.animatable = YES;
  color.enabled = NO;
  color.paletteLockable = YES; // every colour joins the palette generator
  color.paletteGroup = group;  // ...but each property rerolls independently
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
    NSString *label = @(p->label);
    if (!p->isArray) {
      // A single named colour - its own one-colour journey, distinct hue.
      [lanes addObject:ShaderMakeColorLane(label, label, pal[pi % 10])];
      continue;
    }
    // An array: count lane + N swatches (the shared bar above rerolls them).
    NSString *countLabel = [NSString stringWithFormat:@"%@ Count", label];
    KKLane *count = [KKLane laneWithLabel:countLabel];
    count.animatable = NO;
    count.enabled = NO;
    count.integerValued = YES;
    count.scrubStep = 1.0;
    count.componentMin = @[ @(p->minCount) ];
    count.componentMax = @[ @(p->maxCount) ]; // field up to the directive max
    count.sliderMax = @(MIN((NSInteger)p->maxCount, kSliderCap));
    count.categoryKey = @"Colors";
    count.categorySymbol = @"paintpalette";
    [count insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                           values:@[ @(p->defaultCount) ]]];
    [lanes addObject:count];

    for (int i = 0; i < p->maxCount; i++) {
      NSInteger n = i + 1;
      KKLane *color = ShaderMakeColorLane(
          [NSString stringWithFormat:@"%@ %ld", label, (long)n], label,
          pal[i % 10]);
      // "count >= n" via the absolute ceiling, so a swatch still reveals when
      // the stored count is transiently above a just-lowered max.
      color.visibleWhenLabel = countLabel;
      color.visibleWhenValues = ShaderCountAtLeast(n, KK_SHADER_MAX_COLORS);
      [lanes addObject:color];
    }
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
