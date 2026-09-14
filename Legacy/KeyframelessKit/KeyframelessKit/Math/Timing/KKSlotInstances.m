/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKSlotInstances.h"

#import "KKLog.h"
#import "KKTimeline.h"

NSString *const kKKSlotInstanceSeparator = @"#";
NSString *const kKKSlotControlSeparator = @".";
NSString *const kKKSlotLabelNumberToken = @"{n}";

NSString *KKSlotLaneKey(NSString *groupName, NSString *instanceID,
                        NSString *controlKey) {
  return [NSString stringWithFormat:@"%@%@%@%@%@", groupName,
                                    kKKSlotInstanceSeparator, instanceID,
                                    kKKSlotControlSeparator, controlKey];
}

BOOL KKSlotParseLaneKey(NSString *laneKey,
                        NSString *_Nullable *_Nullable outGroupName,
                        NSString *_Nullable *_Nullable outInstanceID,
                        NSString *_Nullable *_Nullable outControlKey) {
  if (![laneKey isKindOfClass:[NSString class]] || laneKey.length == 0)
    return NO;
  NSRange hash = [laneKey rangeOfString:kKKSlotInstanceSeparator];
  if (hash.location == NSNotFound || hash.location == 0)
    return NO;
  NSUInteger afterHash = NSMaxRange(hash);
  NSRange tail = NSMakeRange(afterHash, laneKey.length - afterHash);
  // First dot AFTER the id, not the first dot in the whole key: a group name is
  // free to contain one, a minted id never is.
  NSRange dot = [laneKey rangeOfString:kKKSlotControlSeparator
                               options:0
                                 range:tail];
  if (dot.location == NSNotFound || dot.location == afterHash)
    return NO;
  NSString *control = [laneKey substringFromIndex:NSMaxRange(dot)];
  if (control.length == 0)
    return NO;
  if (outGroupName)
    *outGroupName = [laneKey substringToIndex:hash.location];
  if (outInstanceID)
    *outInstanceID = [laneKey
        substringWithRange:NSMakeRange(afterHash, dot.location - afterHash)];
  if (outControlKey)
    *outControlKey = control;
  return YES;
}

NSArray<NSString *> *KKTimelineSlotInstanceIDs(KKTimeline *timeline,
                                               NSString *groupName) {
  NSArray<NSString *> *ids = timeline.slotGroups[groupName];
  return [ids isKindOfClass:[NSArray class]] ? ids : @[];
}

NSInteger KKTimelineSlotDisplayNumber(KKTimeline *timeline, NSString *groupName,
                                      NSString *instanceID) {
  NSUInteger idx =
      [KKTimelineSlotInstanceIDs(timeline, groupName) indexOfObject:instanceID];
  return idx == NSNotFound ? 0 : (NSInteger)idx + 1;
}

NSArray<KKLane *> *KKTimelineSlotLanes(KKTimeline *timeline,
                                       NSString *groupName,
                                       NSString *instanceID) {
  NSMutableArray<KKLane *> *out = [NSMutableArray array];
  for (KKLane *lane in timeline.lanes) {
    NSString *g = nil, *i = nil;
    if (KKSlotParseLaneKey(lane.key, &g, &i, NULL) &&
        [g isEqualToString:groupName] && [i isEqualToString:instanceID])
      [out addObject:lane];
  }
  return out;
}

NSString *KKSlotRenderedLabel(NSString *prototypeLabel, NSInteger n) {
  if (prototypeLabel.length == 0)
    return @"";
  return [prototypeLabel
      stringByReplacingOccurrencesOfString:kKKSlotLabelNumberToken
                                withString:[@(n) stringValue]];
}

