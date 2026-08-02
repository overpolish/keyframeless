/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KKSlotInstances.h>
#import <KeyframelessKit/KKTimeline.h>

#import "MirageRack.h"  // rack entry ids, and the scoped registry key
#import "MirageSlots.h" // `#slots` grammar: groups, placeholders, uniforms

// --- `#slots`: prototypes, and the instances stamped from them -------------
//
// A control inside a `// #slots` block is not a lane. It is a PROTOTYPE, and
// the lanes are one copy of the whole block per instance the project has, with
// keys minted by the kit (`"<group>#<id>.<uniform>"`) and labels rendered at
// the instance's current display number.
//
// Which means the lane set is a function of the source AND of the timeline: the
// registry of instances lives there (KKTimeline.slotGroups), because the lanes
// alone cannot say that an instance exists but has been left at its defaults.
// Every builder that has a timeline in hand therefore stamps; the ones that do
// not - the code editor's validator, autocomplete, anything asking what a piece
// of GLSL declares - get the prototypes, which is the right answer for a
// question about the source rather than about a project.

/// The group index a built lane belongs to, or nil for an ordinary lane.
///
/// Matched by uniform rather than by position, because one directive can build
/// several lanes: a colour array adds `"<uniform> Count"` and `"<uniform> N"`,
/// an `#audio` binding adds its gate and release under `"<uniform>.…"`. They
/// all belong to the control the uniform names, so they all travel with it.
static inline NSNumber *
MirageSlotGroupIndexForLaneKey(NSString *laneKey,
                               NSDictionary<NSString *, NSNumber *> *byUniform,
                               NSString **outUniform) {
  if (!laneKey.length)
    return nil;
  NSNumber *best = nil;
  NSString *bestUniform = nil;
  for (NSString *uniform in byUniform) {
    if (!uniform.length)
      continue;
    BOOL owns = [laneKey isEqualToString:uniform] ||
                [laneKey hasPrefix:[uniform stringByAppendingString:@" "]] ||
                [laneKey hasPrefix:[uniform stringByAppendingString:@"."]];
    // Longest wins, so a `uColor` prototype cannot claim `uColorStrength`'s
    // lanes on a prefix that is only an accident of naming.
    if (!owns || (bestUniform && bestUniform.length >= uniform.length))
      continue;
    best = byUniform[uniform];
    bestUniform = uniform;
  }
  if (outUniform)
    *outUniform = bestUniform;
  return best;
}

/// One prototype lane, stamped for one instance.
///
/// Everything that IDENTIFIES the lane is rewritten and nothing else is: key,
/// display label, and the keys the lane points at (its keypose-popover scope,
/// its palette group, and any gate aimed at a sibling in the same block). A
/// gate aimed OUTSIDE the block is left alone - it names a control the whole
/// group shares, and rewriting it would point every instance at a lane that
/// does not exist.
static inline KKLane *MirageSlotStampedLane(KKLane *proto, NSString *groupName,
                                            NSString *instanceID,
                                            NSInteger number,
                                            NSArray<KKLane *> *siblings) {
  KKLane *lane = [proto copy];
  lane.key = KKSlotLaneKey(groupName, instanceID, proto.key ?: proto.label);
  // The kit's token first, then the grammar's shouted spelling of it, so
  // `label="Colour {N}"` reads the same as `label="Colour {n}"` rather than
  // reaching the inspector with the placeholder still in it.
  lane.label = MirageSlotsSubstitute(KKSlotRenderedLabel(proto.label, number),
                                     (int)number);
  if (proto.groupKey.length)
    lane.groupKey = KKSlotLaneKey(groupName, instanceID, proto.groupKey);
  if (proto.paletteGroup.length)
    lane.paletteGroup =
        KKSlotLaneKey(groupName, instanceID, proto.paletteGroup);
  for (KKLane *sibling in siblings) {
    if (!sibling.key.length)
      continue;
    if ([proto.visibleWhenKey isEqualToString:sibling.key])
      lane.visibleWhenKey =
          KKSlotLaneKey(groupName, instanceID, proto.visibleWhenKey);
    if ([proto.maxControllerKey isEqualToString:sibling.key])
      lane.maxControllerKey =
          KKSlotLaneKey(groupName, instanceID, proto.maxControllerKey);
  }
  return lane;
}

