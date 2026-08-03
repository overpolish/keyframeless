/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The DECLARATIVE lane + OSC definitions for the Canvas plugin: the
// +availableLanes template factory (Transform / Core / Stroke groups), the OSC
// compound grouping, and the per-layer default OSC element seed. Pure data, no
// instance state - split out of Plugin+CustomUI.m (which keeps the inspector
// view lifecycle + callback wiring).

#import "CanvasLayerTimeline.h" // CanvasLaneScope (templateScopeMask bits)
#import "CanvasStrokeGlyphs.h"  // Line Cap / Join / Marker pill glyphs
#import "Plugin_Private.h"
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKColorLanes.h>
#import <KeyframelessKit/KKTimeline.h>

@implementation CanvasPlugin (LaneDefinitions)

// One declarative spec per lane: WHO the property applies to
// (templateScopeMask, interpreted by CanvasLaneAppliesToPath) and WHERE its
// flat value lives on the layer (templateSeedProvider - the constant keypose
// seeded when a path has no stored lane yet). Lives here, beside the
// definitions, so the timeline builder needs no per-label cascade.
static void CanvasSetLaneSpec(KKLane *lane, NSUInteger scope,
                              NSArray<NSNumber *> * (^seed)(KKBezierPath *p)) {
  lane.templateScopeMask = scope;
  if (seed)
    lane.templateSeedProvider = ^NSArray<NSNumber *> *(id ctx) {
      return [ctx isKindOfClass:[KKBezierPath class]] ? seed((KKBezierPath *)ctx)
                                                      : nil;
    };
}

