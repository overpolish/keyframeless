/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MockHost.h"

// Hidden bool settings all take the same host path: read and toggle inside one
// action, the write in a named undo group, then the refresh token so the host
// repaints at a stationary playhead.
enum { TestSetting = 1042, TestPreferenceSetting = 1050, TestHostRefreshToken = 1060 };

@interface SettingsHost : MockHost <FxCustomParameterActionAPI_v4>
@property NSUInteger starts;
@property NSUInteger ends;
@property BOOL failWrite;
@property CMTime actionTime;
@end
@implementation SettingsHost
- (id)apiForProtocol:(Protocol *)protocol {
  if ([self.missingProtocols containsObject:NSStringFromProtocol(protocol)]) return nil;
  if (protocol == @protocol(FxCustomParameterActionAPI_v4)) return self;
  return [super apiForProtocol:protocol];
}
- (void)startAction:(id)sender { self.starts++; }
- (void)endAction:(id)sender { self.ends++; }
- (CMTime)currentTime { return self.actionTime; }
- (BOOL)setBoolValue:(BOOL)value toParameter:(UInt32)parameter atTime:(CMTime)time {
  return !self.failWrite && [super setBoolValue:value toParameter:parameter atTime:time];
}
@end

static SettingsHost *Host(void) {
  SettingsHost *host = [SettingsHost new];
  host.actionTime = TestTime(2);
  host.editors[@(TestSetting)] = @NO;
  host.editors[@(TestPreferenceSetting)] = @YES;
  return host;
}

static void readAndToggleInsideOneAction(void) {
  SettingsHost *host = Host();
  NSView *sender = [NSView new];
  BOOL value = YES;
  assert(KFReadBoolSetting(host, sender, TestSetting, &value) && !value);
  assert(host.starts == 1 && host.ends == 1);
  // A read never writes and never charges an undo entry.
  assert(host.hostWrites == 0 && host.undoGroupsStarted == 0);

  assert(KFToggleBoolSetting(host, sender, TestSetting, @"Toggle Test Setting"));
  assert([host.editors[@(TestSetting)] boolValue]);
  assert(host.starts == 2 && host.ends == 2);
  assert(host.undoGroupsStarted == 1 && host.undoGroupsEnded == 1 && host.undoDepth == 0);
  // The refresh token is written inside the same group, so one undo entry
  // covers both the setting and the repaint.
  assert([host.blobs[@(TestHostRefreshToken)] length] > 0);
}

static void preferenceWriterRecordsTheNewValue(void) {
  SettingsHost *host = Host();
  NSView *sender = [NSView new];
  __block UInt32 recordedParameter = 0;
  __block BOOL recordedValue = NO;
  __block NSUInteger records = 0;
  KFSetBoolSettingPreferenceWriter(^(UInt32 parameter, BOOL value) {
    recordedParameter = parameter;
    recordedValue = value;
    records++;
  });
  assert(KFToggleBoolSetting(host, sender, TestPreferenceSetting, @"Toggle Preference"));
  assert(records == 1 && recordedParameter == TestPreferenceSetting && recordedValue == NO);

  // A failed write must not record a preference the document does not carry.
  host.failWrite = YES;
  assert(!KFToggleBoolSetting(host, sender, TestPreferenceSetting, @"Toggle Preference"));
  assert(records == 1);
  host.failWrite = NO;
  KFSetBoolSettingPreferenceWriter(nil);
}

