/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineAIMerge.h"

#import "KKConstants.h"
#import "KKDataBlob.h"
#import "KKLog.h"
#import <FxPlug/FxPlugSDK.h>

NSString *KKTimelineAICurrentJSON(id<FxParameterRetrievalAPI_v6> getAPI,
                                  NSArray<KKLane *> *fallbackLanes) {
  NSString *saved = KKReadCustomParamString(getAPI, kKKParamTimelineData);
  if (saved.length && [saved containsString:@"\"label\""])
    return saved;
  KKTimeline *fresh = [KKTimeline timeline];
  fresh.lanes = fallbackLanes;
  NSString *json = [KKTimeline jsonFromTimeline:fresh];
  return json ?: @"{\"lanes\":[]}";
}

NSArray *KKTimelineAIPreserveModulation(NSArray *newKps, NSArray *oldKps) {
  if (![newKps isKindOfClass:[NSArray class]] || newKps.count < 2)
    return newKps;
  if (![oldKps isKindOfClass:[NSArray class]] || oldKps.count < 2)
    return newKps;

  NSMutableArray *out = [NSMutableArray arrayWithCapacity:newKps.count];
  for (NSUInteger i = 0; i < newKps.count; i++) {
    id raw = newKps[i];
    if (![raw isKindOfClass:[NSDictionary class]]) {
      [out addObject:raw];
      continue;
    }
    NSMutableDictionary *kp = [raw mutableCopy];
    NSDictionary *outgoing = kp[@"outgoing"];
    if (![outgoing isKindOfClass:[NSDictionary class]] ||
        i + 1 >= newKps.count) {
      [out addObject:kp];
      continue;
    }
    BOOL linked = [outgoing[@"endpoints_linked"] boolValue];
    NSInteger newMod = [outgoing[@"modulation"] integerValue];
    if (!linked || newMod != 0) {
      [out addObject:kp];
      continue;
    }
    // This is a hold with no modulation. Look for a matching old hold
    // interval whose time range overlaps AND whose value matches this
    // keypose's value (so we only preserve modulation on "the same hold
    // resegmented", not on a new differently-valued hold the user just
    // introduced inside the old region).
    double newStart = [kp[@"time"] doubleValue];
    double newEnd = [((NSDictionary *)newKps[i + 1])[@"time"] doubleValue];
    NSArray *newVals = kp[@"values"];
    for (NSUInteger j = 0; j + 1 < oldKps.count; j++) {
      NSDictionary *oldKp = oldKps[j];
      if (![oldKp isKindOfClass:[NSDictionary class]])
        continue;
      NSDictionary *oldOut = oldKp[@"outgoing"];
      if (![oldOut isKindOfClass:[NSDictionary class]])
        continue;
      BOOL oldLinked = [oldOut[@"endpoints_linked"] boolValue];
      NSInteger oldMod = [oldOut[@"modulation"] integerValue];
      if (!oldLinked || oldMod == 0)
        continue;
      double oldStart = [oldKp[@"time"] doubleValue];
      double oldEnd = [((NSDictionary *)oldKps[j + 1])[@"time"] doubleValue];
      // Time overlap AND matching held value. The value check is what
      // separates "outer wiggle-hold resegmented around a new bump" from
      // "a new quiet middle hold sitting inside the old wiggle region".
      BOOL overlaps = (newStart < oldEnd) && (newEnd > oldStart);
      if (!overlaps)
        continue;
      NSArray *oldVals = oldKp[@"values"];
      if (![newVals isKindOfClass:[NSArray class]] ||
          ![oldVals isKindOfClass:[NSArray class]] ||
          newVals.count != oldVals.count)
        continue;
      BOOL sameValues = YES;
      for (NSUInteger k = 0; k < newVals.count; k++) {
        if (fabs([newVals[k] doubleValue] - [oldVals[k] doubleValue]) > 1e-6) {
          sameValues = NO;
          break;
        }
      }
      if (!sameValues)
        continue;
      NSMutableDictionary *mergedOut = [outgoing mutableCopy];
      mergedOut[@"modulation"] = @(oldMod);
      if (oldOut[@"modulation_intensity"])
        mergedOut[@"modulation_intensity"] = oldOut[@"modulation_intensity"];
      if (oldOut[@"modulation_frequency"])
        mergedOut[@"modulation_frequency"] = oldOut[@"modulation_frequency"];
      if (oldOut[@"modulation_seed"])
        mergedOut[@"modulation_seed"] = oldOut[@"modulation_seed"];
      if (oldOut[@"modulation_linked"] != nil)
        mergedOut[@"modulation_linked"] = oldOut[@"modulation_linked"];
      kp[@"outgoing"] = mergedOut;
      break;
    }
    [out addObject:kp];
  }
  return out;
}

