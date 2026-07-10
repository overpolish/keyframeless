/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// The Mesh generator's lane catalog (Type pill + shared Core lanes + every
// Type's Shader lanes + the colour swatches). Extracted from Plugin+CustomUI.m
// (which just returns MeshBuildAvailableLanes()). One function, cohesive.
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKRotationOSC.h>
#import <KeyframelessKit/KKTimingStage.h>

#import "MeshColorSpace.h"

static inline NSArray<KKLane *> *MeshBuildAvailableLanes(void) {
  // Lane order (top-to-bottom default): Type, then this gradient type's
  // options, then the colour swatches last (colours are dynamic - users
  // add/remove them). Users can reorder in the inspector.
  NSMutableArray<KKLane *> *lanes = [NSMutableArray array];

  // Two procedural generator types (both ported from paper-design/shaders,
  // Apache-2.0), selected by the Type pill. Each type's controls + colours gate
  // to its Type index; Speed is shared. Order: Type, shared + per-type controls
  // (Core), then the colours (Colors) last.
  KKLane *type = [KKLane laneWithLabel:@"Type"];
  type.valueType = KKLaneValueTypeFloat;
  type.choiceLabels = @[
    @"Mesh", @"Dithering", @"Grainy", @"Warp", @"Neuro", @"Simplex",
    @"Metaballs", @"God Rays", @"Fluid", @"Wisp", @"Silk", @"Strata"
  ];
  type.componentMin = @[ @0.0 ];
  type.componentMax = @[ @11.0 ];
  type.integerValued = YES;
  type.wrapsChoicePills =
      YES; // 8 types - wrap onto multiple lines, not overflow
  type.animatable = NO;
  type.enabled = NO;
  type.categoryKey = @"Core";
  type.categorySymbol = @"circle.dotted";
  [type insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0.0 ]]];
  [lanes addObject:type];

  // Speed: shared motion-rate multiplier, visible for both types.
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
      @[ @0, @1, @2, @3, @4, @5, @6, @7, @8, @9, @10, @11 ];
  [speed insertKeypose:[KKKeyPose
                           keyposeAtTime:0.0
                                  values:@[ @(KK_MESH_GRAD_DEFAULT_SPEED) ]]];
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
      @[ @0, @1, @2, @3, @4, @5, @6, @7, @8, @9, @10, @11 ];
  [seed insertKeypose:[KKKeyPose
                          keyposeAtTime:0.0
                                 values:@[ @(KK_MESH_GRAD_DEFAULT_SEED) ]]];
  [lanes addObject:seed];

  // Origin: shared field centre, an [X, Y] point (0.5,0.5 = centre, Y up).
  // Moves the pattern; allowed off-frame, so no min/max (empty =
  // unconstrained). Stored 0..1, displayed as pixels (media-scaled), like
  // MagicMove's Position.
  KKLane *origin = [KKLane laneWithLabel:@"Origin"];
  origin.valueType = KKLaneValueTypeGeneric;
  origin.componentLabels = @[ @"X", @"Y" ];
  origin.componentMin = @[];
  origin.componentMax = @[];
  origin.componentUnits = @[ @"px", @"px" ];
  origin.componentsScaleWithMedia = YES;
  origin.spatialCurvable = YES; // 2D path, keyposes can be smooth (curved)
  origin.animatable = YES;
  origin.enabled = NO;
  origin.categoryKey = @"Core";
  origin.categorySymbol = @"circle.dotted";
  [origin insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0.5, @0.5 ]]];
  [lanes addObject:origin];

  // Scale: common zoom, shared by all types, driven by the reusable Scale box
  // OSC (2-axis, aspect-linked like Glow's Radius). Stored as percent per axis
  // (100 = 1x). The slider tops out at 400% but the field accepts larger values
  // (sliderMax decoupled from the value clamp).
  KKLane *scale = [KKLane laneWithLabel:@"Scale"];
  scale.valueType = KKLaneValueTypeFloat;
  scale.componentMin = @[ @1.0, @1.0 ];
  scale.componentMax = @[ @2000.0, @2000.0 ];
  scale.sliderMax = @400.0;
  scale.componentUnits = @[ @"%", @"%" ];
  scale.componentLabels = @[ @"X", @"Y" ];
  scale.aspectLinkable = YES;
  scale.aspectLinked = YES;
  scale.integerValued = YES; // whole percents; the gizmo snaps to integers too
  scale.scrubStep = 1.0;
  scale.animatable = YES;
  scale.enabled = NO;
  scale.categoryKey = @"Core";
  scale.categorySymbol = @"circle.dotted";
  [scale insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                         values:@[ @100.0, @100.0 ]]];
  [lanes addObject:scale];

  // Rotation: common Z rotation, shared by all types, driven by the reusable
  // Z-ring gizmo. The kit factory builds the standard angle-dial lane (NOT a
  // slider) for just the Z axis.
  KKLane *rotation = KKRotationLaneWithLabel(@"Rotation", KKRotationAxisZ);
  rotation.animatable = YES;
  rotation.enabled = NO;
  rotation.categoryKey = @"Core";
  rotation.categorySymbol = @"circle.dotted";
  [lanes addObject:rotation];

  // Grain + Grain Size: the core film-grain overlay, shared by every type. A
  // subtle nonzero default breaks 8-bit banding out of the box and scales up to
  // stylistic grain; applied in the shader epilogue with a per-type multiplier
  // (Grainy reads grainier by default).
  NSArray<NSNumber *> *allTypes =
      @[ @0, @1, @2, @3, @4, @5, @6, @7, @8, @9, @10, @11 ];
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

  // --- Shader Props: each type's own controls (gated by Type). The type-shape
  // pills come first so they head their type's section.

  // Grainy shape field (distinct label from Dithering's "Shape": lanes are
  // keyed by label). 0-based pill; the shader wants 1-based.
  KKLane *pattern = [KKLane laneWithLabel:@"Pattern"];
  pattern.valueType = KKLaneValueTypeFloat;
  pattern.choiceLabels =
      @[ @"Wave", @"Dots", @"Truchet", @"Corners", @"Ripple", @"Blob" ];
  pattern.componentMin = @[ @0.0 ];
  pattern.componentMax = @[ @5.0 ];
  pattern.integerValued = YES;
  pattern.animatable = NO;
  pattern.enabled = NO;
  pattern.categoryKey = @"Shader";
  pattern.categorySymbol = @"slider.horizontal.3";
  pattern.visibleWhenLabel = @"Type";
  pattern.visibleWhenValues = @[ @2 ];
  [pattern insertKeypose:[KKKeyPose
                             keyposeAtTime:0.0
                                    values:@[ @(KK_GRAIN_DEFAULT_SHAPE - 1) ]]];
  [lanes addObject:pattern];

  // Warp base pattern (distinct label from Dithering's "Shape" / Grainy's
  // "Pattern"). 0-based pill, matching the shader's 0..2.
  KKLane *base = [KKLane laneWithLabel:@"Base"];
  base.valueType = KKLaneValueTypeFloat;
  base.choiceLabels = @[ @"Checks", @"Stripes", @"Edge" ];
  base.componentMin = @[ @0.0 ];
  base.componentMax = @[ @2.0 ];
  base.integerValued = YES;
  base.animatable = NO;
  base.enabled = NO;
  base.categoryKey = @"Shader";
  base.categorySymbol = @"slider.horizontal.3";
  base.visibleWhenLabel = @"Type";
  base.visibleWhenValues = @[ @3 ];
  [base insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                        values:@[ @(KK_WARP_DEFAULT_SHAPE) ]]];
  [lanes addObject:base];

  // --- Mesh controls (Type 0). %-units store 0..100 (the shader wants 0..1).
  struct {
    NSString *label;
    double def, min, max;
    NSString *unit; // nil = raw number (no % scaling)
    BOOL animatable;
    BOOL seedField;
  } meshControls[] = {
      {@"Distortion", KK_MESH_GRAD_DEFAULT_DISTORTION * 100.0, 0.0, 100.0, @"%",
       YES, NO},
      {@"Swirl", KK_MESH_GRAD_DEFAULT_SWIRL * 100.0, 0.0, 100.0, @"%", YES, NO},
  };
  for (unsigned s = 0; s < sizeof(meshControls) / sizeof(meshControls[0]);
       s++) {
    KKLane *lane = [KKLane laneWithLabel:meshControls[s].label];
    lane.valueType = KKLaneValueTypeFloat;
    lane.componentMin = @[ @(meshControls[s].min) ];
    lane.componentMax = @[ @(meshControls[s].max) ];
    if (meshControls[s].unit)
      lane.componentUnits = @[ meshControls[s].unit ];
    lane.animatable = meshControls[s].animatable;
    lane.seedField = meshControls[s].seedField;
    lane.integerValued = meshControls[s].seedField; // seed is an integer
    lane.enabled = NO;
    lane.categoryKey = @"Shader";
    lane.categorySymbol = @"slider.horizontal.3";
    lane.visibleWhenLabel = @"Type";
    // Distortion + Swirl are shared with Warp (same 0..1 noise/swirl controls).
    lane.visibleWhenValues = @[ @0, @3 ];
    [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                          values:@[ @(meshControls[s].def) ]]];
    [lanes addObject:lane];
  }

  // --- Dithering controls (Type 1): Shape + Dither are structural choice
  // pills; Pixel Size is the dither grid size in pixels.
  KKLane *shape = [KKLane laneWithLabel:@"Shape"];
  shape.valueType = KKLaneValueTypeFloat;
  shape.choiceLabels =
      @[ @"Simplex", @"Warp", @"Dots", @"Wave", @"Ripple", @"Swirl" ];
  shape.componentMin = @[ @0.0 ];
  shape.componentMax = @[ @5.0 ];
  shape.integerValued = YES;
  shape.animatable = NO;
  shape.enabled = NO;
  shape.categoryKey = @"Shader";
  shape.categorySymbol = @"slider.horizontal.3";
  shape.visibleWhenLabel = @"Type";
  shape.visibleWhenValues = @[ @1 ];
  [shape insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0.0 ]]];
  [lanes addObject:shape];

  KKLane *dither = [KKLane laneWithLabel:@"Dither"];
  dither.valueType = KKLaneValueTypeFloat;
  dither.choiceLabels = @[ @"Random", @"2×2", @"4×4", @"8×8" ];
  dither.componentMin = @[ @0.0 ];
  dither.componentMax = @[ @3.0 ];
  dither.integerValued = YES;
  dither.animatable = NO;
  dither.enabled = NO;
  dither.categoryKey = @"Shader";
  dither.categorySymbol = @"slider.horizontal.3";
  dither.visibleWhenLabel = @"Type";
  dither.visibleWhenValues = @[ @1 ];
  [dither insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @3.0 ]]]; // 8×8
  [lanes addObject:dither];

  KKLane *pxSize = [KKLane laneWithLabel:@"Pixel Size"];
  pxSize.valueType = KKLaneValueTypeFloat;
  pxSize.componentMin = @[ @1.0 ];
  pxSize.componentMax = @[ @20.0 ];
  pxSize.componentUnits = @[ @"px" ];
  pxSize.integerValued = YES;
  pxSize.animatable = YES;
  pxSize.enabled = NO;
  pxSize.categoryKey = @"Shader";
  pxSize.categorySymbol = @"slider.horizontal.3";
  pxSize.visibleWhenLabel = @"Type";
  pxSize.visibleWhenValues = @[ @1 ];
  [pxSize
      insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                      values:@[ @(KK_DITHER_DEFAULT_PXSIZE) ]]];
  [lanes addObject:pxSize];

  // --- Grainy controls (Type 2). %-units store 0..100 (the shader wants 0..1).
  struct {
    NSString *label;
    double def;
  } grainControls[] = {
      {@"Softness", KK_GRAIN_DEFAULT_SOFTNESS * 100.0},
      {@"Intensity", KK_GRAIN_DEFAULT_INTENSITY * 100.0},
      {@"Noise", KK_GRAIN_DEFAULT_NOISE * 100.0},
  };
  for (unsigned s = 0; s < sizeof(grainControls) / sizeof(grainControls[0]);
       s++) {
    KKLane *lane = [KKLane laneWithLabel:grainControls[s].label];
    lane.valueType = KKLaneValueTypeFloat;
    lane.componentMin = @[ @0.0 ];
    lane.componentMax = @[ @100.0 ];
    lane.componentUnits = @[ @"%" ];
    lane.animatable = YES;
    lane.enabled = NO;
    lane.categoryKey = @"Shader";
    lane.categorySymbol = @"slider.horizontal.3";
    lane.visibleWhenLabel = @"Type";
    // Softness is shared with Warp (same 0..1 colour-transition control);
    // Intensity + Noise stay Grainy-only.
    lane.visibleWhenValues =
        [grainControls[s].label isEqualToString:@"Softness"] ? @[ @2, @3, @5 ]
                                                             : @[ @2 ];
    [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                          values:@[ @(grainControls[s].def) ]]];
    [lanes addObject:lane];
  }

  // --- Warp controls (Type 3). Proportion + Shape Scale are %-units (0..100 ->
  // 0..1); Swirl Iterations is an integer count. Distortion / Swirl / Softness
  // are the lanes shared with Mesh / Grainy above.
  struct {
    NSString *label;
    double def, min, max;
    NSString *unit; // nil = raw number
    BOOL integer;
  } warpControls[] = {
      {@"Proportion", KK_WARP_DEFAULT_PROPORTION * 100.0, 0.0, 100.0, @"%", NO},
      {@"Shape Scale", KK_WARP_DEFAULT_SHAPESCALE * 100.0, 0.0, 100.0, @"%",
       NO},
      {@"Swirl Iterations", KK_WARP_DEFAULT_SWIRLITER, 0.0, 20.0, nil, YES},
  };
  for (unsigned s = 0; s < sizeof(warpControls) / sizeof(warpControls[0]);
       s++) {
    KKLane *lane = [KKLane laneWithLabel:warpControls[s].label];
    lane.valueType = KKLaneValueTypeFloat;
    lane.componentMin = @[ @(warpControls[s].min) ];
    lane.componentMax = @[ @(warpControls[s].max) ];
    if (warpControls[s].unit)
      lane.componentUnits = @[ warpControls[s].unit ];
    lane.integerValued = warpControls[s].integer;
    lane.animatable = YES;
    lane.enabled = NO;
    lane.categoryKey = @"Shader";
    lane.categorySymbol = @"slider.horizontal.3";
    lane.visibleWhenLabel = @"Type";
    lane.visibleWhenValues = @[ @3 ];
    [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                          values:@[ @(warpControls[s].def) ]]];
    [lanes addObject:lane];
  }

  // --- Neuro controls (Type 4). %-units store 0..100 (the shader wants 0..1).
  struct {
    NSString *label;
    double def;
  } neuroControls[] = {
      {@"Brightness", KK_NEURO_DEFAULT_BRIGHTNESS * 100.0},
      {@"Contrast", KK_NEURO_DEFAULT_CONTRAST * 100.0},
  };
  for (unsigned s = 0; s < sizeof(neuroControls) / sizeof(neuroControls[0]);
       s++) {
    KKLane *lane = [KKLane laneWithLabel:neuroControls[s].label];
    lane.valueType = KKLaneValueTypeFloat;
    lane.componentMin = @[ @0.0 ];
    lane.componentMax = @[ @100.0 ];
    lane.componentUnits = @[ @"%" ];
    lane.animatable = YES;
    lane.enabled = NO;
    lane.categoryKey = @"Shader";
    lane.categorySymbol = @"slider.horizontal.3";
    lane.visibleWhenLabel = @"Type";
    lane.visibleWhenValues = @[ @4 ];
    [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                          values:@[ @(neuroControls[s].def) ]]];
    [lanes addObject:lane];
  }

  // --- Simplex controls (Type 5). Steps = extra colour bands between the base
  // colours (integer). Softness is the lane shared with Grainy / Warp above.
  KKLane *steps = [KKLane laneWithLabel:@"Steps"];
  steps.valueType = KKLaneValueTypeFloat;
  steps.componentMin = @[ @1.0 ];
  steps.componentMax = @[ @10.0 ];
  steps.integerValued = YES;
  steps.animatable = YES;
  steps.enabled = NO;
  steps.categoryKey = @"Shader";
  steps.categorySymbol = @"slider.horizontal.3";
  steps.visibleWhenLabel = @"Type";
  steps.visibleWhenValues = @[ @5 ];
  [steps
      insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                      values:@[ @(KK_SIMPLEX_DEFAULT_STEPS) ]]];
  [lanes addObject:steps];

  // --- Metaballs controls (Type 6). Count = active balls (integer 1..20);
  // Size = ball size (percent 0..100 -> 0..1).
  KKLane *ballCount = [KKLane laneWithLabel:@"Count"];
  ballCount.valueType = KKLaneValueTypeFloat;
  ballCount.componentMin = @[ @1.0 ];
  ballCount.componentMax = @[ @20.0 ];
  ballCount.integerValued = YES;
  ballCount.animatable = YES;
  ballCount.enabled = NO;
  ballCount.categoryKey = @"Shader";
  ballCount.categorySymbol = @"slider.horizontal.3";
  ballCount.visibleWhenLabel = @"Type";
  ballCount.visibleWhenValues = @[ @6 ];
  [ballCount
      insertKeypose:[KKKeyPose
                        keyposeAtTime:0.0
                               values:@[ @(KK_METABALLS_DEFAULT_COUNT) ]]];
  [lanes addObject:ballCount];

  KKLane *ballSize = [KKLane laneWithLabel:@"Size"];
  ballSize.valueType = KKLaneValueTypeFloat;
  ballSize.componentMin = @[ @0.0 ];
  ballSize.componentMax = @[ @100.0 ];
  ballSize.componentUnits = @[ @"%" ];
  ballSize.animatable = YES;
  ballSize.enabled = NO;
  ballSize.categoryKey = @"Shader";
  ballSize.categorySymbol = @"slider.horizontal.3";
  ballSize.visibleWhenLabel = @"Type";
  ballSize.visibleWhenValues = @[ @6 ];
  [ballSize
      insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                      values:@[ @(KK_METABALLS_DEFAULT_SIZE *
                                                  100.0) ]]];
  [lanes addObject:ballSize];

  // --- God Rays controls (Type 7). All percent lanes storing 0..100 (the
  // shader wants 0..1). Distinct labels (no shared "Intensity") to keep each
  // type's default independent.
  struct {
    NSString *label;
    double def;
  } godRaysControls[] = {
      {@"Density", KK_GODRAYS_DEFAULT_DENSITY * 100.0},
      {@"Spots", KK_GODRAYS_DEFAULT_SPOTTY * 100.0},
      {@"Glow Size", KK_GODRAYS_DEFAULT_MIDSIZE * 100.0},
      {@"Glow", KK_GODRAYS_DEFAULT_MIDINTENSITY * 100.0},
      {@"Rays", KK_GODRAYS_DEFAULT_INTENSITY * 100.0},
      {@"Bloom", KK_GODRAYS_DEFAULT_BLOOM * 100.0},
  };
  for (unsigned s = 0; s < sizeof(godRaysControls) / sizeof(godRaysControls[0]);
       s++) {
    KKLane *lane = [KKLane laneWithLabel:godRaysControls[s].label];
    lane.valueType = KKLaneValueTypeFloat;
    lane.componentMin = @[ @0.0 ];
    lane.componentMax = @[ @100.0 ];
    lane.componentUnits = @[ @"%" ];
    lane.animatable = YES;
    lane.enabled = NO;
    lane.categoryKey = @"Shader";
    lane.categorySymbol = @"slider.horizontal.3";
    lane.visibleWhenLabel = @"Type";
    lane.visibleWhenValues = @[ @7 ];
    [lane
        insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                        values:@[ @(godRaysControls[s].def) ]]];
    [lanes addObject:lane];
  }

  // --- Fluid controls (Type 8). Marble = domain-warp strength (0 = smooth,
  // higher = intense marbling); Detail = fbm persistence; Vibrance = colour-
  // layer separation. All percent (shader wants 0..N). Distinct labels (not the
  // shared Swirl / Distortion / Contrast) to keep per-type defaults.
  struct {
    NSString *label;
    double def, max;
  } fluidControls[] = {
      {@"Marble", KK_FLUID_DEFAULT_MARBLE * 100.0, 300.0},
      {@"Detail", KK_FLUID_DEFAULT_DETAIL * 100.0, 100.0},
      {@"Vibrance", KK_FLUID_DEFAULT_VIBRANCE * 100.0, 200.0},
  };
  for (unsigned s = 0; s < sizeof(fluidControls) / sizeof(fluidControls[0]);
       s++) {
    KKLane *lane = [KKLane laneWithLabel:fluidControls[s].label];
    lane.valueType = KKLaneValueTypeFloat;
    lane.componentMin = @[ @0.0 ];
    lane.componentMax = @[ @(fluidControls[s].max) ];
    lane.componentUnits = @[ @"%" ];
    lane.animatable = YES;
    lane.enabled = NO;
    lane.categoryKey = @"Shader";
    lane.categorySymbol = @"slider.horizontal.3";
    lane.visibleWhenLabel = @"Type";
    lane.visibleWhenValues = @[ @8 ];
    [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                          values:@[ @(fluidControls[s].def) ]]];
    [lanes addObject:lane];
  }

  // --- Neon controls (Type 9), wisps only (blobs removed). Wisps = tendril
  // coverage; Strands = fineness (frequency); Radiance = HDR neon gain.
  struct {
    NSString *label;
    double def, max;
  } neonControls[] = {
      {@"Wisps", KK_NEON_DEFAULT_WISPS * 100.0, 200.0},
      {@"Strands", KK_NEON_DEFAULT_STRANDS * 100.0, 250.0},
      {@"Radiance", KK_NEON_DEFAULT_RADIANCE * 100.0, 300.0},
  };
  for (unsigned s = 0; s < sizeof(neonControls) / sizeof(neonControls[0]);
       s++) {
    KKLane *lane = [KKLane laneWithLabel:neonControls[s].label];
    lane.valueType = KKLaneValueTypeFloat;
    lane.componentMin = @[ @0.0 ];
    lane.componentMax = @[ @(neonControls[s].max) ];
    lane.componentUnits = @[ @"%" ];
    lane.animatable = YES;
    lane.enabled = NO;
    lane.categoryKey = @"Shader";
    lane.categorySymbol = @"slider.horizontal.3";
    lane.visibleWhenLabel = @"Type";
    lane.visibleWhenValues = @[ @9 ];
    [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                          values:@[ @(neonControls[s].def) ]]];
    [lanes addObject:lane];
  }

  // --- Silk controls (Type 10). Sheen = silk specular intensity; Folds = fold
  // density; Drape = domain-warp strength (curve/flow of the folds).
  struct {
    NSString *label;
    double def, max;
  } silkControls[] = {
      {@"Sheen", KK_SILK_DEFAULT_SHEEN * 100.0, 200.0},
      {@"Folds", KK_SILK_DEFAULT_FOLDS * 100.0, 300.0},
      {@"Drape", KK_SILK_DEFAULT_DRAPE * 100.0, 200.0},
  };
  for (unsigned s = 0; s < sizeof(silkControls) / sizeof(silkControls[0]);
       s++) {
    KKLane *lane = [KKLane laneWithLabel:silkControls[s].label];
    lane.valueType = KKLaneValueTypeFloat;
    lane.componentMin = @[ @0.0 ];
    lane.componentMax = @[ @(silkControls[s].max) ];
    lane.componentUnits = @[ @"%" ];
    lane.animatable = YES;
    lane.enabled = NO;
    lane.categoryKey = @"Shader";
    lane.categorySymbol = @"slider.horizontal.3";
    lane.visibleWhenLabel = @"Type";
    lane.visibleWhenValues = @[ @10 ];
    [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                          values:@[ @(silkControls[s].def) ]]];
    [lanes addObject:lane];
  }

  // --- Strata controls (Type 11). Layers = strata count (integer 2..24);
  // Tectonics = deformation strength; Texture = washi-paper grain intensity.
  KKLane *strataLayers = [KKLane laneWithLabel:@"Layers"];
  strataLayers.valueType = KKLaneValueTypeFloat;
  strataLayers.componentMin = @[ @2.0 ];
  strataLayers.componentMax = @[ @24.0 ];
  strataLayers.integerValued = YES;
  strataLayers.animatable = YES;
  strataLayers.enabled = NO;
  strataLayers.categoryKey = @"Shader";
  strataLayers.categorySymbol = @"slider.horizontal.3";
  strataLayers.visibleWhenLabel = @"Type";
  strataLayers.visibleWhenValues = @[ @11 ];
  [strataLayers
      insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                      values:@[ @(KK_STRATA_DEFAULT_LAYERS) ]]];
  [lanes addObject:strataLayers];

  struct {
    NSString *label;
    double def, max;
  } strataControls[] = {
      {@"Tectonics", KK_STRATA_DEFAULT_TECTONICS * 100.0, 250.0},
      {@"Texture", KK_STRATA_DEFAULT_TEXTURE * 100.0, 200.0},
  };
  for (unsigned s = 0; s < sizeof(strataControls) / sizeof(strataControls[0]);
       s++) {
    KKLane *lane = [KKLane laneWithLabel:strataControls[s].label];
    lane.valueType = KKLaneValueTypeFloat;
    lane.componentMin = @[ @0.0 ];
    lane.componentMax = @[ @(strataControls[s].max) ];
    lane.componentUnits = @[ @"%" ];
    lane.animatable = YES;
    lane.enabled = NO;
    lane.categoryKey = @"Shader";
    lane.categorySymbol = @"slider.horizontal.3";
    lane.visibleWhenLabel = @"Type";
    lane.visibleWhenValues = @[ @11 ];
    [lane
        insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                        values:@[ @(strataControls[s].def) ]]];
    [lanes addObject:lane];
  }

  // --- Fixed colours first (not removable, so they sit above the dynamic
  // swatches): Dithering background + foreground (ink), the Neuro Mid line
  // colour. Background is shared by Dithering + Grainy + Neuro; Foreground by
  // Dithering + Neuro; Mid is Neuro-only.
  struct {
    NSString *label;
    float r, g, b, a;
    NSArray<NSNumber *> *visibleWhen;
  } fixedColors[] = {
      {@"Background", 0.04f, 0.04f, 0.07f, 1.0f,
       @[ @1, @2, @4, @6, @7, @9, @10 ]},
      {@"Foreground", 0.85f, 0.90f, 0.98f, 1.0f, @[ @1, @4 ]},
      {@"Mid", 0.25f, 0.45f, 0.95f, 1.0f, @[ @4 ]},
      {@"Bloom Color", 1.0f, 0.9f, 0.7f, 1.0f, @[ @7 ]},
  };
  for (unsigned c = 0; c < sizeof(fixedColors) / sizeof(fixedColors[0]); c++) {
    KKLane *color = [KKLane laneWithLabel:fixedColors[c].label];
    color.valueType = KKLaneValueTypeColor;
    color.componentMin = @[ @0.0, @0.0, @0.0, @0.0 ];
    color.componentMax = @[ @1.0, @1.0, @1.0, @1.0 ];
    color.animatable = YES;
    color.enabled = NO;
    color.categoryKey = @"Colors";
    color.categorySymbol = @"paintpalette";
    color.visibleWhenLabel = @"Type";
    color.visibleWhenValues = fixedColors[c].visibleWhen;
    [color insertKeypose:[KKKeyPose
                             keyposeAtTime:0.0
                                    values:@[
                                      @(fixedColors[c].r), @(fixedColors[c].g),
                                      @(fixedColors[c].b), @(fixedColors[c].a)
                                    ]]];
    [lanes addObject:color];
  }

  // --- Mesh + Grainy colours (dynamic - users add/remove): one [r,g,b,a]
  // swatch each, seeded from the default palette. Below the fixed colours.
  for (int i = 0; i < KK_MESH_COLOR_COUNT; i++) {
    KKLane *color = [KKLane laneWithLabel:MeshColorLabel(i)];
    color.valueType = KKLaneValueTypeColor;
    color.componentMin = @[ @0.0, @0.0, @0.0, @0.0 ];
    color.componentMax = @[ @1.0, @1.0, @1.0, @1.0 ];
    color.animatable = YES; // colours can be keyframed
    color.enabled = NO;
    color.categoryKey = @"Colors";
    color.categorySymbol = @"paintpalette";
    color.visibleWhenLabel = @"Type";
    color.visibleWhenValues = @[
      @0, @2, @3, @5, @6, @7, @8, @9, @10, @11
    ]; // Mesh + Grainy + Warp + Simplex + Metaballs + God Rays + Fluid + Neon +
       // Silk + Strata share the palette
    const float *c = kMeshDefaultColorsSRGB[i];
    [color insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                           values:@[
                                             @(c[0]), @(c[1]), @(c[2]), @(c[3])
                                           ]]];
    [lanes addObject:color];
  }

  return lanes;
}
