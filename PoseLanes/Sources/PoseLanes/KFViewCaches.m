/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFViewCaches.h"
#import "KFNativeLinks.h"
#import <objc/runtime.h>
#import <ApplicationServices/ApplicationServices.h>

// Associated storage keeps the lane caches with the effect without giving
// PluginHost any notion of keyframed properties.
static const void *KFLaneCachesKey = &KFLaneCachesKey;

@implementation KFEffect (KFViewCaches)
- (void)publishViewCaches {
  id<FxCustomParameterActionAPI_v4> action =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  id<FxParameterSettingAPI_v5> set =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  // Detached library and drag instances reach here before the host exposes a
  // usable action or setting API; the next accessor retries.
  if (![(id<NSObject>)action conformsToProtocol:@protocol(FxCustomParameterActionAPI_v4)] ||
      ![(id<NSObject>)set conformsToProtocol:@protocol(FxParameterSettingAPI_v5)])
    return;
  NSDictionary<NSNumber *, KFPropertyPoseCache *> *caches =
      objc_getAssociatedObject(self, KFLaneCachesKey);
  if (caches) return;
  NSMutableDictionary<NSNumber *, KFPropertyPoseCache *> *created = [NSMutableDictionary dictionary];
  for (KFPropertyLane *lane in KFPropertyLanes()) created[@(lane.parameterID)] = [lane createCache];
  objc_setAssociatedObject(self, KFLaneCachesKey, created, OBJC_ASSOCIATION_RETAIN);
  [action startAction:self];
  @try {
    for (KFPropertyLane *lane in KFPropertyLanes())
      [set setStringParameterValue:created[@(lane.parameterID)].token toParameter:lane.cacheTokenID];
  } @finally { [action endAction:self]; }
}
- (KFPropertyPoseCache *)sharedCacheForLane:(KFPropertyLane *)lane {
  [self publishViewCaches];
  NSDictionary<NSNumber *, KFPropertyPoseCache *> *caches =
      objc_getAssociatedObject(self, KFLaneCachesKey);
  return caches[@(lane.parameterID)];
}
- (void)startNativeLinkCommits {
  __weak KFEffect *weakSelf = self;
  [self startHostTicks:^(id<FxCustomParameterActionAPI_v4> action) {
    KFEffect *effect = weakSelf;
    if (!effect) return;
    // A held mouse is still dragging keys; the partner moves on release.
    if (CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft)) return;
    NSError *error = nil;
    if (!KFCommitNativeLinkMoves(effect.apiManager, NO, &error))
      NSLog(@"Deferred linked edit failed: %@", error);
  }];
}
@end
