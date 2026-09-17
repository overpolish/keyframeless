/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import <AppKit/AppKit.h>
#import <assert.h>
#import <stdio.h>
@import PluginHost;

// Routing answers to whichever binding the plugin registered; these tests use
// one combination throughout and only care about which owner is reached.
static const NSEventModifierFlags TestModifiers =
    NSEventModifierFlagControl | NSEventModifierFlagOption;

static void testMenuHistoryLifetime(void) {
  KFMenuHistoryShortcut *route=[KFMenuHistoryShortcut new];
  NSObject *menu=[NSObject new], *other=[NSObject new];
  __block NSUInteger undo=0,redo=0;
  NSEventModifierFlags cmd=NSEventModifierFlagCommand;
  assert(![route enqueueKeyCode:6 modifiers:cmd repeat:NO]);
  [route beginForOwner:menu action:^BOOL(BOOL isRedo) { if (isRedo) redo++; else undo++; return YES; }];
  assert(![route enqueueKeyCode:7 modifiers:cmd repeat:NO]);
  assert(![route enqueueKeyCode:6 modifiers:cmd | NSEventModifierFlagOption repeat:NO]);
  assert(![route enqueueKeyCode:6 modifiers:0 repeat:NO]);
  assert([route enqueueKeyCode:6 modifiers:cmd repeat:NO]);
  assert([route enqueueKeyCode:6 modifiers:cmd repeat:YES]);
  assert([route enqueueKeyCode:6 modifiers:cmd | NSEventModifierFlagShift repeat:NO]);
  assert(undo==0 && redo==0); // Never call the host inside the input callback.
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
  assert(undo==1 && redo==1);
  assert([route enqueueKeyCode:6 modifiers:cmd repeat:NO]);
  [route endForOwner:menu];
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
  assert(undo==1 && !route.active);
  [route beginForOwner:menu action:^BOOL(BOOL isRedo) { undo++; return YES; }];
  assert([route enqueueKeyCode:6 modifiers:cmd repeat:NO]);
  [route beginForOwner:other action:^BOOL(BOOL isRedo) { redo++; return YES; }];
  [route endForOwner:menu]; // An old menu cannot detach the replacement.
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
  assert(undo==1 && redo==1 && route.active);
  other=nil;
  assert(!route.active && ![route enqueueKeyCode:6 modifiers:cmd repeat:NO]);
}

static void testRouterSelectionAndRepeat(void) {
  KFShortcutRouter *router = [KFShortcutRouter new];
  NSObject *first = [NSObject new];
  NSObject *second = [NSObject new];
  __block NSUInteger firstActions = 0, secondActions = 0;
  BOOL (^firstEligible)(void) = ^BOOL { return YES; };
  BOOL (^secondEligible)(void) = ^BOOL { return YES; };
  BOOL (^firstAction)(void) = ^BOOL { firstActions++; return YES; };
  BOOL (^secondAction)(void) = ^BOOL { secondActions++; return YES; };
  NSEventModifierFlags mods = NSEventModifierFlagControl | NSEventModifierFlagOption;

  [router registerOwner:first eligible:firstEligible action:firstAction];
  [router registerOwner:second eligible:secondEligible action:secondAction];
  // Two eligible owners are ambiguous until one is explicitly activated.
  assert(![router handleKeyCode:46 modifiers:mods repeat:NO]);
  assert(firstActions == 0 && secondActions == 0);

  [router activateOwner:second];
  assert([router handleKeyCode:46 modifiers:mods repeat:NO]);
  assert(secondActions == 1 && firstActions == 0);
  // A matching key repeat is consumed, but never invokes the action.
  assert([router handleKeyCode:46 modifiers:mods repeat:YES]);
  assert(secondActions == 1);

  [router unregisterOwner:second];
  assert([router handleKeyCode:46 modifiers:mods repeat:NO]);
  assert(firstActions == 1);
  assert(![router handleKeyCode:45 modifiers:mods repeat:NO]);
}

