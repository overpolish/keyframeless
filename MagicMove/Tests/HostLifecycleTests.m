/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */
#import "MockHost.h"
#import "Plugin_Private.h"

// Counts the host actions the effect's own tick opens, which is how the
// deferred linked-key commit becomes observable from outside.
@interface LifecycleHost : MockHost <FxCustomParameterActionAPI_v4>
@property NSUInteger starts;
@property NSUInteger ends;
@end
@implementation LifecycleHost
- (id)apiForProtocol:(Protocol *)protocol {
  if (protocol == @protocol(FxCustomParameterActionAPI_v4)) return self;
  return [super apiForProtocol:protocol];
}
- (void)startAction:(id)sender { self.starts++; }
- (void)endAction:(id)sender { self.ends++; }
- (CMTime)currentTime { return TestTime(0); }
@end

static void DrainMainQueue(void) {
  [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}
static BOOL WaitUntil(BOOL (^condition)(void)) {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
  while (!condition() && deadline.timeIntervalSinceNow > 0)
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  return condition();
}

int main(void) {
  @autoreleasepool {
    MagicMovePlugin *plugin;
    LifecycleHost *host = [LifecycleHost new];
    __weak MockHost *weakHost;
    @autoreleasepool {
      MockHost *detached = [MockHost new];
      weakHost = detached;
      plugin = [[MagicMovePlugin alloc] initWithAPIManager:detached];
      assert(plugin.apiManager == detached);
      // Detached library and drag instances stay idle: parameter creation must
      // not make the host answer timing questions for a nonexistent input.
      DrainMainQueue();
      assert(detached.hostWrites == 0);
    }
    assert(weakHost == nil && plugin.apiManager == nil);

    plugin = [[MagicMovePlugin alloc] initWithAPIManager:host];
    [plugin pluginInstanceAddedToDocument];
    assert(WaitUntil(^BOOL { return host.starts > 0; }));
    assert(host.starts == host.ends);
    // Attachment publishes the on-screen control toggles the playhead nudge
    // needs, taken from the lane table rather than a second list.
    assert(plugin.onScreenControlVisibilityParameters.count == 4);

    // Repeated attachment cannot duplicate the polling: a second request for
    // ticks is ignored, so its block never runs.
    __block NSUInteger extraTicks = 0;
    [plugin pluginInstanceAddedToDocument];
    [plugin startHostTicks:^(id<FxCustomParameterActionAPI_v4> action) { extraTicks++; }];
    NSUInteger before = host.starts;
    assert(WaitUntil(^BOOL { return host.starts > before + 1; }));
    assert(extraTicks == 0);

    __weak MagicMovePlugin *weakPlugin = plugin;
    plugin = nil;
    assert(weakPlugin == nil);
    NSUInteger stopped = host.starts;
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    assert(host.starts == stopped && host.starts == host.ends);

    // The host can hand an instance no usable manager at all; every callback
    // must answer with a failure rather than trusting one.
    id<PROAPIAccessing> noManager = nil;
    plugin = [[MagicMovePlugin alloc] initWithAPIManager:noManager];
    assert([plugin createViewForParameterID:UINT32_MAX] == nil);
    assert([plugin classesForCustomParameterID:UINT32_MAX].count == 0);
    FxRect rect = {0};
    NSError *error = nil;
    NSData *state = [NSData data];
    assert(![plugin destinationImageRect:&rect sourceImages:@[] destinationImage:[FxImageTile new]
                             pluginState:state atTime:kCMTimeZero error:&error]);
    assert(error);

    puts("HostLifecycle: detached/attached lifetime, one tick per effect, weak manager, unknown controls and missing input passed");
  }
}