+ (NSArray<KKLane *> *)availableLanes {
  // Transform group. These are lane TEMPLATES: each layer owns its own timeline
  // built from them (per-layer transforms; the inspector shows the selected
  // layer's), so a fresh layer starts at identity. The render ignores them
  // until the transform plumbing lands; stroke / fill groups come later.
  //
  // Scale: 2-component aspect-linked percent, shaped so the box OSC drops
  // straight in. Identity = 100%. Unbounded above; 0 floor.
  KKLane *scale = [KKLane laneWithKey:@"Scale" label:@"Scale"];
  scale.valueType = KKLaneValueTypeFloat;
  scale.componentMin = @[ @0.0, @0.0 ];
  scale.componentUnits = @[ @"%", @"%" ];
  scale.componentLabels = @[ @"X", @"Y" ];
  scale.integerValued = YES; // whole percentages only (1% scrub step)
  scale.aspectLinkable = YES;
  scale.aspectLinked = YES;
  scale.enabled = NO; // constant by default; animate per-layer via the dropdown
  scale.categoryKey = @"Transform";
  scale.categorySymbol = @"arrow.up.and.down.and.arrow.left.and.right";
  [scale insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                         values:@[ @100.0, @100.0 ]]];

  // Position: 2D spatial, stored normalised 0..1 (0.5,0.5 = centred =
  // identity), displayed as pixels. The reusable curved-path Position
  // (spatialCurvable). Off-canvas allowed, so no min/max.
  KKLane *position = [KKLane laneWithKey:@"Position" label:@"Position"];
  position.valueType = KKLaneValueTypeGeneric;
  position.componentMin = @[];
  position.componentMax = @[];
  position.componentUnits = @[ @"px", @"px" ];
  position.componentsScaleWithMedia = YES; // stored 0..1, displayed as pixels
  position.componentLabels = @[ @"X", @"Y" ];
  position.spatialCurvable = YES;
  position.enabled = NO; // constant by default; animate per-layer via dropdown
  position.categoryKey = @"Transform";
  position.categorySymbol = @"arrow.up.and.down.and.arrow.left.and.right";
  [position insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0.5, @0.5 ]]];

  // Rotation: 3-axis (X/Y/Z) Euler degrees, shaped so the kit's KKRotationOSC
  // + mini rotation rings drop straight in.
  // Identity = 0. Unbounded (angles accumulate past 360). Z is the in-plane
  // spin (rendered today); X/Y tilt renders once the perspective transform
  // lands. Axis ring colours: X red, Y green, Z blue.
  KKLane *rotation = [KKLane laneWithKey:@"Rotation" label:@"Rotation"];
  rotation.valueType = KKLaneValueTypeAngle;
  rotation.componentMin = @[];
  rotation.componentMax = @[];
  rotation.componentUnits = @[ @"°", @"°", @"°" ];
  rotation.componentLabels = @[ @"X", @"Y", @"Z" ];
  rotation.componentLabelColors = @[
    [NSColor colorWithSRGBRed:0.95 green:0.35 blue:0.35 alpha:1.0],
    [NSColor colorWithSRGBRed:0.40 green:0.85 blue:0.45 alpha:1.0],
    [NSColor colorWithSRGBRed:0.40 green:0.60 blue:0.95 alpha:1.0],
  ];
  rotation.enabled = NO; // constant by default; animate per-layer via dropdown
  rotation.categoryKey = @"Transform";
  rotation.categorySymbol = @"arrow.up.and.down.and.arrow.left.and.right";
  [rotation insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                            values:@[ @0.0, @0.0, @0.0 ]]];

  // Anchor: the pivot Rotation and Scale swing around. 2-component, stored
  // normalised 0..1 (0.5,0.5 = the layer centre = identity), displayed as
  // pixels, same space as Position. Off-layer allowed, so no min/max. Shaped
  // so the kit's KKAnchorOSC + mini drop straight
  // in. On its own it does nothing - it only moves where rotation/scale pivot.
  KKLane *anchor = [KKLane laneWithKey:@"Anchor" label:@"Anchor"];
  anchor.valueType = KKLaneValueTypeGeneric;
  anchor.componentMin = @[];
  anchor.componentMax = @[];
  anchor.componentUnits = @[ @"px", @"px" ];
  anchor.componentsScaleWithMedia = YES; // stored 0..1, displayed as pixels
  anchor.componentLabels = @[ @"X", @"Y" ];
  anchor.enabled =
      NO; // constant by default; animate per-layer via the dropdown
  anchor.categoryKey = @"Transform";
  anchor.categorySymbol = @"arrow.up.and.down.and.arrow.left.and.right";
  [anchor insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0.5, @0.5 ]]];

  // Opacity: shared kit definition (0-100%, identity 100). Per-layer; the
  // render multiplies the layer's premultiplied RGBA by value/100. No OSC.
  KKLane *opacity = [KKLane opacityLane];
  opacity.enabled = NO; // constant by default; animate per-layer via dropdown
  opacity.categoryKey = @"Transform";
  opacity.categorySymbol = @"arrow.up.and.down.and.arrow.left.and.right";

  // Points: the path's geometry (anchors + handles). OSC-edited only - the
  // inspector shows an "edit on canvas" message instead of value fields. Still
  // animatable: keyposes drive a geometry morph (the points at each keypose are
  // stored as morph snapshots; the render interpolates - wired separately).
  // Scoped to vector-path layers in CanvasLayerTimelineForPath (images / groups
  // have no editable points). Its anchors OSC is the "Points" element.
  KKLane *points = [KKLane laneWithKey:@"Points" label:@"Points"];
  points.valueType = KKLaneValueTypeGeneric;
  points.componentMin = @[];
  points.componentMax = @[];
  points.componentUnits = @[];
  points.componentLabels = @[];
  points.animatable = YES;
  points.oscEditedOnly = YES;
  points.enabled =
      NO; // constant by default; animate per-layer via the dropdown
  points.categoryKey = @"Core";
  points.categorySymbol = @"scribble.variable";
  [points insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[]]];

  // Stroke group (between Core and Transform). "Enabled": a structural on/off
  // CHECKBOX (isToggle) - the group's master switch. Value 1 = on. When off,
  // toggles the rest of the Stroke group via the visibleWhen cascade. Not
  // animatable; vector paths only (ownerScoped, so images / groups don't get it
  // re-seeded). Seeded per-path from the layer's flat strokeEnabled. Listed
  // FIRST so it heads the group.
  KKLane *strokeOn = [KKLane laneWithKey:@"Enabled" label:@"Enabled"];
  strokeOn.valueType = KKLaneValueTypeFloat;
  strokeOn.isToggle = YES;
  strokeOn.animatable = NO;
  strokeOn.integerValued = YES;
  strokeOn.componentLabels = @[];
  strokeOn.componentUnits = @[];
  strokeOn.enabled = NO;
  strokeOn.ownerScoped = YES;
  strokeOn.categoryKey = @"Stroke";
  strokeOn.categorySymbol = @"lineweight";
  [strokeOn insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @1.0 ]]];

  // Stroke group (between Core and Transform). Stroke Width: 2-component
  // aspect-linked float in NATIVE pixels (Start / End), LINKED by default so
  // one box drives both - the classic linked-field pattern (like a radius). The
  // render is constant-width today (uses Start; End taper renders later), and
  // links to End so the linked default is exact. Vector paths only (scoped in
  // CanvasLayerTimelineForPath; images / groups have no stroke). Seeded
  // per-path from the layer's flat strokeWidth/endWidth there, so existing
  // paths are unchanged; the template default matches a freshly-drawn path
  // (20px).
  KKLane *strokeWidth = [KKLane laneWithKey:@"Stroke Width" label:@"Stroke Width"];
  strokeWidth.valueType = KKLaneValueTypeFloat;
  strokeWidth.componentMin = @[ @0.0, @0.0 ]; // no negative width
  strokeWidth.componentUnits = @[ @"px", @"px" ];
  strokeWidth.componentLabels = @[ @"Start", @"End" ];
  strokeWidth.autoSizesComponentLabels =
      YES;                         // "Start"/"End" don't fit 1-char slot
  strokeWidth.integerValued = YES; // whole px (sub-pixel widths don't help)
  strokeWidth.aspectLinkable = YES;
  strokeWidth.aspectLinked = YES;
  strokeWidth.enabled =
      NO; // constant by default; animate per-layer via dropdown
  strokeWidth.ownerScoped = YES; // vector paths only (not re-seeded for images)
  strokeWidth.categoryKey = @"Stroke";
  strokeWidth.categorySymbol = @"lineweight";
  // Gated by the "Enabled" toggle via the shared visibleWhen cascade: when the
  // stroke is off this lane drops out of EVERY surface (constants/keypose
  // popover, animated dropdown, lane filter, Advanced graph) - the one source
  // of truth being the toggle's value. Every later Stroke lane (color, dash,
  // ...) wires the same rule, so the whole group hides as one.
  strokeWidth.visibleWhenKey = @"Enabled";
  strokeWidth.visibleWhenValues = @[ @1 ];
  [strokeWidth insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                               values:@[ @20.0, @20.0 ]]];

  // Stroke colour: the shared reusable colour group (Mode pill + solid swatch +
  // composite gradient). No Dynamic mode - a vector
  // stroke has no source pixels to sample - so the modes are Solid (default) +
  // Gradient. Labels are prefixed ("Stroke Mode" / "Stroke Solid" / "Stroke
  // Gradient") so a future Fill colour group can't collide. Seeded per-path
  // from the flat strokeColorMode / strokeR,G,B in CanvasLayerTimelineForPath.
  // The kit renders the swatch + gradient editor for KKLaneValueType
  // Color/Gradient automatically.
  NSArray<KKLane *> *strokeColor =
      KKColorLanesMake(@"Stroke", /*includesDynamic=*/NO, /*animatable=*/YES);
  for (KKLane *l in strokeColor) {
    l.enabled = NO; // constant by default; animate per-layer via the dropdown
    l.ownerScoped = YES; // vector paths only, like the rest of the group
    l.categoryKey = @"Stroke";
    l.categorySymbol = @"lineweight";
  }
  // Gate the whole colour sub-group with the same Enabled toggle. Only the Mode
  // lane needs the gate: the Solid / Gradient lanes are visibleWhen the Mode
  // lane (set by KKColorLanesMake), and the visibility cascade hides a lane
  // when its controller is itself hidden - so Enabled=off hides Mode, which
  // hides both.
  KKLane *strokeMode = strokeColor[0];
  strokeMode.visibleWhenKey = @"Enabled";
  strokeMode.visibleWhenValues = @[ @1 ];

  // Line Cap (open-path ends) + Line Join (corners): NON-animatable structural
  // enums shown as GLYPH radio pills (the choiceIcons; choiceLabels stay as the
  // accessibility / value names). Seeded per-path from the flat
  // lineCap/lineJoin in CanvasLayerTimelineForPath; gated by Enabled like the
  // rest of the group.
  KKLane *lineCap = [KKLane laneWithKey:@"Line Cap" label:@"Line Cap"];
  lineCap.valueType = KKLaneValueTypeFloat;
  lineCap.choiceLabels = @[ @"Butt", @"Round", @"Square" ];
  lineCap.choiceIcons = CanvasLineCapGlyphs();
  lineCap.componentMin = @[ @0.0 ];
  lineCap.componentMax = @[ @2.0 ];
  lineCap.integerValued = YES;
  lineCap.animatable = NO;
  lineCap.enabled = NO;
  lineCap.ownerScoped = YES;
  lineCap.categoryKey = @"Stroke";
  lineCap.categorySymbol = @"lineweight";
  lineCap.visibleWhenKey = @"Enabled";
  lineCap.visibleWhenValues = @[ @1 ];
  [lineCap insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0.0 ]]];

  KKLane *lineJoin = [KKLane laneWithKey:@"Line Join" label:@"Line Join"];
  lineJoin.valueType = KKLaneValueTypeFloat;
  lineJoin.choiceLabels = @[ @"Miter", @"Round", @"Bevel" ];
  lineJoin.choiceIcons = CanvasLineJoinGlyphs();
  lineJoin.componentMin = @[ @0.0 ];
  lineJoin.componentMax = @[ @2.0 ];
  lineJoin.integerValued = YES;
  lineJoin.animatable = NO;
  lineJoin.enabled = NO;
  lineJoin.ownerScoped = YES;
  lineJoin.categoryKey = @"Stroke";
  lineJoin.categorySymbol = @"lineweight";
  lineJoin.visibleWhenKey = @"Enabled";
  lineJoin.visibleWhenValues = @[ @1 ];
  [lineJoin insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0.0 ]]];

  // Stroke Style: solid / dashed / dotted (structural enum, gated by Enabled).
  // Dashed shows Dash Length + Gap; dotted shows Dot Gap; both show Marching
  // Ants Speed - via the visibleWhen cascade keyed on this lane (which is
  // itself gated by Enabled, so the whole sub-group hides when the stroke is
  // off).
  KKLane *strokeStyle = [KKLane laneWithKey:@"Stroke Style" label:@"Stroke Style"];
  strokeStyle.valueType = KKLaneValueTypeFloat;
  strokeStyle.choiceLabels = @[ @"Solid", @"Dashed", @"Dotted" ];
  strokeStyle.componentMin = @[ @0.0 ];
  strokeStyle.componentMax = @[ @2.0 ];
  strokeStyle.integerValued = YES;
  strokeStyle.animatable = NO;
  strokeStyle.enabled = NO;
  strokeStyle.ownerScoped = YES;
  strokeStyle.categoryKey = @"Stroke";
  strokeStyle.categorySymbol = @"lineweight";
  strokeStyle.visibleWhenKey = @"Enabled";
  strokeStyle.visibleWhenValues = @[ @1 ];
  [strokeStyle insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0.0 ]]];

  // Dash Length / Dash Gap / Dot Gap: animatable px scalars, each shown only
  // for the matching style. Marching Ants Speed (cycles/sec) shown for either
  // dashed or dotted; the renderer advances the pattern by speed x playhead
  // time, and animating this lane keyframes the rate. max is the slider's upper
  // bound: a single-component lane builds a slider that defaults its max to 1.0
  // when componentMax is empty, so every scalar must set a real ceiling or the
  // slider snaps between 0 and 1.
  KKLane * (^strokeScalar)(NSString *, double, double, NSArray *) =
      ^KKLane *(NSString *label, double seed, double max, NSArray *visVals) {
        KKLane *l = [KKLane laneWithKey:label label:label];
        l.valueType = KKLaneValueTypeFloat;
        l.componentMin = @[ @0.0 ];
        l.componentMax = @[ @(max) ];
        l.componentUnits = @[ @"px" ];
        l.integerValued = YES;
        l.enabled = NO;
        l.ownerScoped = YES;
        l.categoryKey = @"Stroke";
        l.categorySymbol = @"lineweight";
        l.visibleWhenKey = @"Stroke Style";
        l.visibleWhenValues = visVals;
        [l insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @(seed) ]]];
        return l;
      };
  KKLane *dashLength = strokeScalar(@"Dash Length", 20.0, 200.0, @[ @1 ]);
  KKLane *dashGap = strokeScalar(@"Dash Gap", 10.0, 200.0, @[ @1 ]);
  KKLane *dotGap = strokeScalar(@"Dot Gap", 10.0, 200.0, @[ @2 ]);
  KKLane *marchSpeed =
      strokeScalar(@"Marching Ants Speed", 0.0, 10.0, @[ @1, @2 ]);
  marchSpeed.componentUnits = @[ @"" ]; // cycles/sec, not pixels

  // Start / end endpoint markers: FOUR independent rows - a NON-animatable
  // glyph pill (the marker TYPE, 6-value order) and an animatable WIDTH field
  // (% of stroke width) for each end, ordered Start / Start Width / End / End
  // Width. Open-path ends only (scoped in the timeline builder); gated by
  // Enabled like the rest of the group.
  KKLane * (^markerType)(NSString *, BOOL) = ^KKLane *(NSString *label,
                                                       BOOL isStart) {
    KKLane *l = [KKLane laneWithKey:label label:label];
    l.valueType = KKLaneValueTypeFloat;
    l.choiceLabels =
        @[ @"None", @"Arrow", @"Circle", @"Square", @"Arrowhead", @"Line" ];
    l.choiceIcons = CanvasMarkerGlyphs(isStart);
    l.wrapsChoicePills = YES; // 6 icon+label pills wrap instead of overflowing
    l.componentMin = @[ @0.0 ];
    l.componentMax = @[ @5.0 ];
    l.integerValued = YES;
    l.animatable = NO;
    l.enabled = NO;
    l.ownerScoped = YES;
    l.categoryKey = @"Stroke";
    l.categorySymbol = @"lineweight";
    l.visibleWhenKey = @"Enabled";
    l.visibleWhenValues = @[ @1 ];
    [l insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0.0 ]]];
    return l;
  };
  // Width only applies when its marker is something other than "None". Gate it
  // on the corresponding type lane (non-None = indices 1..5); the type lane is
  // itself gated on "Enabled", so the visibleWhen cascade hides the width when
  // the stroke is off too (transitive controller carry).
  KKLane * (^markerWidth)(NSString *, NSString *) =
      ^KKLane *(NSString *label, NSString *typeLabel) {
        KKLane *l = [KKLane laneWithKey:label label:label];
        l.valueType = KKLaneValueTypeFloat;
        l.componentMin = @[ @0.0 ];
        l.componentMax = @[ @2000.0 ]; // field hard cap (% of stroke width)
        l.sliderMax = @500.0; // slider tops out at 500 %, field pushes past
        l.componentUnits = @[ @"%" ];
        l.integerValued = YES;
        l.enabled = NO;
        l.ownerScoped = YES;
        l.categoryKey = @"Stroke";
        l.categorySymbol = @"lineweight";
        l.visibleWhenKey = typeLabel;
        l.visibleWhenValues = @[ @1, @2, @3, @4, @5 ];
        [l insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @300.0 ]]];
        return l;
      };
  KKLane *startMarker = markerType(@"Start Marker", YES);
  KKLane *startMarkerWidth =
      markerWidth(@"Start Marker Width", @"Start Marker");
  KKLane *endMarker = markerType(@"End Marker", NO);
  KKLane *endMarkerWidth = markerWidth(@"End Marker Width", @"End Marker");

  // Draw On: a progressive "write-on" reveal trimming the stroke by arc length.
  // Start/End are the visible span fractions (0..100 %, the stroke spans
  // [Start, End]); animating End 0 -> 100 draws the line on. Caps + endpoint
  // markers ride the revealed tips (the render trims them together). Open-path
  // only (scoped in the timeline builder), like caps/markers. Stored as a
  // percentage like Opacity; the render reads /100.
  KKLane * (^drawOn)(NSString *, double) =
      ^KKLane *(NSString *label, double seed) {
        KKLane *l = [KKLane laneWithKey:label label:label];
        l.valueType = KKLaneValueTypeFloat;
        l.componentMin = @[ @0.0 ];
        l.componentMax = @[ @100.0 ];
        l.componentUnits = @[ @"%" ];
        l.integerValued = YES;
        l.enabled = NO; // animate per-layer via the dropdown
        l.ownerScoped = YES;
        l.categoryKey = @"Stroke";
        l.categorySymbol = @"lineweight";
        l.visibleWhenKey = @"Enabled";
        l.visibleWhenValues = @[ @1 ];
        [l insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @(seed) ]]];
        return l;
      };
  KKLane *drawOnStart = drawOn(@"Draw On Start", 0.0);
  KKLane *drawOnEnd = drawOn(@"Draw On End", 100.0);
  // Offset rotates where the visible window begins around the path (a closed
  // shape reveals from a chosen point; an open path's window wraps past the
  // ends). 0 % = no shift. The SLIDER stays 0..100 % but the field is unbounded
  // (the render wraps it mod 1), so you can keep cranking it to spin the reveal
  // round and round - forwards (>100 %) or backwards (<0 %).
  KKLane *drawOnOffset = drawOn(@"Draw On Offset", 0.0);
  drawOnOffset.sliderMin = @0.0;
  drawOnOffset.sliderMax = @100.0;
  drawOnOffset.componentMin = @[ @-1000000.0 ];
  drawOnOffset.componentMax = @[ @1000000.0 ];

  // Fill group: a solid (or gradient) fill of the closed shape, drawn beneath
  // the stroke. "Fill Enabled" is the structural master CHECKBOX (isToggle) -
  // when off it drops the rest of the Fill group via the visibleWhen cascade.
  // Not animatable; vector paths only (ownerScoped). Labelled "Fill Enabled"
  // (NOT "Enabled") so it can't collide with the Stroke group's toggle in the
  // label-keyed timeline. Seeded per-path from the flat fillEnabled.
  KKLane *fillOn = [KKLane laneWithKey:@"Fill Enabled" label:@"Fill Enabled"];
  fillOn.valueType = KKLaneValueTypeFloat;
  fillOn.isToggle = YES;
  fillOn.animatable = NO;
  fillOn.integerValued = YES;
  fillOn.componentLabels = @[];
  fillOn.componentUnits = @[];
  fillOn.enabled = NO;
  fillOn.ownerScoped = YES;
  fillOn.categoryKey = @"Fill";
  fillOn.categorySymbol = @"rectangle.trailinghalf.filled";
  [fillOn insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0.0 ]]];

  // Fill colour: the shared reusable colour group (Mode pill + solid swatch +
  // composite gradient), the SAME helper Stroke uses. No Dynamic mode. Labels
  // are prefixed ("Fill Mode" / "Fill Solid" / "Fill Gradient") so they can't
  // collide with the Stroke colour group. Seeded per-path from the flat
  // fillColorMode / fillR,G,B in CanvasLayerTimelineForPath.
  NSArray<KKLane *> *fillColor =
      KKColorLanesMake(@"Fill", /*includesDynamic=*/NO, /*animatable=*/YES);
  for (KKLane *l in fillColor) {
    l.enabled = NO;
    l.ownerScoped = YES;
    l.categoryKey = @"Fill";
    l.categorySymbol = @"rectangle.trailinghalf.filled";
  }
  // Gate the whole colour sub-group with the Fill Enabled toggle (only the Mode
  // lane needs the gate; Solid / Gradient are visibleWhen Mode, and the cascade
  // hides a lane when its controller is hidden).
  KKLane *fillMode = fillColor[0];
  fillMode.visibleWhenKey = @"Fill Enabled";
  fillMode.visibleWhenValues = @[ @1 ];

  // Fill Amount: IMAGE-layer tint strength (0 = original image, 100 = fully the
  // fill colour). Only meaningful for image layers (a vector path's fill is the
  // shape itself), so the timeline builder scopes this lane to images; gated by
  // Fill Enabled like the rest of the group. Animatable percent.
  KKLane *fillAmount = [KKLane laneWithKey:@"Fill Amount" label:@"Fill Amount"];
  fillAmount.valueType = KKLaneValueTypeFloat;
  fillAmount.componentMin = @[ @0.0 ];
  fillAmount.componentMax = @[ @100.0 ];
  fillAmount.componentUnits = @[ @"%" ];
  fillAmount.integerValued = YES;
  fillAmount.enabled = NO;
  fillAmount.ownerScoped = YES;
  fillAmount.categoryKey = @"Fill";
  fillAmount.categorySymbol = @"rectangle.trailinghalf.filled";
  // Only a Solid fill tints (a hachure has no tint amount). Gated on Fill Style
  // = Solid, which is itself gated by Fill Enabled (so the cascade hides this
  // when the fill is off too).
  fillAmount.visibleWhenKey = @"Fill Style";
  fillAmount.visibleWhenValues = @[ @0 ];
  [fillAmount insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @100.0 ]]];

  // Fill Style: how a VECTOR shape's fill is drawn - Solid, or a hachure /
  // cross-hatch / zigzag / dots line pattern (clipped to the shape, in the fill
  // colour). Structural enum, gated by Fill Enabled. (Independent of the Sketch
  // feature's hand-drawn roughness.)
  KKLane *fillStyle = [KKLane laneWithKey:@"Fill Style" label:@"Fill Style"];
  fillStyle.valueType = KKLaneValueTypeFloat;
  // Short labels (the glyph carries the meaning, like the Line Cap pills) so
  // the 5 pills stay compact - a long label ("Cross-hatch") wraps the row to
  // several lines and pushes the popover tall enough to scroll.
  fillStyle.choiceLabels =
      @[ @"Solid", @"Hachure", @"Cross", @"Zigzag", @"Dots" ];
  fillStyle.choiceIcons = CanvasFillStyleGlyphs();
  fillStyle.wrapsChoicePills = YES; // wrap gracefully on a narrow (sm) popover
  fillStyle.componentMin = @[ @0.0 ];
  fillStyle.componentMax = @[ @4.0 ];
  fillStyle.integerValued = YES;
  fillStyle.animatable = NO;
  fillStyle.enabled = NO;
  fillStyle.ownerScoped = YES;
  fillStyle.categoryKey = @"Fill";
  fillStyle.categorySymbol = @"rectangle.trailinghalf.filled";
  fillStyle.visibleWhenKey = @"Fill Enabled";
  fillStyle.visibleWhenValues = @[ @1 ];
  [fillStyle insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0.0 ]]];

  // Hachure controls (gap / angle / line weight), shown for any non-Solid Fill
  // Style. Animatable; seeded from the flat sketchFill* props.
  KKLane * (^hachure)(NSString *, double, double, double, NSString *) =
      ^KKLane *(NSString *label, double seed, double mn, double mx,
                NSString *unit) {
        KKLane *l = [KKLane laneWithKey:label label:label];
        l.valueType = KKLaneValueTypeFloat;
        l.componentMin = @[ @(mn) ];
        l.componentMax = @[ @(mx) ];
        l.componentUnits = @[ unit ];
        l.integerValued = YES;
        l.enabled = NO;
        l.ownerScoped = YES;
        l.categoryKey = @"Fill";
        l.categorySymbol = @"rectangle.trailinghalf.filled";
        l.visibleWhenKey = @"Fill Style";
        l.visibleWhenValues = @[ @1, @2, @3, @4 ];
        [l insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @(seed) ]]];
        return l;
      };
  KKLane *fillGap = hachure(@"Fill Gap", 25.0, 1.0, 200.0, @"px");
  KKLane *fillWeight = hachure(@"Fill Weight", 3.0, 1.0, 50.0, @"px");
  // Fill Angle uses the same angle control as the Transform Rotation (a dial),
  // so valueType Angle + unbounded; degrees, converted to radians in the
  // render.
  KKLane *fillAngle = [KKLane laneWithKey:@"Fill Angle" label:@"Fill Angle"];
  fillAngle.valueType = KKLaneValueTypeAngle;
  fillAngle.componentMin = @[];
  fillAngle.componentMax = @[];
  fillAngle.componentUnits = @[ @"°" ];
  fillAngle.integerValued = YES;
  fillAngle.enabled = NO;
  fillAngle.ownerScoped = YES;
  fillAngle.categoryKey = @"Fill";
  fillAngle.categorySymbol = @"rectangle.trailinghalf.filled";
  fillAngle.visibleWhenKey = @"Fill Style";
  fillAngle.visibleWhenValues = @[ @1, @2, @3, @4 ];
  [fillAngle insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @(-41.0) ]]];

  // Sketch group: a hand-drawn (rough.js-style) render of the stroke and fill -
  // the path geometry is jittered/bowed and optionally over-drawn. Applies to
  // whatever the layer actually draws, so the timeline builder shows the group
  // for a vector path when its Stroke OR Fill is enabled, and for an image only
  // when its Fill (a hachure) is enabled. "Sketch Enabled" is the structural
  // master checkbox; it gates the rest via the visibleWhen cascade. The OR rule
  // (Fill Enabled OR the Stroke "Enabled" toggle) uses the kit's visibleWhenOr:
  // on an image the absent Stroke toggle counts as off, so it reduces to "Fill
  // Enabled". Seeded per-path from the flat sketch* props.
  KKLane *sketchOn = [KKLane laneWithKey:@"Sketch Enabled" label:@"Sketch Enabled"];
  sketchOn.valueType = KKLaneValueTypeFloat;
  sketchOn.isToggle = YES;
  sketchOn.animatable = NO;
  sketchOn.integerValued = YES;
  sketchOn.componentLabels = @[];
  sketchOn.componentUnits = @[];
  sketchOn.enabled = NO;
  sketchOn.ownerScoped = YES;
  sketchOn.categoryKey = @"Sketch";
  sketchOn.categorySymbol = @"scribble.variable";
  sketchOn.visibleWhenKey = @"Fill Enabled";
  sketchOn.visibleWhenValues = @[ @1 ];
  sketchOn.visibleWhenOrKey = @"Enabled"; // the Stroke group's toggle
  sketchOn.visibleWhenOrValues = @[ @1 ];
  [sketchOn insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0.0 ]]];

  // Roughness / Bowing / Strokes / Seed, all gated by Sketch Enabled. Roughness
  // + Bowing are animatable 0-3 floats (rough.js norms, default 1); Strokes is
  // the over-draw pass count (1 single, 2 double-drawn); Seed varies the random
  // jitter. Seeded from the flat sketch* props.
  KKLane * (^sketchScalar)(NSString *, double, double, double, BOOL,
                           NSString *) =
      ^KKLane *(NSString *label, double seed, double mn, double mx,
                BOOL animatable, NSString *unit) {
        KKLane *l = [KKLane laneWithKey:label label:label];
        l.valueType = KKLaneValueTypeFloat;
        l.componentMin = @[ @(mn) ];
        l.componentMax = @[ @(mx) ];
        l.componentUnits = @[ unit ];
        l.animatable = animatable;
        l.enabled = NO;
        l.ownerScoped = YES;
        l.categoryKey = @"Sketch";
        l.categorySymbol = @"scribble.variable";
        l.visibleWhenKey = @"Sketch Enabled";
        l.visibleWhenValues = @[ @1 ];
        [l insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @(seed) ]]];
        return l;
      };
  KKLane *sketchRoughness =
      sketchScalar(@"Sketch Roughness", 1.0, 0.0, 3.0, YES, @"");
  KKLane *sketchBowing =
      sketchScalar(@"Sketch Bowing", 1.0, 0.0, 3.0, YES, @"");
  // Strokes is a structural 2-way choice (over-draw once or twice), not a
  // range, so it's a radio pill (Single / Double) like Fill Style / Line Cap -
  // value 0 = Single (1 pass), 1 = Double (2 passes). A constant slider for a
  // 1-2 range sat oddly among the animatable Roughness/Bowing sliders; the pill
  // is right-aligned chrome, so it also keeps those two sliders the only bars.
  KKLane *sketchStrokes = [KKLane laneWithKey:@"Sketch Strokes" label:@"Sketch Strokes"];
  sketchStrokes.valueType = KKLaneValueTypeFloat;
  sketchStrokes.choiceLabels = @[ @"Single", @"Double" ];
  sketchStrokes.componentMin = @[ @0.0 ];
  sketchStrokes.componentMax = @[ @1.0 ];
  sketchStrokes.integerValued = YES;
  sketchStrokes.animatable = NO;
  sketchStrokes.enabled = NO;
  sketchStrokes.ownerScoped = YES;
  sketchStrokes.categoryKey = @"Sketch";
  sketchStrokes.categorySymbol = @"scribble.variable";
  sketchStrokes.visibleWhenKey = @"Sketch Enabled";
  sketchStrokes.visibleWhenValues = @[ @1 ];
  [sketchStrokes insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @1.0 ]]];
  // Seed: a value-only random integer with a re-roll dice (KKSeedView), never a
  // lane. integerValued + animatable
  // NO + seedField YES.
  KKLane *sketchSeed =
      sketchScalar(@"Sketch Seed", 1.0, 0.0, 999999.0, NO, @"");
  sketchSeed.integerValued = YES;
  sketchSeed.seedField = YES;

  // Applicability + flat-value seeds, one line per lane (see
  // CanvasSetLaneSpec). Transform lanes (scale/position/rotation/anchor/
  // opacity) apply everywhere and keep their template identity defaults, so
  // they carry no spec.
  const NSUInteger kVec = CanvasLaneScopeVectorOnly;
  const NSUInteger kVecOpen = kVec | CanvasLaneScopeOpenEndOnly;
  const NSUInteger kNoGrp = CanvasLaneScopeNotGroup;
  CanvasSetLaneSpec(points, kVec, nil);
  CanvasSetLaneSpec(strokeOn, kVec, ^(KKBezierPath *p) {
    return @[ @(p.strokeEnabled ? 1.0 : 0.0) ];
  });
  CanvasSetLaneSpec(strokeWidth, kVec, ^(KKBezierPath *p) {
    double sw = p.strokeWidth, ew = p.endWidth > 0 ? p.endWidth : sw;
    return @[ @(sw), @(ew) ];
  });
  CanvasSetLaneSpec(strokeColor[0], kVec, ^(KKBezierPath *p) {
    return @[ @(p.strokeColorMode) ];
  });
  CanvasSetLaneSpec(strokeColor[1], kVec, ^(KKBezierPath *p) {
    return @[ @(p.strokeR), @(p.strokeG), @(p.strokeB), @1.0 ];
  });
  CanvasSetLaneSpec(strokeColor[2], kVec, nil); // gradient keeps its default
  CanvasSetLaneSpec(lineCap, kVecOpen, ^(KKBezierPath *p) {
    return @[ @(p.lineCap) ];
  });
  CanvasSetLaneSpec(lineJoin, kVec, ^(KKBezierPath *p) {
    return @[ @(p.lineJoin) ];
  });
  CanvasSetLaneSpec(startMarker, kVecOpen, ^(KKBezierPath *p) {
    return @[ @(p.startMarker) ];
  });
  CanvasSetLaneSpec(startMarkerWidth, kVecOpen, ^(KKBezierPath *p) {
    return @[ @(p.startMarkerSize * 100.0) ];
  });
  CanvasSetLaneSpec(endMarker, kVecOpen, ^(KKBezierPath *p) {
    return @[ @(p.endMarker) ];
  });
  CanvasSetLaneSpec(endMarkerWidth, kVecOpen, ^(KKBezierPath *p) {
    return @[ @(p.endMarkerSize * 100.0) ];
  });
  CanvasSetLaneSpec(drawOnStart, kVec, ^(KKBezierPath *p) {
    return @[ @(p.drawOnStart * 100.0) ];
  });
  CanvasSetLaneSpec(drawOnEnd, kVec, ^(KKBezierPath *p) {
    return @[ @(p.drawOnEnd * 100.0) ];
  });
  CanvasSetLaneSpec(drawOnOffset, kVec, ^(KKBezierPath *p) {
    return @[ @(p.drawOnOrigin * 100.0) ];
  });
  CanvasSetLaneSpec(strokeStyle, kVec, ^(KKBezierPath *p) {
    return @[ @(p.strokeStyle) ];
  });
  CanvasSetLaneSpec(dashLength, kVec, ^(KKBezierPath *p) {
    return @[ @(p.dashLength) ];
  });
  CanvasSetLaneSpec(dashGap, kVec, ^(KKBezierPath *p) {
    return @[ @(p.dashGap) ];
  });
  CanvasSetLaneSpec(dotGap, kVec, ^(KKBezierPath *p) {
    return @[ @(p.dotGap) ];
  });
  CanvasSetLaneSpec(marchSpeed, kVec, ^(KKBezierPath *p) {
    return @[ @(p.marchingAntsSpeed) ];
  });
  CanvasSetLaneSpec(fillOn, kNoGrp, ^(KKBezierPath *p) {
    return @[ @(p.fillEnabled ? 1.0 : 0.0) ];
  });
  CanvasSetLaneSpec(fillColor[0], kNoGrp, ^(KKBezierPath *p) {
    return @[ @(p.fillColorMode) ];
  });
  CanvasSetLaneSpec(fillColor[1], kNoGrp, ^(KKBezierPath *p) {
    return @[ @(p.fillR), @(p.fillG), @(p.fillB), @1.0 ];
  });
  CanvasSetLaneSpec(fillColor[2], kNoGrp, nil); // gradient keeps its default
  CanvasSetLaneSpec(fillAmount, CanvasLaneScopeImageOnly, ^(KKBezierPath *p) {
    return @[ @(p.fillTint * 100.0) ];
  });
  CanvasSetLaneSpec(fillStyle, kNoGrp, ^(KKBezierPath *p) {
    return @[ @(p.sketchFillStyle) ];
  });
  CanvasSetLaneSpec(fillGap, kNoGrp, ^(KKBezierPath *p) {
    return @[ @(p.sketchFillGap) ];
  });
  CanvasSetLaneSpec(fillAngle, kNoGrp, ^(KKBezierPath *p) {
    return @[ @(p.sketchFillAngle) ];
  });
  CanvasSetLaneSpec(fillWeight, kNoGrp, ^(KKBezierPath *p) {
    return @[ @(p.sketchFillWeight) ];
  });
  CanvasSetLaneSpec(sketchOn, kNoGrp, ^(KKBezierPath *p) {
    return @[ @(p.sketchEnabled ? 1.0 : 0.0) ];
  });
  CanvasSetLaneSpec(sketchRoughness, kNoGrp, ^(KKBezierPath *p) {
    return @[ @(p.sketchRoughness) ];
  });
  CanvasSetLaneSpec(sketchBowing, kNoGrp, ^(KKBezierPath *p) {
    return @[ @(p.sketchBowing) ];
  });
  CanvasSetLaneSpec(sketchStrokes, kNoGrp, ^(KKBezierPath *p) {
    // Pill index: flat sketchStrokes 2 (or default) -> Double (1), 1 ->
    // Single (0).
    return @[ @((p.sketchStrokes >= 2 || p.sketchStrokes == 0) ? 1.0 : 0.0) ];
  });
  CanvasSetLaneSpec(sketchSeed, kNoGrp, ^(KKBezierPath *p) {
    return @[ @(p.sketchSeed ?: 1) ];
  });

  return @[
    points,         strokeOn,         strokeWidth,     strokeColor[0],
    strokeColor[1], strokeColor[2],   lineCap,         lineJoin,
    startMarker,    startMarkerWidth, endMarker,       endMarkerWidth,
    drawOnStart,    drawOnEnd,        drawOnOffset,    strokeStyle,
    dashLength,     dashGap,          dotGap,          marchSpeed,
    fillOn,         fillColor[0],     fillColor[1],    fillColor[2],
    fillAmount,     fillStyle,        fillGap,         fillAngle,
    fillWeight,     sketchOn,         sketchRoughness, sketchBowing,
    sketchStrokes,  sketchSeed,       scale,           position,
    rotation,       anchor,           opacity
  ];
}

