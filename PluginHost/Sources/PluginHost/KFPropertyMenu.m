/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFPropertyMenu.h"
#import "KFHostSettings.h"
#import "KFShortcut.h"
@import InspectorControls;

static NSString *const KFMenuParametersChanged=@"KFMenuParametersChanged";

@interface KFPropertyMenu : ICContextMenu <NSMenuDelegate>
@property(nonatomic,strong) id<PROAPIAccessing> manager;
@property(nonatomic,weak) NSView *sender;
@property(nonatomic) BOOL actionScheduled;
@property(nonatomic) BOOL tracking;
@property(nonatomic,strong) id eventMonitor;
@property(nonatomic,strong) id parameterObserver;
@property(nonatomic,copy) void (^stateHandler)(void);
- (void)refreshHost;
- (BOOL)performHistoryRedo:(BOOL)redo;
- (void)refreshMenuState;
@end
@implementation KFPropertyMenu
- (void)menuWillOpen:(NSMenu *)menu {
  self.actionScheduled=NO; self.tracking=YES;
  if (self.eventMonitor) [NSEvent removeMonitor:self.eventMonitor];
  __weak typeof(self) weakSelf=self;
  if (self.parameterObserver) [NSNotificationCenter.defaultCenter removeObserver:self.parameterObserver];
  self.parameterObserver=[NSNotificationCenter.defaultCenter addObserverForName:KFMenuParametersChanged object:self.manager queue:nil usingBlock:^(NSNotification *note) {
    // Never block a host callback thread waiting for the menu/main thread.
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf refreshMenuState]; });
  }];
  [[KFShortcutCapture sharedCapture] beginMenuHistory:self action:^BOOL(BOOL redo) {
    return [weakSelf performHistoryRedo:redo];
  }];
  self.eventMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
    KFPropertyMenu *strong=weakSelf;
    if (!strong || !strong.tracking) return event;
    if (event.type==NSEventTypeKeyDown && [strong performKeyEquivalent:event]) return nil;
    return event;
  }];
}
- (void)dealloc {
  if (_eventMonitor) [NSEvent removeMonitor:_eventMonitor];
  if (_parameterObserver) [NSNotificationCenter.defaultCenter removeObserver:_parameterObserver];
}
- (void)refreshMenuState {
  if (!self.tracking || !self.stateHandler || !self.sender) return;
  NSView *view=self.sender;
  id<FxCustomParameterActionAPI_v4> action=[self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action) return;
  [action startAction:view];
  @try { self.stateHandler(); }
  @finally { [action endAction:view]; }
}
- (BOOL)performKeyEquivalent:(NSEvent *)event {
  NSEventModifierFlags flags=event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  BOOL history=self.tracking && event.type==NSEventTypeKeyDown &&
      [event.charactersIgnoringModifiers.lowercaseString isEqualToString:@"z"] &&
      (flags & NSEventModifierFlagCommand) &&
      !(flags & (NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagFunction));
  if (!history) return [super performKeyEquivalent:event];
  return [self performHistoryRedo:(flags & NSEventModifierFlagShift)!=0];
}
- (BOOL)performHistoryRedo:(BOOL)redo {
  if (!self.tracking) return NO;
  NSView *view=self.sender;
  id<FxCustomParameterActionAPI_v4> action=[self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!view || !action) return NO;
  BOOL ok=NO; NSError *error=nil;
  [action startAction:view];
  @try {
    id<FxCommandAPI_v2> command=[self.manager apiForProtocol:@protocol(FxCommandAPI_v2)];
    ok=[command performCommand:redo ? kFxCommand_Redo : kFxCommand_Undo error:&error];
    if (command) {
      // Some hosts return NO while applying undo asynchronously. Treat dispatch
      // as handled, then follow published parameter callbacks for final state.
      // Do not write the scratch parameter here: a new edit could clear redo.
      self.actionScheduled=YES;
      if (self.stateHandler) self.stateHandler();
    }
    if (command) ok=YES; // Avoid forwarding an already-dispatched undo twice.
  } @finally { [action endAction:view]; }
  return ok;
}
- (void)menuDidClose:(NSMenu *)menu {
  self.tracking=NO;
  if (self.parameterObserver) {
    [NSNotificationCenter.defaultCenter removeObserver:self.parameterObserver]; self.parameterObserver=nil;
  }
  [[KFShortcutCapture sharedCapture] endMenuHistory:self];
  if (self.eventMonitor) { [NSEvent removeMonitor:self.eventMonitor]; self.eventMonitor=nil; }
  // AppKit can deliver the action after didClose. Decide in the normal loop,
  // after the synchronous menu callbacks have finished selecting an action.
  CFRunLoopPerformBlock(CFRunLoopGetMain(),kCFRunLoopDefaultMode,^{
    if(!self.actionScheduled) [self refreshHost];
  });
  CFRunLoopWakeUp(CFRunLoopGetMain());
}
- (void)refreshHost {
  NSView *view=self.sender; if(!view) return;
  id<FxCustomParameterActionAPI_v4> action=[self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if(!action) return;
  [action startAction:view];
  @try {
    KFRequestHostRefresh(self.manager,[action currentTime]);
  } @finally { [action endAction:view]; }
}
@end
NSMenu *KFCreatePropertyMenu(id<PROAPIAccessing> manager, NSView *sender) {
  KFPropertyMenu *menu=[KFPropertyMenu new];
  menu.manager=manager; menu.sender=sender; menu.delegate=menu;
  return menu;
}
void KFPropertyMenuParametersChanged(id<PROAPIAccessing> manager) {
  [NSNotificationCenter.defaultCenter postNotificationName:KFMenuParametersChanged object:manager];
}
void KFPropertyMenuSetStateHandler(NSMenu *menu, void (^handler)(void)) {
  if ([menu isKindOfClass:KFPropertyMenu.class]) ((KFPropertyMenu *)menu).stateHandler=handler;
}
void KFPropertyMenuActionScheduled(NSMenu *menu) {
  if([menu isKindOfClass:KFPropertyMenu.class]) { ((KFPropertyMenu *)menu).actionScheduled=YES; }
}
void KFPropertyMenuActionFinished(NSMenu *menu,BOOL refreshed) {
  if(!refreshed && [menu isKindOfClass:KFPropertyMenu.class]) [(KFPropertyMenu *)menu refreshHost];
}
