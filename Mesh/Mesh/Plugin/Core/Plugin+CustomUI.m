/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "MeshColorSpace.h"
#import "MeshInspectorView+Guides.h"
#import "MeshInspectorView.h"
#import "MeshLocalized.h"
#import "MeshMiniViewerRenderer.h" // per-instance mini-viewer rendezvous paths
#import "MeshOSCRadiusMath.h"
#import "Plugin_Private.h"
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKColorLanes.h>
#import <KeyframelessKit/KKDataBlob.h>
#import <KeyframelessKit/KKHelpSection.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKPlugin+InspectorCallbacks.h>
#import <KeyframelessKit/KKRotationOSC.h> // KKRotationLaneWithLabel + axis flag
#import <KeyframelessKit/KKTimelineAIMerge.h>
#import <KeyframelessKit/KKTimelineInspectorView+Guide.h> // guide help-button provider
#import <KeyframelessKit/KKTimingCompat.h>
#import <KeyframelessKit/KKTimingStage.h>
@import KeyframelessAI;

/// Plain-text coordinate-space description used by the AI agent's value
/// resolution pass. Kept tight on purpose: this is the only context the
/// values-pass LLM call sees, alongside the user's prompt. No timing words,
/// no in/out, no Basic/Advanced - just lanes and their numeric ranges.
static NSString *_MeshAILaneSchemaText(void) {
  return @"Lane labels and value spaces. This is a procedural generator with "
         @"six "
         @"styles selected by \"Type\": Mesh (animated colour spots blended "
         @"into "
         @"a soft gradient), Dithering (a procedural shape rendered through "
         @"a "
         @"dither into two colours), Grainy (a procedural shape field "
         @"indexing a multi-colour ramp with a grainy overlay), Warp "
         @"(colour fields warped by noise + swirl over a base pattern), "
         @"Neuro (a glowing web of fluid lines), and Simplex (a multi-colour "
         @"gradient mapped through Simplex noise into stepped bands). Set "
         @"the lanes for the chosen type.\n\n"
         @"- \"Type\": the generator style. A structural choice (NOT "
         @"animated), "
         @"stored as an index: 0 = Mesh, 1 = Dithering, 2 = Grainy, 3 = Warp, "
         @"4 = Neuro, 5 = Simplex. Default 0.\n"
         @"- \"Speed\": single value, 0..3 multiplier of the animation rate "
         @"(1 = normal, 0 = frozen, 2 = twice as fast). Shared by all types. "
         @"Animatable. Default 1.\n"
         @"- \"Seed\": integer, the animation start-frame / layout variation "
         @"(any value). Shared by all types. NOT animatable. Default 0.\n"
         @"- \"Origin\": two components [X, Y] normalised 0..1 (0.5,0.5 = "
         @"centre, Y up). Shifts the pattern within the frame. Shared by all "
         @"types. Default [0.5, 0.5].\n"
         @"- \"Scale\": percent zoom of the pattern, 100 = 1x (slider caps at "
         @"400, field allows more). Shared by all types. Default 100.\n"
         @"- \"Rotation\": degrees 0..360, rotates the pattern. Shared by all "
         @"types. Default 0.\n"
         @"\nMesh (Type 0):\n"
         @"- \"Distortion\": percent 0..100. Organic noise warp of the field "
         @"(0 = calm, higher = more churning folds). Default 80.\n"
         @"- \"Swirl\": percent 0..100. Vortex twist around the centre. "
         @"Default 10.\n"
         @"- \"Grain Mixer\": percent 0..100. Grain at the colour-spot edges. "
         @"Default 0.\n"
         @"- \"Grain\": percent 0..100. Post film-grain overlay. Default 6.\n"
         @"- \"Color 1\", \"Color 2\", ... : the gradient's colour spots, each "
         @"[r, g, b, a] in sRGB 0..1. Positions are procedural, so only the "
         @"colours are set. Set as many as the user asks for.\n"
         @"\nDithering (Type 1):\n"
         @"- \"Shape\": the procedural pattern. Structural choice (NOT "
         @"animated), index: 0 = Simplex, 1 = Warp, 2 = Dots, 3 = Wave, "
         @"4 = Ripple, 5 = Swirl. Default 0.\n"
         @"- \"Dither\": the dither matrix. Structural choice, index: "
         @"0 = Random, 1 = 2x2, 2 = 4x4, 3 = 8x8 (higher = finer/smoother). "
         @"Default 3.\n"
         @"- \"Pixel Size\": the dither grid cell size in pixels, integer "
         @"1..20 "
         @"(higher = chunkier). Default 2.\n"
         @"- \"Background\": the base colour [r, g, b, a] in sRGB 0..1.\n"
         @"- \"Foreground\": the ink colour [r, g, b, a] in sRGB 0..1.\n"
         @"\nGrainy (Type 2):\n"
         @"- \"Pattern\": the procedural shape field. Structural choice (NOT "
         @"animated), index: 0 = Wave, 1 = Dots, 2 = Truchet, 3 = Corners, "
         @"4 = Ripple, 5 = Blob. Default 0.\n"
         @"- \"Softness\": percent 0..100. Colour-band edge smoothness "
         @"(0 = hard steps, 100 = smooth gradient). Default 90.\n"
         @"- \"Intensity\": percent 0..100. Noise distortion between the "
         @"colour "
         @"bands. Default 40.\n"
         @"- \"Noise\": percent 0..100. Grainy overlay amount. Default 25.\n"
         @"- \"Color 1\", \"Color 2\", ... : the ramp colours (shared with "
         @"Mesh), each [r, g, b, a] in sRGB 0..1. Set as many as the user "
         @"asks for (up to 7 used).\n"
         @"- \"Background\": the base colour [r, g, b, a] in sRGB 0..1 "
         @"(shared with Dithering).\n"
         @"\nWarp (Type 3):\n"
         @"- \"Base\": the base pattern under the warp. Structural choice (NOT "
         @"animated), index: 0 = Checks, 1 = Stripes, 2 = Edge. Default 0.\n"
         @"- \"Proportion\": percent 0..100. Blend point between colours "
         @"(50 = equal distribution). Default 50.\n"
         @"- \"Softness\": percent 0..100. Colour-transition sharpness "
         @"(0 = hard edge, 100 = smooth). Shared with Grainy. Default 90.\n"
         @"- \"Shape Scale\": percent 0..100. Zoom of the base pattern. "
         @"Default 50.\n"
         @"- \"Distortion\": percent 0..100. Noise distortion strength. Shared "
         @"with Mesh. Default 80.\n"
         @"- \"Swirl\": percent 0..100. Swirl distortion strength. Shared with "
         @"Mesh. Default 10.\n"
         @"- \"Swirl Iterations\": integer 0..20, layered swirl passes "
         @"(effective with Swirl > 0). Default 8.\n"
         @"- \"Color 1\", \"Color 2\", ... : the warped colours (shared with "
         @"Mesh), each [r, g, b, a] in sRGB 0..1. Up to 10 used.\n"
         @"\nNeuro (Type 4):\n"
         @"- \"Brightness\": percent 0..100. Luminosity of the glowing "
         @"crossing "
         @"points. Default 20.\n"
         @"- \"Contrast\": percent 0..100. Sharpness of the bright-dark "
         @"transition. Default 30.\n"
         @"- \"Foreground\": the highlight colour [r, g, b, a] in sRGB 0..1 "
         @"(shared with Dithering).\n"
         @"- \"Mid\": the main line colour [r, g, b, a] in sRGB 0..1.\n"
         @"- \"Background\": the base colour [r, g, b, a] in sRGB 0..1 "
         @"(shared with Dithering + Grainy).\n"
         @"\nSimplex (Type 5):\n"
         @"- \"Steps\": integer 1..10, extra colour bands between the base "
         @"colours (1 = smooth, higher = more stepped). Default 1.\n"
         @"- \"Softness\": percent 0..100. Band-edge sharpness (0 = hard, "
         @"100 = smooth). Shared with Grainy / Warp. Default 90.\n"
         @"- \"Color 1\", \"Color 2\", ... : the gradient colours (shared with "
         @"Mesh), each [r, g, b, a] in sRGB 0..1. Up to 10 used.\n";
}