/// A fresh 6-hex-character id, checked against the ids already in the group.
/// Short because it shows up in every one of the instance's lane keys, and the
/// only uniqueness requirement is within one group of one timeline - a handful
/// of instances, where 16.7M values makes a collision a non-event. Retried
/// anyway, because "unlikely" is not "impossible" and a collision would
/// silently merge two instances' lanes.
static NSString *_KKMintSlotInstanceID(NSArray<NSString *> *existing) {
  for (int attempt = 0; attempt < 64; attempt++) {
    NSString *candidate =
        [NSString stringWithFormat:@"%06x", arc4random_uniform(0x1000000)];
    if (![existing containsObject:candidate])
      return candidate;
  }
  // 64 collisions in a row is not a random-number problem, it is a bug
  // somewhere upstream. Fall back to something guaranteed unique rather than
  // handing back a duplicate.
  KKLogWarn(@"Slot instance id minting kept colliding (%lu existing) - falling "
            @"back to a UUID fragment",
            (unsigned long)existing.count);
  return [[[NSUUID UUID].UUIDString substringToIndex:8] lowercaseString];
}

NSString *_Nullable KKTimelineStampSlotInstance(KKTimeline *timeline,
                                                NSString *groupName,
                                                NSArray<KKLane *> *prototypes) {
  if (!timeline || groupName.length == 0 || prototypes.count == 0)
    return nil;

  NSMutableArray<NSString *> *ids =
      [KKTimelineSlotInstanceIDs(timeline, groupName) mutableCopy];
  NSString *instanceID = _KKMintSlotInstanceID(ids);
  [ids addObject:instanceID];

  NSMutableDictionary<NSString *, NSArray<NSString *> *> *groups =
      [(timeline.slotGroups ?: @{}) mutableCopy];
  groups[groupName] = ids;
  timeline.slotGroups = groups;

  NSInteger number = (NSInteger)ids.count; // 1-based, and it lands last
  NSMutableArray<KKLane *> *lanes =
      [timeline.lanes mutableCopy] ?: [NSMutableArray array];
  for (KKLane *proto in prototypes) {
    KKLane *lane = [proto copy];
    lane.key = KKSlotLaneKey(groupName, instanceID, proto.key ?: proto.label);
    lane.label = KKSlotRenderedLabel(proto.label, number);
    [lanes addObject:lane];
  }
  timeline.lanes = lanes;
  return instanceID;
}

BOOL KKTimelineRemoveSlotInstance(KKTimeline *timeline, NSString *groupName,
                                  NSString *instanceID) {
  if (!timeline || groupName.length == 0 || instanceID.length == 0)
    return NO;
  NSArray<NSString *> *ids = KKTimelineSlotInstanceIDs(timeline, groupName);
  if (![ids containsObject:instanceID])
    return NO;

  NSMutableArray<NSString *> *remaining = [ids mutableCopy];
  [remaining removeObject:instanceID];
  NSMutableDictionary<NSString *, NSArray<NSString *> *> *groups =
      [(timeline.slotGroups ?: @{}) mutableCopy];
  // An emptied group stays registered (as an empty array): the host declared
  // it, and dropping the entry would make "declared but empty" look like
  // "never declared" to the ensure-count path.
  groups[groupName] = remaining;
  timeline.slotGroups = groups;

  NSMutableArray<KKLane *> *lanes = [NSMutableArray array];
  for (KKLane *lane in timeline.lanes) {
    NSString *g = nil, *i = nil;
    BOOL isVictim = KKSlotParseLaneKey(lane.key, &g, &i, NULL) &&
                    [g isEqualToString:groupName] &&
                    [i isEqualToString:instanceID];
    if (!isVictim)
      [lanes addObject:lane];
  }
  timeline.lanes = lanes;
  return YES;
}

