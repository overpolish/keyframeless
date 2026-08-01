/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The Grading panel's view of `#slots`.
//
// Everything the grammar reports is keyed by UNIFORM and named with `{n}` still
// in it, because that is what the source says. The panel works in LANES, whose
// keys are `"<group>#<id>.<uniform>"`, and in pucks the user can tell apart,
// which means "Colour 3" rather than "Colour {n}". This header is the one place
// that crossing happens.
//
// It is a re-keying and nothing more: no response is re-parsed, no puck order
// is re-decided. A shader with no `#slots` block gets its own dictionaries back
// unchanged, so the panel behaves exactly as it did before any of this existed.
#pragma once

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKSlotInstances.h>
#import <KeyframelessKit/KKTimeline.h>

#import "MirageSurfaceResponse.h"

NS_ASSUME_NONNULL_BEGIN

/// The group each slot uniform belongs to, by NAME rather than by index - which
/// is what every caller here actually wants, since the name is what the
/// registry and the lane keys are keyed on.
static inline NSDictionary<NSString *, NSString *> *
MirageSlotGroupNameByUniform(NSString *source) {
  NSMutableDictionary<NSString *, NSString *> *out =
      [NSMutableDictionary dictionary];
  NSArray<NSValue *> *groups = MirageSlotGroupsForSource(source, NULL, NULL);
  if (!groups.count)
    return out;
  NSDictionary<NSString *, NSNumber *> *byIndex =
      MirageSlotGroupIndexByUniform(source);
  for (NSString *uniform in byIndex) {
    NSUInteger gi = byIndex[uniform].unsignedIntegerValue;
    if (gi < groups.count)
      out[uniform] = @(MirageSlotsGroupValue(groups[gi]).name);
  }
  return out;
}

/// Run `block` once per (slot uniform, live instance) pair, in registry order.
/// The one walk the expansions below share, so "which instances exist" is
/// answered in a single place.
static inline void MirageSlotEnumerateInstances(
    NSString *source, KKTimeline *_Nullable timeline,
    void (^block)(NSString *uniform, NSString *groupName, NSString *instanceID,
                  NSInteger number)) {
  if (!timeline || !block)
    return;
  NSDictionary<NSString *, NSString *> *groupByUniform =
      MirageSlotGroupNameByUniform(source);
  for (NSString *uniform in groupByUniform) {
    NSString *group = groupByUniform[uniform];
    NSArray<NSString *> *ids = KKTimelineSlotInstanceIDs(timeline, group);
    for (NSUInteger k = 0; k < ids.count; k++)
      block(uniform, group, ids[k], (NSInteger)k + 1);
  }
}

/// `responses` re-keyed onto the instance lanes, each one's puck name rendered
/// for its instance. The prototype entries are DROPPED: a prototype drives no
/// lane, and leaving it in would let a gesture write a key nothing holds.
static inline NSDictionary<NSString *, NSValue *> *
MirageSlotExpandResponses(NSDictionary<NSString *, NSValue *> *responses,
                          NSString *source, KKTimeline *_Nullable timeline) {
  NSDictionary<NSString *, NSString *> *groupByUniform =
      MirageSlotGroupNameByUniform(source);
  if (!groupByUniform.count || !responses.count)
    return responses;
  NSMutableDictionary<NSString *, NSValue *> *out = [responses mutableCopy];
  for (NSString *uniform in groupByUniform)
    [out removeObjectForKey:uniform];
  MirageSlotEnumerateInstances(
      source, timeline,
      ^(NSString *uniform, NSString *group, NSString *instanceID, NSInteger n) {
        NSValue *boxed = responses[uniform];
        if (!boxed)
          return;
        MirageSurfaceResponse r;
        [boxed getValue:&r];
        NSString *puck = MirageSlotsSubstitute(@(r.puck) ?: @"", (int)n);
        memset(r.puck, 0, sizeof(r.puck));
        strncpy(r.puck, puck.UTF8String ?: "", sizeof(r.puck) - 1);
        out[KKSlotLaneKey(group, instanceID, uniform)] =
            [NSValue valueWithBytes:&r objCType:@encode(MirageSurfaceResponse)];
      });
  return out;
}

