/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasInspectorView.h"
#import "CanvasLayerRender.h" // CanvasReadLayerPaths (fresh, not the snapshot)
#import "CanvasLayerTimeline.h"
#import "CanvasPathEditController.h" // CanvasPathIsLargeVector
#import "CanvasStrokeGlyphs.h"       // Line Cap / Join pill glyphs
#import "Constants.h"
#import "Plugin_Private.h"
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKColorLanes.h>
#import <KeyframelessKit/KKDataBlob.h>
#import <KeyframelessKit/KKPlugin+InspectorCallbacks.h>
#import <KeyframelessKit/KKTimingStage.h>

@implementation CanvasPlugin (CustomUI)

+ (NSArray<KKLane *> *)availableLanes {
  // Transform group. These are lane TEMPLATES: each layer owns its own timeline
  // built from them (per-layer transforms; the inspector shows the selected
  // layer's), so a fresh layer starts at identity. The render ignores them
  // until the transform plumbing lands; stroke / fill groups come later.
  //
  // Scale: 2-component aspect-linked percent, modelled on MagicMove's box-OSC
  // Scale lane so the box OSC drops straight in. Identity = 100%. Unbounded
  // above (like MagicMove); 0 floor.
  KKLane *scale = [KKLane laneWithLabel:@"Scale"];
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
  // identity), displayed as pixels. Same reusable curved-path Position as
  // Glow/MagicMove (spatialCurvable). Off-canvas allowed, so no min/max.
  KKLane *position = [KKLane laneWithLabel:@"Position"];
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

  // Rotation: 3-axis (X/Y/Z) Euler degrees, modelled on MagicMove's Rotation
  // lane so the kit's KKRotationOSC + mini rotation rings drop straight in.
  // Identity = 0. Unbounded (angles accumulate past 360). Z is the in-plane
  // spin (rendered today); X/Y tilt renders once the perspective transform
  // lands. Axis ring colours match MagicMove (X red, Y green, Z blue).
  KKLane *rotation = [KKLane laneWithLabel:@"Rotation"];
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
  // pixels, same space as Position. Off-layer allowed, so no min/max. Modelled
  // on MagicMove's Anchor lane so the kit's KKAnchorOSC + mini drop straight in.
  // On its own it does nothing - it only moves where rotation/scale pivot.
  KKLane *anchor = [KKLane laneWithLabel:@"Anchor"];
  anchor.valueType = KKLaneValueTypeGeneric;
  anchor.componentMin = @[];
  anchor.componentMax = @[];
  anchor.componentUnits = @[ @"px", @"px" ];
  anchor.componentsScaleWithMedia = YES; // stored 0..1, displayed as pixels
  anchor.componentLabels = @[ @"X", @"Y" ];
  anchor.enabled = NO; // constant by default; animate per-layer via the dropdown
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
  KKLane *points = [KKLane laneWithLabel:@"Points"];
  points.valueType = KKLaneValueTypeGeneric;
  points.componentMin = @[];
  points.componentMax = @[];
  points.componentUnits = @[];
  points.componentLabels = @[];
  points.animatable = YES;
  points.oscEditedOnly = YES;
  points.enabled = NO; // constant by default; animate per-layer via the dropdown
  points.categoryKey = @"Core";
  points.categorySymbol = @"scribble.variable";
  [points insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[]]];

  // Stroke group (between Core and Transform). "Enabled": a structural on/off
  // CHECKBOX (isToggle) - the group's master switch. Value 1 = on. When off,
  // toggles the rest of the Stroke group via the visibleWhen cascade. Not
  // animatable; vector paths only (ownerScoped, so images / groups don't get it
  // re-seeded). Seeded per-path from the layer's flat strokeEnabled. Listed
  // FIRST so it heads the group.
  KKLane *strokeOn = [KKLane laneWithLabel:@"Enabled"];
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
  // aspect-linked float in NATIVE pixels (Start / End), LINKED by default so one
  // box drives both - the classic linked-field pattern (like a radius). The
  // render is constant-width today (uses Start; End taper renders later), and
  // links to End so the linked default is exact. Vector paths only (scoped in
  // CanvasLayerTimelineForPath; images / groups have no stroke). Seeded per-path
  // from the layer's flat strokeWidth/endWidth there, so existing paths are
  // unchanged; the template default matches a freshly-drawn path (20px).
  KKLane *strokeWidth = [KKLane laneWithLabel:@"Stroke Width"];
  strokeWidth.valueType = KKLaneValueTypeFloat;
  strokeWidth.componentMin = @[ @0.0, @0.0 ]; // no negative width
  strokeWidth.componentUnits = @[ @"px", @"px" ];
  strokeWidth.componentLabels = @[ @"Start", @"End" ];
  strokeWidth.autoSizesComponentLabels = YES; // "Start"/"End" don't fit 1-char slot
  strokeWidth.integerValued = YES; // whole px (sub-pixel widths don't help)
  strokeWidth.aspectLinkable = YES;
  strokeWidth.aspectLinked = YES;
  strokeWidth.enabled = NO; // constant by default; animate per-layer via dropdown
  strokeWidth.ownerScoped = YES; // vector paths only (not re-seeded for images)
  strokeWidth.categoryKey = @"Stroke";
  strokeWidth.categorySymbol = @"lineweight";
  // Gated by the "Enabled" toggle via the shared visibleWhen cascade: when the
  // stroke is off this lane drops out of EVERY surface (constants/keypose
  // popover, animated dropdown, lane filter, Advanced graph) - the one source of
  // truth being the toggle's value. Every later Stroke lane (color, dash, ...)
  // wires the same rule, so the whole group hides as one.
  strokeWidth.visibleWhenLabel = @"Enabled";
  strokeWidth.visibleWhenValues = @[ @1 ];
  [strokeWidth insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                              values:@[ @20.0, @20.0 ]]];

  // Stroke colour: the shared reusable colour group (Mode pill + solid swatch +
  // composite gradient), the SAME helper Glow uses. No Dynamic mode - a vector
  // stroke has no source pixels to sample - so the modes are Solid (default) +
  // Gradient. Labels are prefixed ("Stroke Mode" / "Stroke Solid" / "Stroke
  // Gradient") so a future Fill colour group can't collide. Seeded per-path from
  // the flat strokeColorMode / strokeR,G,B in CanvasLayerTimelineForPath. The kit
  // renders the swatch + gradient editor for KKLaneValueType Color/Gradient
  // automatically.
  NSArray<KKLane *> *strokeColor =
      KKColorLanesMake(@"Stroke", /*includesDynamic=*/NO, /*animatable=*/YES);
  for (KKLane *l in strokeColor) {
    l.enabled = NO; // constant by default; animate per-layer via the dropdown
    l.ownerScoped = YES; // vector paths only, like the rest of the group
    l.categoryKey = @"Stroke";
    l.categorySymbol = @"lineweight";
  }
  // Gate the whole colour sub-group with the same Enabled toggle. Only the Mode
  // lane needs the gate: the Solid / Gradient lanes are visibleWhen the Mode lane
  // (set by KKColorLanesMake), and the visibility cascade hides a lane when its
  // controller is itself hidden - so Enabled=off hides Mode, which hides both.
  KKLane *strokeMode = strokeColor[0];
  strokeMode.visibleWhenLabel = @"Enabled";
  strokeMode.visibleWhenValues = @[ @1 ];

  // Line Cap (open-path ends) + Line Join (corners): NON-animatable structural
  // enums shown as GLYPH radio pills (the choiceIcons; choiceLabels stay as the
  // accessibility / value names). Seeded per-path from the flat lineCap/lineJoin
  // in CanvasLayerTimelineForPath; gated by Enabled like the rest of the group.
  KKLane *lineCap = [KKLane laneWithLabel:@"Line Cap"];
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
  lineCap.visibleWhenLabel = @"Enabled";
  lineCap.visibleWhenValues = @[ @1 ];
  [lineCap insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0.0 ]]];

  KKLane *lineJoin = [KKLane laneWithLabel:@"Line Join"];
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
  lineJoin.visibleWhenLabel = @"Enabled";
  lineJoin.visibleWhenValues = @[ @1 ];
  [lineJoin insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0.0 ]]];

  // Stroke Style: solid / dashed / dotted (structural enum, gated by Enabled).
  // Dashed shows Dash Length + Gap; dotted shows Dot Gap; both show Marching
  // Ants Speed - via the visibleWhen cascade keyed on this lane (which is itself
  // gated by Enabled, so the whole sub-group hides when the stroke is off).
  KKLane *strokeStyle = [KKLane laneWithLabel:@"Stroke Style"];
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
  strokeStyle.visibleWhenLabel = @"Enabled";
  strokeStyle.visibleWhenValues = @[ @1 ];
  [strokeStyle insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0.0 ]]];

  // Dash Length / Dash Gap / Dot Gap: animatable px scalars, each shown only for
  // the matching style. Marching Ants Speed (cycles/sec) shown for either dashed
  // or dotted; the renderer advances the pattern by speed x playhead time, and
  // animating this lane keyframes the rate.
  // max is the slider's upper bound: a single-component lane builds a slider that
  // defaults its max to 1.0 when componentMax is empty, so every scalar must set
  // a real ceiling or the slider snaps between 0 and 1.
  KKLane *(^strokeScalar)(NSString *, double, double, NSArray *) =
      ^KKLane *(NSString *label, double seed, double max, NSArray *visVals) {
    KKLane *l = [KKLane laneWithLabel:label];
    l.valueType = KKLaneValueTypeFloat;
    l.componentMin = @[ @0.0 ];
    l.componentMax = @[ @(max) ];
    l.componentUnits = @[ @"px" ];
    l.integerValued = YES;
    l.enabled = NO;
    l.ownerScoped = YES;
    l.categoryKey = @"Stroke";
    l.categorySymbol = @"lineweight";
    l.visibleWhenLabel = @"Stroke Style";
    l.visibleWhenValues = visVals;
    [l insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @(seed) ]]];
    return l;
  };
  KKLane *dashLength = strokeScalar(@"Dash Length", 20.0, 200.0, @[ @1 ]);
  KKLane *dashGap = strokeScalar(@"Dash Gap", 10.0, 200.0, @[ @1 ]);
  KKLane *dotGap = strokeScalar(@"Dot Gap", 10.0, 200.0, @[ @2 ]);
  KKLane *marchSpeed = strokeScalar(@"Marching Ants Speed", 0.0, 10.0, @[ @1, @2 ]);
  marchSpeed.componentUnits = @[ @"" ]; // cycles/sec, not pixels

  // Start / end endpoint markers: FOUR independent rows - a NON-animatable glyph
  // pill (the marker TYPE, 6-value order) and an animatable WIDTH field (% of
  // stroke width) for each end, ordered Start / Start Width / End / End Width.
  // Open-path ends only (scoped in the timeline builder); gated by Enabled like
  // the rest of the group.
  KKLane *(^markerType)(NSString *, BOOL) = ^KKLane *(NSString *label,
                                                      BOOL isStart) {
    KKLane *l = [KKLane laneWithLabel:label];
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
    l.visibleWhenLabel = @"Enabled";
    l.visibleWhenValues = @[ @1 ];
    [l insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0.0 ]]];
    return l;
  };
  // Width only applies when its marker is something other than "None". Gate it
  // on the corresponding type lane (non-None = indices 1..5); the type lane is
  // itself gated on "Enabled", so the visibleWhen cascade hides the width when
  // the stroke is off too (transitive controller carry).
  KKLane *(^markerWidth)(NSString *, NSString *) =
      ^KKLane *(NSString *label, NSString *typeLabel) {
    KKLane *l = [KKLane laneWithLabel:label];
    l.valueType = KKLaneValueTypeFloat;
    l.componentMin = @[ @0.0 ];
    l.componentMax = @[ @2000.0 ]; // field hard cap (% of stroke width)
    l.sliderMax = @500.0;          // slider tops out at 500 %, field pushes past
    l.componentUnits = @[ @"%" ];
    l.integerValued = YES;
    l.enabled = NO;
    l.ownerScoped = YES;
    l.categoryKey = @"Stroke";
    l.categorySymbol = @"lineweight";
    l.visibleWhenLabel = typeLabel;
    l.visibleWhenValues = @[ @1, @2, @3, @4, @5 ];
    [l insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @300.0 ]]];
    return l;
  };
  KKLane *startMarker = markerType(@"Start Marker", YES);
  KKLane *startMarkerWidth = markerWidth(@"Start Marker Width", @"Start Marker");
  KKLane *endMarker = markerType(@"End Marker", NO);
  KKLane *endMarkerWidth = markerWidth(@"End Marker Width", @"End Marker");

  return @[
    points, strokeOn, strokeWidth, strokeColor[0], strokeColor[1],
    strokeColor[2], lineCap, lineJoin, startMarker, startMarkerWidth, endMarker,
    endMarkerWidth, strokeStyle, dashLength, dashGap, dotGap, marchSpeed, scale,
    position, rotation, anchor, opacity
  ];
}

