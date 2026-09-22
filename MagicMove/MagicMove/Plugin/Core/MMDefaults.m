/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMDefaults.h"
#import "Constants.h"
#import <math.h>
@import MotionTiming;
@import PluginPreferences;

static PPDefaultStore *MMDefaultStore(void) {
  static PPDefaultStore *store;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    store = [[PPDefaultStore alloc]
        initWithDefaults:[[NSUserDefaults alloc]
                             initWithSuiteName:NSProcessInfo.processInfo
                                                       .environment[@"MM_PREFERENCES_SUITE"]
                                                   ?: @"com.keyframeless.magicmove.preferences"]
               namespace:@"defaults"];
  });
  return store;
}

static BOOL MMNumber(id value, double min, double max) {
  return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) &&
         [value doubleValue] >= min && [value doubleValue] <= max;
}
static NSString *MMOSCVisibilityKey(UInt32 parameter) {
  switch (parameter) {
  case MMShowScaleOSC: return @"osc.scale";
  case MMShowRotationOSC: return @"osc.rotation";
  case MMShowAnchorOSC: return @"osc.anchor";
  default: return @"osc.position";
  }
}
static BOOL MMIsOSCVisibilityKey(NSString *key) { return [key hasPrefix:@"osc."]; }
BOOL MMIsOSCVisibilityParameter(UInt32 parameter) {
  return parameter == MMShowPositionOSC || parameter == MMShowScaleOSC ||
         parameter == MMShowRotationOSC || parameter == MMShowAnchorOSC;
}

static NSDictionary *MMFactory(NSString *key) {
  if ([key isEqual:KFDurationDefaultKey]) return @{@"value" : @1.2};
  if ([key isEqual:KFEasingDefaultKey]) return @{@"value" : @(MTEasingSmooth)};
  // The transform controls start visible; the anchor square does not, because
  // the pivot only matters while it is being moved.
  if (MMIsOSCVisibilityKey(key)) return @{@"value" : @(![key isEqual:@"osc.anchor"])};
  return @{@"amount" : @1, @"speed" : @1};
}
static BOOL MMValidDefault(NSString *key, NSDictionary *v) {
  if ([key isEqual:KFDurationDefaultKey]) return v.count == 1 && MMNumber(v[@"value"], 0, 60);
  if ([key isEqual:KFEasingDefaultKey])
    return v.count == 1 && MMNumber(v[@"value"], 0, 3) &&
           floor([v[@"value"] doubleValue]) == [v[@"value"] doubleValue];
  if (MMIsOSCVisibilityKey(key))
    return v.count == 1 && [v[@"value"] isKindOfClass:NSNumber.class];
  if (![@[ @"motion.1", @"motion.2", @"motion.3" ] containsObject:key]) return NO;
  return v.count == 2 && MMNumber(v[@"amount"], 0, 3) && MMNumber(v[@"speed"], 0.05, 10);
}

@interface MMDefaultsAdapter : NSObject <KFDefaults>
@end
@implementation MMDefaultsAdapter
- (NSDictionary *)defaultForKey:(NSString *)key {
  return [MMDefaultStore() valueForKey:key
                               factory:MMFactory(key)
                              validate:^BOOL(NSDictionary *v) { return MMValidDefault(key, v); }];
}
- (BOOL)setDefault:(NSDictionary *)value forKey:(NSString *)key {
  return [MMDefaultStore() setValue:value
                             forKey:key
                           validate:^BOOL(NSDictionary *v) { return MMValidDefault(key, v); }];
}
- (BOOL)restoreFactoryDefaultForKey:(NSString *)key {
  [MMDefaultStore() restoreFactoryForKey:key];
  return YES;
}
@end

id<KFDefaults> MMDefaults(void) {
  static MMDefaultsAdapter *adapter;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ adapter = [MMDefaultsAdapter new]; });
  return adapter;
}

BOOL MMReadOSCVisibilityDefault(UInt32 parameter) {
  return [KFReadDefault(MMOSCVisibilityKey(parameter))[@"value"] boolValue];
}
BOOL MMSaveOSCVisibilityDefault(UInt32 parameter, BOOL visible) {
  return KFSaveDefault(MMOSCVisibilityKey(parameter), @{@"value" : @(visible)});
}
