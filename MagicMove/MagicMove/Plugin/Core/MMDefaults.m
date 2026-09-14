/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMDefaults.h"
#import <math.h>
PPDefaultStore *MMDefaultStore(void) {
  static PPDefaultStore *store;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    store = [[PPDefaultStore alloc]
        initWithDefaults:
            [[NSUserDefaults alloc]
                initWithSuiteName:NSProcessInfo.processInfo
                                          .environment[@"MM_PREFERENCES_SUITE"]
                                      ?: @"co.overpolish.magicmove.preferences"]
               namespace:@"defaults"];
  });
  return store;
}
NSString *MMMotionDefaultKey(MTAddedMotion type) {
  return [NSString stringWithFormat:@"motion.%u", (unsigned)type];
}
static BOOL MMNumber(id value, double min, double max) {
  return [value isKindOfClass:NSNumber.class] &&
         isfinite([value doubleValue]) && [value doubleValue] >= min &&
         [value doubleValue] <= max;
}
static NSDictionary *MMFactory(NSString *key) {
  if ([key isEqual:@"duration"])
    return @{@"value" : @1.2};
  if ([key isEqual:@"easing"])
    return @{@"value" : @(MTEasingSmooth)};
  return @{@"amount" : @1, @"speed" : @1};
}
static BOOL MMValidDefault(NSString *key, NSDictionary *v) {
  if ([key isEqual:@"duration"])
    return v.count == 1 && MMNumber(v[@"value"], 0, 60);
  if ([key isEqual:@"easing"])
    return v.count == 1 && MMNumber(v[@"value"], 0, 3) &&
           floor([v[@"value"] doubleValue]) == [v[@"value"] doubleValue];
  if (![@[ @"motion.1", @"motion.2", @"motion.3" ] containsObject:key])
    return NO;
  return v.count == 2 && MMNumber(v[@"amount"], 0, 3) &&
         MMNumber(v[@"speed"], 0.05, 10);
}
NSDictionary *MMReadDefault(NSString *key) {
  return [MMDefaultStore() valueForKey:key
                               factory:MMFactory(key)
                              validate:^BOOL(NSDictionary *v) {
                                return MMValidDefault(key, v);
                              }];
}
BOOL MMSaveDefault(NSString *key, NSDictionary *v) {
  return [MMDefaultStore() setValue:v
                             forKey:key
                           validate:^BOOL(NSDictionary *x) {
                             return MMValidDefault(key, x);
                           }];
}
MMPoseTiming *MMTimingWithCreationDefaults(MMPoseTiming *timing) {
  return [[[MMPoseTiming alloc]
      initWithDuration:[MMReadDefault(@"duration")[@"value"] doubleValue]
             available:timing.available
                amount:timing.amount
                 speed:timing.speed] timingByCopyingMotionOptionsFrom:timing];
}
BOOL MMIsNewKeyTime(NSArray<NSDictionary *> *entries, CMTime time) {
  if (!entries.firstObject[@"nativeTime"] || !CMTIME_IS_NUMERIC(time))
    return NO;
  for (NSDictionary *e in entries)
    if (fabs([e[@"time"] doubleValue] - CMTimeGetSeconds(time)) < 1e-6)
      return NO;
  return YES;
}

#import "MMCombinedPose.h"
#import "MMPropertyLane.h"
#import "MMScalePose.h"
id MMPoseWithCreationDefaults(id pose) {
  MMPoseTiming *timing = MMTimingWithCreationDefaults([pose timing]);
  MTEasing easing = (MTEasing)[MMReadDefault(@"easing")[@"value"] integerValue];
  if ([pose isKindOfClass:MMCombinedPose.class]) {
    MMCombinedPose *p = pose;
    return [[[MMCombinedPose alloc] initWithPositionX:p.positionX
                                            positionY:p.positionY
                                                scale:p.scale
                                             authored:p.authored
                                               easing:easing
                                          addedMotion:p.addedMotion]
        poseByReplacingTiming:timing];
  }
  if ([pose isKindOfClass:MMScalePose.class]) {
    MMScalePose *p = pose;
    return [[[MMScalePose alloc] initWithX:p.x
                                         y:p.y
                                  authored:p.authored
                                    easing:easing
                               addedMotion:p.addedMotion]
        poseByReplacingTiming:timing];
  }
  id<MMPropertyPose> p = pose;
  return [p poseByReplacingValues:p.values
                         authored:p.authored
                           easing:easing
                      addedMotion:p.addedMotion
                           timing:timing];
}
@implementation MMDefaultKeyTracker {
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