+ (NSArray<NSArray<NSString *> *> *)oscCompounds {
  return @[
    @[ @"Points" ], @[ @"Position", @"Path" ], @[ @"Scale" ],
    @[ @"Rotation", @"Rotation.X", @"Rotation.Y", @"Rotation.Z" ], @[ @"Anchor" ]
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
    @"Position" : @NO,
    @"Path" : @NO,
    @"Scale" : @NO,
    @"Rotation.X" : @NO,
    @"Rotation.Y" : @NO,
    @"Rotation.Z" : @NO,
    @"Anchor" : @NO
  };
}

- (void)canvasApplyOSCForLayer:(NSString *)layerID
                          keys:(NSArray<NSString *> *)keys {
  KKPluginInstanceState *ist = KKInstanceStateForAPI(self.apiManager);
  if (!ist)
    return;
  // Resolve the layer up front: its kind picks the default OSC seed AND scopes
  // the checklist below (a vector path has point editing; an image / group only
  // has the transform gizmo).
  // Read the layer stack FRESH from the param (not the published snapshot): on a
  // path-op undo both kParamLayerData + kParamUIState change, and this can run
  // (from the UIState handler) before the blob snapshot is republished - the
  // stale snapshot wouldn't contain the restored operand, so it'd resolve to nil
  // and fall back to the image-like gizmo defaults until a reselect.
  KKBezierPath *layer = nil;
  for (KKBezierPath *p in CanvasReadLayerPaths(self.apiManager, self))
    if ([p.layerID isEqualToString:(layerID ?: @"")]) {
      layer = p;
      break;
    }
  // A too-large path (e.g. a detailed imported SVG) isn't editable per-anchor,
  // so it's treated like an image: the transform gizmo shows by default, not the
  // point-edit OSC.
  BOOL vector = layer && !layer.isImage && !layer.isGroup &&
                (layer.strokeEnabled || layer.fillEnabled) &&
                !CanvasPathIsLargeVector(layer);

  NSDictionary *els = ist.oscElementsByOwner[layerID ?: @""];
  if (![els isKindOfClass:[NSDictionary class]])
    els = [CanvasPlugin
        defaultOSCElementsForVector:vector]; // new / unseen layer -> default
  // Refresh through the kit from a synthesized state (global master + THIS
  // layer's element map); this sets the active hiddenOSCElements + view + mini.
  NSDictionary *state =
      @{@"oscMasterVisible" : @(ist.oscMasterVisible), @"oscElements" : els};
  [self kkRefreshOSCVisibilityFromState:state
                                   view:(KKTimelineInspectorView *)
                                            self.inspectorView
                               renderer:nil
                            elementKeys:keys];
  [(CanvasInspectorView *)self.inspectorView syncMiniHandleVisibility];
  // Scope the OSC checklist's path-only "Points" element to vector-path layers:
  // images / groups drop it so they don't list a control they can't use. The
  // checklist + its states read this live property (see kkWire), so the next
  // open rebuilds against the scoped set.
  NSMutableArray<NSArray<NSString *> *> *scoped = [NSMutableArray array];
  for (NSArray<NSString *> *c in [CanvasPlugin oscCompounds])
    if (vector || ![c containsObject:@"Points"])
      [scoped addObject:c];
  ((KKTimelineInspectorView *)self.inspectorView).oscVisibilityCompounds =
      scoped;
  // If the OSC settings popover is open (companion layer list drove the
  // switch), refresh its checkboxes to this layer's set.
  [(KKTimelineInspectorView *)self.inspectorView refreshOpenOSCChecklist];
}