@implementation MeshPlugin (CustomUI)

- (BOOL)usesMotionBlur {
  return YES;
}

+ (NSArray<KKLane *> *)availableLanes {
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
  type.choiceLabels =
      @[ @"Mesh", @"Dithering", @"Grainy", @"Warp", @"Neuro", @"Simplex" ];
  type.componentMin = @[ @0.0 ];
  type.componentMax = @[ @5.0 ];
  type.integerValued = YES;
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
  speed.visibleWhenValues = @[ @0, @1, @2, @3, @4, @5 ];
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
  seed.visibleWhenValues = @[ @0, @1, @2, @3, @4, @5 ];
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
      {@"Grain Mixer", KK_MESH_GRAD_DEFAULT_GRAINMIXER * 100.0, 0.0, 100.0,
       @"%", YES, NO},
      {@"Grain", KK_MESH_DEFAULT_GRAIN * 100.0, 0.0, 100.0, @"%", YES, NO},
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
    // Distortion + Swirl are shared with Warp (same 0..1 noise/swirl controls);
    // Grain Mixer + Grain stay Mesh-only.
    BOOL sharedWithWarp =
        [meshControls[s].label isEqualToString:@"Distortion"] ||
        [meshControls[s].label isEqualToString:@"Swirl"];
    lane.visibleWhenValues = sharedWithWarp ? @[ @0, @3 ] : @[ @0 ];
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

  // --- Fixed colours first (not removable, so they sit above the dynamic
  // swatches): Dithering background + foreground (ink), the Neuro Mid line
  // colour. Background is shared by Dithering + Grainy + Neuro; Foreground by
  // Dithering + Neuro; Mid is Neuro-only.
  struct {
    NSString *label;
    float r, g, b, a;
    NSArray<NSNumber *> *visibleWhen;
  } fixedColors[] = {
      {@"Background", 0.04f, 0.04f, 0.07f, 1.0f, @[ @1, @2, @4 ]},
      {@"Foreground", 0.85f, 0.90f, 0.98f, 1.0f, @[ @1, @4 ]},
      {@"Mid", 0.25f, 0.45f, 0.95f, 1.0f, @[ @4 ]},
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
    color.visibleWhenValues =
        @[ @0, @2, @3, @5 ]; // Mesh + Grainy + Warp + Simplex share the palette
    const float *c = kMeshDefaultColorsSRGB[i];
    [color insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                           values:@[
                                             @(c[0]), @(c[1]), @(c[2]), @(c[3])
                                           ]]];
    [lanes addObject:color];
  }

  return lanes;
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == kParamInspectorUI) {
    id<FxCustomParameterActionAPI_v4> actionAPI = [self.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actionAPI startAction:self];
    id<FxParameterRetrievalAPI_v6> getAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];

    KKInspectorPersistedState *st =
        [self kkReadInspectorPersistedStateWithGetAPI:getAPI
                                       uiStateParamID:kParamUIState];
    BOOL loopEnabled = st.loopEnabled;
    NSInteger activeTab = st.activeTab;
    BOOL oscMasterVisible = st.oscMasterVisible;
    KKMiniViewerRenderMode renderMode = (KKMiniViewerRenderMode)st.renderMode;
    BOOL motionBlurEnabled = st.motionBlurEnabled;
    double motionBlurShutterAngle = st.motionBlurShutterAngle;
    NSInteger motionBlurSamples = st.motionBlurSamples;
    NSInteger motionBlurTechnique = st.motionBlurTechnique;
    NSDictionary *uiState = st.uiState;
    KKTimeline *timeline = [self timelineStampedWithClipDuration:st.timeline];

    // Cold-boot seed for the OSC. Without this, the first drawOSC tick after
    // FCP relaunch sees an empty snapshot → falls through to "no lane =
    // constant", radius reads default 20, crop reads [1,1,0,0] → handle is
    // visible at the canvas TR regardless of saved state. parameterChanged
    // eventually catches up, but only after a redraw nudge.
    MeshSetTimelineSnapshot(timeline);

    // Frame + clip duration for the keypose-snap epsilon AND the basic-view
    // scrubber clamp. FxTimingAPI resolves inside this action scope. We
    // also push these into the view itself right after construction (below)
    // because the Plugin+Render push is gated on lastPushedClipDuration and
    // can race with view creation: if the first render fires before the
    // inspector view exists, the push targets a nil weak ref and the basic
    // view never learns the frame duration for the lifetime of this session.
    id<FxTimingAPI_v4> timingAPI =
        [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
    double seedFrameDurSec = 0.0;
    double seedClipDurSec = 0.0;
    if (timingAPI) {
      CMTime frameDur = kCMTimeZero, clipDur = kCMTimeZero;
      [timingAPI frameDuration:&frameDur];
      [timingAPI durationTimeForEffect:&clipDur];
      seedFrameDurSec = CMTimeGetSeconds(frameDur);
      seedClipDurSec = CMTimeGetSeconds(clipDur);
      if (seedFrameDurSec > 0)
        MeshSetFrameDurationSeconds(seedFrameDurSec);
    }

    // Per-instance OSC-visibility state: mint the UUID here (inside the action
    // scope where the setting API resolves) and seed the master tick.
    KKInstanceStateEnsureForAPI(self.apiManager).oscMasterVisible =
        oscMasterVisible;

    [actionAPI endAction:self];

    NSArray<KKLane *> *available = [MeshPlugin availableLanes];
    MeshInspectorView *view =
        [[MeshInspectorView alloc] initWithAPIManager:self.apiManager
                                          loopEnabled:loopEnabled
                                maintainTimingEnabled:st.maintainTimingEnabled
                                            activeTab:activeTab
                                       availableLanes:available
                                             timeline:timeline];
    // Per-instance rendezvous paths (keyed by the instance UUID minted above)
    // so two stacked Mesh clips read/write distinct /tmp files instead of the
    // clip below showing the top clip's source in its mini-viewer.
    NSString *instUUID = KKInstanceUUIDForAPI(self.apiManager);
    view.miniViewerDescriptorPath =
        MeshMiniViewerDescriptorPathForUUID(instUUID);
    view.miniViewerRequestPath = MeshMiniViewerRequestPathForUUID(instUUID);
    // Seed the basic-view scrubber clamp immediately. Plugin+Render's
    // dispatch_async push runs once on first render - if it raced ahead
    // and weakSelf.inspectorView was still nil, the basic view would
    // never see the frame duration. Pushing here too is idempotent.
    if (seedClipDurSec > 0)
      [view setClipDurationSeconds:seedClipDurSec];
    if (seedFrameDurSec > 0)
      [view setFrameDurationSeconds:seedFrameDurSec];
    [view setMotionBlurEnabled:motionBlurEnabled];
    [view setMotionBlurShutterAngle:motionBlurShutterAngle
                            samples:motionBlurSamples];
    [view setMotionBlurTechnique:(KKMotionBlurTechnique)motionBlurTechnique];

    // On-screen-control visibility: master tick + per-element pills (Origin,
    // Path) + opt-click-hide + opt-reveal. The element key is the lane label
    // (KKPositionOSC / the mini controller key their visibility on it). Shared
    // glue in KKPlugin (OSCVisibility); the renderer is the mini-viewer
    // delegate.
    KKMiniViewerRenderer *oscRenderer =
        (KKMiniViewerRenderer *)view.miniViewerDelegate;
    // The Scale mini box reads the plugin's lane templates for the aspect-link
    // default of an untouched (not-yet-in-timeline) constant Scale.
    if ([oscRenderer isKindOfClass:[MeshMiniViewerRenderer class]])
      ((MeshMiniViewerRenderer *)oscRenderer).laneTemplates = available;
    NSArray<NSArray<NSString *> *> *oscCompounds =
        @[ @[ @"Origin" ], @[ @"Path" ], @[ @"Scale" ], @[ @"Rotation" ] ];
    oscRenderer.handlesHidden = !oscMasterVisible;
    [self kkApplyOSCVisibilityFromState:uiState
                            elementKeys:[KKPlugin kkOSCElementKeysForCompounds:
                                                      oscCompounds]
                               renderer:oscRenderer];
    [self kkWireOSCVisibilityForView:view
                            renderer:oscRenderer
                           compounds:oscCompounds
                             paramID:kParamUIState];
    [view setOSCVisible:oscMasterVisible];
    [view setRenderMode:renderMode];

    // Force OSCs visible while a guide runs (so its mini-viewer + viewer
    // handles are usable), then restore the user's OSC setting on guide end.
    [self kkInstallGuideOSCForcingOnHost:[(MeshInspectorView *)
                                                 view timingGuideHost]
                                    view:view
                             elementKeys:[KKPlugin kkOSCElementKeysForCompounds:
                                                       oscCompounds]
                            nudgeParamID:kParamRenderNudge];

    [self kkWireStandardInspectorCallbacksForView:view
                                   uiStateParamID:kParamUIState
                               renderNudgeParamID:kParamRenderNudge
                                    dragUndoLabel:@"Adjust Origin"
                               detachedWindowSize:CGSizeMake(720.0, 460.0)];

    self.inspectorView = view;

    // Let the intro guide's closing step spotlight this effect's Help button
    // (owned by the plugin's logo banner, resolved live).
    __weak typeof(self) weakHelp = self;
    view.guideHelpButtonScreenRectProvider = ^NSRect {
      return [weakHelp helpButtonScreenRect];
    };

    if (!self.playheadPoller) {
      self.playheadPoller =
          [[KKPlayheadPoller alloc] initWithAPIManager:self.apiManager
                                          actionTarget:self
                                           renderCache:self.renderCache];
    }
    [self.playheadPoller setInspectorView:view];
    // The render tick may have established timing before the inspector
    // view existed (poller nil then, ensureRunning was a no-op nil-send).
    // Kick it now so the scrubber appears without needing a user scrub.
    if (self.renderCache.effectDurSec > 0.0)
      [self.playheadPoller ensureRunning];
    return view;
  }
  typedef NSView *(*ViewIMP)(id, SEL, UInt32);
  ViewIMP imp = (ViewIMP)[KKPlugin instanceMethodForSelector:_cmd];
  return imp(self, _cmd, parameterID);
}

