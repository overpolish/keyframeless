@import InspectorControls;
/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFCreationDefaults.h"
#import "KFMatchEndpoints.h"
#import "KFNativeEdits.h"
#import "KFNativeLinks.h"
#import "KFPropertyMenu.h"
#import "KFHostSettings.h"
#import "KFResetParameter.h"
#import "KFTimingEditorModel.h"

static id KFCache(id<PROAPIAccessing> m, UInt32 p) {
  return [KFPropertyLaneForParameter(p) cacheForManager:m];
}
NSArray<NSDictionary *> *KFEntries(id<PROAPIAccessing> m, UInt32 p) {
  return [KFCache(m, p) snapshotEntries];
}
static NSString *KFLink(id pose) { return [[pose timing] linkID] ?: @""; }
CMTime KFTime(NSDictionary *e) {
  CMTime t = kCMTimeInvalid;
  [e[@"nativeTime"] getValue:&t];
  return t;
}
BOOL KFSame(CMTime a, CMTime b) {
  return CMTIME_IS_NUMERIC(a) && CMTIME_IS_NUMERIC(b) &&
         fabs(CMTimeGetSeconds(CMTimeSubtract(a, b))) < 1e-6;
}
NSDictionary *KFAt(NSArray *entries, CMTime t) {
  for (NSDictionary *e in entries)
    if (KFSame(KFTime(e), t))
      return e;
  return nil;
}
static NSDictionary *KFTarget(NSArray *entries, CMTime t) {
  if (!CMTIME_IS_NUMERIC(t) || !entries.firstObject[@"nativeTime"])
    return nil;
  double now = CMTimeGetSeconds(t);
  if (now > [entries.lastObject[@"time"] doubleValue] + 1e-6)
    return nil;
  for (NSDictionary *e in entries)
    if (now <= [e[@"time"] doubleValue] + 1e-6)
      return e;
  return nil;
}
id KFSample(id<PROAPIAccessing> m, UInt32 p, CMTime t) {
  return [KFPropertyLaneForParameter(p) sampleEntries:KFEntries(m, p) time:t];
}
id KFReplace(id old, KFPoseTiming *timing, MTEasing easing,
                    MTAddedMotion motion) {
  id<KFPropertyPose> pose = old;
  return [pose poseByReplacingValues:pose.values
                            authored:YES
                              easing:easing
                         addedMotion:motion
                              timing:timing];
}
NSArray<NSNumber *> *KFValues(id pose) { return [pose values]; }
id KFPoseWithValues(id old, NSArray<NSNumber *> *values, KFPoseTiming *timing,
                    MTEasing easing, MTAddedMotion motion) {
  return [(id<KFPropertyPose>)old poseByReplacingValues:values
                                               authored:YES
                                                 easing:easing
                                            addedMotion:motion
                                                 timing:timing];
}
NSDictionary *KFEntry(id pose, CMTime time, NSDictionary *old) {
  FxKeyframe key;
  FxInitKeyframe(key, kFxKeyframe_CurrentVersion);
  if (old[@"nativeKey"])
    [old[@"nativeKey"] getValue:&key];
  key.time = time;
  return @{
    @"pose" : pose,
    @"time" : @(CMTimeGetSeconds(time)),
    @"nativeTime" : [NSValue valueWithBytes:&time objCType:@encode(CMTime)],
    @"nativeKey" : [NSValue valueWithBytes:&key objCType:@encode(FxKeyframe)]
  };
}
NSArray *KFReplacing(NSArray *entries, NSDictionary *before,
                            NSDictionary *after) {
  NSMutableArray *result = [NSMutableArray array];
  for (NSDictionary *entry in entries)
    if (entry[@"nativeTime"] && entry != before)
      [result addObject:entry];
  if (after)
    [result addObject:after];
  [result sortUsingComparator:^NSComparisonResult(NSDictionary *a,
                                                  NSDictionary *b) {
    return [a[@"time"] compare:b[@"time"]];
  }];
  return result;
}
@interface KFNativeLinkState : NSObject
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,KFDefaultKeyTracker *> *defaultTrackers;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *defaultInsertions;
@property(nonatomic) BOOL applying;
@property(nonatomic, strong)
    NSMutableDictionary<NSNumber *, NSArray *> *observed;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSDictionary *> *moves;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *copies;