- (void)canvasToggleOSCElement:(NSString *)key
                       visible:(BOOL)visible
                          keys:(NSArray<NSString *> *)keys {
  CanvasInspectorView *view = (CanvasInspectorView *)self.inspectorView;
  NSString *layerID = view.resolvedSelectedLayerID ?: @"";
  KKPluginInstanceState *ist = KKInstanceStateForAPI(self.apiManager);
  if (!ist)
    return;
  // Flip the ACTIVE set (the selected layer's), then write it back into that
  // layer's slot in the per-layer map and persist the whole map.
  NSMutableSet<NSString *> *hidden =
      [(ist.hiddenOSCElements ?: [NSSet set]) mutableCopy];
  if (visible)
    [hidden removeObject:key];
  else
    [hidden addObject:key];
  ist.hiddenOSCElements = hidden;
  NSMutableDictionary<NSString *, NSNumber *> *els =
      [NSMutableDictionary dictionaryWithCapacity:keys.count];
  for (NSString *k in keys)
    els[k] = @(![hidden containsObject:k]);
  NSMutableDictionary *byLayer = [(ist.oscElementsByOwner ?: @{}) mutableCopy];
  byLayer[layerID] = els;
  ist.oscElementsByOwner = byLayer;
  [self patchUIStateKey:@"oscElementsByLayer"
                  value:byLayer
                paramID:kParamUIState];
  [view syncMiniHandleVisibility];
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
    // Per-layer timelines: the kit inspector EDITS the SELECTED layer's own
    // animationJSON with PLAIN labels (so the Animated dropdown / Constants /
    // Keypose work unchanged). The all-layers overview is drawn separately as
    // read-only context. (NOT the global kKKParamTimelineData; st.timeline is
    // unused here.) Selection is the topmost layer until panel-driven selection
    // lands.
    NSString *layerB64 = KKReadCustomParamString(getAPI, kParamLayerData);
    NSMutableArray<KKBezierPath *> *layerPaths =
        layerB64.length
            ? [KKBezierPath
                  pathsFromBlob:[[NSData alloc]
                                    initWithBase64EncodedString:layerB64
                                                        options:0]]
            : [NSMutableArray array];
    KKTimeline *layerTL =
        CanvasLayerTimelineForPath(CanvasSelectedLayerForPaths(layerPaths, nil),
                                   [CanvasPlugin availableLanes]);
    KKTimeline *timeline = [self timelineStampedWithClipDuration:layerTL];

    // Frame + clip duration for the keypose-snap epsilon and the basic-view
    // scrubber clamp. FxTimingAPI resolves inside this action scope; we push
    // them into the view right after construction to avoid the render-push
    // race documented in Rounded.
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
    }

    // Mint the per-instance state UUID here (inside the action scope, where the
    // setting API resolves) so the viewer Transform OSC can read its visibility
    // - without it the OSC reads no state and defaults to visible.
    KKInstanceStateEnsureForAPI(self.apiManager);

    // Publish the full UIState JSON for the viewer OSC (it can't read the custom
    // param) - it reads view-prefs like "autoSelect" and uses it as the base to
    // merge a new selection into on a hit-test click.
    CanvasSetUIStateSnapshot(KKReadCustomParamString(getAPI, kParamUIState));

    [actionAPI endAction:self];

    NSArray<KKLane *> *available = [CanvasPlugin availableLanes];
    CanvasInspectorView *view =
        [[CanvasInspectorView alloc] initWithAPIManager:self.apiManager
                                            loopEnabled:st.loopEnabled
                                  maintainTimingEnabled:st.maintainTimingEnabled
                                              activeTab:st.activeTab
                                         availableLanes:available
                                               timeline:timeline];
    if (seedClipDurSec > 0)
      [view setClipDurationSeconds:seedClipDurSec];
    if (seedFrameDurSec > 0)
      [view setFrameDurationSeconds:seedFrameDurSec];
    // Seed the motion-blur toolbar row from the persisted blob (the standard
    // callbacks below own the write-back; this restores the toggle on reopen).
    [view setMotionBlurEnabled:st.motionBlurEnabled];
    [view setMotionBlurShutterAngle:st.motionBlurShutterAngle
                            samples:st.motionBlurSamples];
    [view setMotionBlurMode:(KKMotionBlurMode)st.motionBlurMode];

    [self kkWireStandardInspectorCallbacksForView:view
                                   uiStateParamID:kParamUIState
                               renderNudgeParamID:kParamRenderNudge
                                    dragUndoLabel:@"Adjust Canvas"
                               detachedWindowSize:CGSizeMake(720.0, 460.0)];

    // Persist timeline edits PER LAYER instead of to the global timeline param:
    // decompose the edited merged timeline by layerKey and write each layer's
    // clean animationJSON back into the layer blob. Overrides the shared
    // wiring's onTimelineMutated (which targets kKKParamTimelineData). Runs in
    // an action scope so it nests inside the drag undo group (onDragBegin/End).
    __weak CanvasPlugin *weakSelf = self;
    view.onTimelineMutated = ^(KKTimeline *updated) {
      __strong CanvasPlugin *s = weakSelf;
      if (!s)
        return;
      id<FxCustomParameterActionAPI_v4> act = [s.apiManager
          apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
      if (!act)
        return;
      [act startAction:s];
      id<FxParameterRetrievalAPI_v6> get =
          [s.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      id<FxParameterSettingAPI_v5> set =
          [s.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      NSString *b64 = KKReadCustomParamString(get, kParamLayerData);
      NSMutableArray<KKBezierPath *> *cur =
          b64.length
              ? [KKBezierPath pathsFromBlob:[[NSData alloc]
                                                initWithBase64EncodedString:b64
                                                                    options:0]]
              : [NSMutableArray array];
      CanvasApplyTimelineToPath(
          updated,
          CanvasSelectedLayerForPaths(
              cur, ((CanvasInspectorView *)s.inspectorView).selectedLayerID));
      NSData *blob = [KKBezierPath blobFromPaths:cur];
      KKWriteCustomParamString(set, [blob base64EncodedStringWithOptions:0],
                               kParamLayerData);
      [act endAction:s];
    };

    // Keypose edits in either graph mutate the ALL-LAYERS graph timeline; split
    // it back per layer (by layerKey) and write each layer's animationJSON.
    view.basicLanesView.onGraphTimelineMutated = ^(KKTimeline *merged) {
      __strong CanvasPlugin *s = weakSelf;
      if (!s)
        return;
      id<FxCustomParameterActionAPI_v4> act = [s.apiManager
          apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
      if (!act)
        return;
      [act startAction:s];
      id<FxParameterRetrievalAPI_v6> get =
          [s.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      id<FxParameterSettingAPI_v5> set =
          [s.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      NSString *b64 = KKReadCustomParamString(get, kParamLayerData);
      NSMutableArray<KKBezierPath *> *cur =
          b64.length
              ? [KKBezierPath pathsFromBlob:[[NSData alloc]
                                                initWithBase64EncodedString:b64
                                                                    options:0]]
              : [NSMutableArray array];
      CanvasApplyMergedTimelineToPaths(merged, cur,
                                       [CanvasPlugin availableLanes]);
      NSData *blob = [KKBezierPath blobFromPaths:cur];
      KKWriteCustomParamString(set, [blob base64EncodedStringWithOptions:0],
                               kParamLayerData);
      [act endAction:s];
    };

    self.inspectorView = view;

    // Viewer OSC visibility: a global "show controls" toggle + per-element
    // opt-click hide/show, HIDDEN by default (master defaults OFF for Canvas).
    // nil renderer so the toggle drives only the viewer OSC's instance state
    // (which CanvasOSC reads), not the popover MINI handles
    // (editing-contextual, stay shown). Pills: Position (+ its motion Path),
    // Scale, and Rotation (+ its X/Y/Z rings). Shared definition so the
    // parameterChanged refresh uses the identical element-key set.
    NSArray<NSArray<NSString *> *> *oscCompounds = [CanvasPlugin oscCompounds];
    // Wire the REAL mini renderer here so onHandleVisibilityToggled is set -
    // the mini's opt-reveal ghost gates on (revealHidden &&
    // onHandleVisibilityToggled
    // != nil); the kit overlay already drives revealHidden on Option-hold, so
    // this is the missing half (it also gives opt-click-in-mini hide/show, like
    // MagicMove/Glow). handlesHidden + hiddenHandleLabels stay owned by
    // -syncMiniHandleVisibility (so lock ORs in without fighting the kit's
    // async master set); kkRefresh below keeps nil for the same reason.
    [self kkWireOSCVisibilityForView:view
                            renderer:(KKMiniViewerRenderer *)
                                         view.miniViewerDelegate
                           compounds:oscCompounds
                             paramID:kParamUIState];
    NSArray<NSString *> *oscKeys =
        [CanvasPlugin kkOSCElementKeysForCompounds:oscCompounds];
    NSMutableDictionary *visState =
        [st.uiState mutableCopy] ?: [NSMutableDictionary dictionary];
    // Master "show controls" toggle stays GLOBAL (kkWire persists it under
    // oscMasterVisible). Default ON so opt-hold can reveal the per-layer
    // ghosts.
    KKPluginInstanceState *ist = KKInstanceStateEnsureForAPI(self.apiManager);
    ist.oscMasterVisible = visState[@"oscMasterVisible"]
                               ? [visState[@"oscMasterVisible"] boolValue]
                               : YES;
    // Per-LAYER element visibility: each layer keeps its own hidden set, stored
    // in kParamUIState["oscElementsByLayer"] keyed by layerID and mirrored into
    // the per-instance state. The ACTIVE set (ist.hiddenOSCElements, read by
    // the viewer OSC + mini in this same process) tracks the selected layer;
    // switch layers -> swap the active set (see -canvasApplyOSCForLayer:keys:).
    // A new layer with no entry falls back to the shared default seed.
    NSDictionary *byLayer = visState[@"oscElementsByLayer"];
    ist.oscElementsByOwner =
        [byLayer isKindOfClass:[NSDictionary class]] ? byLayer : @{};
    // Restore the SAVED selected layer. createView otherwise starts at the
    // topmost layer, so after a reboot the inspector/OSC/Constants target layer
    // 1 instead of the layer that was selected when the project was saved. Do it
    // BEFORE canvasApplyOSCForLayer so the OSC visibility set is the restored
    // layer's. restoreSelectedLayerID self-guards no-ops; the persist-on-select
    // block isn't wired yet (so no churn), but flag restoringSelection anyway.
    NSString *savedSel = visState[@"selectedLayerID"];
    NSArray<NSString *> *savedSelIDs =
        [visState[@"selectedLayerIDs"] isKindOfClass:[NSArray class]]
            ? visState[@"selectedLayerIDs"]
            : nil;
    if (([savedSel isKindOfClass:[NSString class]] && savedSel.length) ||
        savedSelIDs.count) {
      self.restoringSelection = YES;
      [view restoreSelectedLayerIDs:savedSelIDs primary:savedSel];
      self.restoringSelection = NO;
    }
    [self canvasApplyOSCForLayer:view.resolvedSelectedLayerID keys:oscKeys];

    __weak CanvasPlugin *weakOSC = self;
    // Element toggle routes to the SELECTED layer (replaces the kit's global
    // per-element handler wired above; master + states stay as kkWire set
    // them).
    view.oscVisibilityElementToggled = ^(NSInteger compoundIdx,
                                         NSInteger segIdx, BOOL isOn) {
      __strong CanvasPlugin *s = weakOSC;
      // Index into the LIVE (per-layer scoped) compounds, not the full set, so
      // the checklist's row indices map to the right element after Points is
      // dropped for an image / group.
      NSArray<NSArray<NSString *> *> *cmp =
          ((KKTimelineInspectorView *)s.inspectorView).oscVisibilityCompounds;
      if (compoundIdx < 0 || compoundIdx >= (NSInteger)cmp.count ||
          segIdx < 0 || segIdx >= (NSInteger)cmp[compoundIdx].count)
        return;
      [s canvasToggleOSCElement:cmp[compoundIdx][segIdx]
                        visible:isOn
                           keys:oscKeys];
    };
    // Opt-click a handle in the MINI viewer hides it for the SELECTED layer too
    // (kkWire pointed this at the kit's global toggle; re-point per-layer).
    KKMiniViewerRenderer *miniRenderer =
        (KKMiniViewerRenderer *)view.miniViewerDelegate;
    miniRenderer.onHandleVisibilityToggled = ^(NSString *label) {
      __strong CanvasPlugin *s = weakOSC;
      BOOL currentlyHidden =
          [KKInstanceStateForAPI(s.apiManager).hiddenOSCElements
              containsObject:label];
      [s canvasToggleOSCElement:label visible:currentlyHidden keys:oscKeys];
    };
    // Layer-selection change swaps the active OSC set to that layer's. The mini
    // updates synchronously (syncMiniHandleVisibility); the VIEWER OSC only
    // re-reads on its next drawOSC, and a selection isn't a param write, so
    // nudge a render to redraw it immediately (else it lags a few ticks).
    // Toggles already nudge via the kParamUIState write.
    view.onSelectedLayerChanged =
        ^(NSString *resolvedLayerID, NSArray<NSString *> *selectedLayerIDs) {
          __strong CanvasPlugin *s = weakOSC;
          [s canvasApplyOSCForLayer:resolvedLayerID keys:oscKeys];
          // Persist the selection so it lands on the undo stack (like standard
          // editors: changing the active layer is itself undoable). Skip while
          // restoring from an undo/redo, else we'd push a duplicate entry. The
          // primary id and the full multi-selection set go in ONE action
          // (patchUIStateKeys) so they're a single undo entry. The kParamUIState
          // write also forces the render round-trip that redraws the viewer OSC,
          // so no separate kParamRenderNudge is needed (it would only add a
          // phantom undo entry - the "takes two cmd-Z" problem).
          if (!s.restoringSelection)
            [s patchUIStateKeys:@{
              @"selectedLayerID" : (resolvedLayerID ?: @""),
              @"selectedLayerIDs" : (selectedLayerIDs ?: @[])
            }
                        paramID:kParamUIState];
        };

    // "Auto-select layers" toggle: seed the checkbox from the persisted state
    // (OFF when absent) and persist flips to kParamUIState. The write triggers
    // parameterChanged, which re-publishes the UIState snapshot the viewer OSC
    // reads.
    [view setAutoSelect:[visState[@"autoSelect"] boolValue]];
    // Seed the mini's grid + toolbar state on cold load too (pluginState only
    // fires on a change, so without this the mini grid / toolbar position would
    // sit at defaults until the user interacts).
    [view setGridEnabled:[visState[@"gridEnabled"] boolValue]
                adaptive:(visState[@"gridAdaptive"]
                              ? [visState[@"gridAdaptive"] boolValue]
                              : YES)
                 spacing:(visState[@"gridSpacing"]
                              ? [visState[@"gridSpacing"] integerValue]
                              : 10)
                    snap:[visState[@"gridSnap"] boolValue]];
    NSArray *seedTbPos = visState[@"miniToolbarPos"];
    CGPoint seedTbNorm =
        ([seedTbPos isKindOfClass:[NSArray class]] && seedTbPos.count == 2)
            ? CGPointMake([seedTbPos[0] doubleValue], [seedTbPos[1] doubleValue])
            : CGPointMake(-1, -1);
    [view setToolbarTool:(visState[@"tool"] ? [visState[@"tool"] integerValue]
                                            : 0)
                 normPos:seedTbNorm];
    view.onAutoSelectChanged = ^(BOOL on) {
      __strong CanvasPlugin *s = weakOSC;
      [s patchUIStateKey:@"autoSelect" value:@(on) paramID:kParamUIState];
    };
    // Mini-viewer toolbar toggles / drag persist their kParamUIState key the same
    // way; the write round-trips to refresh both the viewer OSC + the mini.
    view.onUIStatePatch = ^(NSString *key, id value) {
      __strong CanvasPlugin *s = weakOSC;
      [s patchUIStateKey:key value:value paramID:kParamUIState];
    };

    // The Layers panel opens parameter actions to read/write kParamLayerData;
    // they only persist if the action sender is a host-recognized editor (the
    // plugin), like the playhead poller's actionTarget below.
    [view setLayerParamActionTarget:self];
    if (!self.playheadPoller) {
      self.playheadPoller =
          [[KKPlayheadPoller alloc] initWithAPIManager:self.apiManager
                                          actionTarget:self
                                           renderCache:self.renderCache];
    }
    [self.playheadPoller setInspectorView:view];
    if (self.renderCache.effectDurSec > 0.0)
      [self.playheadPoller ensureRunning];
    return view;
  }
  typedef NSView *(*ViewIMP)(id, SEL, UInt32);
  ViewIMP imp = (ViewIMP)[KKPlugin instanceMethodForSelector:_cmd];
  return imp(self, _cmd, parameterID);
}

@end
