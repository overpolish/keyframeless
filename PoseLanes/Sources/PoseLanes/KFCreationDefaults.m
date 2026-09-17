/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFCreationDefaults.h"
#import "KFPropertyLane.h"
#import <math.h>

NSString *const KFDurationDefaultKey = @"duration";
NSString *const KFEasingDefaultKey = @"easing";
NSString *KFMotionDefaultKey(MTAddedMotion type) {
  return [NSString stringWithFormat:@"motion.%u", (unsigned)type];
}

// The plugin owns the preference store, the validation and the factory values;
// this model only asks for a saved value or writes one back.
static id<KFDefaults> KFDefaultsBacking;
void KFSetDefaults(id<KFDefaults> defaults) { KFDefaultsBacking = defaults; }
NSDictionary *KFReadDefault(NSString *key) { return [KFDefaultsBacking defaultForKey:key] ?: @{}; }
BOOL KFSaveDefault(NSString *key, NSDictionary *value) { return [KFDefaultsBacking setDefault:value forKey:key]; }
BOOL KFRestoreFactoryDefault(NSString *key) { return [KFDefaultsBacking restoreFactoryDefaultForKey:key]; }

KFPoseTiming *KFTimingWithCreationDefaults(KFPoseTiming *timing) {
  return [[[KFPoseTiming alloc]
      initWithDuration:[KFReadDefault(KFDurationDefaultKey)[@"value"] doubleValue]
             available:timing.available
                amount:timing.amount
                 speed:timing.speed] timingByCopyingMotionOptionsFrom:timing];
}
BOOL KFIsNewKeyTime(NSArray<NSDictionary *> *entries, CMTime time) {
  if (!entries.firstObject[@"nativeTime"] || !CMTIME_IS_NUMERIC(time))
    return NO;
  for (NSDictionary *e in entries)
    if (fabs([e[@"time"] doubleValue] - CMTimeGetSeconds(time)) < 1e-6)
      return NO;
  return YES;
}
id KFPoseWithCreationDefaults(id pose) {
  id<KFPropertyPose> p = pose;
  return [p poseByReplacingValues:p.values
                         authored:p.authored
                           easing:(MTEasing)[KFReadDefault(KFEasingDefaultKey)[@"value"] integerValue]
                      addedMotion:p.addedMotion
                           timing:KFTimingWithCreationDefaults(p.timing)];
}
@implementation KFDefaultKeyTracker {
  NSArray<NSDictionary *> *_previous;
  NSMutableSet *_known;
}
- (instancetype)init {
  if ((self = [super init]))
    _known = [NSMutableSet new];
  return self;
}
- (void)rememberEntries:(NSArray<NSDictionary *> *)entries {
  for (NSDictionary *e in entries)
    if (e[@"nativeTime"])
      [_known addObject:@{@"time" : e[@"time"], @"pose" : e[@"pose"]}];
}
- (NSArray<NSDictionary *> *)insertionsInEntries:
    (NSArray<NSDictionary *> *)entries {
  if (!entries)
    return @[];
  @synchronized(self) {
    NSMutableArray *added = [NSMutableArray new];
    NSMutableSet *oldTimes = [NSMutableSet new], *newTimes = [NSMutableSet new];
    for (NSDictionary *e in _previous)
      if (e[@"nativeTime"])
        [oldTimes addObject:e[@"time"]];
    for (NSDictionary *e in entries)
      if (e[@"nativeTime"])
        [newTimes addObject:e[@"time"]];
    // A move, deletion, or first document snapshot cannot establish creation.
    if (_previous && newTimes.count > oldTimes.count &&
        [oldTimes isSubsetOfSet:newTimes]) {
      for (NSDictionary *e in entries)
        if (e[@"nativeTime"] && ![oldTimes containsObject:e[@"time"]] &&
            ![_known
                containsObject:@{@"time" : e[@"time"], @"pose" : e[@"pose"]}])
          [added addObject:e];
    }
    [self rememberEntries:entries];
    _previous = [entries copy];
    return added;
  }
}
@end