/// Replace each group's prototypes with its instances, in place.
///
/// A group the timeline has never registered is brought up to the declared
/// `default=` first, which is what a fresh apply and a project made before the
/// directive existed both look like. A group it HAS registered is taken exactly
/// as it stands, however many that is: the count is the user's, not the
/// author's, the moment they have touched it.
///
/// The instances land where the prototypes were, INSTANCE-MAJOR - every control
/// of Colour 1, then every control of Colour 2 - because the block is the unit
/// the user added, and a control-major list interleaves two things they think
/// of as one each.
///
/// Per INSPECTOR GROUP, though, not as one run: a block declaring a colour and
/// a slider puts one in Colours and the other wherever it asked to go, and the
/// ordering pass at the end of the build sorts by that group. Moving both to
/// the first prototype's position would drag the colours ahead of the palette
/// bar they belong under.
///
/// `entryID` is the RACK ENTRY the source belongs to, and it scopes the
/// REGISTRY only: the instances of a group declared inside entry E are tracked
/// under `MirageRackScopedSlotGroupName(E, name)`, so two entries running the
/// same template each mint their own. The stamped lane KEYS stay bare
/// (`<group>#<id>.<uniform>`) - the rack prefix is applied once, afterwards, by
/// the entry's key-rewrite pass, which is what makes the composition in
/// MirageRackScopedSlotGroupName's note hold.
static inline void
MirageStampSlotLanesForRackEntry(NSMutableArray<KKLane *> *lanes,
                                 NSString *source, KKTimeline *timeline,
                                 NSString *entryID) {
  if (!timeline || !lanes.count)
    return;
  NSArray<NSValue *> *groups = MirageSlotGroupsForSource(source, NULL, NULL);
  if (!groups.count)
    return;
  NSDictionary<NSString *, NSNumber *> *byUniform =
      MirageSlotGroupIndexByUniform(source);
  if (!byUniform.count)
    return;
  for (NSUInteger gi = 0; gi < groups.count; gi++) {
    MirageSlotsGroup g = MirageSlotsGroupValue(groups[gi]);
    NSString *name = @(g.name);
    NSString *registryName = MirageRackScopedSlotGroupName(entryID, name);
    NSMutableArray<KKLane *> *protos = [NSMutableArray array];
    // The prototypes of one inspector group, and the row the first of them
    // occupies - which is where that group's instances go.
    NSMutableDictionary<NSString *, NSMutableArray<KKLane *> *> *byCategory =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *anchorRow =
        [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < lanes.count; i++) {
      NSNumber *owner =
          MirageSlotGroupIndexForLaneKey(lanes[i].key, byUniform, NULL);
      if (!owner || owner.unsignedIntegerValue != gi)
        continue;
      [protos addObject:lanes[i]];
      NSString *category = lanes[i].categoryKey ?: @"";
      if (!byCategory[category]) {
        byCategory[category] = [NSMutableArray array];
        anchorRow[category] = @(i);
      }
      [byCategory[category] addObject:lanes[i]];
    }
    if (!protos.count)
      continue;
    if (!timeline.slotGroups[registryName])
      KKTimelineEnsureSlotCount(timeline, registryName, g.defaultCount, protos);
    NSArray<NSString *> *ids =
        KKTimelineSlotInstanceIDs(timeline, registryName);
    // One pass: a prototype is replaced by its group's instances at the row the
    // first of them held, and dropped everywhere else.
    NSMutableArray<KKLane *> *rebuilt =
        [NSMutableArray arrayWithCapacity:lanes.count];
    for (NSUInteger i = 0; i < lanes.count; i++) {
      NSNumber *owner =
          MirageSlotGroupIndexForLaneKey(lanes[i].key, byUniform, NULL);
      if (!owner || owner.unsignedIntegerValue != gi) {
        [rebuilt addObject:lanes[i]];
        continue;
      }
      NSString *category = lanes[i].categoryKey ?: @"";
      if (anchorRow[category].unsignedIntegerValue != i)
        continue;
      for (NSUInteger k = 0; k < ids.count; k++)
        for (KKLane *proto in byCategory[category])
          [rebuilt addObject:MirageSlotStampedLane(proto, name, ids[k],
                                                   (NSInteger)k + 1, protos)];
    }
    [lanes setArray:rebuilt];
  }
}

/// The `#slots` groups `shaderSource` declares, as
/// `@{@"name": …, @"max": …, @"min": …, @"default": …}`, in declaration order.
/// The panel's view of the grammar, so it needs no struct of its own to ask how
/// many instances a group may have.
static inline NSArray<NSDictionary<NSString *, id> *> *
MirageSlotGroupSummariesForSource(NSString *shaderSource) {
  NSMutableArray<NSDictionary<NSString *, id> *> *out = [NSMutableArray array];
  for (NSValue *boxed in MirageSlotGroupsForSource(shaderSource, NULL, NULL)) {
    MirageSlotsGroup g = MirageSlotsGroupValue(boxed);
    [out addObject:@{
      @"name" : @(g.name),
      @"max" : @(g.maxCount),
      @"min" : @(g.minCount),
      @"default" : @(g.defaultCount)
    }];
  }
  return out;
}
