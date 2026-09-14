/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMShortcut.h"
#import "Constants.h"
#import <ApplicationServices/ApplicationServices.h>
#import <unistd.h>

NSString *MMMotionBlurShortcutKey(void) { return @"m"; }
NSEventModifierFlags MMMotionBlurShortcutModifiers(void) { return NSEventModifierFlagControl | NSEventModifierFlagOption; }
NSString *MMMotionBlurShortcutDisplay(void) { return @"⌃⌥M"; }

// Binding is separate from routing/capture so a settings recorder can replace it.
BOOL MMShortcutMatches(unsigned short code, NSEventModifierFlags flags) {
  NSEventModifierFlags meaningful = NSEventModifierFlagCommand | NSEventModifierFlagControl |
      NSEventModifierFlagOption | NSEventModifierFlagShift | NSEventModifierFlagFunction;
  return code == 46 && (flags & meaningful) == MMMotionBlurShortcutModifiers();
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
@property(nonatomic, weak) id effect;
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
  [self registerOwner:owner effect:owner eligible:eligible action:action];
}
- (void)registerOwner:(id)owner effect:(id)effect eligible:(BOOL (^)(void))eligible action:(BOOL (^)(void))action {
  [self unregisterOwner:owner];
  MMShortcutEntry *entry=[MMShortcutEntry new]; entry.owner=owner; entry.effect=effect; entry.eligible=eligible; entry.action=action;
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
  MMShortcutEntry *only=nil, *active=nil; id soleEffect=nil; BOOL multipleEffects=NO;
  for (MMShortcutEntry *entry in self.entries) {
    id owner=entry.owner;
    id effect=entry.effect;
    if (!owner || !effect || !entry.eligible()) continue;
    if (!soleEffect) { soleEffect=effect; only=entry; }
    else if (effect!=soleEffect) multipleEffects=YES;
    if (owner==self.activeOwner) active=entry;
  }
  MMShortcutEntry *target=active ?: (!multipleEffects ? only : nil);
  if (!target) return NO;
  if (repeat) return YES;
  return target.action();
}
@end

@interface MMMenuHistoryShortcut ()
@property(nonatomic,weak) id owner;
@property(nonatomic,copy) BOOL (^action)(BOOL redo);
@property(nonatomic) NSUInteger generation;
@end
@implementation MMMenuHistoryShortcut
- (BOOL)active { return self.owner != nil && self.action != nil; }
- (void)beginForOwner:(id)owner action:(BOOL (^)(BOOL))action {
  self.generation++; self.owner=owner; self.action=action;
}
- (void)endForOwner:(id)owner {
  if (self.owner != owner) return;
  self.generation++; self.owner=nil; self.action=nil;
}
- (BOOL)enqueueKeyCode:(unsigned short)code modifiers:(NSEventModifierFlags)flags repeat:(BOOL)repeat {
  if (!self.active || code!=6 || !(flags & NSEventModifierFlagCommand) ||
      (flags & (NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagFunction))) return NO;
  if (repeat) return YES;
  NSUInteger generation=self.generation;
  BOOL redo=(flags & NSEventModifierFlagShift)!=0;
  __weak typeof(self) weakSelf=self;
  dispatch_async(dispatch_get_main_queue(), ^{
    MMMenuHistoryShortcut *strong=weakSelf;
    if (!strong.active || strong.generation!=generation) return;
    strong.action(redo);
  });
  return YES;
}
@end

@interface MMShortcutCapture () {
  CFMachPortRef _tap;
  CFRunLoopSourceRef _source;
}
@property(nonatomic, strong) MMShortcutRouter *router;
@property(nonatomic, strong) MMMenuHistoryShortcut *menuHistory;
- (void)ensureCapture;
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
  dispatch_once(&once, ^{ capture=[self new]; capture.router=[MMShortcutRouter new]; capture.menuHistory=[MMMenuHistoryShortcut new]; capture.views=[NSHashTable weakObjectsHashTable]; });
  return capture;
}
- (void)attachView:(NSView *)view action:(BOOL (^)(void))action {
  [self attachView:view effect:view action:action];
}
- (void)attachView:(NSView *)view effect:(id)effect action:(BOOL (^)(void))action {
  [self.views addObject:view];
  __weak NSView *weakView=view;
  [self.router registerOwner:view effect:effect eligible:^BOOL {
    NSView *v=weakView;
    return v && v.window.isVisible && !v.hiddenOrHasHiddenAncestor;
  } action:action];
  [self ensureCapture];
}
- (void)ensureCapture {
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
  if (!self.views.allObjects.count && !self.menuHistory.active) [self stop];
}
- (void)activateView:(NSView *)view { [self.router activateOwner:view]; }
- (void)beginMenuHistory:(id)owner action:(BOOL (^)(BOOL))action {
  [self.menuHistory beginForOwner:owner action:action];
  [self ensureCapture];
}
- (void)endMenuHistory:(id)owner {
  [self.menuHistory endForOwner:owner];
  if (!self.views.allObjects.count && !self.menuHistory.active) [self stop];
}
- (BOOL)handleHostEvent:(CGEventRef)event {
  unsigned short code=(unsigned short)CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode);
  NSEventModifierFlags flags=(NSEventModifierFlags)CGEventGetFlags(event);
  if (CGEventGetIntegerValueField(event,kCGEventTargetUnixProcessID)==getpid() || !MMHostIsFrontmost()) return NO;
  // An explicitly open menu owns history commands, regardless of the host's
  // underlying text focus. Outside that lifetime, normal host routing wins.
  if ([self.menuHistory enqueueKeyCode:code modifiers:flags repeat:CGEventGetIntegerValueField(event,kCGKeyboardEventAutorepeat)!=0]) return YES;
  if (!MMShortcutMatches(code,flags) || MMTextEditorIsFocused()) return NO;
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
