/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */

#import "MMShortcut.h"
#import "Constants.h"
#import "MockHost.h"

@interface ShortcutHost : MockHost <FxCustomParameterActionAPI_v4>
@property(nonatomic) NSUInteger actionsStarted;
@property(nonatomic) NSUInteger actionsEnded;
@property(nonatomic) CMTime actionTime;
@property(nonatomic) CMTime lastWriteTime;
@property(nonatomic) BOOL throwOnWrite;
@property(nonatomic) BOOL failWrite;
@end

@implementation ShortcutHost
- (id)apiForProtocol:(Protocol *)protocol {
  if ([self.missingProtocols containsObject:NSStringFromProtocol(protocol)]) return nil;
  if (protocol == @protocol(FxCustomParameterActionAPI_v4) ||
      protocol == @protocol(FxParameterRetrievalAPI_v6) ||
      protocol == @protocol(FxParameterSettingAPI_v5) ||
      protocol == @protocol(FxUndoAPI)) return self;
  return [super apiForProtocol:protocol];
}
- (void)startAction:(id)sender { self.actionsStarted++; }
- (void)endAction:(id)sender { self.actionsEnded++; }
- (CMTime)currentTime { return self.actionTime; }
- (BOOL)setBoolValue:(BOOL)value toParameter:(UInt32)parameter atTime:(CMTime)time {
  self.lastWriteTime = time;
  if (self.throwOnWrite) @throw [NSException exceptionWithName:@"ShortcutTestException"
                                                        reason:@"setter failure"
                                                      userInfo:nil];
  if (self.failWrite) return NO;
  return [super setBoolValue:value toParameter:parameter atTime:time];
}
@end


static void testShortcutMatching(void) {
  NSEventModifierFlags required = NSEventModifierFlagControl | NSEventModifierFlagOption;
  assert(MMShortcutMatches(46, required));
  assert(MMShortcutMatches(46, required | NSEventModifierFlagCapsLock));

  assert(!MMShortcutMatches(45, required));
  assert(!MMShortcutMatches(46, NSEventModifierFlagControl));
  assert(!MMShortcutMatches(46, required | NSEventModifierFlagCommand));
  assert(!MMShortcutMatches(46, required | NSEventModifierFlagShift));
  assert(!MMShortcutMatches(46, required | NSEventModifierFlagFunction));
}

static void testMotionBlurToggle(void) {
  ShortcutHost *host = [ShortcutHost new];
  host.actionTime = TestTime(3.25);
  host.editors[@(MMMotionBlur)] = @NO;
  NSUInteger writes = host.hostWrites;
  assert(MMToggleMotionBlur(host, host));
  assert([host.editors[@(MMMotionBlur)] boolValue]);
  assert(host.hostWrites == writes + 1);
  assert(host.actionsStarted == 1 && host.actionsEnded == 1);
  assert(host.undoGroupsStarted == 1 && host.undoGroupsEnded == 1 && host.undoDepth == 0);
  assert(CMTimeCompare(host.lastWriteTime, host.actionTime) == 0);

  host.actionTime = TestTime(6.5);
  assert(MMToggleMotionBlur(host, host));
  assert(![host.editors[@(MMMotionBlur)] boolValue]);
  assert(host.actionsStarted == 2 && host.actionsEnded == 2);
  assert(host.undoGroupsStarted == 2 && host.undoGroupsEnded == 2 && host.undoDepth == 0);
  assert(CMTimeCompare(host.lastWriteTime, host.actionTime) == 0);
}

static void testMotionBlurReadFailureAndExceptionBalance(void) {
  ShortcutHost *host = [ShortcutHost new];
  host.actionTime = TestTime(2.0);
  host.editors[@(MMMotionBlur)] = @YES;
  host.failReadParameter = MMMotionBlur;
  NSUInteger writes = host.hostWrites;
  assert(!MMToggleMotionBlur(host, host));
  assert(host.hostWrites == writes);
  assert(host.actionsStarted == 1 && host.actionsEnded == 1);
  assert(host.undoGroupsStarted == 0 && host.undoGroupsEnded == 0);

  host.failReadParameter = 0;
  host.failWrite = YES;
  writes = host.hostWrites;
  assert(!MMToggleMotionBlur(host, host));
  assert(host.hostWrites == writes);
  assert(host.actionsStarted == 2 && host.actionsEnded == 2);
  assert(host.undoGroupsStarted == 1 && host.undoGroupsEnded == 1 && host.undoDepth == 0);

  host.failWrite = NO;
  host.missingProtocols = [NSSet setWithObject:NSStringFromProtocol(@protocol(FxParameterSettingAPI_v5))];
  writes = host.hostWrites;
  assert(!MMToggleMotionBlur(host, host));
  assert(host.hostWrites == writes);
  assert(host.actionsStarted == 3 && host.actionsEnded == 3);
  assert(host.undoGroupsStarted == 1 && host.undoGroupsEnded == 1);
}

int main(void) {
  @autoreleasepool {
    testShortcutMatching();
    testMotionBlurToggle();
    testMotionBlurReadFailureAndExceptionBalance();
    puts("Motion blur shortcut: physical matching, toggle, read failure and action balancing passed");
  }
}