void KKTimelineRestampSlotLabels(KKTimeline *timeline, NSString *groupName,
                                 NSArray<KKLane *> *prototypes) {
  if (!timeline || groupName.length == 0 || prototypes.count == 0)
    return;
  NSMutableDictionary<NSString *, NSString *> *labelByControl =
      [NSMutableDictionary dictionaryWithCapacity:prototypes.count];
  for (KKLane *proto in prototypes)
    labelByControl[proto.key ?: proto.label] = proto.label ?: @"";

  NSArray<NSString *> *ids = KKTimelineSlotInstanceIDs(timeline, groupName);
  NSMutableArray<KKLane *> *lanes = [NSMutableArray array];
  for (KKLane *lane in timeline.lanes) {
    NSString *g = nil, *i = nil, *control = nil;
    NSString *proto = nil;
    if (KKSlotParseLaneKey(lane.key, &g, &i, &control) &&
        [g isEqualToString:groupName])
      proto = labelByControl[control];
    NSUInteger idx = proto ? [ids indexOfObject:i] : NSNotFound;
    if (idx == NSNotFound) {
      [lanes addObject:lane];
      continue;
    }
    KKLane *c = [lane copy];
    c.label = KKSlotRenderedLabel(proto, (NSInteger)idx + 1);
    [lanes addObject:c];
  }
  timeline.lanes = lanes;
}

NSString *KKSlotRegistrySignature(KKTimeline *timeline) {
  NSDictionary<NSString *, NSArray<NSString *> *> *groups = timeline.slotGroups;
  if (!groups.count)
    return @"";
  NSMutableString *signature = [NSMutableString string];
  for (NSString *group in
       [groups.allKeys sortedArrayUsingSelector:@selector(compare:)])
    [signature appendFormat:@"%@=%@;", group,
                            [groups[group] componentsJoinedByString:@","]];
  return signature;
}

NSDictionary<NSString *, NSArray<NSString *> *> *
KKSlotSignatureParse(NSString *signature) {
  NSMutableDictionary<NSString *, NSArray<NSString *> *> *out =
      [NSMutableDictionary dictionary];
  for (NSString *entry in [signature componentsSeparatedByString:@";"]) {
    NSRange eq = [entry rangeOfString:@"="];
    if (!entry.length || eq.location == NSNotFound)
      continue;
    NSString *ids = [entry substringFromIndex:eq.location + 1];
    out[[entry substringToIndex:eq.location]] =
        ids.length ? [ids componentsSeparatedByString:@","] : @[];
  }
  return out;
}

NSString *_Nullable KKSlotFirstAddedInstance(
    NSString *_Nullable was, NSString *_Nullable now,
    NSString *_Nullable *_Nullable outGroup) {
  NSDictionary<NSString *, NSArray<NSString *> *> *before =
      KKSlotSignatureParse(was ?: @"");
  NSDictionary<NSString *, NSArray<NSString *> *> *after =
      KKSlotSignatureParse(now ?: @"");
  for (NSString *group in
       [after.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    NSSet<NSString *> *had = [NSSet setWithArray:before[group] ?: @[]];
    for (NSString *instance in after[group]) {
      if ([had containsObject:instance])
        continue;
      if (outGroup)
        *outGroup = group;
      return instance;
    }
  }
  return nil;
}

BOOL KKTimelineEnsureSlotCount(KKTimeline *timeline, NSString *groupName,
                               NSInteger count, NSArray<KKLane *> *prototypes) {
  if (!timeline || groupName.length == 0 || count < 0)
    return NO;
  BOOL changed = NO;
  while ((NSInteger)KKTimelineSlotInstanceIDs(timeline, groupName).count >
         count) {
    NSString *last = KKTimelineSlotInstanceIDs(timeline, groupName).lastObject;
    if (!KKTimelineRemoveSlotInstance(timeline, groupName, last))
      break;
    changed = YES;
  }
  while ((NSInteger)KKTimelineSlotInstanceIDs(timeline, groupName).count <
         count) {
    if (!KKTimelineStampSlotInstance(timeline, groupName, prototypes))
      break;
    changed = YES;
  }
  if (changed)
    KKTimelineRestampSlotLabels(timeline, groupName, prototypes);
  return changed;
}
