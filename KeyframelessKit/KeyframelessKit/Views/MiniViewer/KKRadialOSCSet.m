/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKRadialOSCSet_Protected.h"

#import <KeyframelessKit/KKPluginHost.h> // KKProcessFrameDurationSeconds
#import <KeyframelessKit/KKTimeline.h>   // KKLane / KKTimeline (aspectLinked)
#import <KeyframelessKit/KKTimingEvaluation.h> // KKLaneVisibleAtFraction
#import <math.h>

@implementation KKRadialOSCSet {
  NSDictionary<NSString *, NSDictionary<NSString *, id> *> *_specByLabel;
}

- (instancetype)initWithRenderer:(KKMiniViewerRenderer *)renderer {
  self = [super init];
  if (self) {
    _renderer = renderer;
    _specs = @[];
    _specByLabel = @{};
  }
  return self;
}

- (void)setSpecs:(NSArray<NSDictionary<NSString *, id> *> *)specs {
  _specs = [specs copy] ?: @[];
  NSMutableDictionary *byLabel = [NSMutableDictionary dictionary];
  for (NSDictionary *s in _specs) {
    NSString *label = s[@"label"];
    if (label.length)
      byLabel[label] = s;
  }
  _specByLabel = byLabel;
  // Drop a drag whose spec vanished.
  if (self.activeLabel && !_specByLabel[self.activeLabel])
    self.activeLabel = nil;
}

- (NSDictionary<NSString *, id> *)specForLabel:(NSString *)label {
  return label.length ? _specByLabel[label] : nil;
}

- (NSArray<NSString *> *)labels {
  NSMutableArray<NSString *> *out = [NSMutableArray array];
  for (NSDictionary *s in _specs)
    if (((NSString *)s[@"label"]).length)
      [out addObject:s[@"label"]];
  return out;
}

- (BOOL)isActiveLabel:(NSString *)label forContentRect:(CGRect)cr {
  if (CGRectIsEmpty(cr) || !label.length ||
      [_renderer.suppressedHandleLabels containsObject:label] ||
      ![_renderer labelVisibleOrRevealing:label])
    return NO;
  // Constant-or-on-keypose, the same editFraction sweep every other handle set
  // applies (KKPointOSCSet's arc, MirageExprMiniSet's rings). This replaces a
  // stricter constant-only test that made a radial handle vanish for good the
  // moment its lane animated - now it behaves like its siblings: constants
  // always, animated lanes on their keyposes, hidden in between.
  KKLane *lane = nil;
  for (KKLane *l in _renderer.timeline.lanes)
    if ([l.key isEqualToString:label]) {
      lane = l;
      break;
    }
  return KKLaneVisibleAtFraction(lane, _renderer.editFraction,
                                 KKProcessFrameDurationSeconds());
}

- (NSArray<NSNumber *> *)valuesForLabel:(NSString *)label {
  // ROOT value: this feeds the ring geometry + drag seed (the OSC edits the
  // lane's own value, not the link-expression result - else a drag would
  // compound). The rendered object still uses the renderer's resolved
  // valuesForLabel:.
  NSArray<NSNumber *> *v = [_renderer rootValuesForLabel:label];
  if (v.count)
    return v;
  NSDictionary *s = _specByLabel[label];
  int fields = MAX(1, [s[@"fields"] intValue]);
  double mn = [s[@"min"] doubleValue];
  NSMutableArray<NSNumber *> *out = [NSMutableArray array];
  for (int k = 0; k < fields; k++)
    [out addObject:@(mn)];
  return out;
}

- (NSArray<NSNumber *> *)normsForLabel:(NSString *)label {
  NSDictionary *s = _specByLabel[label];
  double mn = [s[@"min"] doubleValue], mx = [s[@"max"] doubleValue];
  double span = mx - mn;
  NSMutableArray<NSNumber *> *out = [NSMutableArray array];
  for (NSNumber *n in [self valuesForLabel:label])
    [out
        addObject:@(span > 0.0 ? fmax(0.0, (n.doubleValue - mn) / span) : 0.0)];
  return out;
}

- (BOOL)laneLinkedForLabel:(NSString *)label {
  // Use the timeline lane's persisted lock ONLY when it carries aspect metadata
  // (a properly template-merged lane reflecting the user's toggle). The mini's
  // timeline is usually the raw blob-derived one where aspectLinkable isn't
  // serialized (=0) and aspectLinked is the un-materialized default (0) rather
  // than the directive's lock; there, fall back to the template's aspectLinked
  // so the OSC honours the directive default and matches the main viewer.
  for (KKLane *l in _renderer.timeline.lanes)
    if ([l.key isEqualToString:label]) {
      if (l.aspectLinkable)
        return l.aspectLinked;
      break;
    }
  KKLane *tmpl = [_renderer templateLaneForLabel:label];
  return tmpl ? tmpl.aspectLinked : YES;
}

- (CGPoint)centerForSpec:(NSDictionary<NSString *, id> *)s
             contentRect:(CGRect)cr {
  NSString *link = s[@"linkLabel"];
  double cx, cy;
  // A centre that depends on the lane's CURRENT value (a plugin's expression,
  // not a bare uniform reference) can't be baked into the spec - the spec is
  // built once per source change, when the value isn't known. Such a spec
  // carries a block that resolves the fraction per draw instead.
  CGPoint (^liveCenter)(CGRect) = s[@"centerFractionBlock"];
  if (liveCenter) {
    CGPoint f = liveCenter(cr);
    cx = f.x;
    cy = f.y;
  } else if ([link isKindOfClass:NSString.class] && link.length) {
    // Root value of the linked centre point: keep the ring anchored to that
    // point's OSC handle (also root), consistent across handles.
    NSArray<NSNumber *> *pv = [_renderer rootValuesForLabel:link];
    cx = pv.count >= 1 ? pv[0].doubleValue : 0.5;
    cy = pv.count >= 2 ? pv[1].doubleValue : 0.5;
  } else {
    cx = [s[@"centerX"] doubleValue];
    cy = [s[@"centerY"] doubleValue];
  }
  return [_renderer handlePointForContentRect:cr position:@[ @(cx), @(cy) ]];
}

- (CGFloat)ghostAlphaForLabel:(NSString *)label {
  return [_renderer ghostAlphaForLabel:label];
}

@end
