/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MockHost.h"

// One action per tick for every registered view, a timer that exists only
// while views are registered, and weak registrations that survive a host
// dropping a view without unregistering it.
@interface ClockHost : MockHost <FxCustomParameterActionAPI_v4>
@property NSUInteger starts;
@property NSUInteger ends;
@end
@implementation ClockHost
- (id)apiForProtocol:(Protocol *)protocol {
  if ([self.missingProtocols containsObject:NSStringFromProtocol(protocol)]) return nil;
  if (protocol == @protocol(FxCustomParameterActionAPI_v4)) return self;
  return [super apiForProtocol:protocol];
}
- (void)startAction:(id)sender { self.starts++; }
- (void)endAction:(id)sender { self.ends++; }
- (CMTime)currentTime { return TestTime(1); }
@end

@interface CountingView : NSObject <KFInspectorRefreshable>
@property NSUInteger refreshes;
@property(weak) ClockHost *host;
@property NSUInteger startsSeen;
@end
@implementation CountingView
- (void)refreshInspectorValuesInAction:(id<FxCustomParameterActionAPI_v4>)action {
  self.refreshes++;
  // A view must always see an open action; it never opens one itself.
  self.startsSeen = self.host.starts;
}
@end

// Run the main run loop until a condition holds, rather than assuming one
// timer slice arrives within a fixed sleep on a loaded machine.
static BOOL WaitUntil(BOOL (^condition)(void)) {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
  while (!condition() && deadline.timeIntervalSinceNow > 0)
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
  return condition();
}

static void oneActionPerTick(void) {
  ClockHost *host = [ClockHost new];
  KFInspectorClock *clock = [[KFInspectorClock alloc] initWithManager:host];
  CountingView *first = [CountingView new], *second = [CountingView new];
  first.host = host;
  second.host = host;
  [clock addView:first];
  [clock addView:second];
  assert(WaitUntil(^BOOL { return first.refreshes > 0 && second.refreshes > 0; }));
  // Both views refresh from the same action, so actions never outnumber ticks.
  assert(host.starts <= first.refreshes + 1 && host.starts == host.ends);
  assert(first.startsSeen > 0 && second.startsSeen > 0);

  __block NSUInteger ticks = 0;
  clock.onTick = ^(id<FxCustomParameterActionAPI_v4> action) {
    assert(action != nil);
    ticks++;
  };
  assert(WaitUntil(^BOOL { return ticks > 0; }));

  NSUInteger stopped = host.starts;
  [clock removeView:first];
  [clock removeView:second];
  // With no views the timer stops, so no further action is opened.
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.3, false);
  assert(host.starts == stopped && host.starts == host.ends);
}

static void weakRegistrationsAndMissingAction(void) {
  ClockHost *host = [ClockHost new];
  KFInspectorClock *clock = [[KFInspectorClock alloc] initWithManager:host];
  CountingView *kept = [CountingView new];
  kept.host = host;
  @autoreleasepool {
    CountingView *dropped = [CountingView new];
    [clock addView:dropped];
    [clock addView:kept];
  }
  assert(WaitUntil(^BOOL { return kept.refreshes > 0; }));

  // A host that exposes no action API must not be refreshed at all.
  host.missingProtocols =
      [NSSet setWithObject:NSStringFromProtocol(@protocol(FxCustomParameterActionAPI_v4))];
  NSUInteger refreshes = kept.refreshes;
  [clock refreshNow];
  assert(kept.refreshes == refreshes);
  assert(host.starts == host.ends);
}

int main(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    oneActionPerTick();
    weakRegistrationsAndMissingAction();
    puts("Inspector clock: one action per tick, stops when idle, weak views, no action no refresh passed");
  }
  return 0;
}
