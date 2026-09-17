/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFShortcut.h"
#import <ApplicationServices/ApplicationServices.h>
#import <unistd.h>

// Routing has to know which combination it answers to, but not what it means:
// the plugin registers its own binding.
static BOOL (^KFShortcutBinding)(unsigned short code, NSEventModifierFlags flags);
void KFSetShortcutMatcher(BOOL (^matcher)(unsigned short code, NSEventModifierFlags flags)) {
  KFShortcutBinding = [matcher copy];
}
static BOOL KFShortcutMatches(unsigned short code, NSEventModifierFlags flags) {
  return KFShortcutBinding ? KFShortcutBinding(code, flags) : NO;
}

@interface KFShortcutEntry : NSObject
@property(nonatomic, weak) id owner;
@property(nonatomic, weak) id effect;
@property(nonatomic, copy) BOOL (^eligible)(void);
@property(nonatomic, copy) BOOL (^action)(void);
@end
@implementation KFShortcutEntry
@end
@interface KFShortcutRouter ()
@property(nonatomic, strong) NSMutableArray<KFShortcutEntry *> *entries;
@property(nonatomic, weak) id activeOwner;
@end
@implementation KFShortcutRouter
- (instancetype)init { if ((self=[super init])) _entries=[NSMutableArray new]; return self; }
- (void)registerOwner:(id)owner eligible:(BOOL (^)(void))eligible action:(BOOL (^)(void))action {
  [self registerOwner:owner effect:owner eligible:eligible action:action];
}
- (void)registerOwner:(id)owner effect:(id)effect eligible:(BOOL (^)(void))eligible action:(BOOL (^)(void))action {
  [self unregisterOwner:owner];
  KFShortcutEntry *entry=[KFShortcutEntry new]; entry.owner=owner; entry.effect=effect; entry.eligible=eligible; entry.action=action;
  [self.entries addObject:entry];
}
- (void)unregisterOwner:(id)owner {
  NSIndexSet *removed=[self.entries indexesOfObjectsPassingTest:^BOOL(KFShortcutEntry *e, NSUInteger i, BOOL *stop) {
    return !e.owner || e.owner==owner;
  }];
  [self.entries removeObjectsAtIndexes:removed];
  if (self.activeOwner==owner) self.activeOwner=nil;
}
- (void)activateOwner:(id)owner { self.activeOwner=owner; }
- (BOOL)handleKeyCode:(unsigned short)code modifiers:(NSEventModifierFlags)flags repeat:(BOOL)repeat {
  if (!KFShortcutMatches(code,flags)) return NO;
  KFShortcutEntry *only=nil, *active=nil; id soleEffect=nil; BOOL multipleEffects=NO;
  for (KFShortcutEntry *entry in self.entries) {
    id owner=entry.owner;
    id effect=entry.effect;
    if (!owner || !effect || !entry.eligible()) continue;
    if (!soleEffect) { soleEffect=effect; only=entry; }
    else if (effect!=soleEffect) multipleEffects=YES;
    if (owner==self.activeOwner) active=entry;
  }
  KFShortcutEntry *target=active ?: (!multipleEffects ? only : nil);
  if (!target) return NO;
  if (repeat) return YES;
  return target.action();
}
@end

@interface KFMenuHistoryShortcut ()
@property(nonatomic,weak) id owner;
@property(nonatomic,copy) BOOL (^action)(BOOL redo);
@property(nonatomic) NSUInteger generation;
@end
@implementation KFMenuHistoryShortcut
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
    KFMenuHistoryShortcut *strong=weakSelf;
    if (!strong.active || strong.generation!=generation) return;
    strong.action(redo);
  });
  return YES;
}
@end

@interface KFShortcutCapture () {
  CFMachPortRef _tap;
  CFRunLoopSourceRef _source;
}
@property(nonatomic, strong) KFShortcutRouter *router;
@property(nonatomic, strong) KFMenuHistoryShortcut *menuHistory;
- (void)ensureCapture;
@property(nonatomic, strong) NSHashTable<NSView *> *views;
@property(nonatomic, strong) id localMonitor;
- (BOOL)handleHostEvent:(CGEventRef)event;
- (void)stop;
- (void)resumeCapture;
@end
static CGEventRef KFCaptureEvent(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
  KFShortcutCapture *capture=(__bridge KFShortcutCapture *)context;
  if (type==kCGEventTapDisabledByTimeout || type==kCGEventTapDisabledByUserInput) {
    [capture resumeCapture]; return event;
  }
  if (type!=kCGEventKeyDown) return event;
  return [capture handleHostEvent:event] ? NULL : event;
}
static BOOL KFHostIsFrontmost(void) {
  NSString *bundle=NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier;
  return [bundle isEqualToString:@"com.apple.FinalCut"] || [bundle isEqualToString:@"com.apple.motionapp"];
}
static BOOL KFTextEditorIsFocused(void) {
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
@implementation KFShortcutCapture
+ (instancetype)sharedCapture {
  static KFShortcutCapture *capture; static dispatch_once_t once;
  dispatch_once(&once, ^{ capture=[self new]; capture.router=[KFShortcutRouter new]; capture.menuHistory=[KFMenuHistoryShortcut new]; capture.views=[NSHashTable weakObjectsHashTable]; });
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
    __weak KFShortcutCapture *weakSelf=self;
    self.localMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
      KFShortcutCapture *s=weakSelf;
      if (!s || [NSApp.keyWindow.firstResponder isKindOfClass:NSTextView.class]) return event;
      return [s.router handleKeyCode:event.keyCode modifiers:event.modifierFlags repeat:event.isARepeat] ? nil : event;
    }];
  }
  // The tap stays installed once created: Motion rebuilds inspector rows
  // several times per selection, and CGEventTapCreate is a window-server round
  // trip that cost ~10ms every time the last row unregistered.
  if (!_tap) {
    _tap=CGEventTapCreate(kCGSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionDefault,
                          CGEventMaskBit(kCGEventKeyDown),KFCaptureEvent,(__bridge void *)self);
    if (_tap) {
      _source=CFMachPortCreateRunLoopSource(kCFAllocatorDefault,_tap,0);
      if (_source) { CFRunLoopAddSource(CFRunLoopGetMain(),_source,kCFRunLoopCommonModes); CGEventTapEnable(_tap,true); }
      else { CFRelease(_tap); _tap=NULL; }
    }
  }
}
- (void)detachView:(NSView *)view {
  [self.router unregisterOwner:view]; [self.views removeObject:view];
  // The tap and monitor stay installed: Motion rebuilds inspector rows several
  // times per selection, and CGEventTapCreate is a window-server round trip
  // that cost ~10ms every time the last row unregistered.
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
  if (CGEventGetIntegerValueField(event,kCGEventTargetUnixProcessID)==getpid() || !KFHostIsFrontmost()) return NO;
  // An explicitly open menu owns history commands, regardless of the host's
  // underlying text focus. Outside that lifetime, normal host routing wins.
  if ([self.menuHistory enqueueKeyCode:code modifiers:flags repeat:CGEventGetIntegerValueField(event,kCGKeyboardEventAutorepeat)!=0]) return YES;
  if (!KFShortcutMatches(code,flags) || KFTextEditorIsFocused()) return NO;
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

