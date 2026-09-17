/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFCreationDefaults.h"
#import "KFMatchEndpoints.h"
#import "KFNativeEdits.h"
#import "KFNativeLinks.h"
#import "KFNativeLinks_Private.h"

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
