/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerTimeline.h"
#import "CanvasLayerRender.h"
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKColorLanes.h>
#import <KeyframelessKit/KKTimeline.h>

// Process-wide layer-blob snapshot for the viewer OSC (see header).
static NSString *sCanvasLayerBlobSnapshot = nil;

void CanvasSetLayerBlobSnapshot(NSString *b64) {
  sCanvasLayerBlobSnapshot = [b64 copy];
}

NSString *CanvasLayerBlobSnapshot(void) { return sCanvasLayerBlobSnapshot; }

// Process-wide kParamUIState snapshot for the viewer OSC (see header).
static NSString *sCanvasUIStateSnapshot = nil;

void CanvasSetUIStateSnapshot(NSString *json) {
  sCanvasUIStateSnapshot = [json copy];
}

NSString *CanvasUIStateSnapshot(void) { return sCanvasUIStateSnapshot; }

// Process-wide real output-size snapshot for path ops (see header).
static float sCanvasOutputWidth = 0.0f;
static float sCanvasOutputHeight = 0.0f;

void CanvasSetOutputSize(float width, float height) {
  if (width > 0.0f && height > 0.0f) {
    sCanvasOutputWidth = width;
    sCanvasOutputHeight = height;
  }
}

BOOL CanvasOutputSize(float *outWidth, float *outHeight) {
  if (sCanvasOutputWidth <= 0.0f || sCanvasOutputHeight <= 0.0f)
    return NO;
  *outWidth = sCanvasOutputWidth;
  *outHeight = sCanvasOutputHeight;
  return YES;
}

KKBezierPath *CanvasSelectedLayerForPaths(NSArray<KKBezierPath *> *paths,
                                          NSString *selectedLayerID) {
  // Groups animate too (their own explicit transform; no propagation), so they
  // are selectable layers like any other - no isGroup skip.
  KKBezierPath *first = nil;
  for (KKBezierPath *p in paths) {
    if (!first)
      first = p;
    if (selectedLayerID.length && [p.layerID isEqualToString:selectedLayerID])
      return p;
  }
  return first;
}

