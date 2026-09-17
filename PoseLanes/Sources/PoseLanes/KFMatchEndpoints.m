/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFMatchEndpoints.h"
#import "KFNativeEdits.h"
#import "KFPropertyLane.h"

static BOOL KFMatchError(NSError **error, NSString *message) {
  if (error)
    *error = [NSError errorWithDomain:FxPlugErrorDomain
                                 code:kFxError_InvalidParameter
                             userInfo:@{NSLocalizedDescriptionKey : message}];
  return NO;
}

UInt32 KFMatchToggleForProperty(UInt32 parameter) {
  return KFPropertyLaneForParameter(parameter).matchToggleID;
}

BOOL KFPropertyMatchEnabled(id<PROAPIAccessing> manager, UInt32 parameter) {
  UInt32 toggle = KFMatchToggleForProperty(parameter);
  id<FxParameterRetrievalAPI_v6> get =
      [manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  BOOL enabled = NO;
  // Lane-wide and not animatable, so any valid time reads the same value.
  return toggle && get &&
                 [get getBoolValue:&enabled
                     fromParameter:toggle
                            atTime:kCMTimeZero]
             ? enabled
             : NO;
}

// The opposite endpoint of a sole keyframe. A sole key has no intrinsic In/Out
// role, so this creates the Out at the last frame, except for a key already
// sitting there, which instead gains its In at the effect start.
static BOOL KFOppositeEndpointTime(id<PROAPIAccessing> manager,
                                   NSArray<NSDictionary *> *entries,
                                   CMTime *result, NSError **error) {
  id<FxTimingAPI_v4> api = [manager apiForProtocol:@protocol(FxTimingAPI_v4)];
  if (!api)
    return KFMatchError(
        error, @"Effect timing is unavailable for creating the matching endpoint");
  CMTime start = kCMTimeInvalid, duration = kCMTimeInvalid,
         frame = kCMTimeInvalid;
  [api startTimeForEffect:&start];
  [api durationTimeForEffect:&duration];
  [api frameDuration:&frame];
  if (!CMTIME_IS_NUMERIC(start) || !CMTIME_IS_NUMERIC(duration) ||
      !CMTIME_IS_NUMERIC(frame) || CMTimeCompare(frame, kCMTimeZero) <= 0 ||
      CMTimeCompare(duration, frame) < 0)
    return KFMatchError(
        error, @"Effect timing cannot provide a distinct matching endpoint");
  CMTime sole = KFTime(entries.firstObject);
  CMTime end = CMTimeSubtract(CMTimeAdd(start, duration), frame);
  BOOL matchIn = KFSame(end, sole);
  CMTime boundary = matchIn ? start : end;
  if (!CMTIME_IS_NUMERIC(sole) ||
      (matchIn && CMTimeCompare(boundary, sole) >= 0) ||
      (!matchIn && CMTimeCompare(boundary, sole) <= 0))
    return KFMatchError(error,
                        @"There is no room for a matching endpoint in that direction");
  if (result)
    *result = boundary;
  return YES;
}

BOOL KFPropertyMatchAvailable(id<PROAPIAccessing> manager, UInt32 parameter) {
  if (!KFMatchToggleForProperty(parameter))
    return NO;
  NSArray<NSDictionary *> *entries = KFEntries(manager, parameter);
  if (!entries.firstObject[@"nativeTime"])
    return NO;
  return entries.count > 1 ||
         KFOppositeEndpointTime(manager, entries, NULL, NULL);
}

// Keeps the target's own Added Motion settings and link membership while
// adopting the paired incoming transition.
static KFPoseTiming *KFTimingByAdoptingTransition(KFPoseTiming *own,
                                                  KFPoseTiming *source) {
  return [[[[KFPoseTiming alloc] initWithDuration:source.duration
                                        available:source.available
                                           amount:own.amount
                                            speed:own.speed]
      timingByCopyingMotionOptionsFrom:own] timingByReplacingLinkID:own.linkID];
}

static BOOL KFCreateOppositeEndpoint(id<PROAPIAccessing> manager,
                                     UInt32 parameter,
                                     NSArray<NSDictionary *> *entries,
                                     NSError **error) {
  CMTime boundary = kCMTimeInvalid;
  if (!KFOppositeEndpointTime(manager, entries, &boundary, error))
    return NO;
  id old = entries.firstObject[@"pose"];
  // The new key exists in this property alone, so it joins no link group.
  id pose = KFReplace(old, [[old timing] timingByReplacingLinkID:@""],
                      [old easing], [old addedMotion]);
  NSArray *after = KFReplacing(entries, nil, KFEntry(pose, boundary, nil));
  return KFApply(manager, @{@(parameter) : after}, KFNativeEditLink) ||
         KFMatchError(error, @"Unable to create the matching endpoint");
}

BOOL KFMirrorsValueEdit(id<PROAPIAccessing> manager, UInt32 parameter,
                        CMTime target) {
  if (!CMTIME_IS_NUMERIC(target) || !KFPropertyMatchEnabled(manager, parameter))
    return NO;
  NSArray<NSDictionary *> *entries = KFEntries(manager, parameter);
  if (entries.count < 2 || !entries.firstObject[@"nativeTime"])
    return NO;
  return KFSame(target, KFTime(entries.firstObject)) ||
         KFSame(target, KFTime(entries.lastObject));
}

NSArray<NSDictionary *> *KFMatchedEntries(id<PROAPIAccessing> manager,
                                          UInt32 parameter,
                                          NSArray<NSDictionary *> *entries) {
  if (entries.count < 2 || !entries.firstObject[@"nativeTime"] ||
      !KFMatchToggleForProperty(parameter))
    return nil;
  NSDictionary *last = entries.lastObject;
  id source = entries.firstObject[@"pose"], target = last[@"pose"];
  // Two keys share one incoming transition, so only the values pair until a
  // middle key exists. Three or more pair K1 to K2 with K[n-1] to Kn.
  id transition = entries.count > 2 ? entries[1][@"pose"] : target;
  KFPoseTiming *timing =
      KFTimingByAdoptingTransition([target timing], [transition timing]);
  id pose = KFPoseWithValues(target, KFValues(source), timing,
                             [transition easing], [target addedMotion]);
  if ([pose isEqual:target])
    return nil;
  return KFReplacing(entries, last, KFEntry(pose, KFTime(last), last));
}

BOOL KFMirrorsTimingEdit(id<PROAPIAccessing> manager, UInt32 parameter,
                         CMTime target) {
  if (!CMTIME_IS_NUMERIC(target) || !KFPropertyMatchEnabled(manager, parameter))
    return NO;
  NSArray<NSDictionary *> *entries = KFEntries(manager, parameter);
  if (entries.count < 3 || !entries.firstObject[@"nativeTime"])
    return NO;
  return KFSame(target, KFTime(entries[1])) ||
         KFSame(target, KFTime(entries.lastObject));
}

BOOL KFApplyPropertyMatch(id<PROAPIAccessing> manager, UInt32 parameter,
                          NSError **error) {
  if (!KFMatchToggleForProperty(parameter))
    return KFMatchError(error, @"That property cannot match its endpoints");
  NSArray<NSDictionary *> *entries = KFEntries(manager, parameter);
  if (!entries.firstObject[@"nativeTime"])
    return KFMatchError(error,
                        @"Matching needs a keyframe to pair an endpoint with");
  if (entries.count == 1)
    return KFCreateOppositeEndpoint(manager, parameter, entries, error);
  NSArray *after = KFMatchedEntries(manager, parameter, entries);
  if (!after)
    return YES;
  return KFApply(manager, @{@(parameter) : after}, KFNativeEditMetadata) ||
         KFMatchError(error, @"Unable to update the matched endpoint");
}

BOOL KFSetPropertyMatch(id<PROAPIAccessing> manager, UInt32 parameter,
                        BOOL enabled, NSError **error) {
  UInt32 toggle = KFMatchToggleForProperty(parameter);
  id<FxParameterSettingAPI_v5> set =
      [manager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!toggle || !set)
    return KFMatchError(error, @"That property cannot match its endpoints");
  if (enabled && !KFPropertyMatchAvailable(manager, parameter))
    return KFMatchError(error, @"This property has no endpoints to match");
  if (![set setBoolValue:enabled toParameter:toggle atTime:kCMTimeZero])
    return KFMatchError(error, @"Unable to save the Match In/Out setting");
  return enabled ? KFApplyPropertyMatch(manager, parameter, error) : YES;
}
