/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMOSCPlayheadNudge.h"
#import "MockHost.h"
@import OSCViewer;

// The viewer's controls hide themselves while the playhead moves and cannot
// request the redraw that brings them back, so the plugin writes the host
// refresh nonce once the playhead settles.
@interface NudgeHost : MockHost <FxCustomParameterActionAPI_v4>
@property CMTime playhead;
@property NSUInteger actions;
@property NSUInteger refreshWrites;
@end
@implementation NudgeHost
- (CMTime)currentTime { return self.playhead; }
- (BOOL)startAction:(id)target { self.actions++; return YES; }
- (BOOL)endAction:(id)target { return YES; }
- (BOOL)setCustomParameterValue:(id)value toParameter:(UInt32)parameter atTime:(CMTime)time {
  if (parameter == MMHostRefreshToken) self.refreshWrites++;
  return [super setCustomParameterValue:value toParameter:parameter atTime:time];
}
@end

static NudgeHost *Host(void) {
  NudgeHost *host = [NudgeHost new];
  host.editors[@(MMShowPositionOSC)] = @YES;
  return host;
}

// Playback then a stop: exactly one nonce, written after the playhead settles
// and not repeated while it stays parked.
static void oneNudgePerStop(void) {
  NudgeHost *host = Host();
  MMOSCPlayheadNudge *nudge = [[MMOSCPlayheadNudge alloc] initWithManager:host];
  host.playhead = TestTime(0);
  assert(![nudge tickInAction:host wall:100]); // baseline
  for (int frame = 1; frame <= 10; ++frame) {
    host.playhead = TestTime(frame / 30.0);
    assert(![nudge tickInAction:host wall:100 + frame * 0.1]);
  }
  assert(host.refreshWrites == 0); // Nothing while it is still moving.
  NSTimeInterval stopped = 100 + 10 * 0.1;
  assert(![nudge tickInAction:host wall:stopped + 0.1]); // inside the window
  assert([nudge tickInAction:host wall:stopped + OSCPlayheadIdleSeconds + 0.01]);
  assert(host.refreshWrites == 1);
  assert(host.undoGroupsStarted == 1 && host.undoGroupsStarted == host.undoGroupsEnded);
  for (int tick = 0; tick < 20; ++tick)
    assert(![nudge tickInAction:host wall:stopped + 1 + tick * 0.1]);
  assert(host.refreshWrites == 1);
}

// A parked playhead on its own never writes: the controls are already drawn,
// and an undo entry per idle tick would be intolerable.
static void parkedPlayheadIsSilent(void) {
  NudgeHost *host = Host();
  MMOSCPlayheadNudge *nudge = [[MMOSCPlayheadNudge alloc] initWithManager:host];
  host.playhead = TestTime(2);
  for (int tick = 0; tick < 40; ++tick)
    assert(![nudge tickInAction:host wall:100 + tick * 0.1]);
  assert(host.refreshWrites == 0 && host.undoGroupsStarted == 0);
}

// With every control switched off the redraw would change nothing, so the
// write is skipped rather than charging an undo entry for no visible effect.
static void noVisibleControlNoWrite(void) {
  NudgeHost *host = Host();
  host.editors[@(MMShowPositionOSC)] = @NO;
  MMOSCPlayheadNudge *nudge = [[MMOSCPlayheadNudge alloc] initWithManager:host];
  host.playhead = TestTime(0);
  assert(![nudge tickInAction:host wall:100]);
  host.playhead = TestTime(1);
  assert(![nudge tickInAction:host wall:100.1]);
  assert(![nudge tickInAction:host wall:100.5]);
  assert(host.refreshWrites == 0 && host.undoGroupsStarted == 0);
  // Any one control being on is enough.
  host.editors[@(MMShowAnchorOSC)] = @YES;
  host.playhead = TestTime(2);
  assert(![nudge tickInAction:host wall:100.6]);
  assert([nudge tickInAction:host wall:101.1]);
  assert(host.refreshWrites == 1);
}

// A scrub that ends on the frame it started from still settles, and an
// unusable host time is ignored rather than counted as a stop.
static void scrubAndUnusableTime(void) {
  NudgeHost *host = Host();
  MMOSCPlayheadNudge *nudge = [[MMOSCPlayheadNudge alloc] initWithManager:host];
  host.playhead = TestTime(1);
  assert(![nudge tickInAction:host wall:100]);
  host.playhead = TestTime(3);
  assert(![nudge tickInAction:host wall:100.1]);
  host.playhead = TestTime(1);
  assert(![nudge tickInAction:host wall:100.2]);
  host.playhead = kCMTimeInvalid;
  assert(![nudge tickInAction:host wall:100.6]);
  assert(host.refreshWrites == 0); // The invalid tick decided nothing.
  host.playhead = TestTime(1);
  assert([nudge tickInAction:host wall:100.7]);
  assert(host.refreshWrites == 1);
}

// No action API, no write: the nudge must not touch parameters outside a host
// action scope, where the setting API is ignored.
static void missingActionIsSafe(void) {
  NudgeHost *host = Host();
  MMOSCPlayheadNudge *nudge = [[MMOSCPlayheadNudge alloc] initWithManager:host];
  id<FxCustomParameterActionAPI_v4> absent = nil;
  assert(![nudge tickInAction:absent wall:100]);
  assert(host.refreshWrites == 0);
}

int main(void) {
  @autoreleasepool {
    oneNudgePerStop();
    parkedPlayheadIsSilent();
    noVisibleControlNoWrite();
    scrubAndUnusableTime();
    missingActionIsSafe();
    puts("OSC nudge: one write per stop, silent while parked, gated on a visible control passed");
  }
  return 0;
}