- (NSArray<KKHelpGuide *> *)helpGuides {
  // The Introduction + Advanced Timing entries (copy, gating, completion
  // wiring) are identical across plugins, so the kit builds them. Mesh only
  // supplies the canvas-reference gate (the final Basic step's viewer cutout
  // needs an OSC draw tick) and the live inspector.
  __weak typeof(self) weak = self;
  return [KKTimingGuide
      standardHelpGuidesForInspectorProvider:^KKTimelineInspectorView * {
        __strong typeof(weak) strong = weak;
        return strong.inspectorView;
      }
      enabledProvider:^BOOL {
        return MeshHasCanvasReference();
      }];
}

- (NSNotificationName)helpGuideRefreshNotificationName {
  return kMeshOSCPositionNotification;
}

- (nullable NSView *)aiAccessoryView {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // Shared timeline docs now live in the kit framework bundle (so the kit
    // help window can render the same source); register them from there.
    [KKAIKnowledge registerSharedTimelineDocsWithBundle:
                       [NSBundle bundleForClass:[KKOnScreenControl class]]];
    [KKAIKnowledge
        registerBundleDocsWithName:@"Mesh"
                            bundle:[NSBundle bundleForClass:[MeshPlugin class]]
                      subdirectory:@"AIKnowledge"];
    // Shared on-screen-control docs live in the kit framework (flattened to its
    // Resources root). Filter to just the topics Mesh actually uses - it has
    // no rotation OSC, so only the visibility doc.
    [KKAIKnowledge
        registerBundleDocsWithName:@"On-Screen Controls"
                            bundle:[NSBundle
                                       bundleForClass:[KKOnScreenControl class]]
                      subdirectory:nil
                      onlyTopicIDs:@[ @"visibility" ]];
  });

  NSString *productContext = RLoc(
      @"Mesh, a Final Cut Pro plugin that rounds corners, crops with a box, "
      @"and animates with the shared Keyframeless timeline system (Basic and "
      @"Advanced timing, easing, motion blur). Always refer to yourself as "
      @"Mesh. Detailed feature information is in the reference docs below.",
      @"AI assistant product context for Mesh plugin.");

  NSArray<NSArray<NSString *> *> *examples = @[
    @[
      RLoc(@"Animate radius 0→100% with bounce",
           @"AI example chip: animate radius with bounce."),
      RLoc(@"Animate the radius from 0% to 100% over 1 second with bounce.",
           @"AI example value: animate radius with bounce.")
    ],
    @[
      RLoc(@"Crop to top right", @"AI example chip: crop to top right."),
      RLoc(@"Crop to the top right quadrant.",
           @"AI example value: crop to top right.")
    ],
    @[
      RLoc(@"Reveal then hide", @"AI example chip: in/out crop animation."),
      RLoc(@"Animate the crop in from the top right and back out at the "
           @"end, while the radius rounds over the whole clip.",
           @"AI example value: in/out crop animation.")
    ],
    @[
      RLoc(@"What's Basic vs Advanced?",
           @"AI example chip: Basic vs Advanced timing question."),
      RLoc(@"What's the difference between Basic and Advanced timing?",
           @"AI example value: Basic vs Advanced timing question.")
    ],
  ];

  NSString *placeholder = RLoc(@"Ask a question or describe an animation…",
                               @"AI prompt field placeholder for Mesh.");

  __weak typeof(self) weakSelf = self;
  return [KKAIBannerHost
      makePluginButtonWithProductContext:productContext
                            examplePairs:examples
                             placeholder:placeholder
                                   onRun:^(NSString *prompt) {
                                     __strong typeof(weakSelf) strong =
                                         weakSelf;
                                     if (!strong)
                                       return;
                                     [strong _runAIPrompt:prompt
                                           productContext:productContext];
                                   }];
}