// Properties whose key structure changed, so a matched pairing may be stale.
@property(nonatomic, strong) NSMutableSet<NSNumber *> *matchCandidates;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *colorSlots;
@end
@implementation KFNativeLinkState
- (instancetype)init {
  if ((self = [super init])) {
    _observed = [NSMutableDictionary new];
    _defaultTrackers=[NSMutableDictionary new];
    _defaultInsertions=[NSMutableArray new];
    _moves = [NSMutableDictionary new];
    _copies = [NSMutableArray new];
    _matchCandidates = [NSMutableSet new];
    _colorSlots = [NSMutableDictionary new];
  }
  return self;
}
@end
static KFNativeLinkState *KFState(id manager) {
  static NSMapTable *states;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    states = [NSMapTable weakToStrongObjectsMapTable];
  });
  @synchronized(states) {
    KFNativeLinkState *s = [states objectForKey:manager];
    if (!s) {
      s = [KFNativeLinkState new];
      [states setObject:s forKey:manager];
    }
    return s;
  }
}
void KFPrimeDefaultKeyTracker(id<PROAPIAccessing> manager,UInt32 parameter) {
  KFNativeLinkState *state=KFState(manager);
  @synchronized(state) {
    if (state.defaultTrackers[@(parameter)]) return;
    NSArray *entries=KFEntries(manager,parameter);
    if (!entries) return;
    KFDefaultKeyTracker *tracker=[KFDefaultKeyTracker new];
    [tracker insertionsInEntries:entries];
    state.defaultTrackers[@(parameter)]=tracker;
  }
}

