/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFNativeEdits.h"
#import "KFNativeLinks.h"
#import "KFNativeLinks_Private.h"
@import InspectorControls;

NSArray<NSDictionary *> *KFMembers(id<PROAPIAccessing> m,
                                          NSString *link) {
  NSMutableArray *result = [NSMutableArray new];
  if (!link.length)
    return result;
  for (NSNumber *p in KFProperties())
    for (NSDictionary *e in KFEntries(m, p.unsignedIntValue))
      if (e[@"nativeTime"] && [KFLink(e[@"pose"]) isEqual:link])
        [result addObject:@{@"parameter" : p, @"entry" : e}];
  return result;
}
BOOL KFNativePropertyLinked(id<PROAPIAccessing> m, UInt32 parameter,
                            CMTime playhead) {
  NSDictionary *e = KFTarget(KFEntries(m, parameter), playhead);
  return KFMembers(m, KFLink(e[@"pose"])).count > 1;
}
NSColor *KFNativePropertyLinkColor(id<PROAPIAccessing> manager, UInt32 parameter, CMTime playhead) {
  NSString *link=KFLink(KFTarget(KFEntries(manager,parameter),playhead)[@"pose"]);
  if (!link.length) return nil;
  NSMutableDictionary<NSString *,NSNumber *> *counts=[NSMutableDictionary new];
  for (NSNumber *p in KFProperties())
    for (NSDictionary *entry in KFEntries(manager,p.unsignedIntValue)) {
      NSString *identifier=KFLink(entry[@"pose"]);
      if (entry[@"nativeTime"] && identifier.length) counts[identifier]=@([counts[identifier] unsignedIntegerValue]+1);
    }
  if ([counts[link] unsignedIntegerValue]<2) return nil;
  NSArray<NSColor *> *palette=ICInspectorTokens.linkGroupColors;
  KFNativeLinkState *state=KFState(manager);
  @synchronized(state) {
    // Seed from persisted identity, then avoid palette collisions between
    // groups. Retain assignments through moves, membership edits and undo.
    // Sorting makes initial assignment independent of inspector row order.
    NSMutableSet *used=[NSMutableSet setWithArray:state.colorSlots.allValues];
    for (NSString *identifier in [counts.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      if ([counts[identifier] unsignedIntegerValue]<2 || state.colorSlots[identifier]) continue;
      uint32_t hash=2166136261u;
      NSData *bytes=[identifier dataUsingEncoding:NSUTF8StringEncoding];
      for (NSUInteger i=0;i<bytes.length;i++) hash=(hash ^ ((const uint8_t *)bytes.bytes)[i])*16777619u;
      NSUInteger slot=hash%palette.count;
      for (NSUInteger offset=0;offset<palette.count;offset++) {
        NSUInteger candidate=(slot+offset)%palette.count;
        if (![used containsObject:@(candidate)]) { slot=candidate; break; }
      }
      state.colorSlots[identifier]=@(slot); [used addObject:@(slot)];
    }
    return palette[state.colorSlots[link].unsignedIntegerValue];
  }
}

BOOL KFSetNativePropertyLink(id<PROAPIAccessing> m, UInt32 sourceID,
                             UInt32 partnerID, CMTime playhead, BOOL linked) {
  if (sourceID == partnerID || ![KFProperties() containsObject:@(sourceID)] ||
      ![KFProperties() containsObject:@(partnerID)])
    return NO;
  NSArray *sourceEntries = KFEntries(m, sourceID);
  NSDictionary *source = KFTarget(sourceEntries, playhead);
  if (!source) {
    // An unkeyed row adopts the chosen property's destination, including its
    // incoming timing. Reverse the operation to reuse silent-partner creation.
    if (linked && !sourceEntries.firstObject[@"nativeTime"] &&
        KFTarget(KFEntries(m, partnerID), playhead))
      return KFSetNativePropertyLink(m, partnerID, sourceID, playhead, YES);
    if (linked && CMTIME_IS_NUMERIC(playhead) &&
        !sourceEntries.firstObject[@"nativeTime"] &&
        !KFEntries(m, partnerID).firstObject[@"nativeTime"]) {
      id pose = KFSample(m, sourceID, playhead);
      if (!pose) return NO;
      source = KFEntry(pose, playhead, nil);
    } else return NO;
  }
  CMTime target = KFTime(source);
  NSString *sourceLink = KFLink(source[@"pose"]);
  NSArray *members = KFMembers(m, sourceLink);
  NSDictionary *partner = nil;
  for (NSDictionary *member in members)
    if ([member[@"parameter"] unsignedIntValue] == partnerID) {
      partner = member[@"entry"];
      break;
    }
  NSMutableDictionary *after = [NSMutableDictionary new];
  if (!linked) {
    if (!partner)
      return YES;
    for (NSDictionary *member in members) {
      UInt32 p = [member[@"parameter"] unsignedIntValue];
      if (p != partnerID && members.count > 2)
        continue;
      NSDictionary *e = member[@"entry"];
      id old = e[@"pose"];
      id pose = KFReplace(old, [[old timing] timingByReplacingLinkID:@""],
                          [old easing], [old addedMotion]);
      after[@(p)] =
          KFReplacing(KFEntries(m, p), e, KFEntry(pose, KFTime(e), e));
    }
    return KFApply(m, after, KFNativeEditLink);
  }
  if (partner)
    return YES;
  partner = KFAt(KFEntries(m, partnerID), target);
  NSString *partnerLink = KFLink(partner[@"pose"]);
  NSMutableArray *all = [members mutableCopy];
  if (!all.count)
    [all addObject:@{@"parameter" : @(sourceID), @"entry" : source}];
  NSArray *others = KFMembers(m, partnerLink);
  if (others.count)
    [all addObjectsFromArray:others];
  else {
    id pose = partner ? partner[@"pose"] : KFSample(m, partnerID, target);
    if (!pose)
      return NO;
    [all addObject:@{
      @"parameter" : @(partnerID),
      @"entry" : partner ?: KFEntry(pose, target, nil)
    }];
  }
  // Merge groups only when every property has one key at this same moment.
  NSMutableSet *seen = [NSMutableSet new];
  for (NSDictionary *member in all) {
    if ([seen containsObject:member[@"parameter"]] ||
        !KFSame(KFTime(member[@"entry"]), target))
      return NO;
    [seen addObject:member[@"parameter"]];
  }
  NSString *link = members.count > 1 ? sourceLink : NSUUID.UUID.UUIDString;
  id leader = source[@"pose"];
  for (NSDictionary *member in all) {
    UInt32 p = [member[@"parameter"] unsignedIntValue];
    NSDictionary *e = member[@"entry"];
    id old = e[@"pose"];
    KFPoseTiming *own = [old timing], *incoming = [leader timing];
    KFPoseTiming *timing = [[[[KFPoseTiming alloc]
        initWithDuration:incoming.duration
               available:incoming.available
                  amount:own.amount
                   speed:own.speed]
        timingByCopyingMotionOptionsFrom:own] timingByReplacingLinkID:link];
    id pose = KFReplace(old, timing, [leader easing], [old addedMotion]);
    NSArray *entries = KFEntries(m, p);
    after[@(p)] =
        KFReplacing(entries, KFAt(entries, target), KFEntry(pose, target, e));
  }
  return KFApply(m, after, KFNativeEditLink);
}