- (void)_runAIPrompt:(NSString *)prompt
      productContext:(NSString *)productContext {
  [KKAIDraft setRouting:YES];
  [KKAIDraft setError:nil];

  // Read current timeline + clip duration inside an action scope.
  id<FxCustomParameterActionAPI_v4> readAct =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!readAct) {
    [KKAIDraft setRouting:NO];
    [KKAIDraft setError:@"Couldn't open the FCP action scope."];
    return;
  }
  [readAct startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSString *currentJSON =
      KKTimelineAICurrentJSON(getAPI, [MeshPlugin availableLanes]);
  NSString *uiJson = KKReadCustomParamString(getAPI, kParamUIState);
  NSDictionary *uiState =
      (uiJson.length
           ? [NSJSONSerialization
                 JSONObjectWithData:[uiJson
                                        dataUsingEncoding:NSUTF8StringEncoding]
                            options:0
                              error:nil]
           : nil)
          ?: @{};
  NSInteger activeTab = [uiState[@"activeTab"] integerValue];
  NSString *currentMode = (activeTab == 1) ? @"Advanced" : @"Basic";
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  CMTime clipDur = kCMTimeZero;
  if (timingAPI)
    [timingAPI durationTimeForEffect:&clipDur];
  double clipDurSec = CMTimeGetSeconds(clipDur);
  if (clipDurSec <= 0 || isnan(clipDurSec))
    clipDurSec = 5.0;
  [readAct endAction:self];

  NSString *schema = _MeshAILaneSchemaText();

  __weak typeof(self) weakSelf = self;
  [KKAIPluginAgent
              runWithPrompt:prompt
             productContext:productContext
             laneSchemaText:schema
        currentTimelineJSON:currentJSON
        clipDurationSeconds:clipDurSec
       currentInspectorMode:currentMode
      supportsLayerCreation:NO
                 completion:^(KKAIPluginResult *result, NSError *err) {
                   dispatch_async(dispatch_get_main_queue(), ^{
                     __strong typeof(weakSelf) strong = weakSelf;
                     if (!strong)
                       return;
                     [KKAIDraft setRouting:NO];
                     if (err) {
                       KKLogError(@"AI[err] %@", err.localizedDescription);
                       [KKAIDraft setError:err.localizedDescription];
                       return;
                     }
                     if (!result) {
                       KKLogError(@"AI[err] empty result");
                       [KKAIDraft setError:@"Empty AI response."];
                       return;
                     }
                     if (result.kind == KKAIPluginResultKindAnswer) {
                       [KKAIDraft setAnswer:result.answer];
                       return;
                     }
                     // The merge also snaps final keyposes to the last
                     // renderable frame (FCP's last frame is one frame before
                     // the clip end, so a keypose at 1.0 is never reached) -
                     // clipDur from the prompt, frameDur from the process
                     // cache.
                     NSString *merged = KKTimelineAIMergeMutationJSON(
                         currentJSON, result.mutationJSON, clipDurSec,
                         KKProcessFrameDurationSeconds());
                     if (!merged) {
                       KKLogError(@"AI[err] merge returned nil");
                       [KKAIDraft
                           setError:
                               @"AI returned an invalid timeline mutation."];
                       return;
                     }
                     id<FxCustomParameterActionAPI_v4> writeAct =
                         [strong.apiManager
                             apiForProtocol:@protocol(
                                                FxCustomParameterActionAPI_v4)];
                     if (!writeAct) {
                       [KKAIDraft
                           setError:@"Couldn't open the FCP action scope to "
                                    @"apply the mutation."];
                       return;
                     }
                     [writeAct startAction:strong];
                     id<FxParameterSettingAPI_v5> setAPI = [strong.apiManager
                         apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
                     KKWriteCustomParamString(setAPI, merged,
                                              kKKParamTimelineData);

                     // If the new timeline isn't representable in Basic, force
                     // the inspector to Advanced so the user sees the actual
                     // structure. Keeping the activeTab on Basic when the data
                     // is Advanced-only shows the compatibility banner instead
                     // of the new animation.
                     KKTimeline *resultTimeline =
                         [KKTimeline timelineFromJSON:merged];
                     double mergeFrameDur = KKProcessFrameDurationSeconds();
                     double aiEndFrac =
                         (clipDurSec > 0.0 && mergeFrameDur > 0.0 &&
                          mergeFrameDur < clipDurSec)
                             ? (clipDurSec - mergeFrameDur) / clipDurSec
                             : 1.0;
                     if (resultTimeline && !KKTimelineIsBasicCompatible(
                                               resultTimeline, aiEndFrac)) {
                       [strong patchUIStateKey:@"activeTab"
                                         value:@(1)
                                       paramID:kParamUIState];
                     }
                     [writeAct endAction:strong];
                     [KKAIDraft setAnswer:nil];
                     [KKAIDraft clearPrompt];
                   });
                 }];
}

- (nullable NSString *)helpHeaderTitle {
  return RLoc(@"Mesh", @"Help section title (plugin name).");
}

- (nullable NSImage *)helpHeaderIcon {
  return [NSImage imageWithSystemSymbolName:@"square.dotted"
                   accessibilityDescription:nil];
}

- (NSArray<KKHelpSection *> *)helpSections {
  // Quick reference: short overview + parameter list (single-sourced from
  // mesh.md), then an on-screen-control shortcuts table. The per-property
  // deep docs (radius/box-crop.md) stay AI-only.
  KKHelpSection *overview = [self
      helpSectionFromKnowledgeTopic:@"mesh"
                              title:RLoc(@"Mesh",
                                         @"Help section title (plugin name).")
                             symbol:@"square.dotted"
                          localizer:^NSString *(NSString *tip) {
                            return RLoc(tip, @"Mesh help tip (from "
                                             @"AIKnowledge markdown).");
                          }];

  NSMutableArray<KKHelpShortcut *> *rows = [@[
    [KKHelpShortcut
        shortcutWithKeysMarkup:RLoc(@"Drag the Radius handle",
                                    @"Shortcut keys.")
                    descMarkup:RLoc(@"Set the corner rounding on the canvas",
                                    @"Help shortcut.")],
    [KKHelpShortcut
        shortcutWithKeysMarkup:RLoc(@"Drag a Crop edge or corner",
                                    @"Shortcut keys.")
                    descMarkup:RLoc(@"Crop from that side", @"Help shortcut.")],
  ] mutableCopy];
  [rows addObjectsFromArray:[KKPlugin sharedOnScreenControlShortcuts]];

  KKHelpSection *shortcuts =
      [KKHelpSection sectionWithTitle:RLoc(@"On-screen control shortcuts",
                                           @"Help section title.")
                            tipMarkup:nil
                            shortcuts:rows];
  shortcuts.icon = [NSImage imageWithSystemSymbolName:@"hand.point.up.left"
                             accessibilityDescription:nil];

  return @[ overview, shortcuts ];
}

@end
