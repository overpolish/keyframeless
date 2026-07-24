/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Conditional lane visibility: resolve which lanes are shown given the current
// values (a lane can gate on another lane via visibleWhen*). The recursive
// clause evaluator + KKLaneComponentLabels / KKConditionalVisibleLaneKeys.

#import "KKTimeline.h"

#import "KKBezierPath.h"
#import "KKEasing.h"
#import "KKPathMorph.h"

NSArray<NSString *> *KKLaneComponentLabels(KKLane *lane) {
  if (!lane)
    return nil;
  if (lane.componentLabels.count)
    return lane.componentLabels;
  switch (lane.valueType) {
  case KKLaneValueTypeCrop:
    return @[ @"W", @"H", @"X", @"Y" ];
  case KKLaneValueTypeColor:
    return @[ @"R", @"G", @"B", @"A" ];
  case KKLaneValueTypeAngle: {
    // A multi-axis angle (e.g. Rotation X/Y/Z) carries explicit labels and
    // returned above; a lone angle (Fill Angle, a gradient direction) has none,
    // so hand back a single empty label. The static-value row keys its circular
    // knob off a >= 1 component count, so without this a 1-axis angle would
    // fall through to a plain field instead of the dial.
    NSUInteger n = lane.keyposes.firstObject.values.count;
    if (n <= 1)
      return @[ @"" ];
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++)
      [out addObject:@""];
    return out;
  }
  case KKLaneValueTypeFloat:
  case KKLaneValueTypeNormalized:
    return nil;
  case KKLaneValueTypeGradient:
  case KKLaneValueTypeGeneric:
  default: {
    NSUInteger n = lane.keyposes.firstObject.values.count;
    if (n <= 1)
      return nil;
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++)
      [out
          addObject:[NSString stringWithFormat:@"%lu", (unsigned long)(i + 1)]];
    return out;
  }
  }
}

// Component values a lane currently holds for a visibility test - the live
// override (mid-edit) when present, else the first keypose.
static NSArray<NSNumber *> *_KKLaneCondValues(
    KKLane *lane,
    NSDictionary<NSString *, NSArray<NSNumber *> *> *valuesByLabel) {
  NSArray<NSNumber *> *v = valuesByLabel[lane.key];
  return v ?: (lane.keyposes.firstObject.values ?: @[]);
}

static BOOL _KKLaneCondVisible(
    KKLane *lane, NSDictionary<NSString *, KKLane *> *byLabel,
    NSDictionary<NSString *, NSArray<NSNumber *> *> *valuesByLabel,
    NSMutableDictionary<NSString *, NSNumber *> *memo);

// One visibility clause: does `ctrlLabel`'s component-0 value match `values`,
// and is the controller itself visible? An absent controller / empty label =
// NO (the clause doesn't hold) - the OR caller treats that as "this side off".
static BOOL _KKLaneCondClause(
    NSString *ctrlLabel, NSArray<NSNumber *> *values, KKLane *lane,
    NSDictionary<NSString *, KKLane *> *byLabel,
    NSDictionary<NSString *, NSArray<NSNumber *> *> *valuesByLabel,
    NSMutableDictionary<NSString *, NSNumber *> *memo) {
  if (ctrlLabel.length == 0)
    return NO;
  KKLane *ctrl = byLabel[ctrlLabel];
  if (!ctrl)
    return NO;
  NSArray<NSNumber *> *cv = _KKLaneCondValues(ctrl, valuesByLabel);
  NSInteger idx = cv.count ? (NSInteger)llround(cv[0].doubleValue) : 0;
  BOOL match = NO;
  for (NSNumber *n in values)
    if ((NSInteger)llround(n.doubleValue) == idx) {
      match = YES;
      break;
    }
  if (!match)
    return NO;
  if (ctrl == lane)
    return YES;
  return _KKLaneCondVisible(ctrl, byLabel, valuesByLabel, memo);
}

static BOOL _KKLaneCondVisible(
    KKLane *lane, NSDictionary<NSString *, KKLane *> *byLabel,
    NSDictionary<NSString *, NSArray<NSNumber *> *> *valuesByLabel,
    NSMutableDictionary<NSString *, NSNumber *> *memo) {
  if (lane.visibleWhenKey.length == 0 &&
      lane.visibleWhenOrKey.length == 0 &&
      lane.visibleWhenAndKey.length == 0)
    return YES;
  NSNumber *cached = memo[lane.key];
  if (cached)
    return cached.boolValue;
  memo[lane.key] = @NO; // cycle guard
  BOOL vis;
  if (lane.visibleWhenOrKey.length > 0) {
    // OR mode: visible if either clause holds (absent controller = clause off).
    vis = _KKLaneCondClause(lane.visibleWhenKey, lane.visibleWhenValues, lane,
                            byLabel, valuesByLabel, memo) ||
          _KKLaneCondClause(lane.visibleWhenOrKey, lane.visibleWhenOrValues,
                            lane, byLabel, valuesByLabel, memo);
  } else if (lane.visibleWhenKey.length == 0) {
    // No primary rule (AND-only lane): the primary side is unconstrained.
    vis = YES;
  } else if (!byLabel[lane.visibleWhenKey]) {
    // Single rule, controller absent: can't evaluate, so don't filter.
    vis = YES;
  } else {
    vis = _KKLaneCondClause(lane.visibleWhenKey, lane.visibleWhenValues, lane,
                            byLabel, valuesByLabel, memo);
  }
  // Optional second AND gate: an absent controller counts as false (hide), like
  // the OR clause, so a lane can require both a Type match AND a count >= N.
  if (vis && lane.visibleWhenAndKey.length > 0)
    vis = _KKLaneCondClause(lane.visibleWhenAndKey, lane.visibleWhenAndValues,
                            lane, byLabel, valuesByLabel, memo);
  memo[lane.key] = @(vis);
  return vis;
}

NSSet<NSString *> *KKConditionalVisibleLaneKeys(
    NSArray<KKLane *> *lanes,
    NSDictionary<NSString *, NSArray<NSNumber *> *> *valuesByLabel) {
  NSMutableDictionary<NSString *, KKLane *> *byLabel =
      [NSMutableDictionary dictionaryWithCapacity:lanes.count];
  for (KKLane *l in lanes)
    byLabel[l.key] = l;
  NSMutableSet<NSString *> *out = [NSMutableSet setWithCapacity:lanes.count];
  NSMutableDictionary<NSString *, NSNumber *> *memo =
      [NSMutableDictionary dictionaryWithCapacity:lanes.count];
  for (KKLane *l in lanes)
    if (_KKLaneCondVisible(l, byLabel, valuesByLabel ?: @{}, memo))
      [out addObject:l.key];
  return out;
}