static void failurePathsBalanceTheAction(void) {
  SettingsHost *host = Host();
  NSView *sender = [NSView new];
  BOOL value = NO;

  host.failReadParameter = TestSetting;
  assert(!KFReadBoolSetting(host, sender, TestSetting, &value));
  assert(!KFToggleBoolSetting(host, sender, TestSetting, @"Toggle Test Setting"));
  assert(host.hostWrites == 0 && host.undoGroupsStarted == 0);
  host.failReadParameter = 0;

  host.failWrite = YES;
  assert(!KFToggleBoolSetting(host, sender, TestSetting, @"Toggle Test Setting"));
  assert(![host.editors[@(TestSetting)] boolValue]);
  assert(host.undoGroupsStarted == 1 && host.undoGroupsEnded == 1 && host.undoDepth == 0);
  host.failWrite = NO;

  // An unusable host time decides nothing; neither does a missing setting API.
  host.actionTime = kCMTimeInvalid;
  assert(!KFToggleBoolSetting(host, sender, TestSetting, @"Toggle Test Setting"));
  host.actionTime = TestTime(2);
  host.missingProtocols =
      [NSSet setWithObject:NSStringFromProtocol(@protocol(FxParameterSettingAPI_v5))];
  assert(!KFToggleBoolSetting(host, sender, TestSetting, @"Toggle Test Setting"));
  host.missingProtocols = nil;
  assert(host.starts == host.ends);

  // Without an action API nothing may be read or written at all.
  host.missingProtocols =
      [NSSet setWithObject:NSStringFromProtocol(@protocol(FxCustomParameterActionAPI_v4))];
  NSUInteger starts = host.starts;
  assert(!KFReadBoolSetting(host, sender, TestSetting, &value));
  assert(!KFToggleBoolSetting(host, sender, TestSetting, @"Toggle Test Setting"));
  assert(host.starts == starts && host.hostWrites == 0);
}

static void menuItemStateFollowsTheHost(void) {
  SettingsHost *host = Host();
  NSView *sender = [NSView new];
  NSMenu *menu = [NSMenu new];
  // Production menus manage their own enabled state, like the real ones.
  menu.autoenablesItems = NO;
  NSMenuItem *item = KFSettingMenuItem(host, sender, TestSetting, @"Test Setting", @"Toggle Test Setting");
  [menu addItem:item];
  // The item ships disabled: its state is unknown until an action is open.
  assert(!item.enabled && [item.title isEqual:@"Test Setting"]);
  KFRefreshSettingMenuItems(menu, host, sender);
  assert(item.enabled && item.state == NSControlStateValueOff);

  host.editors[@(TestSetting)] = @YES;
  KFRefreshSettingMenuItems(menu, host, sender);
  assert(item.state == NSControlStateValueOn);

  // An unreadable setting is shown disabled rather than guessed.
  host.failReadParameter = TestSetting;
  KFRefreshSettingMenuItems(menu, host, sender);
  assert(!item.enabled);
  host.failReadParameter = 0;

  // Activating the item leaves menu tracking before touching the host.
  host.editors[@(TestSetting)] = @NO;
  KFRefreshSettingMenuItems(menu, host, sender);
  assert(item.enabled && item.state == NSControlStateValueOff);
  NSUInteger writes = host.hostWrites;
  [menu performActionForItemAtIndex:0];
  assert(host.hostWrites == writes);
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1];
  while (host.hostWrites == writes && deadline.timeIntervalSinceNow > 0)
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
  assert([host.editors[@(TestSetting)] boolValue]);
  assert(host.starts == host.ends);
}

static void refreshNeedsARegisteredTokenAndUsableTime(void) {
  SettingsHost *host = Host();
  assert(KFRequestHostRefresh(host, TestTime(1)));
  assert(!KFRequestHostRefresh(host, kCMTimeInvalid));
  KFSetHostRefreshParameter(0);
  assert(!KFRequestHostRefresh(host, TestTime(1)));
  KFSetHostRefreshParameter(TestHostRefreshToken);
}

int main(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    KFSetHostRefreshParameter(TestHostRefreshToken);
    readAndToggleInsideOneAction();
    preferenceWriterRecordsTheNewValue();
    failurePathsBalanceTheAction();
    menuItemStateFollowsTheHost();
    refreshNeedsARegisteredTokenAndUsableTime();
    puts("Host settings: one action per read and toggle, undo grouping, preference writer, menu state and failure balance passed");
  }
  return 0;
}
