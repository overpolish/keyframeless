/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFEffect.h"
#import "KFOSCPlayheadNudge.h"

NSNotificationName const KFInspectorPresentationChanged = @"KFInspectorPresentationChanged";

@interface KFEffect ()
@property(nonatomic, strong) KFInspectorClock *sharedInspectorClock;
@property(nonatomic, strong) KFOSCPlayheadNudge *playheadNudge;
@property(nonatomic, strong) NSTimer *hostTickTimer;
@end

@implementation KFEffect

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)manager {
  if ((self = [super init])) _apiManager = manager;
  return self;
}

- (void)pluginInstanceAddedToDocument {}

- (BOOL)parameterChanged:(UInt32)parameterID atTime:(CMTime)time error:(NSError **)error { return YES; }

- (void)dealloc { [_hostTickTimer invalidate]; }

- (void)startHostTicks:(void (^)(id<FxCustomParameterActionAPI_v4> action))tick {
  if (!tick) return;
  __weak KFEffect *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    KFEffect *effect = weakSelf;
    if (!effect || effect.hostTickTimer) return;
    effect.hostTickTimer = [NSTimer timerWithTimeInterval:(1.0/30.0) repeats:YES block:^(NSTimer *timer) {
      KFEffect *ticking = weakSelf;
      if (!ticking) { [timer invalidate]; return; }
      id<FxCustomParameterActionAPI_v4> action =
          [ticking.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
      if (!action) return;
      [action startAction:ticking];
      @try { tick(action); }
      @finally { [action endAction:ticking]; }
    }];
    [NSRunLoop.mainRunLoop addTimer:effect.hostTickTimer forMode:NSDefaultRunLoopMode];
  });
}

- (KFInspectorClock *)inspectorClock {
  if (!self.sharedInspectorClock) {
    self.sharedInspectorClock = [[KFInspectorClock alloc] initWithManager:self.apiManager];
    // The viewer's controls hide themselves while the playhead moves and
    // cannot ask for the redraw that brings them back; this tick is where that
    // redraw is requested. It rides the clock the inspector already runs.
    self.playheadNudge = [[KFOSCPlayheadNudge alloc] initWithManager:self.apiManager
                                               visibilityParameters:self.onScreenControlVisibilityParameters];
    KFOSCPlayheadNudge *nudge = self.playheadNudge;
    self.sharedInspectorClock.onTick = ^(id<FxCustomParameterActionAPI_v4> action) {
      [nudge tickInAction:action];
    };
  }
  return self.sharedInspectorClock;
}
@end