KKTimeline *CanvasLayerTimelineForPath(KKBezierPath *path,
                                       NSArray<KKLane *> *templates) {
  KKTimeline *tl = [KKTimeline timeline];
  if (!path) {
    // No layer at all (empty stack): still surface the transform lanes, but
    // LOCKED so the constants popover + graphs render read-only. Editing a
    // value here has nowhere to persist (no owning layer), so it must not look
    // adjustable. The kit's seed preserves `locked` on a present lane, and the
    // templates already carry their identity keypose for the readout.
    NSMutableArray<KKLane *> *lanes =
        [NSMutableArray arrayWithCapacity:templates.count];
    NSMutableArray<NSString *> *order =
        [NSMutableArray arrayWithCapacity:templates.count];
    for (KKLane *t in templates) {
      if ([t.label isEqualToString:@"Points"])
        continue; // no layer = no path geometry
      KKLane *src = [t copy];
      src.locked = YES;
      [lanes addObject:src];
      if (t.label)
        [order addObject:t.label];
    }
    tl.lanes = lanes;
    tl.paramOrder = order;
    return tl;
  }

  // The layer's own stored lanes, keyed by label (preserve enabled + keyposes).
  NSMutableDictionary<NSString *, KKLane *> *stored =
      [NSMutableDictionary dictionary];
  if (path.animationJSON.length) {
    KKTimeline *s = [KKTimeline timelineFromJSON:path.animationJSON];
    for (KKLane *l in s.lanes)
      if (l.label)
        stored[l.label] = l;
  }

  // Build in TEMPLATE order (= the parameter order) so every layer's lanes are
  // ordered identically (Scale, Position, ...), regardless of the order they
  // happened to be stored in. A param with no stored lane uses the template
  // (constant default); a stored one keeps its animated state + keyposes.
  NSString *lid = path.layerID.length ? path.layerID : nil;
  NSString *name = path.name.length ? path.name : @"Layer";
  NSMutableArray<KKLane *> *lanes =
      [NSMutableArray arrayWithCapacity:templates.count];
  NSMutableArray<NSString *> *order =
      [NSMutableArray arrayWithCapacity:templates.count];
  for (KKLane *t in templates) {
    // Points (path geometry) and the Stroke group apply to vector-path layers
    // only - images and groups have no editable anchors or stroke.
    BOOL vectorOnly =
        [t.label isEqualToString:@"Points"] ||
        [t.label isEqualToString:@"Stroke Width"] ||
        [t.label isEqualToString:@"Enabled"] ||
        [t.label isEqualToString:@"Line Cap"] ||
        [t.label isEqualToString:@"Line Join"] ||
        [t.label isEqualToString:@"Start Marker"] ||
        [t.label isEqualToString:@"End Marker"] ||
        [t.label isEqualToString:@"Start Marker Width"] ||
        [t.label isEqualToString:@"End Marker Width"] ||
        [t.label isEqualToString:@"Draw On Start"] ||
        [t.label isEqualToString:@"Draw On End"] ||
        [t.label isEqualToString:@"Draw On Offset"] ||
        [t.label isEqualToString:@"Stroke Style"] ||
        [t.label isEqualToString:@"Dash Length"] ||
        [t.label isEqualToString:@"Dash Gap"] ||
        [t.label isEqualToString:@"Dot Gap"] ||
        [t.label isEqualToString:@"Marching Ants Speed"] ||
        [t.label isEqualToString:KKColorLanesModeLabel(@"Stroke")] ||
        [t.label isEqualToString:KKColorLanesSolidLabel(@"Stroke")] ||
        [t.label isEqualToString:KKColorLanesGradientLabel(@"Stroke")];
    // Fill (enabled + colour + style/hachure) applies to vector paths AND image
    // layers (a shape fill / an image tint or hachure overlay), but never to
    // groups. Fill Amount is the image-tint strength only (a vector fill is the
    // whole shape), so it's image-only.
    BOOL fillLane =
        [t.label isEqualToString:@"Fill Enabled"] ||
        [t.label isEqualToString:KKColorLanesModeLabel(@"Fill")] ||
        [t.label isEqualToString:KKColorLanesSolidLabel(@"Fill")] ||
        [t.label isEqualToString:KKColorLanesGradientLabel(@"Fill")] ||
        [t.label isEqualToString:@"Fill Style"] ||
        [t.label isEqualToString:@"Fill Gap"] ||
        [t.label isEqualToString:@"Fill Angle"] ||
        [t.label isEqualToString:@"Fill Weight"];
    BOOL fillAmountLane = [t.label isEqualToString:@"Fill Amount"];
    // Sketch (hand-drawn roughness) applies to a vector path OR an image (never
    // a group); its own visibleWhen cascade (Stroke OR Fill enabled) hides the
    // group when there's nothing to roughen.
    BOOL sketchLane = [t.label isEqualToString:@"Sketch Enabled"] ||
                      [t.label isEqualToString:@"Sketch Roughness"] ||
                      [t.label isEqualToString:@"Sketch Bowing"] ||
                      [t.label isEqualToString:@"Sketch Strokes"] ||
                      [t.label isEqualToString:@"Sketch Seed"];
    if (vectorOnly && (path.isImage || path.isGroup))
      continue;
    if (fillLane && path.isGroup)
      continue;
    if (fillAmountLane && !path.isImage)
      continue;
    if (sketchLane && path.isGroup)
      continue;
    // Line Cap only matters on an OPEN end: hide it for a closed single contour
    // or any multi-contour path (the renderer treats those as closed, so no
    // caps are drawn). Line Join still applies - closed shapes have corners
    // too.
    BOOL hasOpenEnd = path.contourCount <= 1 && !path.closed;
    BOOL isMarkerLane = [t.label isEqualToString:@"Start Marker"] ||
                        [t.label isEqualToString:@"End Marker"] ||
                        [t.label isEqualToString:@"Start Marker Width"] ||
                        [t.label isEqualToString:@"End Marker Width"];
    if (([t.label isEqualToString:@"Line Cap"] || isMarkerLane) && !hasOpenEnd)
      continue;
    // Draw-on reveals each contour's arc (open OR closed); a multi-contour path
    // reveals every branch per-contour, so the lanes apply there too.
    KKLane *src = [(stored[t.label] ?: t) copy];
    // Re-assert the template's canonical DISPLAY / picker metadata onto a
    // stored (round-tripped) lane - the animationJSON drops non-codable props,
    // notably componentLabelColors (the R/G/B/A graph-line tints), so an
    // animated colour lane drew every channel in the default accent instead of
    // red/green/blue. Mirrors the kit seeder (_timelineSeededFrom); user state
    // (keyposes, enabled, aspectLinked) is untouched.
    src.valueType = t.valueType;
    src.componentMin = t.componentMin;
    src.componentMax = t.componentMax;
    src.sliderMax = t.sliderMax;
    src.sliderMin = t.sliderMin;
    src.componentUnits = t.componentUnits;
    src.componentLabels = t.componentLabels;
    src.componentLabelColors = t.componentLabelColors;
    src.componentsScaleWithMedia = t.componentsScaleWithMedia;
    [src kkApplyPickerMetadataFrom:t];
    // A non-animatable param (a structural enum / toggle like the colour "Mode"
    // or the stroke "Enabled") is ALWAYS constant - it can't be animated, so it
    // must never read as enabled, whatever a stale animationJSON says. Without
    // this an old blob (or a controller carried back by the merged-timeline
    // split) could leave Mode enabled and wrongly show it as an animated row.
    if (!t.animatable)
      src.enabled = NO;
    // Stroke Width with no stored lane: seed from the layer's flat
    // strokeWidth/endWidth so an existing path keeps its width (the render
    // reads the lane). End falls back to Start when unset (no taper). A stored
    // lane (already edited / animated) wins.
    if (!stored[t.label] && [t.label isEqualToString:@"Stroke Width"]) {
      double sw = path.strokeWidth, ew = path.endWidth > 0 ? path.endWidth : sw;
      src.keyposes = @[ [KKKeyPose keyposeAtTime:0.0
                                          values:@[ @(sw), @(ew) ]] ];
    }
    // Stroke "Enabled" with no stored lane: seed from the layer's flat
    // strokeEnabled (boolean-op results / explicit toggles start off).
    if (!stored[t.label] && [t.label isEqualToString:@"Enabled"]) {
      src.keyposes =
          @[ [KKKeyPose keyposeAtTime:0.0
                               values:@[ @(path.strokeEnabled ? 1.0 : 0.0) ]] ];
    }
    // Fill "Enabled" with no stored lane: seed from the flat fillEnabled.
    if (!stored[t.label] && [t.label isEqualToString:@"Fill Enabled"]) {
      src.keyposes =
          @[ [KKKeyPose keyposeAtTime:0.0
                               values:@[ @(path.fillEnabled ? 1.0 : 0.0) ]] ];
    }
    // Fill colour Mode / Solid with no stored lane: seed from the flat
    // fillColorMode (0=Solid, 1=Gradient) and fillR,G,B (alpha 1). The Gradient
    // lane keeps the template default for now (gradient fill render is a
    // follow-up).
    if (!stored[t.label] &&
        [t.label isEqualToString:KKColorLanesModeLabel(@"Fill")]) {
      src.keyposes = @[ [KKKeyPose keyposeAtTime:0.0
                                          values:@[ @(path.fillColorMode) ]] ];
    }
    if (!stored[t.label] &&
        [t.label isEqualToString:KKColorLanesSolidLabel(@"Fill")]) {
      src.keyposes = @[ [KKKeyPose
          keyposeAtTime:0.0
                 values:@[
                   @(path.fillR), @(path.fillG), @(path.fillB), @1.0
                 ]] ];
    }
    // Fill Amount (image tint strength) with no stored lane: seed from the flat
    // fillTint (0..1) as a percentage.
    if (!stored[t.label] && [t.label isEqualToString:@"Fill Amount"]) {
      src.keyposes =
          @[ [KKKeyPose keyposeAtTime:0.0
                               values:@[ @(path.fillTint * 100.0) ]] ];
    }
    // Fill Style + hachure controls with no stored lane: seed from the flat
    // sketchFillStyle / sketchFillGap / sketchFillAngle / sketchFillWeight.
    if (!stored[t.label] && [t.label isEqualToString:@"Fill Style"]) {
      src.keyposes =
          @[ [KKKeyPose keyposeAtTime:0.0
                               values:@[ @(path.sketchFillStyle) ]] ];
    }
    if (!stored[t.label] && [t.label isEqualToString:@"Fill Gap"]) {
      src.keyposes = @[ [KKKeyPose keyposeAtTime:0.0
                                          values:@[ @(path.sketchFillGap) ]] ];
    }
    if (!stored[t.label] && [t.label isEqualToString:@"Fill Angle"]) {
      src.keyposes =
          @[ [KKKeyPose keyposeAtTime:0.0
                               values:@[ @(path.sketchFillAngle) ]] ];
    }
    if (!stored[t.label] && [t.label isEqualToString:@"Fill Weight"]) {
      src.keyposes =
          @[ [KKKeyPose keyposeAtTime:0.0
                               values:@[ @(path.sketchFillWeight) ]] ];
    }
    // Sketch group with no stored lane: seed from the flat sketch* props
    // (sketchEnabled toggle, roughness/bowing/strokes/seed). A fresh path
    // starts with sketch off, so the group hides until enabled.
    if (!stored[t.label] && [t.label isEqualToString:@"Sketch Enabled"]) {
      src.keyposes =
          @[ [KKKeyPose keyposeAtTime:0.0
                               values:@[ @(path.sketchEnabled ? 1.0 : 0.0) ]] ];
    }
    if (!stored[t.label] && [t.label isEqualToString:@"Sketch Roughness"]) {
      src.keyposes =
          @[ [KKKeyPose keyposeAtTime:0.0
                               values:@[ @(path.sketchRoughness) ]] ];
    }
    if (!stored[t.label] && [t.label isEqualToString:@"Sketch Bowing"]) {
      src.keyposes = @[ [KKKeyPose keyposeAtTime:0.0
                                          values:@[ @(path.sketchBowing) ]] ];
    }
    if (!stored[t.label] && [t.label isEqualToString:@"Sketch Strokes"]) {
      // Pill index: flat sketchStrokes 2 (or default) -> Double (1), 1 ->
      // Single (0).
      double idx = (path.sketchStrokes >= 2 || path.sketchStrokes == 0) ? 1 : 0;
      src.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:@[ @(idx) ]] ];
    }
    if (!stored[t.label] && [t.label isEqualToString:@"Sketch Seed"]) {
      src.keyposes =
          @[ [KKKeyPose keyposeAtTime:0.0
                               values:@[ @(path.sketchSeed ?: 1) ]] ];
    }
    // Stroke colour Mode / Solid with no stored lane: seed from the flat
    // strokeColorMode (0=Solid, 1=Gradient - same ordering, no Dynamic) and
    // strokeR,G,B (alpha 1). Gradient lane keeps the template default for now;
    // the gradient render increment seeds it from the flat gradient props.
    if (!stored[t.label] &&
        [t.label isEqualToString:KKColorLanesModeLabel(@"Stroke")]) {
      src.keyposes =
          @[ [KKKeyPose keyposeAtTime:0.0
                               values:@[ @(path.strokeColorMode) ]] ];
    }
    if (!stored[t.label] &&
        [t.label isEqualToString:KKColorLanesSolidLabel(@"Stroke")]) {
      src.keyposes = @[ [KKKeyPose
          keyposeAtTime:0.0
                 values:@[
                   @(path.strokeR), @(path.strokeG), @(path.strokeB), @1.0
                 ]] ];
    }
    // Line Cap / Join with no stored lane: seed from the flat lineCap/lineJoin
    // (same 0/1/2 ordering as the choice pills).
    if (!stored[t.label] && [t.label isEqualToString:@"Line Cap"]) {
      src.keyposes = @[ [KKKeyPose keyposeAtTime:0.0
                                          values:@[ @(path.lineCap) ]] ];
    }
    if (!stored[t.label] && [t.label isEqualToString:@"Line Join"]) {
      src.keyposes = @[ [KKKeyPose keyposeAtTime:0.0
                                          values:@[ @(path.lineJoin) ]] ];
    }
    // Markers with no stored lane: seed types from the flat start/end marker
    // (6-value pill order) and sizes from the flat multiplier as a percentage
    // (startMarkerSize 3.0 -> 300 %).
    if (!stored[t.label] && [t.label isEqualToString:@"Start Marker"]) {
      src.keyposes = @[ [KKKeyPose keyposeAtTime:0.0
                                          values:@[ @(path.startMarker) ]] ];
    }
    if (!stored[t.label] && [t.label isEqualToString:@"End Marker"]) {
      src.keyposes = @[ [KKKeyPose keyposeAtTime:0.0
                                          values:@[ @(path.endMarker) ]] ];
    }
    if (!stored[t.label] && [t.label isEqualToString:@"Start Marker Width"]) {
      src.keyposes =
          @[ [KKKeyPose keyposeAtTime:0.0
                               values:@[ @(path.startMarkerSize * 100.0) ]] ];
    }
    if (!stored[t.label] && [t.label isEqualToString:@"End Marker Width"]) {
      src.keyposes =
          @[ [KKKeyPose keyposeAtTime:0.0
                               values:@[ @(path.endMarkerSize * 100.0) ]] ];
    }
    // Draw-on reveal: seed from the flat drawOnStart/drawOnEnd (0..1) as a
    // percentage (0 / 100 = whole stroke shown).
    if (!stored[t.label] && [t.label isEqualToString:@"Draw On Start"]) {
      src.keyposes =
          @[ [KKKeyPose keyposeAtTime:0.0
                               values:@[ @(path.drawOnStart * 100.0) ]] ];
    }
    if (!stored[t.label] && [t.label isEqualToString:@"Draw On End"]) {
      src.keyposes =
          @[ [KKKeyPose keyposeAtTime:0.0
                               values:@[ @(path.drawOnEnd * 100.0) ]] ];
    }
    if (!stored[t.label] && [t.label isEqualToString:@"Draw On Offset"]) {
      src.keyposes =
          @[ [KKKeyPose keyposeAtTime:0.0
                               values:@[ @(path.drawOnOrigin * 100.0) ]] ];
    }
    // Stroke Style / dash metrics / marching-ants speed: seed from the flat
    // strokeStyle (0/1/2) + dashLength/dashGap/dotGap + marchingAntsSpeed.
    if (!stored[t.label] && [t.label isEqualToString:@"Stroke Style"]) {
      src.keyposes = @[ [KKKeyPose keyposeAtTime:0.0
                                          values:@[ @(path.strokeStyle) ]] ];
    }
    if (!stored[t.label] && [t.label isEqualToString:@"Dash Length"]) {
      src.keyposes = @[ [KKKeyPose keyposeAtTime:0.0
                                          values:@[ @(path.dashLength) ]] ];
    }
    if (!stored[t.label] && [t.label isEqualToString:@"Dash Gap"]) {
      src.keyposes = @[ [KKKeyPose keyposeAtTime:0.0
                                          values:@[ @(path.dashGap) ]] ];
    }
    if (!stored[t.label] && [t.label isEqualToString:@"Dot Gap"]) {
      src.keyposes = @[ [KKKeyPose keyposeAtTime:0.0
                                          values:@[ @(path.dotGap) ]] ];
    }
    if (!stored[t.label] && [t.label isEqualToString:@"Marching Ants Speed"]) {
      src.keyposes =
          @[ [KKKeyPose keyposeAtTime:0.0
                               values:@[ @(path.marchingAntsSpeed) ]] ];
    }
    // Tag with the layer for the Advanced view's layer header. The LABEL stays
    // plain ("Scale") so the kit's label-keyed edit surfaces are unaffected;
    // only layerKey/layerLabel drive the header. Group layers get a folder
    // glyph (others keep the header's default stacked-squares).
    src.layerKey = lid;
    src.layerLabel = name;
    src.layerSymbol = path.isGroup ? @"folder" : nil;
    src.locked = path.locked; // read-only lanes when the layer is locked
    [lanes addObject:src];
    if (t.label)
      [order addObject:t.label];
  }
  // Stroke group gating is NOT done here: the "Enabled" toggle drives the
  // shared visibleWhen cascade (set on the template lanes), so a disabled
  // stroke drops its lanes out of every timeline surface uniformly - no
  // per-build lock.
  tl.lanes = lanes;
  tl.paramOrder = order;
  return tl;
}

