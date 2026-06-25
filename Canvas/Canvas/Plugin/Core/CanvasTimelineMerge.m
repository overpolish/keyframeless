/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The MERGED (all-layers) timeline: flatten every layer's animated lanes into
// one timeline for the Advanced graph view (each lane tagged with its owning
// layerID so multiple layers' lanes coexist), and write an edited merged set
// back out to the individual layers. Split out of CanvasLayerTimeline.m (which
// keeps the per-layer builder + seeding) - this is the cross-layer concern.

#import "CanvasLayerTimeline.h"
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKTimingStage.h>

// U+001F separator joining a context lane's short label to its layerID (unique
// across layers; KKLocalizedParamName strips it for display).
static NSString *const kCanvasLaneSep = @"\x1f";

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
    // Source the layer's lanes from the SAME per-layer builder the rest of the
    // UI uses (not raw JSON), so a gated lane's CONSTANT controller (e.g. the
    // stroke "Enabled" toggle, whose value may live only in the flat prop) is
    // present + seeded - otherwise the visibleWhen cascade can't resolve it
    // here.
    KKTimeline *s = CanvasLayerTimelineForPath(p, templates);
    NSMutableDictionary<NSString *, KKLane *> *stored =
        [NSMutableDictionary dictionary];
    for (KKLane *l in s.lanes)
      if (l.label)
        stored[l.label] = l;
    // Emit in TEMPLATE (parameter) order, only the layer's ANIMATED lanes, so
    // every layer's rows share one stable order and constant-only layers add
    // nothing. Lane labels (and any visibleWhen controller reference) are
    // tagged with the layer id so each layer's cascade resolves against ITS
    // controller.
    NSMutableSet<NSString *> *emittedPlain = [NSMutableSet set];
    NSMutableSet<NSString *> *neededControllers = [NSMutableSet set];
    void (^tag)(KKLane *, NSString *) = ^(KKLane *c, NSString *plain) {
      c.label = CanvasTaggedLabel(plain, lid);
      if (c.visibleWhenLabel.length)
        c.visibleWhenLabel = CanvasTaggedLabel(c.visibleWhenLabel, lid);
      c.layerKey = lid;
      c.layerLabel = name;
      c.layerSymbol = p.isGroup ? @"folder" : nil;
      c.locked = p.locked;
    };
    for (KKLane *t in templates) {
      KKLane *st = stored[t.label];
      if (!st || !st.enabled)
        continue;
      KKLane *c = [st copy];
      tag(c, t.label);
      [lanes addObject:c];
      [order addObject:c.label];
      [emittedPlain addObject:t.label];
      if (st.visibleWhenLabel.length)
        [neededControllers addObject:st.visibleWhenLabel];
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
      [order addObject:cc.label];
      [carried addObject:ctrlPlain];
      if (cst.visibleWhenLabel.length)
        [pending addObject:cst.visibleWhenLabel]; // its own controller, in turn
    }
  }
  tl.lanes = lanes;
  tl.paramOrder = order;
  return tl;
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
    // Strip the layer tag from the visibleWhen CONTROLLER reference too, not
    // just the label - CanvasMergedTimeline tags both. If we persist a tagged
    // controller ("Mode\x1f<lid>"), the next rebuild can't re-find the plain
    // "Mode" lane to carry, the cascade's controller lookup fails, and a gated
    // lane (Gradient when Mode=Solid) falls open and wrongly shows.
    if (c.visibleWhenLabel.length)
      c.visibleWhenLabel = CanvasPlainLabel(c.visibleWhenLabel);
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
