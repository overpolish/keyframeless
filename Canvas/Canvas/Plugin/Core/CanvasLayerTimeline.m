/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerTimeline.h"
#import "CanvasLayerRender.h"
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKTimingStage.h>

// U+001F separator joining a context lane's short label to its layerID (unique
// across layers; KKLocalizedParamName strips it for display).
static NSString *const kCanvasLaneSep = @"\x1f";

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
    // Points (path geometry) applies to vector-path layers only - images and
    // groups have no editable anchors.
    if ([t.label isEqualToString:@"Points"] && (path.isImage || path.isGroup))
      continue;
    KKLane *src = [(stored[t.label] ?: t) copy];
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

// Tagged label joining a lane's plain short label to its owning layerID.
static NSString *CanvasTaggedLabel(NSString *plain, NSString *layerID) {
  return [NSString stringWithFormat:@"%@%@%@", plain, kCanvasLaneSep, layerID];
}

// Plain short label of a (possibly tagged) lane label.
static NSString *CanvasPlainLabel(NSString *tagged) {
  NSRange r = [tagged rangeOfString:kCanvasLaneSep];
  return r.location == NSNotFound ? tagged
                                  : [tagged substringToIndex:r.location];
}

KKTimeline *CanvasMergedTimeline(NSArray<KKBezierPath *> *paths,
                                 NSArray<KKLane *> *templates) {
  KKTimeline *tl = [KKTimeline timeline];
  NSMutableArray<KKLane *> *lanes = [NSMutableArray array];
  NSMutableArray<NSString *> *order = [NSMutableArray array];
  for (KKBezierPath *p in paths) {
    if (p.animationJSON.length == 0)
      continue;
    NSString *lid = p.layerID.length ? p.layerID : @"";
    NSString *name = p.name.length ? p.name : @"Layer";
    KKTimeline *s = [KKTimeline timelineFromJSON:p.animationJSON];
    NSMutableDictionary<NSString *, KKLane *> *stored =
        [NSMutableDictionary dictionary];
    for (KKLane *l in s.lanes)
      if (l.label)
        stored[l.label] = l;
    // Emit in TEMPLATE (parameter) order, only the layer's ANIMATED lanes, so
    // every layer's rows share one stable order and constant-only layers add
    // nothing.
    for (KKLane *t in templates) {
      KKLane *st = stored[t.label];
      if (!st || !st.enabled)
        continue;
      KKLane *c = [st copy];
      c.label = CanvasTaggedLabel(t.label, lid);
      c.layerKey = lid;
      c.layerLabel = name;
      c.layerSymbol = p.isGroup ? @"folder" : nil;
      c.locked = p.locked;
      [lanes addObject:c];
      [order addObject:c.label];
    }
  }
  tl.lanes = lanes;
  tl.paramOrder = order;
  return tl;
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

void CanvasApplyMergedTimelineToPaths(KKTimeline *merged,
                                      NSArray<KKBezierPath *> *paths,
                                      NSArray<KKLane *> *templates) {
  // Group edited lanes by owning layerID, stripped back to plain labels.
  NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, KKLane *> *>
      *byLayer = [NSMutableDictionary dictionary];
  for (KKLane *l in merged.lanes) {
    NSString *lid = l.layerKey.length ? l.layerKey : @"";
    NSMutableDictionary<NSString *, KKLane *> *edits = byLayer[lid];
    if (!edits) {
      edits = [NSMutableDictionary dictionary];
      byLayer[lid] = edits;
    }
    KKLane *c = [l copy];
    c.label = CanvasPlainLabel(l.label);
    c.layerKey = nil;
    c.layerLabel = nil;
    c.layerSymbol = nil;
    edits[c.label] = c;
  }

  NSMutableArray<NSString *> *paramOrder =
      [NSMutableArray arrayWithCapacity:templates.count];
  for (KKLane *t in templates)
    if (t.label)
      [paramOrder addObject:t.label];

  for (KKBezierPath *p in paths) {
    // No lock guard: lock is UI-enforced (Advanced blocks locked lanes), and
    // Basic ignores lock by design (shared timings) - its edits flow through
    // the merged write too, so guarding would wrongly revert them.
    NSString *lid = p.layerID.length ? p.layerID : @"";
    NSDictionary<NSString *, KKLane *> *edits = byLayer[lid];
    if (edits.count == 0)
      continue; // this layer had no animated lanes in the edited set
    KKTimeline *s = p.animationJSON.length
                        ? [KKTimeline timelineFromJSON:p.animationJSON]
                        : [KKTimeline timeline];
    NSMutableArray<KKLane *> *lanes =
        s.lanes ? [s.lanes mutableCopy] : [NSMutableArray array];
    // Replace each edited plain lane in place; keep the layer's other
    // (constant/disabled) lanes untouched.
    [edits enumerateKeysAndObjectsUsingBlock:^(NSString *plain, KKLane *lane,
                                               BOOL *stop) {
      BOOL found = NO;
      for (NSUInteger i = 0; i < lanes.count; i++)
        if ([lanes[i].label isEqualToString:plain]) {
          lanes[i] = lane;
          found = YES;
          break;
        }
      if (!found)
        [lanes addObject:lane];
    }];
    s.lanes = lanes;
    s.paramOrder = paramOrder;
    p.animationJSON = [KKTimeline jsonFromTimeline:s];
  }
}
