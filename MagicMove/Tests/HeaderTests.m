/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMInspectorHeader.h"
#import "Constants.h"
#import "MockHost.h"
#import "Plugin_Private.h"
#import "MMShortcut.h"
#import "MMDefaults.h"
@interface MMInspectorHeader (Testing)
- (KFShortcutCapture *)shortcutCapture;
- (BOOL)toggleSetting:(UInt32)parameter;
- (BOOL)writeBlurSetting:(UInt32)parameter value:(NSInteger)value;
@end
@interface HeaderHost : MockHost <FxCustomParameterActionAPI_v4>
@property NSUInteger starts;
@property NSUInteger ends;
@property BOOL failWrite;
@end
@implementation HeaderHost
- (id)apiForProtocol:(Protocol *)protocol {
  if([self.missingProtocols containsObject:NSStringFromProtocol(protocol)]) return nil;
  if(protocol==@protocol(FxCustomParameterActionAPI_v4)) return self;
  return [super apiForProtocol:protocol];
}
- (void)startAction:(id)sender { self.starts++; }
- (void)endAction:(id)sender { self.ends++; }
- (CMTime)currentTime { return TestTime(1); }
- (BOOL)setIntValue:(int)value toParameter:(UInt32)parameter atTime:(CMTime)time {
  return !self.failWrite && [super setIntValue:value toParameter:parameter atTime:time];
}
- (BOOL)setBoolValue:(BOOL)value toParameter:(UInt32)parameter atTime:(CMTime)time {
  return !self.failWrite && [super setBoolValue:value toParameter:parameter atTime:time];
}
@end
// Test the production header lifecycle against the real router without installing
// a system-wide event tap or requiring host input permissions.
@interface HeaderTestCapture : KFShortcutCapture
@property(nonatomic,strong) KFShortcutRouter *testRouter;
@end
@implementation HeaderTestCapture
- (instancetype)init { if((self=[super init])) _testRouter=[KFShortcutRouter new]; return self; }
- (void)attachView:(NSView *)view effect:(id)effect action:(BOOL (^)(void))action {
  __weak NSView *weakView=view;
  [self.testRouter registerOwner:view effect:effect eligible:^BOOL {
    return weakView.window.isVisible && !weakView.hiddenOrHasHiddenAncestor;
  } action:action];
}
- (void)detachView:(NSView *)view { [self.testRouter unregisterOwner:view]; }
- (void)activateView:(NSView *)view { [self.testRouter activateOwner:view]; }
@end
@interface RoutingHeader : MMInspectorHeader
@property(nonatomic,strong) HeaderTestCapture *testCapture;
@end
@implementation RoutingHeader
- (KFShortcutCapture *)shortcutCapture { return self.testCapture; }
@end
@interface HeaderTestWindow : NSWindow
@end
@implementation HeaderTestWindow
- (BOOL)isVisible { return YES; }
@end
// Wait for queued UI actions deterministically, rather than assuming a 10ms
// slice is enough during cold AppKit startup and concurrent build activity.
static void DrainHeaderActions(void) {
  __block BOOL drained=NO;
  dispatch_async(dispatch_get_main_queue(), ^{ drained=YES; });
  NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:1];
  while(!drained && deadline.timeIntervalSinceNow>0)
    CFRunLoopRunInMode(kCFRunLoopDefaultMode,.01,false);
  assert(drained);
}
static void testClosedMenuRouting(void) {
  HeaderTestCapture *capture=[HeaderTestCapture new];
  HeaderHost *a=[HeaderHost new], *b=[HeaderHost new];
  RoutingHeader *first=[[RoutingHeader alloc] initWithManager:a]; first.testCapture=capture;
  RoutingHeader *second=[[RoutingHeader alloc] initWithManager:b]; second.testCapture=capture;
  NSWindow *window=[[HeaderTestWindow alloc] initWithContentRect:NSMakeRect(0,0,640,100) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
  [window.contentView addSubview:first];
  NSView *propertyRow=[NSView new]; [window.contentView addSubview:propertyRow];
  __block NSUInteger rowCalls=0;
  [capture attachView:propertyRow effect:a action:^BOOL { rowCalls++; return YES; }];
  assert([capture.testRouter handleKeyCode:46 modifiers:MMMotionBlurShortcutModifiers() repeat:NO]);
  DrainHeaderActions();
  assert([a.editors[@(MMMotionBlur)] boolValue] && rowCalls==0);
  [a setBoolValue:NO toParameter:MMMotionBlur atTime:TestTime(1)];
  [capture detachView:propertyRow]; [propertyRow removeFromSuperview];
  [window.contentView addSubview:second];
  // Clear the active row left by executing the initial toggle, simulating no selection click.
  [capture.testRouter activateOwner:nil];
  NSEventModifierFlags flags=MMMotionBlurShortcutModifiers();
  assert(![capture.testRouter handleKeyCode:46 modifiers:flags repeat:NO]); // No guessed effect.
  [first settingsMenu]; // Header interaction activates its route; no menu is open.
  NSUInteger before=a.hostWrites;
  assert([capture.testRouter handleKeyCode:46 modifiers:flags repeat:NO]);
  assert(a.hostWrites==before); // Remote work is deferred out of the input callback.
  DrainHeaderActions();
  assert([a.editors[@(MMMotionBlur)] boolValue] && b.hostWrites==0);
  before=a.hostWrites;
  assert([capture.testRouter handleKeyCode:46 modifiers:flags repeat:YES]);
  DrainHeaderActions(); assert(a.hostWrites==before);
  [second motionBlurMenu];
  assert([capture.testRouter handleKeyCode:46 modifiers:flags repeat:NO]);
  DrainHeaderActions();
  assert([b.editors[@(MMMotionBlur)] boolValue] && a.hostWrites==before);
  [first.accessoryButtons.firstObject performClick:nil]; // Left-click activates too.
  assert(![a.editors[@(MMMotionBlur)] boolValue]);
  assert([capture.testRouter handleKeyCode:46 modifiers:flags repeat:NO]);
  before=a.hostWrites;
  [first removeFromSuperview]; // A queued shortcut must not edit a detached effect.
  DrainHeaderActions(); assert(a.hostWrites==before);
  [second removeFromSuperview];
  assert(![capture.testRouter handleKeyCode:46 modifiers:flags repeat:NO]);
  assert(a.starts==a.ends && b.starts==b.ends);
}
int main(void) { @autoreleasepool {
  [NSApplication sharedApplication];
  testClosedMenuRouting();
  HeaderHost *host=[HeaderHost new];
  MagicMovePlugin *plugin=[[MagicMovePlugin alloc] initWithAPIManager:host];
  host.plugin=plugin; assert([plugin addParametersWithError:NULL]);
  MMInspectorHeader *view=[[MMInspectorHeader alloc] initWithManager:host];
  NSMenu *menu=[view settingsMenu];
  assert(menu.numberOfItems==7);
  assert([menu.itemArray[0].title isEqual:@"Explicit Keyframe Editing"]);
  assert([menu.itemArray[0].subtitle isEqual:@"Prevents automatic keyframe creation when changing values."]);
  assert(menu.itemArray[1].isSeparatorItem && menu.itemArray[2].isSectionHeader);
  assert([menu.itemArray[3].title isEqual:@"Position Box"] && [menu.itemArray[4].title isEqual:@"Scale Handles"] &&
         [menu.itemArray[5].title isEqual:@"Rotation Rings"] && [menu.itemArray[6].title isEqual:@"Anchor Point"]);
  // Visibility starts from the stored preference, so compare against the host.
  BOOL showScale=NO;
  assert(KFReadBoolSetting(host,view,MMShowScaleOSC,&showScale));
  assert(menu.itemArray[4].state==(showScale ? NSControlStateValueOn:NSControlStateValueOff));
  assert(MMReadOSCVisibilityDefault(MMShowScaleOSC)==showScale);
  // Menu actions leave tracking first, like every other host write here.
  NSUInteger visibilityWrites=host.hostWrites;
  [menu performActionForItemAtIndex:4];
  assert(host.hostWrites==visibilityWrites);
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
  assert([host.editors[@(MMShowScaleOSC)] boolValue]==!showScale);
  // The toggle is the default for the next effect; no separate preference UI.
  assert(MMReadOSCVisibilityDefault(MMShowScaleOSC)==!showScale);
  assert([view settingsMenu].itemArray[4].state==(!showScale ? NSControlStateValueOn:NSControlStateValueOff));
  assert([host.blobs[@(MMHostRefreshToken)] length]>0);
  assert(MMSaveOSCVisibilityDefault(MMShowScaleOSC,showScale));
  NSEvent *rightClick=[NSEvent mouseEventWithType:NSEventTypeRightMouseDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil eventNumber:1 clickCount:1 pressure:1];
  NSMenu *blurMenu=[view.accessoryButtons.firstObject menuForEvent:rightClick];
  assert(blurMenu.numberOfItems==4);
  NSMenuItem *blur=blurMenu.itemArray.firstObject;
  assert(blur.tag==MMMotionBlur && blur.offStateImage==nil && blur.view==nil);
  assert(blurMenu.itemArray[2].view==nil && blurMenu.itemArray[2].submenu!=nil);
  assert(blurMenu.itemArray[3].view==nil && blurMenu.itemArray[3].submenu!=nil);
  assert(menu.itemArray.firstObject.tag==MMExplicitCreation);
  assert([blur.keyEquivalent isEqual:@"m"]);
  assert(blur.keyEquivalentModifierMask==(NSEventModifierFlagControl|NSEventModifierFlagOption));
  [blurMenu.delegate menuWillOpen:blurMenu];
  assert(MMToggleMotionBlur(host,view));
  DrainHeaderActions();
  assert(blur.state==NSControlStateValueOn);
  assert(MMToggleMotionBlur(host,view));
  DrainHeaderActions();
  assert(blur.state==NSControlStateValueOff);
  KFPropertyMenuActionScheduled(blurMenu);
  [blurMenu.delegate menuDidClose:blurMenu];
  NSUInteger groups=host.undoGroupsStarted;
  assert([view toggleSetting:MMMotionBlur]);
  assert(host.undoGroupsStarted==groups+1 && host.undoGroupsStarted==host.undoGroupsEnded);
  assert([host.editors[@(MMMotionBlur)] boolValue]);
  assert([host.blobs[@(MMHostRefreshToken)] length]>0);
  [view refreshSettings]; assert(view.accessoryButtons.firstObject.state==NSControlStateValueOn);
  assert([view.accessoryButtons.firstObject menuForEvent:rightClick].itemArray.firstObject.state==NSControlStateValueOn);
  // External changes (including host undo) are read back, never guessed locally.
  [host setBoolValue:NO toParameter:MMMotionBlur atTime:TestTime(1)];
  [view refreshSettings]; assert(view.accessoryButtons.firstObject.state==NSControlStateValueOff);
  assert([view toggleSetting:MMExplicitCreation]);
  assert([view settingsMenu].itemArray[0].state==NSControlStateValueOn);
  // Menu actions must leave tracking before host writes, then wake without input.
  NSMenu *changedMenu=[view settingsMenu];
  NSUInteger writes=host.hostWrites;
  [changedMenu performActionForItemAtIndex:0];
  assert(host.hostWrites==writes);
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
  assert(![host.editors[@(MMExplicitCreation)] boolValue]);
  assert([view toggleSetting:MMExplicitCreation]);
  // Numeric options remain editable with blur off and use the same deferred host action.
  NSMenu *options=[view motionBlurMenu];
  NSMenu *samples=options.itemArray[2].submenu;
  assert(samples.numberOfItems==7 && samples.itemArray[3].state==NSControlStateValueOn);
  groups=host.undoGroupsStarted; writes=host.hostWrites;
  [samples performActionForItemAtIndex:4]; // 32 samples
  assert(host.hostWrites==writes);
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
  assert([host.editors[@(MMMotionBlurSamples)] intValue]==32);
  assert(![host.editors[@(MMMotionBlur)] boolValue]);
  assert(host.undoGroupsStarted==groups+1 && host.undoGroupsStarted==host.undoGroupsEnded);
  assert([view motionBlurMenu].itemArray[2].submenu.itemArray[4].state==NSControlStateValueOn);
  assert([view writeBlurSetting:MMMotionBlurShutterAngle value:0]);
  assert([view motionBlurMenu].itemArray[3].submenu.itemArray[0].state==NSControlStateValueOn);
  assert(![view writeBlurSetting:MMMotionBlurSamples value:1]);
  assert(![view writeBlurSetting:MMMotionBlurSamples value:129]);
  assert(![view writeBlurSetting:MMMotionBlurShutterAngle value:361]);
  assert(![view writeBlurSetting:MMMotionBlur value:10]);
  host.failWrite=YES;
  assert(![view writeBlurSetting:MMMotionBlurSamples value:64]);
  assert([host.editors[@(MMMotionBlurSamples)] intValue]==32);
  assert(![view toggleSetting:MMExplicitCreation]);
  assert([view settingsMenu].itemArray[0].state==NSControlStateValueOn);
  host.failReadParameter=MMMotionBlurSamples;
  for(NSMenuItem *choice in [view motionBlurMenu].itemArray[2].submenu.itemArray) assert(!choice.enabled);
  host.failReadParameter=MMMotionBlur;
  [view refreshSettings]; assert(!view.accessoryButtons.firstObject.enabled);
  assert(![view toggleSetting:MMMotionBlur]);
  assert(host.starts==host.ends && host.undoDepth==0);
  assert(![view toggleSetting:MMMotionBlurSamples]);
  NSLog(@"HeaderTests passed");
} return 0; }