void CanvasSeedGroupAnchor(KKBezierPath *group, NSArray<KKBezierPath *> *paths,
                           NSArray<KKLane *> *templates) {
  if (!group.isGroup)
    return;
  float cx = 0.5f, cy = 0.5f;
  if (!CanvasGroupContentCenterObj(paths, group, &cx, &cy))
    return; // no measurable content: leave the anchor at the clip centre
  // Seed the group onto its content centre (Y-down cy -> 1-cy):
  //  - FROZEN rest (group.translateX/Y, repurposed): the reference the group's
  //    Position is measured from. The render translation is Position - rest, so
  //    seeding Position to the content centre leaves members in place.
  //  - Position lane: the content centre, so the Position handle sits ON the
  //    group, not alone at the clip centre.
  //  - Anchor lane: the content centre too, so the rotation / scale pivot lands
  //    on the content. The Anchor is a free pan-behind pivot afterwards (it
  //    never feeds rest), so dragging it never moves the rendered content.
  group.translateX = cx;
  group.translateY = (float)(1.0 - cy);
  KKTimeline *tl = CanvasLayerTimelineForPath(group, templates);
  for (KKLane *l in tl.lanes) {
    if (![l.label isEqualToString:@"Anchor"] &&
        ![l.label isEqualToString:@"Position"])
      continue;
    l.keyposes = @[ [KKKeyPose keyposeAtTime:0.0
                                      values:@[ @(cx), @(1.0 - cy) ]] ];
  }
  CanvasApplyTimelineToPath(tl, group);
}

void CanvasApplyTimelineToPath(KKTimeline *timeline, KKBezierPath *path) {
  if (!path)
    return;
  // No lock guard here: lock is enforced at the UI (Advanced graph blocks
  // locked lanes; Advanced keypose + Constants popovers render read-only).
  // Basic deliberately ignores lock (shared timings), and Basic edits flow
  // through here - guarding would wrongly revert them.
  path.animationJSON = timeline ? [KKTimeline jsonFromTimeline:timeline] : nil;
}

BOOL CanvasLayerHasConstant(KKBezierPath *path, NSArray<KKLane *> *templates) {
  if (!path)
    return NO;
  if (path.animationJSON.length == 0)
    return YES; // nothing animated => every param is constant
  KKTimeline *s = [KKTimeline timelineFromJSON:path.animationJSON];
  NSUInteger animated = 0;
  for (KKLane *l in s.lanes)
    if (l.enabled)
      animated++;
  return animated < templates.count; // some template isn't animated here
}

BOOL CanvasAnyLayerHasConstant(NSArray<KKBezierPath *> *paths,
                               NSArray<KKLane *> *templates) {
  for (KKBezierPath *p in paths)
    if (CanvasLayerHasConstant(p, templates))
      return YES;
  return NO;
}
