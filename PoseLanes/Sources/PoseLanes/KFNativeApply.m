/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFHostSettings.h"
#import "KFNativeEdits.h"
#import "KFNativeLinks_Private.h"

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
        // The host journals a parameter for undo when its value is written,
        // not when a key is removed: undoing a bare removal restores nothing,
        // as undoing an insertion does drop the key it recorded a write for.
        // Re-writing each doomed keypose puts the state undo has to come back
        // to in the caller's group before the key goes.
        if (structural)
          for (NSDictionary *e in old)
            if (e[@"nativeTime"] && !KFAt(next, KFTime(e)))
              [set setCustomParameterValue:e[@"pose"] toParameter:pid atTime:KFTime(e)];
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
        // The scratch token invalidates the host's cached frame, so it has to
        // name the frame on screen: invalidating time zero leaves the viewer
        // showing the pre-edit render until the pointer moves.
        id<FxCustomParameterActionAPI_v4> action =
            [m apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
        CMTime now = action ? [action currentTime] : kCMTimeZero;
        KFRequestHostRefresh(m, CMTIME_IS_NUMERIC(now) ? now : kCMTimeZero);
      }
    } @finally {
      @synchronized(state) {
        state.applying = NO;
      }
    }
    return ok;
  }
}