/// `pick=` subscriptions re-keyed onto the instance lanes.
static inline NSDictionary<NSString *, NSNumber *> *
MirageSlotExpandPicks(NSDictionary<NSString *, NSNumber *> *picks,
                      NSString *source, KKTimeline *_Nullable timeline) {
  NSDictionary<NSString *, NSString *> *groupByUniform =
      MirageSlotGroupNameByUniform(source);
  if (!groupByUniform.count || !picks.count)
    return picks;
  NSMutableDictionary<NSString *, NSNumber *> *out = [picks mutableCopy];
  for (NSString *uniform in groupByUniform)
    [out removeObjectForKey:uniform];
  MirageSlotEnumerateInstances(
      source, timeline,
      ^(NSString *uniform, NSString *group, NSString *instanceID, NSInteger n) {
        NSNumber *kind = picks[uniform];
        if (kind)
          out[KKSlotLaneKey(group, instanceID, uniform)] = kind;
      });
  return out;
}

/// The puck each control belongs to, re-keyed onto the instance lanes and
/// rendered for the instance - so `puck={"Colour {n}"}` on one prototype
/// becomes one handle per instance rather than one handle every instance fights
/// over.
static inline NSDictionary<NSString *, NSString *> *
MirageSlotExpandPuckNames(NSDictionary<NSString *, NSString *> *puckNames,
                          NSString *source, KKTimeline *_Nullable timeline) {
  NSDictionary<NSString *, NSString *> *groupByUniform =
      MirageSlotGroupNameByUniform(source);
  if (!groupByUniform.count || !puckNames.count)
    return puckNames;
  NSMutableDictionary<NSString *, NSString *> *out = [puckNames mutableCopy];
  for (NSString *uniform in groupByUniform)
    [out removeObjectForKey:uniform];
  MirageSlotEnumerateInstances(
      source, timeline,
      ^(NSString *uniform, NSString *group, NSString *instanceID, NSInteger n) {
        NSString *proto = puckNames[uniform];
        if (proto.length)
          out[KKSlotLaneKey(group, instanceID, uniform)] =
              MirageSlotsSubstitute(proto, (int)n);
      });
  return out;
}

/// The group each PROTOTYPE puck name belongs to, from the block its control
/// sits in. The panel's way back from a handle to the thing it is an instance
/// of, without a second model of the source.
static inline NSDictionary<NSString *, NSString *> *
MirageSlotGroupByPuckPrototype(NSString *source) {
  NSMutableDictionary<NSString *, NSString *> *out =
      [NSMutableDictionary dictionary];
  NSArray<NSValue *> *groups = MirageSlotGroupsForSource(source, NULL, NULL);
  if (!groups.count)
    return out;
  for (NSTextCheckingResult *dm in MirageSlotsDirectiveMatches(source)) {
    NSInteger gi = MirageSlotGroupIndexForLocation(groups, dm.range.location);
    if (gi < 0)
      continue;
    NSString *attrs = [source substringWithRange:[dm rangeAtIndex:2]];
    char name[48] = {0}, symbol[48] = {0};
    MirageParseNamedPairAttr(attrs, @"puck", name, sizeof(name), symbol,
                             sizeof(symbol));
    if (name[0])
      out[@(name)] = @(MirageSlotsGroupValue(groups[(NSUInteger)gi]).name);
  }
  return out;
}

