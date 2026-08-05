/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The MERGED (all-layers) timeline: flatten every layer's animated lanes into
// one timeline for the Advanced graph view, and write an edited merged set
// back out to the individual layers. Split out of CanvasLayerTimeline.m (which
// keeps the per-layer builder + seeding) - this is the cross-layer concern.
//
// Identity model: a merged lane's KEY is the layer-scoped composite
// "templateKey\x1flayerID" (opaque outside this file - every edit surface
// routes on it, and two layers' same-named lanes never collide), while its
// LABEL is the plain display name ("Scale"), duplicated freely across layers.

#import "CanvasLayerTimeline.h"
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKTimeline.h>

// U+001F separator joining a lane's template key to its layerID inside the
// merged-timeline KEY.
static NSString *const kCanvasLaneSep = @"\x1f";

// Layer-scoped merged key for a per-layer template key.
static NSString *CanvasTaggedKey(NSString *plain, NSString *layerID) {
  return [NSString stringWithFormat:@"%@%@%@", plain, kCanvasLaneSep, layerID];
}

// Plain template key of a (possibly layer-scoped) merged key.
static NSString *CanvasPlainKey(NSString *tagged) {
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
    // Source the layer's lanes from the SAME per-layer builder the rest of the
    // UI uses (not raw JSON), so a gated lane's CONSTANT controller (e.g. the
    // stroke "Enabled" toggle, whose value may live only in the flat prop) is
    // present + seeded - otherwise the visibleWhen cascade can't resolve it
    // here.
    KKTimeline *s = CanvasLayerTimelineForPath(p, templates);
    NSMutableDictionary<NSString *, KKLane *> *stored =
        [NSMutableDictionary dictionary];
    for (KKLane *l in s.lanes)
      if (l.key)
        stored[l.key] = l;
    // Emit in TEMPLATE (parameter) order, only the layer's ANIMATED lanes, so
    // every layer's rows share one stable order and constant-only layers add
    // nothing. Lane KEYS (and any visibleWhen controller reference, which is
    // a key reference) are layer-scoped so each layer's cascade resolves
    // against ITS controller; labels stay plain for display.
    NSMutableSet<NSString *> *emittedPlain = [NSMutableSet set];
    NSMutableSet<NSString *> *neededControllers = [NSMutableSet set];
    void (^tag)(KKLane *, NSString *) = ^(KKLane *c, NSString *plain) {
      c.key = CanvasTaggedKey(CanvasPlainKey(c.key ?: plain), lid);
      c.label = plain;
      if (c.visibleWhenKey.length)
        c.visibleWhenKey = CanvasTaggedKey(c.visibleWhenKey, lid);
      c.layerKey = lid;
      c.layerLabel = name;
      c.layerSymbol = p.isGroup ? @"folder" : nil;
      c.locked = p.locked;
    };
    for (KKLane *t in templates) {
      KKLane *st = stored[t.key];
      if (!st || !st.enabled)
        continue;
      KKLane *c = [st copy];
      tag(c, t.key);
      [lanes addObject:c];
      [order addObject:c.key];
      [emittedPlain addObject:t.key];
      if (st.visibleWhenKey.length)
        [neededControllers addObject:st.visibleWhenKey];
    }
    // A gated animated lane (e.g. Stroke Width) is controlled by a CONSTANT
    // lane (e.g. the "Enabled" toggle) that the animated-only emit above skips.
    // Carry those controllers in (tagged) so the visibleWhen cascade can read
    // their value here too - the graph/filter re-gate on `enabled`, so a
    // constant controller never renders as a row, it only resolves the rule.
    // TRANSITIVELY: a controller can itself be gated (Solid -> Mode ->
    // Enabled), so carrying Mode must also carry its controller Enabled.
    NSMutableArray<NSString *> *pending =
        [neededControllers.allObjects mutableCopy];
    NSMutableSet<NSString *> *carried = [NSMutableSet set];
    while (pending.count) {
      NSString *ctrlPlain = pending.lastObject;
      [pending removeLastObject];
      if ([emittedPlain containsObject:ctrlPlain] ||
          [carried containsObject:ctrlPlain])
        continue;
      KKLane *cst = stored[ctrlPlain];
      if (!cst)
        continue;
      KKLane *cc = [cst copy];
      tag(cc, ctrlPlain);
      [lanes addObject:cc];
      [order addObject:cc.key];
      [carried addObject:ctrlPlain];
      if (cst.visibleWhenKey.length)
        [pending addObject:cst.visibleWhenKey]; // its own controller, in turn
    }
  }
  tl.lanes = lanes;
  tl.paramOrder = order;
  return tl;
}

