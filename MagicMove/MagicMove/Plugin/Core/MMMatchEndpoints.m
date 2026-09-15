/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMMatchEndpoints.h"
#import "Constants.h"
#import "MMNativeEdits.h"
#import "MMPropertyLane.h"

static BOOL MMMatchError(NSError **error, NSString *message) {
  if (error)
    *error = [NSError errorWithDomain:FxPlugErrorDomain
                                 code:kFxError_InvalidParameter
                             userInfo:@{NSLocalizedDescriptionKey : message}];
  return NO;
}

UInt32 MMMatchToggleForProperty(UInt32 parameter) {
  switch (parameter) {
  case MMCustomControls:
    return MMPositionMatchEnds;
  case MMScaleControls:
    return MMScaleMatchEnds;
  case MMRotationControls:
    return MMRotationMatchEnds;
  case MMOpacityControls:
    return MMOpacityMatchEnds;
  case MMBlurControls:
    return MMBlurMatchEnds;
  case MMAnchorControls:
    return MMAnchorMatchEnds;
  default:
    return 0;
  }
}

BOOL MMPropertyMatchEnabled(id<PROAPIAccessing> manager, UInt32 parameter) {
  UInt32 toggle = MMMatchToggleForProperty(parameter);
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
static BOOL MMOppositeEndpointTime(id<PROAPIAccessing> manager,
                                   NSArray<NSDictionary *> *entries,
                                   CMTime *result, NSError **error) {
  id<FxTimingAPI_v4> api = [manager apiForProtocol:@protocol(FxTimingAPI_v4)];
  if (!api)
    return MMMatchError(
        error, @"Effect timing is unavailable for creating the matching endpoint");
  CMTime start = kCMTimeInvalid, duration = kCMTimeInvalid,
         frame = kCMTimeInvalid;
  [api startTimeForEffect:&start];
  [api durationTimeForEffect:&duration];
  [api frameDuration:&frame];
  if (!CMTIME_IS_NUMERIC(start) || !CMTIME_IS_NUMERIC(duration) ||
      !CMTIME_IS_NUMERIC(frame) || CMTimeCompare(frame, kCMTimeZero) <= 0 ||
      CMTimeCompare(duration, frame) < 0)
    return MMMatchError(
        error, @"Effect timing cannot provide a distinct matching endpoint");
  CMTime sole = MMTime(entries.firstObject);
  CMTime end = CMTimeSubtract(CMTimeAdd(start, duration), frame);
  BOOL matchIn = MMSame(end, sole);
  CMTime boundary = matchIn ? start : end;
  if (!CMTIME_IS_NUMERIC(sole) ||
      (matchIn && CMTimeCompare(boundary, sole) >= 0) ||
      (!matchIn && CMTimeCompare(boundary, sole) <= 0))
    return MMMatchError(error,
                        @"There is no room for a matching endpoint in that direction");
  if (result)
    *result = boundary;
  return YES;
}

BOOL MMPropertyMatchAvailable(id<PROAPIAccessing> manager, UInt32 parameter) {
  if (!MMMatchToggleForProperty(parameter))
    return NO;
  NSArray<NSDictionary *> *entries = MMEntries(manager, parameter);
  if (!entries.firstObject[@"nativeTime"])
    return NO;
  return entries.count > 1 ||
         MMOppositeEndpointTime(manager, entries, NULL, NULL);
}

// Keeps the target's own Added Motion settings and link membership while
// adopting the paired incoming transition.
static MMPoseTiming *MMTimingByAdoptingTransition(MMPoseTiming *own,
                                                  MMPoseTiming *source) {
  return [[[[MMPoseTiming alloc] initWithDuration:source.duration
                                        available:source.available
                                           amount:own.amount
                                            speed:own.speed]
      timingByCopyingMotionOptionsFrom:own] timingByReplacingLinkID:own.linkID];
}

static BOOL MMCreateOppositeEndpoint(id<PROAPIAccessing> manager,
                                     UInt32 parameter,
                                     NSArray<NSDictionary *> *entries,
                                     NSError **error) {
  CMTime boundary = kCMTimeInvalid;
  if (!MMOppositeEndpointTime(manager, entries, &boundary, error))
    return NO;
  id old = entries.firstObject[@"pose"];
  // The new key exists in this property alone, so it joins no link group.
  id pose = MMReplace(old, [[old timing] timingByReplacingLinkID:@""],
                      [old easing], [old addedMotion]);
  NSArray *after = MMReplacing(entries, nil, MMEntry(pose, boundary, nil));
  return MMApply(manager, @{@(parameter) : after}, MMNativeEditLink) ||
         MMMatchError(error, @"Unable to create the matching endpoint");
}

BOOL MMMirrorsValueEdit(id<PROAPIAccessing> manager, UInt32 parameter,
                        CMTime target) {
  if (!CMTIME_IS_NUMERIC(target) || !MMPropertyMatchEnabled(manager, parameter))
    return NO;
  NSArray<NSDictionary *> *entries = MMEntries(manager, parameter);
  if (entries.count < 2 || !entries.firstObject[@"nativeTime"])
    return NO;
  return MMSame(target, MMTime(entries.firstObject)) ||
         MMSame(target, MMTime(entries.lastObject));
}

NSArray<NSDictionary *> *MMMatchedEntries(id<PROAPIAccessing> manager,
                                          UInt32 parameter,
                                          NSArray<NSDictionary *> *entries) {
  if (entries.count < 2 || !entries.firstObject[@"nativeTime"] ||
      !MMMatchToggleForProperty(parameter))
    return nil;
  NSDictionary *last = entries.lastObject;
  id source = entries.firstObject[@"pose"], target = last[@"pose"];
  // Two keys share one incoming transition, so only the values pair until a
  // middle key exists. Three or more pair K1 to K2 with K[n-1] to Kn.
  id transition = entries.count > 2 ? entries[1][@"pose"] : target;
  MMPoseTiming *timing =
      MMTimingByAdoptingTransition([target timing], [transition timing]);
  id pose = MMPoseWithValues(target, MMValues(source), timing,
                             [transition easing], [target addedMotion]);
  if ([pose isEqual:target])
    return nil;
  return MMReplacing(entries, last, MMEntry(pose, MMTime(last), last));
}

BOOL MMMirrorsTimingEdit(id<PROAPIAccessing> manager, UInt32 parameter,
                         CMTime target) {
  if (!CMTIME_IS_NUMERIC(target) || !MMPropertyMatchEnabled(manager, parameter))
    return NO;
  NSArray<NSDictionary *> *entries = MMEntries(manager, parameter);
  if (entries.count < 3 || !entries.firstObject[@"nativeTime"])
    return NO;
  return MMSame(target, MMTime(entries[1])) ||
         MMSame(target, MMTime(entries.lastObject));
}

BOOL MMApplyPropertyMatch(id<PROAPIAccessing> manager, UInt32 parameter,
                          NSError **error) {
  if (!MMMatchToggleForProperty(parameter))
    return MMMatchError(error, @"That property cannot match its endpoints");
  NSArray<NSDictionary *> *entries = MMEntries(manager, parameter);
  if (!entries.firstObject[@"nativeTime"])
    return MMMatchError(error,
                        @"Matching needs a keyframe to pair an endpoint with");
  if (entries.count == 1)
    return MMCreateOppositeEndpoint(manager, parameter, entries, error);
  NSArray *after = MMMatchedEntries(manager, parameter, entries);
  if (!after)
    return YES;
  return MMApply(manager, @{@(parameter) : after}, MMNativeEditMetadata) ||
         MMMatchError(error, @"Unable to update the matched endpoint");
}

BOOL MMSetPropertyMatch(id<PROAPIAccessing> manager, UInt32 parameter,
                        BOOL enabled, NSError **error) {
  UInt32 toggle = MMMatchToggleForProperty(parameter);
  id<FxParameterSettingAPI_v5> set =
      [manager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!toggle || !set)
    return MMMatchError(error, @"That property cannot match its endpoints");
  if (enabled && !MMPropertyMatchAvailable(manager, parameter))
    return MMMatchError(error, @"This property has no endpoints to match");
  if (![set setBoolValue:enabled toParameter:toggle atTime:kCMTimeZero])
    return MMMatchError(error, @"Unable to save the Match In/Out setting");
  return enabled ? MMApplyPropertyMatch(manager, parameter, error) : YES;
}