/// A ring's puck list with each prototype handle expanded into one entry per
/// live instance, carrying the `group` and `instance` it came from so a click
/// on it can be traced back.
///
/// Order is the source's, with an instance run in registry order where the
/// prototype was: the author decides where the repeatable handles sit among the
/// fixed ones, and the user decides how many.
static inline NSArray<NSDictionary<NSString *, NSString *> *> *
MirageSlotExpandPucks(NSArray<NSDictionary<NSString *, NSString *> *> *pucks,
                      NSString *source, KKTimeline *_Nullable timeline) {
  NSDictionary<NSString *, NSString *> *groupByProto =
      MirageSlotGroupByPuckPrototype(source);
  if (!groupByProto.count || !timeline)
    return pucks;
  NSMutableArray<NSDictionary<NSString *, NSString *> *> *out =
      [NSMutableArray array];
  for (NSDictionary<NSString *, NSString *> *spec in pucks) {
    NSString *group = groupByProto[spec[@"name"] ?: @""];
    if (!group.length) {
      [out addObject:spec];
      continue;
    }
    NSArray<NSString *> *ids = KKTimelineSlotInstanceIDs(timeline, group);
    for (NSUInteger k = 0; k < ids.count; k++) {
      NSMutableDictionary<NSString *, NSString *> *entry = [spec mutableCopy];
      entry[@"name"] = MirageSlotsSubstitute(spec[@"name"] ?: @"", (int)k + 1);
      entry[@"symbol"] =
          MirageSlotsSubstitute(spec[@"symbol"] ?: @"", (int)k + 1);
      // The number this instance shows the user, carried so the panel can fall
      // back to it when the prototype declared no symbol: a run of handles the
      // author left undecorated still counts off rather than reading as one
      // handle drawn several times.
      entry[@"number"] = [@(k + 1) stringValue];
      entry[@"group"] = group;
      entry[@"instance"] = ids[k];
      [out addObject:entry];
    }
  }
  return out;
}

/// The expanded puck entry with this name, or nil. Names are unique by
/// construction - that is what the grammar's `{n}` requirement buys - so a name
/// is enough to identify one instance's handle.
static inline NSDictionary<NSString *, NSString *>
    *_Nullable MirageSlotPuckEntryNamed(
        NSArray<NSDictionary<NSString *, NSString *> *> *expandedPucks,
        NSString *_Nullable name) {
  for (NSDictionary<NSString *, NSString *> *entry in expandedPucks)
    if ([entry[@"name"] isEqualToString:name ?: @""] &&
        [entry[@"instance"] length])
      return entry;
  return nil;
}

/// The groups whose controls put a handle on `ring`, in declaration order.
/// `filterRing` is NO for a shader with a single surface, where every handle is
/// on the one circle whether or not it says so.
static inline NSArray<NSString *> *
MirageSlotGroupsWithPuckOnRing(NSString *source, MirageColorSurfaceRing ring,
                               BOOL filterRing) {
  NSMutableArray<NSString *> *out = [NSMutableArray array];
  NSArray<NSValue *> *groups = MirageSlotGroupsForSource(source, NULL, NULL);
  if (!groups.count)
    return out;
  for (NSTextCheckingResult *dm in MirageSlotsDirectiveMatches(source)) {
    NSInteger gi = MirageSlotGroupIndexForLocation(groups, dm.range.location);
    if (gi < 0)
      continue;
    NSString *attrs = [source substringWithRange:[dm rangeAtIndex:2]];
    MirageSurfaceResponse r = MirageParseSurfaceResponse(attrs);
    if (!r.present || !r.puck[0])
      continue;
    if (filterRing && !MirageSurfaceResponseOnRing(r, ring, YES))
      continue;
    NSString *name = @(MirageSlotsGroupValue(groups[(NSUInteger)gi]).name);
    if (![out containsObject:name])
      [out addObject:name];
  }
  return out;
}

/// `groupName`'s declared ceiling and floor, 0 when it declares no such group.
static inline void MirageSlotGroupLimits(NSString *source, NSString *groupName,
                                         NSInteger *outMax, NSInteger *outMin) {
  if (outMax)
    *outMax = 0;
  if (outMin)
    *outMin = 0;
  for (NSValue *boxed in MirageSlotGroupsForSource(source, NULL, NULL)) {
    MirageSlotsGroup g = MirageSlotsGroupValue(boxed);
    if (![@(g.name) isEqualToString:groupName ?: @""])
      continue;
    if (outMax)
      *outMax = g.maxCount;
    if (outMin)
      *outMin = g.minCount;
    return;
  }
}

NS_ASSUME_NONNULL_END