void CanvasApplyMergedTimelineToPaths(KKTimeline *merged,
                                      NSArray<KKBezierPath *> *paths,
                                      NSArray<KKLane *> *templates) {
  // Group edited lanes by owning layerID, keys stripped back to the plain
  // per-layer template key.
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
    NSString *plain = CanvasPlainKey(l.key ?: l.label);
    c.key = plain;
    c.label = plain;
    // Strip the layer scope from the visibleWhen CONTROLLER reference too. If
    // we persist a scoped controller ("Mode\x1f<lid>"), the next rebuild can't
    // re-find the plain "Mode" lane to carry, the cascade's controller lookup
    // fails, and a gated lane (Gradient when Mode=Solid) falls open and
    // wrongly shows.
    if (c.visibleWhenKey.length)
      c.visibleWhenKey = CanvasPlainKey(c.visibleWhenKey);
    c.layerKey = nil;
    c.layerLabel = nil;
    c.layerSymbol = nil;
    edits[c.key] = c;
  }

  NSMutableArray<NSString *> *paramOrder =
      [NSMutableArray arrayWithCapacity:templates.count];
  for (KKLane *t in templates)
    if (t.key)
      [paramOrder addObject:t.key];

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
        if ([lanes[i].key isEqualToString:plain]) {
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

KKTimeline *CanvasAITimeline(NSArray<KKBezierPath *> *paths,
                             NSArray<KKLane *> *templates) {
  KKTimeline *tl = [KKTimeline timeline];
  NSMutableArray<KKLane *> *lanes = [NSMutableArray array];
  NSMutableArray<NSString *> *order = [NSMutableArray array];
  for (KKBezierPath *p in paths) {
    NSString *lid = p.layerID.length ? p.layerID : @"";
    NSString *name = p.name.length ? p.name : @"Layer";
    // The same per-layer builder the UI uses: it returns exactly the lanes that
    // apply to this layer type (vector-only lanes absent on an image/group),
    // each seeded with the layer's CURRENT value (transform +
    // stroke/fill/sketch constants read from the flat props). Expose ALL of
    // them so the AI can change any property - animate a transform, retime an
    // existing animation, or set a constant (stroke colour, width, fill,
    // draw-on...). The kit merge only mutates labels already present here, so
    // anything not exposed can't be touched.
    KKTimeline *s = CanvasLayerTimelineForPath(p, templates);
    NSMutableDictionary<NSString *, KKLane *> *stored =
        [NSMutableDictionary dictionary];
    for (KKLane *l in s.lanes)
      if (l.key)
        stored[l.key] = l;
    void (^tag)(KKLane *, NSString *) = ^(KKLane *c, NSString *plain) {
      c.key = CanvasTaggedKey(CanvasPlainKey(c.key ?: plain), lid);
      c.label = plain;
      if (c.visibleWhenKey.length)
        c.visibleWhenKey = CanvasTaggedKey(c.visibleWhenKey, lid);
      c.layerKey = lid;
      c.layerLabel = name;
      c.layerSymbol = p.isGroup ? @"folder" : nil;
      c.locked = p.locked;
    };
    // Emit in template (parameter) order so every layer's lanes share a stable
    // order.
    for (KKLane *t in templates) {
      KKLane *st = stored[t.key];
      if (!st)
        continue; // lane doesn't apply to this layer type
      KKLane *c = [st copy];
      tag(c, t.key);
      [lanes addObject:c];
      [order addObject:c.key];
    }
  }
  tl.lanes = lanes;
  tl.paramOrder = order;
  return tl;
}