+ (NSArray<NSArray<NSString *> *> *)oscCompounds {
  return @[
    @[ @"Points" ], @[ @"Corners" ], @[ @"Position", @"Path" ], @[ @"Scale" ],
    @[ @"Rotation", @"Rotation.X", @"Rotation.Y", @"Rotation.Z" ],
    @[ @"Anchor" ]
  ];
}

+ (NSDictionary<NSString *, NSNumber *> *)defaultOSCElementsForVector:
    (BOOL)vector {
  if (!vector) {
    // Image / group: no point/pen editing, so the transform gizmo shows by
    // default (otherwise the layer would have NO visible control). The rings
    // show per-axis; "Points" is off (it's not applicable and the path-edit OSC
    // skips images anyway).
    return @{
      @"Points" : @NO,
      @"Corners" : @NO, // images / groups have no corner-radius widgets
      @"Position" : @YES,
      @"Path" : @YES,
      @"Scale" : @YES,
      @"Rotation.X" : @YES,
      @"Rotation.Y" : @YES,
      @"Rotation.Z" : @YES,
      @"Anchor" : @YES
    };
  }
  // Vector path: transform OSCs start hidden so the viewer is clean; Opt-peek
  // reveals them as ghosts to Opt-click on. Rotation hides its individual X/Y/Z
  // RINGS rather than the group: Opt-peek only reveals individually-hidden
  // elements, and a hidden GROUP wouldn't make its axes reveal-eligible (you
  // could never Opt-click them back). Leaving the group on keeps the rings
  // per-axis revealable + re-enableable.
  return @{
    @"Points" : @YES, // the path-edit anchors show by default (point-editing is
                      // the obvious action); transform OSCs start hidden
    @"Corners" : @YES, // corner-radius widgets show by default; toggle off to
                       // declutter a busy path (separate from Points)
    @"Position" : @NO,
    @"Path" : @NO,
    @"Scale" : @NO,
    @"Rotation.X" : @NO,
    @"Rotation.Y" : @NO,
    @"Rotation.Z" : @NO,
    @"Anchor" : @NO
  };
}

@end