static void testRouterEligibilityAndWeakOwners(void) {
  KFShortcutRouter *router = [KFShortcutRouter new];
  NSObject *first = [NSObject new];
  NSObject *second = [NSObject new];
  __block BOOL firstIsEligible = YES;
  __block BOOL secondIsEligible = YES;
  __block NSUInteger actions = 0;
  NSEventModifierFlags mods = NSEventModifierFlagControl | NSEventModifierFlagOption;
  [router registerOwner:first eligible:^BOOL { return firstIsEligible; } action:^BOOL {
    actions++; return YES;
  }];
  [router registerOwner:second eligible:^BOOL { return secondIsEligible; } action:^BOOL {
    actions++; return YES;
  }];

  [router activateOwner:second];
  secondIsEligible = NO;
  // With exactly one eligible owner, routing falls back to it.
  assert([router handleKeyCode:46 modifiers:mods repeat:NO]);
  assert(actions == 1);

  secondIsEligible = YES;
  firstIsEligible = NO;
  assert([router handleKeyCode:46 modifiers:mods repeat:NO]);
  assert(actions == 2);

  firstIsEligible = YES;
  secondIsEligible = YES;
  [router unregisterOwner:second];
  // A registered owner is weak; after unregistering the sole second owner,
  // the first owner remains the only eligible route.
  assert([router handleKeyCode:46 modifiers:mods repeat:NO]);
  assert(actions == 3);

  __weak NSObject *weakOwner;
  @autoreleasepool {
    NSObject *temporary = [NSObject new];
    weakOwner = temporary;
    [router registerOwner:temporary eligible:^BOOL { return YES; } action:^BOOL {
      actions++; return YES;
    }];
  }
  assert(weakOwner == nil);
  assert([router handleKeyCode:46 modifiers:mods repeat:NO]);
  assert(actions == 4);
}

static void testEffectSelectionWithoutInspectorInteraction(void) {
  KFShortcutRouter *router=[KFShortcutRouter new];
  NSObject *effectA=[NSObject new], *effectB=[NSObject new];
  NSArray *a=@[[NSObject new],[NSObject new],[NSObject new]];
  NSArray *b=@[[NSObject new],[NSObject new]];
  __block NSInteger selected=1;
  __block NSUInteger callsA=0,callsB=0;
  for(id owner in a) [router registerOwner:owner effect:effectA eligible:^BOOL { return selected==1; } action:^BOOL { callsA++; return YES; }];
  for(id owner in b) [router registerOwner:owner effect:effectB eligible:^BOOL { return selected==2; } action:^BOOL { callsB++; return YES; }];
  NSEventModifierFlags flags=TestModifiers;
  assert([router handleKeyCode:46 modifiers:flags repeat:NO]);
  assert(callsA==1 && callsB==0); // Three visible rows still make one effect.
  selected=0; // Selecting an unrelated host object makes no effect eligible.
  assert(![router handleKeyCode:46 modifiers:flags repeat:NO]);
  selected=1; // Return to the effect, without activating any inspector row.
  assert([router handleKeyCode:46 modifiers:flags repeat:NO]);
  assert(callsA==2 && callsB==0);
  selected=2;
  assert([router handleKeyCode:46 modifiers:flags repeat:NO]);
  assert(callsA==2 && callsB==1);
  [router activateOwner:b[0]];
  selected=1; // A previously active row cannot override current eligibility.
  assert([router handleKeyCode:46 modifiers:flags repeat:NO]);
  assert(callsA==3 && callsB==1);
  [router unregisterOwner:a[0]];
  assert([router handleKeyCode:46 modifiers:flags repeat:NO]);
  assert(callsA==4 && callsB==1);
}

int main(void) {
  @autoreleasepool {
    KFSetShortcutMatcher(^BOOL(unsigned short code, NSEventModifierFlags flags) {
      NSEventModifierFlags meaningful = NSEventModifierFlagCommand | NSEventModifierFlagControl |
          NSEventModifierFlagOption | NSEventModifierFlagShift | NSEventModifierFlagFunction;
      return code == 46 && (flags & meaningful) == TestModifiers;
    });
    testMenuHistoryLifetime();
    testEffectSelectionWithoutInspectorInteraction();
    testRouterSelectionAndRepeat();
    testRouterEligibilityAndWeakOwners();
    puts("Shortcuts: menu history lifetime, effect routing, repeats and weak owners passed");
  }
}