// Failure recovery only. Resolve the index from the host now, never from a
// cached ordinal: an unrelated key may have been added since the snapshot.
static BOOL KFFindRollbackKey(id<FxKeyframeAPI_v3> keys, UInt32 parameter,
                              CMTime time, NSUInteger *index) {
  NSUInteger count=0, matches=0;
  if ([keys keyframeCount:&count forParameter:parameter andChannel:0]) return NO;
  for (NSUInteger i=0; i<count; i++) {
    FxKeyframe key; FxInitKeyframe(key,kFxKeyframe_CurrentVersion);
    if ([keys keyframe:&key forParameter:parameter channel:0 andIndex:i]) return NO;
    if (KFSame(key.time,time)) { *index=i; matches++; }
  }
  return matches==1;
}
static void KFRollbackLink(id<PROAPIAccessing> manager, NSArray *journal,
                           NSDictionary *before, id<FxKeyframeAPI_v3> keys,
                           id<FxParameterSettingAPI_v5> set) {
  id<FxParameterRetrievalAPI_v6> get=[manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSMutableSet *addedParameters=[NSMutableSet new];
  for (NSDictionary *change in journal.reverseObjectEnumerator) {
    UInt32 parameter=[change[@"parameter"] unsignedIntValue];
    NSDictionary *entry=change[@"after"], *old=change[@"before"];
    CMTime time=KFTime(entry); NSUInteger index=0;
    if (!KFFindRollbackKey(keys,parameter,time,&index)) continue;
    if ([change[@"added"] boolValue]) {
      // Only remove keys inserted by this transaction. Existing host keys and
      // their curve metadata are never removed/rebuilt by link recovery.
      [keys removeKeyframeAtIndex:index fromParameter:parameter andChannel:0];
      [addedParameters addObject:@(parameter)];
    } else if (old) {
      NSObject<NSSecureCoding,NSCopying> *current=nil;
      if ([get getCustomParameterValue:&current fromParameter:parameter atTime:time] &&
          ([current isEqual:entry[@"pose"]] || [current isEqual:old[@"pose"]]))
        [set setCustomParameterValue:old[@"pose"] toParameter:parameter atTime:time];
    }
  }
  for (NSNumber *p in addedParameters) {
    NSDictionary *constant=[before[p] firstObject]; NSUInteger count=0;
    if (!constant[@"nativeTime"] &&
        ![keys keyframeCount:&count forParameter:p.unsignedIntValue andChannel:0] && count==0)
      [set setCustomParameterValue:constant[@"pose"] toParameter:p.unsignedIntValue atTime:kCMTimeZero];
  }
}
static void KFRefreshLinkCache(id<PROAPIAccessing> manager, UInt32 parameter) {
  [KFPropertyLaneForParameter(parameter) refreshCacheForManager:manager time:kCMTimeZero];
}

// Apply complete, preflighted lane snapshots. Remove descending before inserts;
// FxPlug's remote setKeyframeIndex wrapper cannot reliably move an indexed key.
BOOL KFApply(id<PROAPIAccessing> m,
                    NSDictionary<NSNumber *, NSArray *> *after,
                    KFNativeEditKind kind) {
  BOOL structural=kind==KFNativeEditStructural;
  BOOL linking=kind==KFNativeEditLink;
  KFNativeLinkState *state = KFState(m);
  {
    id<FxKeyframeAPI_v3> keys = [m apiForProtocol:@protocol(FxKeyframeAPI_v3)];
    id<FxParameterSettingAPI_v5> set =
        [m apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    if (!keys || !set)
      return NO;
    @synchronized(state) {
      if (state.applying)
        return NO;
    }
    NSMutableDictionary *before = [NSMutableDictionary new];
    for (NSNumber *p in after) {
      NSArray *entries = KFEntries(m, p.unsignedIntValue);
      if (!entries.count)
        return NO;
      before[p] = entries;
      if (structural) {
        NSUInteger count = 0;
        if ([keys keyframeCount:&count
                   forParameter:p.unsignedIntValue andChannel:0])
          return NO;
        if (count != (entries.firstObject[@"nativeTime"] ? entries.count : 0))
          return NO;
      } else if (linking) {
        // Linking may add keys or update metadata, but cannot remove/move any
        // existing key. Its successful path needs no synchronous host reads.
        for (NSDictionary *entry in entries)
          if (entry[@"nativeTime"] && !KFAt(after[p],KFTime(entry))) return NO;
        for (NSDictionary *entry in after[p])
          if (!CMTIME_IS_NUMERIC(KFTime(entry)) || !entry[@"nativeKey"] || !entry[@"pose"]) return NO;
      } else {
        // Metadata edits must remain as responsive as ordinary value fields:
        // use existing cached key times, with no native key enumeration.
        if (entries.count != after[p].count)
          return NO;
        for (NSDictionary *e in after[p])
          if (!KFAt(entries, KFTime(e)))
            return NO;
      }
      for (NSUInteger i = 1; i < after[p].count; i++)
        if (KFSame(KFTime(after[p][i - 1]), KFTime(after[p][i])))
          return NO;
    }
    @synchronized(state) {
      if (state.applying)
        return NO;
      state.applying = YES;
    }
    BOOL ok = YES;
    NSMutableSet *touched = [NSMutableSet new];
    NSMutableArray *journal=[NSMutableArray new];
    @try {
      for (NSNumber *p in after) {
        NSArray *old = before[p], *next = after[p];
        UInt32 pid = p.unsignedIntValue;
        [touched addObject:p];
        for (NSUInteger i = old.count; i > 0; i--)
          if (old[i - 1][@"nativeTime"] && !KFAt(next, KFTime(old[i - 1]))) {
            if ([keys removeKeyframeAtIndex:i - 1 fromParameter:pid andChannel:0]) {
              ok = NO;
              break;
            }
          }
        if (!ok)
          break;
        for (NSDictionary *e in next) {
          NSDictionary *existing = KFAt(old, KFTime(e));
          if (existing && [existing[@"pose"] isEqual:e[@"pose"]])
            continue;
          FxKeyframe key;
          [e[@"nativeKey"] getValue:&key];
          if (!existing && [keys addKeyframe:&key toParameter:pid andChannel:0]) {
            ok = NO;
            break;
          }
          if (linking) {
            NSMutableDictionary *change=[@{@"parameter":p,@"after":e,@"added":@(!existing)} mutableCopy];
            if (existing) change[@"before"]=existing;
            [journal addObject:change];
          }
          if (![set setCustomParameterValue:e[@"pose"] toParameter:pid atTime:key.time]) {
            ok = NO;
            break;
          }
        }
        if (!ok)
          break;
      }
      if (!ok && linking) {
        KFRollbackLink(m,journal,before,keys,set);
      } else if (!ok) {
        // Recover the touched lanes on a rejected mutation, preserving native
        // curve metadata and independent values. Never rewrite untouched lanes.
        for (NSNumber *p in touched) {
          if (structural &&
              [keys removeAllKeyframesForParameter:p.unsignedIntValue
                                        andChannel:0])
            continue;
          for (NSDictionary *e in before[p]) {
            CMTime time = KFTime(e);
            if (structural && e[@"nativeTime"]) {
              FxKeyframe key;
              FxInitKeyframe(key, kFxKeyframe_CurrentVersion);
              if (e[@"nativeKey"])
                [e[@"nativeKey"] getValue:&key];
              key.time = time;
              if ([keys addKeyframe:&key
                        toParameter:p.unsignedIntValue
                         andChannel:0])
                continue;
            } else if (!e[@"nativeTime"])
              time = kCMTimeZero;
            [set setCustomParameterValue:e[@"pose"]
                             toParameter:p.unsignedIntValue
                                  atTime:time];
          }
        }
      }
      NSDictionary *published = ok ? after : before;
      if (!ok && linking) {
        // Re-read after recovery, retaining any unrelated host edits rather
        // than publishing an obsolete full snapshot over them.
        NSMutableDictionary *actual=[NSMutableDictionary new];
        for (NSNumber *p in before) {
          KFRefreshLinkCache(m,p.unsignedIntValue);
          NSArray *entries=KFEntries(m,p.unsignedIntValue);
          if (entries) actual[p]=entries;
        }
        published=actual;
      }
      for (NSNumber *p in published) {
        [KFCache(m, p.unsignedIntValue) publishEntries:published[p]];
        @synchronized(state) {
          state.observed[p] = published[p];
          if (!state.defaultTrackers[p]) state.defaultTrackers[p]=[KFDefaultKeyTracker new];
          [state.defaultTrackers[p] insertionsInEntries:published[p]];
        }
      }
      if (ok) {
        KFRequestHostRefresh(m,kCMTimeZero);
      }
    } @finally {
      @synchronized(state) {
        state.applying = NO;
      }
    }
    return ok;
  }
}
static NSArray<NSDictionary *> *KFMembers(id<PROAPIAccessing> m,
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
// A timing edit reaches its link partners and, for a matched property, the
// opposite endpoint, transitively. Each edge carries only the settings it owns,
// so values mirror across a match but never across a link.
typedef struct {
  BOOL duration, available, amount, speed, easing, motion, values;
} KFEditMask;
static const KFEditMask KFMaskAll = {YES, YES, YES, YES, YES, YES, YES};
static const KFEditMask KFMaskLink = {YES, YES, YES, YES, YES, YES, NO};
// Matching pairs the incoming transitions of K2 and Kn, and the values of K1
// and Kn. Added Motion belongs to the key preceding a gap, so it never crosses.
static const KFEditMask KFMaskMatchTransition = {YES, YES, NO, NO, YES, NO, NO};
static const KFEditMask KFMaskMatchValue = {NO, NO, NO, NO, NO, NO, YES};
static KFEditMask KFMaskIntersect(KFEditMask a, KFEditMask b) {
  return (KFEditMask){a.duration && b.duration, a.available && b.available,
                      a.amount && b.amount,     a.speed && b.speed,
                      a.easing && b.easing,     a.motion && b.motion,
                      a.values && b.values};
}
static BOOL KFMaskEmpty(KFEditMask m) {
  return !m.duration && !m.available && !m.amount && !m.speed && !m.easing &&
         !m.motion && !m.values;
}
@interface KFEditNode : NSObject
@property UInt32 parameter;
@property(strong) NSDictionary *entry;
@property KFEditMask mask;
@end
@implementation KFEditNode
@end
static KFEditNode *KFNode(UInt32 parameter, NSDictionary *entry,
                          KFEditMask mask) {
  KFEditNode *node = [KFEditNode new];
  node.parameter = parameter;
  node.entry = entry;
  node.mask = mask;
  return node;
}
static NSString *KFNodeKey(KFEditNode *node) {
  return [NSString stringWithFormat:@"%u@%.6f", node.parameter,
                                    CMTimeGetSeconds(KFTime(node.entry))];
}
// Adopts whatever the seed edit changed and this edge allows, leaving every
// other setting as this pose had it.
static id KFUpdatedPose(id old, id before, id after, KFEditMask mask) {
  KFPoseTiming *own = [old timing], *was = [before timing],
               *now = [after timing];
  KFPoseTiming *timing = [[[[KFPoseTiming alloc]
      initWithDuration:mask.duration && now.duration != was.duration
                           ? now.duration
                           : own.duration
             available:mask.available && now.available != was.available
                           ? now.available
                           : own.available
                amount:mask.amount && now.amount != was.amount ? now.amount
                                                               : own.amount
                 speed:mask.speed && now.speed != was.speed ? now.speed
                                                            : own.speed]
      timingByCopyingMotionOptionsFrom:own] timingByReplacingLinkID:KFLink(old)];
  MTEasing easing = mask.easing && [after easing] != [before easing]
                        ? [after easing]
                        : [old easing];
  MTAddedMotion motion =
      mask.motion && [after addedMotion] != [before addedMotion]
          ? [after addedMotion]
          : [old addedMotion];
  if (mask.values && ![KFValues(before) isEqual:KFValues(after)])
    return KFPoseWithValues(old, KFValues(after), timing, easing, motion);
  return KFReplace(old, timing, easing, motion);
}
// The keys this one pairs with while its property matches its endpoints.
static void KFEnqueueMatched(id<PROAPIAccessing> m, KFEditNode *node,
                             NSMutableArray<KFEditNode *> *queue) {
  if (!KFPropertyMatchEnabled(m, node.parameter))
    return;
  NSArray *entries = KFEntries(m, node.parameter);
  if (entries.count < 2 || !entries.firstObject[@"nativeTime"])
    return;
  CMTime time = KFTime(node.entry);
  NSDictionary *first = entries.firstObject, *last = entries.lastObject;
  KFEditMask values = KFMaskIntersect(node.mask, KFMaskMatchValue);
  if (!KFMaskEmpty(values)) {
    if (KFSame(time, KFTime(first)))
      [queue addObject:KFNode(node.parameter, last, values)];
    else if (KFSame(time, KFTime(last)))
      [queue addObject:KFNode(node.parameter, first, values)];
  }
  // Two keys share one incoming transition, so there is nothing to pair it with.
  if (entries.count < 3)
    return;
  KFEditMask transition = KFMaskIntersect(node.mask, KFMaskMatchTransition);
  if (KFMaskEmpty(transition))
    return;
  NSDictionary *second = entries[1];
  if (KFSame(time, KFTime(second)))
    [queue addObject:KFNode(node.parameter, last, transition)];
  else if (KFSame(time, KFTime(last)))
    [queue addObject:KFNode(node.parameter, second, transition)];
}
BOOL KFWriteNativeLinkedPose(id<PROAPIAccessing> m, UInt32 parameter,
                             CMTime time, id pose) {
  NSDictionary *entry = KFAt(KFEntries(m, parameter), time);
  if (!entry)
    return NO;
  id before = entry[@"pose"];
  NSMutableDictionary *after = [NSMutableDictionary new];
  NSMutableSet *seen = [NSMutableSet new];
  NSMutableArray<KFEditNode *> *queue =
      [NSMutableArray arrayWithObject:KFNode(parameter, entry, KFMaskAll)];
  while (queue.count) {
    KFEditNode *node = queue.lastObject;
    [queue removeLastObject];
    NSString *key = KFNodeKey(node);
    if ([seen containsObject:key])
      continue;
    [seen addObject:key];
    id updated = node.entry == entry && node.parameter == parameter
                     ? pose
                     : KFUpdatedPose(node.entry[@"pose"], before, pose,
                                     node.mask);
    NSArray *entries = after[@(node.parameter)] ?: KFEntries(m, node.parameter);
    after[@(node.parameter)] =
        KFReplacing(entries, node.entry,
                    KFEntry(updated, KFTime(node.entry), node.entry));
    KFEditMask linked = KFMaskIntersect(node.mask, KFMaskLink);
    if (!KFMaskEmpty(linked))
      for (NSDictionary *member in KFMembers(m, KFLink(node.entry[@"pose"])))
        [queue addObject:KFNode([member[@"parameter"] unsignedIntValue],
                                member[@"entry"], linked)];
    KFEnqueueMatched(m, node, queue);
  }
  return KFApply(m, after, KFNativeEditMetadata);
}
void KFObserveNativeLinks(id<PROAPIAccessing> m, UInt32 parameter,
                          BOOL mouseDown) {
  KFNativeLinkState *state = KFState(m);
  @synchronized(state) {
    if (state.applying)
      return;
    NSArray *next = KFEntries(m, parameter);
    if (!next)
      return;
    NSArray *before = state.observed[@(parameter)];
    KFDefaultKeyTracker *tracker=state.defaultTrackers[@(parameter)];
    if (!tracker) { tracker=[KFDefaultKeyTracker new]; state.defaultTrackers[@(parameter)]=tracker; }
    for (NSDictionary *e in [tracker insertionsInEntries:next]) {
      id pose=KFPoseWithCreationDefaults(e[@"pose"]);
      if (![pose isEqual:e[@"pose"]]) [state.defaultInsertions addObject:@{@"parameter":@(parameter),@"entry":e,@"pose":pose}];
    }
    for (NSDictionary *e in next) {
      NSString *link = KFLink(e[@"pose"]);
      if (!link.length || !e[@"nativeTime"])
        continue;
      NSArray *matches = [next
          filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(
                                                       NSDictionary *a,
                                                       NSDictionary *bindings) {
            return [KFLink(a[@"pose"]) isEqual:link];
          }]];
      if (matches.count > 1) {
        NSArray *previous = [before
            filteredArrayUsingPredicate:[NSPredicate
                                            predicateWithBlock:^BOOL(
                                                NSDictionary *a,
                                                NSDictionary *bindings) {
                                              return [KFLink(a[@"pose"])
                                                  isEqual:link];
                                            }]];
        // A pasted/held-value key can inherit the payload. Preserve the known
        // existing key, and detach only the newly added copy; never infer a
        // move.
        if (previous.count == 1 && KFAt(matches, KFTime(previous[0])))
          for (NSDictionary *copy in matches)
            if (!KFSame(KFTime(copy), KFTime(previous[0])))
              [state.copies addObject:@{
                @"parameter" : @(parameter),
                @"time" : copy[@"nativeTime"],
                @"link" : link
              }];
      }
      if (!mouseDown && !state.moves[link])
        continue; // Restore/Undo is not a new drag.
      if (matches.count != 1)
        continue; // Never guess which copied key owns a group.
      for (NSDictionary *old in before)
        if ([KFLink(old[@"pose"]) isEqual:link] &&
            !KFSame(KFTime(old), KFTime(e))) {
          state.moves[link] =
              @{@"parameter" : @(parameter),
                @"time" : e[@"nativeTime"]};
          break;
        }
    }
    // Endpoints are positional, so any change of the first or last key can
    // leave a matched property paired with the wrong keys. Evaluating that
    // needs host reads, which belong on the commit path, not in this callback.
    if (before && (before.count != next.count ||
                   !KFSame(KFTime(before.firstObject), KFTime(next.firstObject)) ||
                   !KFSame(KFTime(before.lastObject), KFTime(next.lastObject))))
      [state.matchCandidates addObject:@(parameter)];
    state.observed[@(parameter)] = next;
  }
}
BOOL KFHasPendingNativeLinkMoves(id<PROAPIAccessing> m) {
  KFNativeLinkState *s = KFState(m);
  @synchronized(s) {
    return s.moves.count > 0 || s.copies.count > 0 || s.defaultInsertions.count > 0;
  }
}
BOOL KFCommitNativeLinkMoves(id<PROAPIAccessing> m, BOOL mouseDown,
                             NSError **error) {
  KFNativeLinkState *state = KFState(m);
  NSDictionary *moves;
  NSArray *copies, *defaults;
  NSSet *matches;
  @synchronized(state) {
    if (mouseDown || state.applying ||
        (!state.moves.count && !state.copies.count && !state.defaultInsertions.count &&
         !state.matchCandidates.count))
      return YES;
    moves = [state.moves copy];
    copies = [state.copies copy];
    defaults=[state.defaultInsertions copy];
    matches=[state.matchCandidates copy];
    [state.defaultInsertions removeAllObjects];
    [state.moves removeAllObjects];
    [state.copies removeAllObjects];
    [state.matchCandidates removeAllObjects];
  }
  {
    NSMutableDictionary *after = [NSMutableDictionary new],
                        *requests = [NSMutableDictionary new];
    for (NSString *link in moves) {
      NSDictionary *move = moves[link];
      for (NSDictionary *member in KFMembers(m, link)) {
        NSNumber *p = member[@"parameter"];
        if ([p isEqual:move[@"parameter"]])
          continue;
        NSDictionary *original = member[@"entry"];
        if (!requests[p])
          requests[p] = [NSMutableDictionary new];
        requests[p][original[@"nativeTime"]] = move[@"time"];
      }
    }
    for (NSNumber *p in requests) {
      NSMutableArray *entries = [NSMutableArray new];
      BOOL changed = NO;
      for (NSDictionary *e in KFEntries(m, p.unsignedIntValue)) {
        NSValue *targetValue =
            e[@"nativeTime"] ? requests[p][e[@"nativeTime"]] : nil;
        CMTime target;
        if (targetValue)
          [targetValue getValue:&target];
        if (targetValue && !KFSame(KFTime(e), target)) {
          [entries addObject:KFEntry(e[@"pose"], target, e)];
          changed = YES;
        } else
          [entries addObject:e];
      }
      [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a,
                                                       NSDictionary *b) {
        return [a[@"time"] compare:b[@"time"]];
      }];
      for (NSUInteger i = 1; i < entries.count; i++)
        if (KFSame(KFTime(entries[i - 1]), KFTime(entries[i]))) {
          if (error)
            *error = [NSError
                errorWithDomain:@"MagicMove.NativeLinks"
                           code:1
                       userInfo:@{
                         NSLocalizedDescriptionKey :
                             @"Linked move would overlap an existing keypose"
                       }];
          return NO;
        }
      if (changed)
        after[p] = entries;
    }
    for (NSDictionary *request in defaults) {
      NSNumber *p=request[@"parameter"];
      NSArray *entries=after[p] ?: KFEntries(m,p.unsignedIntValue);
      NSDictionary *before=request[@"entry"], *current=KFAt(entries,KFTime(before));
      // A value edit, undo, or removal may have overtaken the queued creation.
      if (!current || ![current[@"pose"] isEqual:before[@"pose"]]) continue;
      after[p]=KFReplacing(entries,current,KFEntry(request[@"pose"],KFTime(current),current));
    }
    for (NSDictionary *copy in copies) {
      NSNumber *p = copy[@"parameter"];
      CMTime t;
      [copy[@"time"] getValue:&t];
      NSArray *entries = after[p] ?: KFEntries(m, p.unsignedIntValue);
      NSDictionary *e = KFAt(entries, t);
      if (!e || ![KFLink(e[@"pose"]) isEqual:copy[@"link"]])
        continue;
      id old = e[@"pose"];
      id pose = KFReplace(old, [[old timing] timingByReplacingLinkID:@""],
                          [old easing], [old addedMotion]);
      after[p] = KFReplacing(entries, e, KFEntry(pose, t, e));
    }
    // Last, so a matched property pairs the keys it ends this edit with.
    BOOL matched = NO;
    for (NSNumber *p in matches) {
      UInt32 parameter = p.unsignedIntValue;
      if (!KFPropertyMatchEnabled(m, parameter))
        continue;
      NSArray *entries = after[p] ?: KFEntries(m, parameter);
      NSArray *paired = KFMatchedEntries(m, parameter, entries);
      if (!paired)
        continue;
      after[p] = paired;
      matched = YES;
    }
    if (!after.count)
      return YES;
    BOOL metadataOnly = !moves.count && !copies.count;
    id<FxUndoAPI> undo = [m apiForProtocol:@protocol(FxUndoAPI)];
    if (![undo startUndoGroup:!metadataOnly              ? @"Move linked keyposes"
                              : defaults.count            ? @"Set keyframe defaults"
                              : matched                   ? @"Match In/Out"
                                                          : @"Set keyframe defaults"])
      return NO;
    @try {
      return KFApply(m, after, metadataOnly ? KFNativeEditMetadata : KFNativeEditStructural);
    } @finally {
      [undo endUndoGroup];
    }
  }
}

@interface KFMatchMenuTarget : NSObject
@property(nonatomic, strong) id<PROAPIAccessing> manager;
@property(nonatomic, weak) NSView *sender;
@property UInt32 parameter;
- (void)refreshItem:(NSMenuItem *)item;
@end
@implementation KFMatchMenuTarget
- (void)refreshItem:(NSMenuItem *)item {
  item.enabled = KFPropertyMatchAvailable(self.manager, self.parameter);
  item.state = KFPropertyMatchEnabled(self.manager, self.parameter)
                   ? NSControlStateValueOn
                   : NSControlStateValueOff;
}
- (void)toggle:(NSMenuItem *)sender {
  NSMenu *menu = sender.menu;
  KFPropertyMenuActionScheduled(menu);
  // Return the ViewBridge button callback before asking the host for keyframes.
  dispatch_async(dispatch_get_main_queue(), ^{
    [self applyToggle:sender menu:menu];
  });
}
- (void)applyToggle:(NSMenuItem *)sender menu:(NSMenu *)menu {
  NSView *view = self.sender;
  if (!view)
    return;
  id<FxCustomParameterActionAPI_v4> action =
      [self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action) {
    KFPropertyMenuActionFinished(menu, NO);
    return;
  }
  BOOL ok = NO;
  [action startAction:view];
  @try {
    id<FxUndoAPI> undo = [self.manager apiForProtocol:@protocol(FxUndoAPI)];
    if (![undo startUndoGroup:@"Match In/Out"])
      return;
    @try {
      BOOL enabled = KFPropertyMatchEnabled(self.manager, self.parameter);
      ok = KFSetPropertyMatch(self.manager, self.parameter, !enabled, NULL);
      if (ok)
        [self refreshItem:sender];
      else
        NSBeep();
    } @finally {
      [undo endUndoGroup];
    }
  } @finally {
    [action endAction:view];
    KFPropertyMenuActionFinished(menu, ok);
  }
}
@end
@interface KFNativeLinkMenuTarget : NSObject
@property(nonatomic, strong) id<PROAPIAccessing> manager;
@property(nonatomic, weak) NSView *sender;
@property UInt32 source;
@property UInt32 partner;
@property CMTime time;
@property BOOL linked;
- (void)refreshItem:(NSMenuItem *)item;
- (void)applyToggle:(NSMenuItem *)sender menu:(NSMenu *)menu;
@end
@implementation KFNativeLinkMenuTarget
- (void)refreshItem:(NSMenuItem *)item {
  NSDictionary *source = KFTarget(KFEntries(self.manager, self.source), self.time);
  BOOL sourceUnkeyed = !KFEntries(self.manager, self.source).firstObject[@"nativeTime"];
  BOOL partnerUnkeyed = !KFEntries(self.manager, self.partner).firstObject[@"nativeTime"];
  item.enabled = CMTIME_IS_NUMERIC(self.time) && (source != nil ||
      (sourceUnkeyed && (partnerUnkeyed || KFTarget(KFEntries(self.manager, self.partner), self.time))));
  ((NSControl *)item.view).enabled = item.enabled;
  self.linked = NO;
  for (NSDictionary *member in KFMembers(self.manager, KFLink(source[@"pose"])))
    if ([member[@"parameter"] unsignedIntValue] == self.partner) self.linked = YES;
  item.state = self.linked ? NSControlStateValueOn : NSControlStateValueOff;
  item.view.needsDisplay = YES;
}
- (void)toggle:(NSMenuItem *)sender {
  NSMenu *menu=sender.menu; KFPropertyMenuActionScheduled(menu);
  // Return the ViewBridge button callback before asking the host for keyframes.
  // Use the main dispatch queue, as with history; the callback has no named
  // run-loop mode, so a mode-specific run-loop block can wait for mouse input.
  dispatch_async(dispatch_get_main_queue(), ^{
    [self applyToggle:sender menu:menu];
  });
}
- (void)applyToggle:(NSMenuItem *)sender menu:(NSMenu *)menu {
  // A click is committed even if its menu closes before dispatch. The weak
  // inspector view prevents applying it after the owning control is destroyed.
  NSView *view = self.sender;
  if (!view)
    return;
  id<FxCustomParameterActionAPI_v4> action =
      [self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action) { KFPropertyMenuActionFinished(menu,NO); return; }
  BOOL ok=NO;
  [action startAction:view];
  @try {
    id<FxUndoAPI> undo = [self.manager apiForProtocol:@protocol(FxUndoAPI)];
    if (![undo startUndoGroup:@"Link keyposes"])
      return;
    @try {
      [self refreshItem:sender];
      ok=KFSetNativePropertyLink(self.manager, self.source, self.partner,self.time,!self.linked);
      if (ok) {
        for (NSMenuItem *item in menu.itemArray)
          if ([item.target isKindOfClass:KFNativeLinkMenuTarget.class])
            [(KFNativeLinkMenuTarget *)item.target refreshItem:item];
      } else NSBeep();
    } @finally {
      [undo endUndoGroup];
    }
  } @finally {
    [action endAction:view];
    KFPropertyMenuActionFinished(menu,ok);
  }
}
@end
NSMenu *KFNativePropertyMenu(id<PROAPIAccessing> m, NSView *sender,
                             UInt32 parameter) {
  NSMenu *menu = KFResetParameterMenu(m, sender, parameter);
  menu.autoenablesItems = NO;
  __weak NSMenu *weakMenu=menu;
  KFPropertyMenuSetStateHandler(menu, ^{
    NSMenu *activeMenu=weakMenu;
    if (!activeMenu) return;
    for (NSMenuItem *item in activeMenu.itemArray) {
      KFRefreshSettingMenuItem(item);
      if ([item.target isKindOfClass:KFNativeLinkMenuTarget.class]) [(KFNativeLinkMenuTarget *)item.target refreshItem:item];
      if ([item.target isKindOfClass:KFMatchMenuTarget.class]) [(KFMatchMenuTarget *)item.target refreshItem:item];
    }
  });
  // A property that owns an on-screen control offers its visibility toggle.
  KFPropertyLane *lane = KFPropertyLaneForParameter(parameter);
  if (lane.visibilityToggleID) {
    NSString *undoName = [NSString stringWithFormat:@"Toggle %@ On-Screen Control", lane.displayName];
    [menu addItem:KFSettingMenuItem(m, sender, lane.visibilityToggleID, @"On-Screen Control", undoName)];
    [menu addItem:NSMenuItem.separatorItem];
  }
  KFMatchMenuTarget *match = [KFMatchMenuTarget new];
  match.manager = m;
  match.sender = sender;
  match.parameter = parameter;
  NSMenuItem *matchItem = [[NSMenuItem alloc] initWithTitle:@"Match In/Out"
                                                    action:@selector(toggle:)
                                             keyEquivalent:@""];
  matchItem.target = match;
  matchItem.representedObject = match;
  matchItem.enabled = NO;
  [menu addItem:matchItem];
  [menu addItem:NSMenuItem.separatorItem];
  NSMenuItem *header = [NSMenuItem sectionHeaderWithTitle:@"LINK WITH"];
  [menu addItem:header];
  id<FxCustomParameterActionAPI_v4> action =
      [m apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action)
    return menu;
  [action startAction:sender];
  @try {
    // Reading the toggles and the cached keys needs the action scope, like the
    // link items below.
    for (NSMenuItem *item in menu.itemArray) KFRefreshSettingMenuItem(item);
    [match refreshItem:matchItem];
    CMTime now = [action currentTime];
    NSDictionary *source = KFTarget(KFEntries(m, parameter), now);
    NSArray *members = KFMembers(m, KFLink(source[@"pose"]));
    for (NSNumber *p in KFProperties())
      if (p.unsignedIntValue != parameter) {
        BOOL linked = NO;
        for (NSDictionary *member in members)
          if ([member[@"parameter"] isEqual:p])
            linked = YES;
        KFNativeLinkMenuTarget *target = [KFNativeLinkMenuTarget new];
        target.manager = m;
        target.sender = sender;
        target.source = parameter;
        target.partner = p.unsignedIntValue;
        NSDictionary *destination = source;
        if (!destination && !KFEntries(m, parameter).firstObject[@"nativeTime"])
          destination = KFTarget(KFEntries(m, p.unsignedIntValue), now);
        BOOL bothUnkeyed = !KFEntries(m, parameter).firstObject[@"nativeTime"] &&
            !KFEntries(m, p.unsignedIntValue).firstObject[@"nativeTime"];
        target.time = now;
        target.linked = linked;
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:KFPropertyDisplayName(p.unsignedIntValue)
                                                      action:@selector(toggle:)
                                               keyEquivalent:@""];
        item.target = target;
        item.representedObject = target;
        item.state = linked ? NSControlStateValueOn : NSControlStateValueOff;
        item.enabled = CMTIME_IS_NUMERIC(now) && (destination != nil || bothUnkeyed);
        item.indentationLevel = 1;
        item.view = [[ICMenuToggleView alloc] initWithMenuItem:item];
        ((NSControl *)item.view).enabled = item.enabled;
        [menu addItem:item];
      }
  } @finally {
    [action endAction:sender];
  }
  return menu;
}
