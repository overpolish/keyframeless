/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFInspectorClock.h"

static const NSTimeInterval KFInspectorRefreshInterval = 0.1;

@interface KFInspectorClock ()
@property(nonatomic, weak) id<PROAPIAccessing> manager;
@property(nonatomic, strong) NSHashTable<id<KFInspectorRefreshable>> *views;
@property(nonatomic, strong) NSTimer *timer;
@end

@implementation KFInspectorClock
- (instancetype)initWithManager:(id<PROAPIAccessing>)manager {
  if ((self = [super init])) {
    _manager = manager;
    _views = [NSHashTable weakObjectsHashTable];
  }
  return self;
}
- (void)dealloc { [_timer invalidate]; }

- (void)addView:(id<KFInspectorRefreshable>)view {
  if (!view) return;
  [self.views addObject:view];
  if (self.timer) return;
  __weak KFInspectorClock *weakSelf = self;
  self.timer = [NSTimer timerWithTimeInterval:KFInspectorRefreshInterval repeats:YES
                                        block:^(NSTimer *timer) {
    KFInspectorClock *clock = weakSelf;
    if (!clock) { [timer invalidate]; return; }
    [clock tick];
  }];
  [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSDefaultRunLoopMode];
}
- (void)removeView:(id<KFInspectorRefreshable>)view {
  [self.views removeObject:view];
  [self stopIfIdle];
}
- (void)stopIfIdle {
  if (self.views.count) return;
  [self.timer invalidate];
  self.timer = nil;
}

- (void)tick {
  // Weak registrations can empty without a removeView: call when the host
  // drops a view without moving it out of its window first.
  [self stopIfIdle];
  [self refreshNow];
}
- (void)refreshNow {
  id<FxCustomParameterActionAPI_v4> action =
      [self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (![(id<NSObject>)action conformsToProtocol:@protocol(FxCustomParameterActionAPI_v4)]) return;
  NSArray<id<KFInspectorRefreshable>> *views = self.views.allObjects;
  // No views, no action: the timer is stopped in that state anyway, so the
  // per-tick work rides the same registration the views do.
  if (!views.count) return;
  void (^tick)(id<FxCustomParameterActionAPI_v4>) = self.onTick;
  [action startAction:self];
  @try {
    for (id<KFInspectorRefreshable> view in views)
      [view refreshInspectorValuesInAction:action];
    // Last, so a write here cannot disturb the reads above.
    if (tick) tick(action);
  } @finally { [action endAction:self]; }
  // Outside the action: drawing reads the caches the refresh just filled and
  // must not hold a host scope open while AppKit runs plug-in drawing code.
  for (id<KFInspectorRefreshable> view in views)
    if ([view respondsToSelector:@selector(inspectorRefreshView)])
      [[view inspectorRefreshView] displayIfNeeded];
}
@end
