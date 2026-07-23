/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The render-path resolver: turn a lane's link expression (plus every `${ref}`
// it names) into a concrete value at a project time. Reads published curves
// through KKLinkBus's file store; the recursion resolves referenced sources
// against their OWN authored span. Compiled expressions are cached by source
// string (parsing is pure and this runs per lane per frame).

#import "KKLinkBus_Private.h"

#import "KKLinkExpr.h"
#import "KKTimingEvaluation.h"
#import "KKTimeline.h"

static KKExprVal KKLinkExprValFromArray(NSArray<NSNumber *> *arr) {
  KKExprVal v = {{0, 0, 0, 0}, 1};
  NSUInteger n = MIN((NSUInteger)4, arr.count);
  if (n >= 1) {
    v.n = (int)n;
    for (int i = 0; i < v.n; i++)
      v.v[i] = arr[i].doubleValue;
  }
  return v;
}

static NSArray<NSNumber *> *KKLinkArrayFromExprVal(KKExprVal v) {
  NSMutableArray<NSNumber *> *a =
      [NSMutableArray arrayWithCapacity:(NSUInteger)v.n];
  for (int i = 0; i < v.n; i++)
    [a addObject:@(v.v[i])];
  return a;
}

// Compiled-expression cache: the render path resolves the same expression
// string every frame, and parsing is pure, so cache by source. NSCache is
// thread-safe.
static KKLinkExpr *KKLinkCompile(NSString *src) {
  if (src.length == 0)
    return nil;
  static NSCache<NSString *, KKLinkExpr *> *cache = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cache = [[NSCache alloc] init];
  });
  KKLinkExpr *e = [cache objectForKey:src];
  if (!e) {
    e = [KKLinkExpr compile:src error:nil];
    if (e)
      [cache setObject:e forKey:src];
  }
  return e;
}

// Recursively evaluate a published source `name` at project time `T`: its OWN
// value is its keyposes sampled at T (held outside its authored span), then its
// own expression is applied - and each `${ref}` it names recurses through here.
// The visited set breaks cycles (A->B->A resolves to 0 instead of hanging).
static KKExprVal KKLinkResolveSource(NSString *name, double T,
                                     NSMutableSet<NSString *> *visiting,
                                     KKLinkRefOverride refOverride) {
  if (refOverride) {
    NSArray<NSNumber *> *ov = refOverride(name);
    if (ov.count > 0)
      return KKLinkExprValFromArray(ov); // live-drag value; skip the bus
  }
  if ([visiting containsObject:name])
    return KKExprScalar(0.0);
  KKLinkedCurve *curve = [KKLinkBus loadCurve:name];
  if (!curve)
    return KKExprScalar(0.0);
  NSArray<NSNumber *> *own =
      [curve valuesAtTimelineSeconds:T outOfRange:KKLinkOutOfRangeHold];
  KKExprVal ownVal = KKLinkExprValFromArray(own);
  KKLinkExpr *expr = KKLinkCompile(curve.lane.linkExpression);
  if (!expr)
    return ownVal; // no / bad expression -> the source's raw keyposes
  // The SOURCE's own clip-relative time, from its authored span, so a source
  // whose expression uses progress/ct animates against its OWN clip.
  double dur = curve.timelineEnd - curve.timelineStart;
  double local = T - curve.timelineStart;
  double srcProgress = dur > 0.0 ? MAX(0.0, MIN(1.0, local / dur)) : 0.0;
  double srcClipTime = dur > 0.0 ? MAX(0.0, MIN(dur, local)) : MAX(0.0, local);
  // HOLD outside the source's span for `t` too: clamp the ABSOLUTE time to the
  // authored span, so a source whose expression uses `t` (e.g. sin(t*tau))
  // freezes at its boundary value before/after the source clip exists, instead
  // of running live everywhere. Matches the held keyposes + clamped
  // progress/ct, so the WHOLE value holds - and the hold boundaries move with
  // the clip.
  double srcT = MAX(curve.timelineStart, MIN(curve.timelineEnd, T));
  [visiting addObject:name];
  KKExprVal out =
      [expr evalWithValue:ownVal
                        t:srcT
                 progress:srcProgress
                 clipTime:srcClipTime
               resolveRef:^KKExprVal(NSString *n) {
                 return KKLinkResolveSource(n, T, visiting, refOverride);
               }];
  [visiting removeObject:name];
  return out;
}

NSArray<NSNumber *> *KKLinkResolvedLaneValue(KKLane *lane, double frac,
                                             double timelineSec,
                                             double clipDurSec) {
  return KKLinkResolvedLaneValueWithOverride(lane, frac, timelineSec,
                                             clipDurSec, nil);
}

NSArray<NSNumber *> *
KKLinkResolvedLaneValueWithOverride(KKLane *lane, double frac,
                                    double timelineSec, double clipDurSec,
                                    KKLinkRefOverride refOverride) {
  NSString *exprStr = lane.linkExpression;
  BOOL trivial =
      exprStr.length == 0 ||
      [[exprStr
          stringByTrimmingCharactersInSet:[NSCharacterSet
                                              whitespaceAndNewlineCharacterSet]]
          isEqualToString:@"value"];
  if (trivial)
    // No expression (or bare passthrough) -> the lane's own value.
    return KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
  KKLinkExpr *expr = KKLinkCompile(exprStr);
  NSArray<NSNumber *> *own =
      KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
  if (!expr)
    return own;
  KKExprVal ownVal = KKLinkExprValFromArray(own);
  NSMutableSet<NSString *> *visiting = [NSMutableSet set];
  // `frac` is already the clip's 0..1 position; clip-local seconds = frac *
  // dur.
  KKExprVal out = [expr
      evalWithValue:ownVal
                  t:timelineSec
           progress:frac
           clipTime:frac * clipDurSec
         resolveRef:^KKExprVal(NSString *n) {
           return KKLinkResolveSource(n, timelineSec, visiting, refOverride);
         }];
  return KKLinkArrayFromExprVal(out);
}

NSSet<NSString *> *KKLinkTimelineSourceNames(KKTimeline *timeline) {
  NSMutableSet<NSString *> *names = [NSMutableSet set];
  for (KKLane *lane in timeline.lanes) {
    NSString *expr = lane.linkExpression;
    BOOL trivial = expr.length == 0 ||
                   [[expr stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceAndNewlineCharacterSet]]
                       isEqualToString:@"value"];
    if (!trivial) {
      KKLinkExpr *compiled = KKLinkCompile(expr);
      if (compiled)
        [names addObjectsFromArray:compiled.references];
    }
  }
  return names;
}
