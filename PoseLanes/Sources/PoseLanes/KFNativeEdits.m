/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFNativeEdits.h"
#import "KFNativeLinks_Private.h"

id KFCache(id<PROAPIAccessing> m, UInt32 p) {
  return [KFPropertyLaneForParameter(p) cacheForManager:m];
}
NSArray<NSDictionary *> *KFEntries(id<PROAPIAccessing> m, UInt32 p) {
  return [KFCache(m, p) snapshotEntries];
}
NSString *KFLink(id pose) { return [[pose timing] linkID] ?: @""; }
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
NSDictionary *KFTarget(NSArray *entries, CMTime t) {
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
