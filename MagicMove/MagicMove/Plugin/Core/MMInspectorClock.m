/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMInspectorClock.h"

static const NSTimeInterval MMInspectorRefreshInterval = 0.1;

@interface MMInspectorClock ()
@property(nonatomic, weak) id<PROAPIAccessing> manager;
@property(nonatomic, strong) NSHashTable<id<MMInspectorRefreshable>> *views;
@property(nonatomic, strong) NSTimer *timer;
@end

@implementation MMInspectorClock
- (instancetype)initWithManager:(id<PROAPIAccessing>)manager {
  if ((self = [super init])) {
    _manager = manager;
    _views = [NSHashTable weakObjectsHashTable];
  }
  return self;
}
- (void)dealloc { [_timer invalidate]; }

- (void)addView:(id<MMInspectorRefreshable>)view {
  if (!view) return;
  [self.views addObject:view];
  if (self.timer) return;
  __weak MMInspectorClock *weakSelf = self;
  self.timer = [NSTimer timerWithTimeInterval:MMInspectorRefreshInterval repeats:YES
                                        block:^(NSTimer *timer) {
    MMInspectorClock *clock = weakSelf;
    if (!clock) { [timer invalidate]; return; }
    [clock tick];
  }];
  [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSDefaultRunLoopMode];
}
- (void)removeView:(id<MMInspectorRefreshable>)view {
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
  NSArray<id<MMInspectorRefreshable>> *views = self.views.allObjects;
  if (!views.count) return;
  [action startAction:self];
  @try {
    for (id<MMInspectorRefreshable> view in views)
      [view refreshInspectorValuesInAction:action];
  } @finally { [action endAction:self]; }
}
@end
