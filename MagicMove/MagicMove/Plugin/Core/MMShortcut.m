/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMShortcut.h"
#import "Constants.h"
#import <ApplicationServices/ApplicationServices.h>
#import <unistd.h>

// Binding is separate from routing/capture so a settings recorder can replace it.
BOOL MMShortcutMatches(unsigned short code, NSEventModifierFlags flags) {
  NSEventModifierFlags meaningful = NSEventModifierFlagCommand | NSEventModifierFlagControl |
      NSEventModifierFlagOption | NSEventModifierFlagShift | NSEventModifierFlagFunction;
  return code == 46 && (flags & meaningful) == (NSEventModifierFlagControl | NSEventModifierFlagOption);
}
BOOL MMToggleMotionBlur(id<PROAPIAccessing> manager, id sender) {
  id<FxCustomParameterActionAPI_v4> action = [manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action) return NO;
  [action startAction:sender];
  @try {
    id<FxParameterRetrievalAPI_v6> get = [manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> set = [manager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    CMTime time = [action currentTime]; BOOL enabled = NO;
    if (!get || !set || !CMTIME_IS_NUMERIC(time) ||
        ![get getBoolValue:&enabled fromParameter:MMMotionBlur atTime:time]) return NO;
    id<FxUndoAPI> undo = [manager apiForProtocol:@protocol(FxUndoAPI)];
    BOOL grouped = [undo startUndoGroup:@"Toggle Motion Blur"];
    @try { return [set setBoolValue:!enabled toParameter:MMMotionBlur atTime:time]; }
    @finally { if (grouped) [undo endUndoGroup]; }
  } @finally { [action endAction:sender]; }
}

@interface MMShortcutEntry : NSObject
@property(nonatomic, weak) id owner;
@property(nonatomic, copy) BOOL (^eligible)(void);
@property(nonatomic, copy) BOOL (^action)(void);
@end
@implementation MMShortcutEntry
@end
@interface MMShortcutRouter ()
@property(nonatomic, strong) NSMutableArray<MMShortcutEntry *> *entries;
@property(nonatomic, weak) id activeOwner;
@end
@implementation MMShortcutRouter
- (instancetype)init { if ((self=[super init])) _entries=[NSMutableArray new]; return self; }
- (void)registerOwner:(id)owner eligible:(BOOL (^)(void))eligible action:(BOOL (^)(void))action {
  [self unregisterOwner:owner];
  MMShortcutEntry *entry=[MMShortcutEntry new]; entry.owner=owner; entry.eligible=eligible; entry.action=action;
  [self.entries addObject:entry];
}
- (void)unregisterOwner:(id)owner {
  NSIndexSet *removed=[self.entries indexesOfObjectsPassingTest:^BOOL(MMShortcutEntry *e, NSUInteger i, BOOL *stop) {
    return !e.owner || e.owner==owner;
  }];
  [self.entries removeObjectsAtIndexes:removed];
  if (self.activeOwner==owner) self.activeOwner=nil;
}
- (void)activateOwner:(id)owner { self.activeOwner=owner; }
- (BOOL)handleKeyCode:(unsigned short)code modifiers:(NSEventModifierFlags)flags repeat:(BOOL)repeat {
  if (!MMShortcutMatches(code,flags)) return NO;
  MMShortcutEntry *only=nil, *active=nil; NSUInteger count=0;
  for (MMShortcutEntry *entry in self.entries) {
    id owner=entry.owner;
    if (!owner || !entry.eligible()) continue;
    only=entry; count++;
    if (owner==self.activeOwner) active=entry;
  }
  MMShortcutEntry *target=active ?: (count==1 ? only : nil);
  if (!target) return NO;
  if (repeat) return YES;
  return target.action();
}
@end

@interface MMShortcutCapture () {
  CFMachPortRef _tap;
  CFRunLoopSourceRef _source;
}
@property(nonatomic, strong) MMShortcutRouter *router;
@property(nonatomic, strong) NSHashTable<NSView *> *views;
@property(nonatomic, strong) id localMonitor;
- (BOOL)handleHostEvent:(CGEventRef)event;
- (void)stop;
- (void)resumeCapture;
@end
static CGEventRef MMCaptureEvent(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
  MMShortcutCapture *capture=(__bridge MMShortcutCapture *)context;
  if (type==kCGEventTapDisabledByTimeout || type==kCGEventTapDisabledByUserInput) {
    [capture resumeCapture]; return event;
  }
  if (type!=kCGEventKeyDown) return event;
  return [capture handleHostEvent:event] ? NULL : event;
}
static BOOL MMHostIsFrontmost(void) {
  NSString *bundle=NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier;
  return [bundle isEqualToString:@"com.apple.FinalCut"] || [bundle isEqualToString:@"com.apple.motionapp"];
}
static BOOL MMTextEditorIsFocused(void) {
  if ([NSApp.keyWindow.firstResponder isKindOfClass:NSTextView.class]) return YES;
  pid_t pid=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
  AXUIElementRef app=AXUIElementCreateApplication(pid);
  CFTypeRef focused=NULL,role=NULL;
  AXError result=AXUIElementCopyAttributeValue(app,kAXFocusedUIElementAttribute,&focused);
  if (result==kAXErrorSuccess && focused)
    result=AXUIElementCopyAttributeValue((AXUIElementRef)focused,kAXRoleAttribute,&role);
  // Unknown focus should not steal a host text command.
  BOOL editing=result!=kAXErrorSuccess || !role || CFEqual(role,kAXTextFieldRole) ||
      CFEqual(role,kAXTextAreaRole) || CFEqual(role,kAXComboBoxRole);
  if (role) CFRelease(role); if (focused) CFRelease(focused); CFRelease(app);
  return editing;
}
@implementation MMShortcutCapture
+ (instancetype)sharedCapture {
  static MMShortcutCapture *capture; static dispatch_once_t once;
  dispatch_once(&once, ^{ capture=[self new]; capture.router=[MMShortcutRouter new]; capture.views=[NSHashTable weakObjectsHashTable]; });
  return capture;
}
- (void)attachView:(NSView *)view action:(BOOL (^)(void))action {
  [self.views addObject:view];
  __weak NSView *weakView=view;
  [self.router registerOwner:view eligible:^BOOL {
    NSView *v=weakView;
    return v && v.window.isVisible && !v.hiddenOrHasHiddenAncestor;
  } action:action];
  if (!self.localMonitor) {
    __weak MMShortcutCapture *weakSelf=self;
    self.localMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
      MMShortcutCapture *s=weakSelf;
      if (!s || [NSApp.keyWindow.firstResponder isKindOfClass:NSTextView.class]) return event;
      return [s.router handleKeyCode:event.keyCode modifiers:event.modifierFlags repeat:event.isARepeat] ? nil : event;
    }];
  }
  if (!_tap) {
    _tap=CGEventTapCreate(kCGSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionDefault,
                          CGEventMaskBit(kCGEventKeyDown),MMCaptureEvent,(__bridge void *)self);
    if (_tap) {
      _source=CFMachPortCreateRunLoopSource(kCFAllocatorDefault,_tap,0);
      if (_source) { CFRunLoopAddSource(CFRunLoopGetMain(),_source,kCFRunLoopCommonModes); CGEventTapEnable(_tap,true); }
      else { CFRelease(_tap); _tap=NULL; }
    }
  }
}
- (void)detachView:(NSView *)view {
  [self.router unregisterOwner:view]; [self.views removeObject:view];
  if (!self.views.allObjects.count) [self stop];
}
- (void)activateView:(NSView *)view { [self.router activateOwner:view]; }
- (BOOL)handleHostEvent:(CGEventRef)event {
  unsigned short code=(unsigned short)CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode);
  NSEventModifierFlags flags=(NSEventModifierFlags)CGEventGetFlags(event);
  if (!MMShortcutMatches(code,flags) || CGEventGetIntegerValueField(event,kCGEventTargetUnixProcessID)==getpid() ||
      !MMHostIsFrontmost() || MMTextEditorIsFocused()) return NO;
  return [self.router handleKeyCode:code modifiers:flags
                            repeat:CGEventGetIntegerValueField(event,kCGKeyboardEventAutorepeat)!=0];
}
- (void)resumeCapture { if (_tap) CGEventTapEnable(_tap,true); }
- (void)stop {
  if (self.localMonitor) { [NSEvent removeMonitor:self.localMonitor]; self.localMonitor=nil; }
  if (_source) { CFRunLoopRemoveSource(CFRunLoopGetMain(),_source,kCFRunLoopCommonModes); CFRelease(_source); _source=NULL; }
  if (_tap) { CGEventTapEnable(_tap,false); CFRelease(_tap); _tap=NULL; }
}
- (void)dealloc { [self stop]; }
@end