NSString *KKTimelineAIMergeMutationJSON(NSString *currentTimelineJSON,
                                        NSString *mutationJSON,
                                        double clipDurSec, double frameDurSec) {
  NSData *curD = [currentTimelineJSON dataUsingEncoding:NSUTF8StringEncoding];
  NSError *err = nil;
  NSMutableDictionary *current =
      [NSJSONSerialization JSONObjectWithData:curD
                                      options:NSJSONReadingMutableContainers
                                        error:&err];
  if (![current isKindOfClass:[NSMutableDictionary class]])
    return nil;
  NSData *mutD = [mutationJSON dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *mut = [NSJSONSerialization JSONObjectWithData:mutD
                                                      options:0
                                                        error:&err];
  if (![mut isKindOfClass:[NSDictionary class]])
    return nil;
  NSArray *ops = mut[@"operations"];
  NSMutableArray *curLanes = current[@"lanes"];
  if (![ops isKindOfClass:[NSArray class]] ||
      ![curLanes isKindOfClass:[NSMutableArray class]])
    return nil;

  NSMutableDictionary *byLabel = [NSMutableDictionary dictionary];
  for (NSUInteger i = 0; i < curLanes.count; i++) {
    NSDictionary *L = curLanes[i];
    if (![L isKindOfClass:[NSDictionary class]])
      continue;
    NSString *label = L[@"label"];
    if ([label isKindOfClass:[NSString class]])
      byLabel[label] = @(i);
  }

  for (id op in ops) {
    if (![op isKindOfClass:[NSDictionary class]])
      continue;
    NSString *label = op[@"lane"];
    if (![label isKindOfClass:[NSString class]])
      continue;
    NSNumber *idxN = byLabel[label];
    if (!idxN) {
      KKLogWarn(@"AI tried to write unknown lane label: %@", label);
      continue;
    }
    NSMutableDictionary *target =
        [curLanes[idxN.unsignedIntegerValue] mutableCopy];
    if (op[@"keyposes"]) {
      NSArray *newKps = op[@"keyposes"];
      NSArray *oldKps = curLanes[idxN.unsignedIntegerValue][@"keyposes"];
      target[@"keyposes"] = KKTimelineAIPreserveModulation(newKps, oldKps);
    }
    if (op[@"hold_shape"])
      target[@"hold_shape"] = op[@"hold_shape"];
    target[@"enabled"] = @YES;
    curLanes[idxN.unsignedIntegerValue] = target;
  }

  // Snap each lane's final keypose from the nominal clip end (the AI emits
  // time ~1.0) back to the last renderable frame, so the animation reaches its
  // end instead of stopping a frame short. Done here, on the raw dict (no
  // KKTimeline round-trip that could drop unmodelled fields), so every plugin's
  // AI path inherits it. Only the last keypose, only when it's past the last
  // frame, and never before the previous keypose (degenerate short clips).
  if (clipDurSec > 0.0 && frameDurSec > 0.0 && frameDurSec < clipDurSec) {
    double lastFrameFrac = (clipDurSec - frameDurSec) / clipDurSec;
    for (NSUInteger i = 0; i < curLanes.count; i++) {
      NSArray *kps = curLanes[i][@"keyposes"];
      if (![kps isKindOfClass:[NSArray class]] || kps.count == 0)
        continue;
      NSDictionary *last = kps.lastObject;
      if (![last isKindOfClass:[NSDictionary class]] ||
          [last[@"time"] doubleValue] <= lastFrameFrac + 1e-6)
        continue;
      if (kps.count >= 2 &&
          [kps[kps.count - 2][@"time"] doubleValue] >= lastFrameFrac)
        continue;
      NSMutableArray *mkps = [kps mutableCopy];
      NSMutableDictionary *nl = [last mutableCopy];
      nl[@"time"] = @(lastFrameFrac);
      mkps[mkps.count - 1] = nl;
      NSMutableDictionary *lane = [curLanes[i] mutableCopy];
      lane[@"keyposes"] = mkps;
      curLanes[i] = lane;
    }
  }

  current[@"lanes"] = curLanes;
  NSData *outD = [NSJSONSerialization dataWithJSONObject:current
                                                 options:0
                                                   error:&err];
  return [[NSString alloc] initWithData:outD encoding:NSUTF8StringEncoding];
}
