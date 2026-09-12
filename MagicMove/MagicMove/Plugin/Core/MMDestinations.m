/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMDestinations.h"
#import "Constants.h"
#import <KeyframelessKit/KKDataBlob.h>
#import <math.h>

static NSData *MMFail(NSError **error, NSString *message) {
  if (error) *error = [NSError errorWithDomain:FxPlugErrorDomain code:kFxError_InvalidParameter
                                     userInfo:@{NSLocalizedDescriptionKey:message}];
  return nil;
}
static int MMCompareRecords(const void *a, const void *b) {
  double x = ((const MTDurationRecord *)a)->time, y = ((const MTDurationRecord *)b)->time;
  return (x > y) - (x < y);
}
NSData *MMReadDestinations(id<PROAPIAccessing> manager, UInt32 valueID, UInt32 dataID, NSError **error) {
  NSData *previous = MMReadSavedDestinations(manager, dataID, error);
  return previous ? MMReadDestinationsFromPrevious(manager, valueID, previous, error) : nil;
}
NSData *MMReadDestinationsFromPrevious(id<PROAPIAccessing> manager, UInt32 valueID, NSData *previous, NSError **error) {
  id<FxKeyframeAPI_v3> keys = [manager apiForProtocol:@protocol(FxKeyframeAPI_v3)];
  id<FxParameterRetrievalAPI_v6> get = [manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!keys || !get) return MMFail(error, @"Magic Move needs host keyframe access");
  NSUInteger count = 0;
  NSError *failure = [keys keyframeCount:&count forParameter:valueID andChannel:0];
  if (failure) { if (error) *error = failure; return nil; }
  NSMutableData *current = [NSMutableData dataWithLength:count*sizeof(MTDurationRecord)];
  MTDurationRecord *records = current.mutableBytes;
  for (NSUInteger i=0; i<count; ++i) {
    FxKeyframe key;
    FxInitKeyframe(key, kFxKeyframe_CurrentVersion);
    failure = [keys keyframe:&key forParameter:valueID channel:0 andIndex:i];
    if (failure) { if (error) *error = failure; return nil; }
    if (!CMTIME_IS_NUMERIC(key.time) ||
        ![get getFloatValue:&records[i].value fromParameter:valueID atTime:key.time])
      return MMFail(error, @"Unable to read a motion keyframe");
    records[i].time = CMTimeGetSeconds(key.time);
  }
  if (count) qsort(records, count, sizeof(*records), MMCompareRecords);
  const MTDurationRecord *old = previous.bytes;
  NSMutableData *result = [NSMutableData dataWithLength:current.length];
  if (!MTReconcileDurations(old, previous.length/sizeof(*old), records, count, 1.2, result.mutableBytes))
    return MMFail(error, @"Unable to associate durations with motion keys");
  return result;
}
NSData *MMReadSavedDestinations(id<PROAPIAccessing> manager, UInt32 dataID, NSError **error) {
  id<FxParameterRetrievalAPI_v6> get = [manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSObject<NSSecureCoding,NSCopying> *blob = nil;
  if (![get getCustomParameterValue:&blob fromParameter:dataID atTime:kCMTimeZero] ||
      ![blob isKindOfClass:KKDataBlob.class])
    return MMFail(error, @"Unable to read saved durations; add a fresh Magic Move effect");
  id json = [NSJSONSerialization JSONObjectWithData:((KKDataBlob *)blob).data options:0 error:error];
  if (![json isKindOfClass:NSArray.class]) return MMFail(error, @"Invalid saved duration data");
  NSArray *saved = json;
  NSMutableData *previous = [NSMutableData dataWithLength:saved.count*sizeof(MTDurationRecord)];
  MTDurationRecord *old = previous.mutableBytes;
  for (NSUInteger i=0; i<saved.count; ++i) {
    id entry = saved[i];
    if (![entry isKindOfClass:NSDictionary.class] ||
        ![entry[@"time"] isKindOfClass:NSNumber.class] ||
        ![entry[@"value"] isKindOfClass:NSNumber.class] ||
        ![entry[@"duration"] isKindOfClass:NSNumber.class] ||
        (entry[@"useAvailableTime"] && ![entry[@"useAvailableTime"] isKindOfClass:NSNumber.class]) ||
        (entry[@"linkID"] && ![entry[@"linkID"] isKindOfClass:NSNumber.class]) ||
        (entry[@"addedMotion"] && (![entry[@"addedMotion"] isKindOfClass:NSNumber.class] || [entry[@"addedMotion"] integerValue] < MTAddedMotionNone || [entry[@"addedMotion"] integerValue] > MTAddedMotionHandheld)) ||
        (entry[@"easing"] && (![entry[@"easing"] isKindOfClass:NSNumber.class] || [entry[@"easing"] integerValue] < MTEasingSmooth || [entry[@"easing"] integerValue] > MTEasingEaseOut)) ||
        (entry[@"matchEndpoints"] && ![entry[@"matchEndpoints"] isKindOfClass:NSNumber.class]))
      return MMFail(error, @"Invalid saved duration entry");
    old[i] = (MTDurationRecord){[entry[@"time"] doubleValue], [entry[@"value"] doubleValue],
                                [entry[@"duration"] doubleValue], [entry[@"useAvailableTime"] boolValue],
                                [entry[@"linkID"] unsignedLongLongValue], SIZE_MAX, [entry[@"matchEndpoints"] boolValue], (MTEasing)[entry[@"easing"] intValue], (MTAddedMotion)[entry[@"addedMotion"] intValue]};
  }
  return previous;
}
BOOL MMWriteDestinations(id<PROAPIAccessing> manager, UInt32 dataID, NSData *data) {
  const MTDurationRecord *records = data.bytes;
  NSMutableArray *json = [NSMutableArray array];
  for (NSUInteger i=0; i<data.length/sizeof(*records); ++i)
    [json addObject:@{@"time":@(records[i].time), @"value":@(records[i].value),
                     @"duration":@(records[i].duration), @"useAvailableTime":@(records[i].useAvailableTime),
                     @"linkID":@(records[i].linkID), @"matchEndpoints":@(records[i].matchEndpoints), @"easing":@(records[i].easing), @"addedMotion":@(records[i].addedMotion)}];
  NSData *encoded = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingSortedKeys error:nil];
  id<FxParameterRetrievalAPI_v6> get = [manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSObject<NSSecureCoding,NSCopying> *old = nil;
  [get getCustomParameterValue:&old fromParameter:dataID atTime:kCMTimeZero];
  if ([old isKindOfClass:KKDataBlob.class] && [((KKDataBlob *)old).data isEqual:encoded]) return YES;
  id<FxParameterSettingAPI_v5> set = [manager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  return encoded && [set setCustomParameterValue:(id)[KKDataBlob blobWithData:encoded]
                                     toParameter:dataID atTime:kCMTimeZero];
}
NSInteger MMKeyposeAtTime(NSData *data, CMTime time) {
  if (!CMTIME_IS_NUMERIC(time)) return NSNotFound;
  double seconds = CMTimeGetSeconds(time);
  const MTDurationRecord *records = data.bytes;
  // One microsecond tolerance handles rational-to-double conversion only,
  // not a neighbouring frame. Linking also applies to the first key.
  for (NSUInteger i=0; i<data.length/sizeof(*records); ++i)
    if (fabs(records[i].time-seconds) < 1e-6) return (NSInteger)i;
  return NSNotFound;
}

NSInteger MMDestinationAtTime(NSData *data, CMTime time) {
  if (!CMTIME_IS_NUMERIC(time)) return NSNotFound;
  const MTDurationRecord *records = data.bytes;
  NSUInteger count = data.length/sizeof(*records);
  double seconds = CMTimeGetSeconds(time);
  if (count < 2 || seconds <= records[0].time + 1e-6) return NSNotFound;
  // Exact keys own their IN; between keys, the next arrival owns the interval.
  for (NSUInteger i=1; i<count; ++i)
    if (seconds <= records[i].time || fabs(seconds-records[i].time) < 1e-6) return (NSInteger)i;
  return NSNotFound;
}

BOOL MMDestinationsEqual(NSData *a, NSData *b) {
  if (!a || !b || a.length != b.length) return NO;
  const MTDurationRecord *x = a.bytes, *y = b.bytes;
  for (NSUInteger i=0; i<a.length/sizeof(*x); ++i)
    if (x[i].time != y[i].time || x[i].value != y[i].value ||
        x[i].duration != y[i].duration || x[i].useAvailableTime != y[i].useAvailableTime ||
        x[i].addedMotion != y[i].addedMotion || x[i].easing != y[i].easing || x[i].linkID != y[i].linkID || x[i].matchEndpoints != y[i].matchEndpoints) return NO;
  return YES;
}

NSInteger MMOriginAtTime(NSData *data, CMTime time) {
  if (!CMTIME_IS_NUMERIC(time)) return NSNotFound;
  const MTDurationRecord *records = data.bytes;
  NSUInteger count = data.length/sizeof(*records);
  double seconds = CMTimeGetSeconds(time);
  if (count < 2 || seconds < records[0].time-1e-6 || seconds >= records[count-1].time-1e-6) return NSNotFound;
  for (NSUInteger i=count-1; i>0; --i)
    if (seconds >= records[i-1].time-1e-6) return (NSInteger)i-1;
  return NSNotFound;
}
