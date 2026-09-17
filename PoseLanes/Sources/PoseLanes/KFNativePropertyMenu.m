/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFHostSettings.h"
#import "KFMatchEndpoints.h"
#import "KFNativeEdits.h"
#import "KFNativeLinks.h"
#import "KFNativeLinks_Private.h"
#import "KFPropertyMenu.h"
#import "KFResetParameter.h"
@import InspectorControls;

@interface KFMatchMenuTarget : NSObject
@property(nonatomic, strong) id<PROAPIAccessing> manager;
@property(nonatomic, weak) NSView *sender;
@property UInt32 parameter;
- (void)refreshItem:(NSMenuItem *)item;
@end
@implementation KFMatchMenuTarget
- (void)refreshItem:(NSMenuItem *)item {
  item.enabled = KFPropertyMatchAvailable(self.manager, self.parameter);
  item.state = KFPropertyMatchEnabled(self.manager, self.parameter)
                   ? NSControlStateValueOn
                   : NSControlStateValueOff;
}
- (void)toggle:(NSMenuItem *)sender {
  NSMenu *menu = sender.menu;
  KFPropertyMenuActionScheduled(menu);
  // Return the ViewBridge button callback before asking the host for keyframes.
  dispatch_async(dispatch_get_main_queue(), ^{
    [self applyToggle:sender menu:menu];
  });
}
- (void)applyToggle:(NSMenuItem *)sender menu:(NSMenu *)menu {
  NSView *view = self.sender;
  if (!view)
    return;
  id<FxCustomParameterActionAPI_v4> action =
      [self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action) {
    KFPropertyMenuActionFinished(menu, NO);
    return;
  }
  BOOL ok = NO;
  [action startAction:view];
  @try {
    id<FxUndoAPI> undo = [self.manager apiForProtocol:@protocol(FxUndoAPI)];
    if (![undo startUndoGroup:@"Match In/Out"])
      return;
    @try {
      BOOL enabled = KFPropertyMatchEnabled(self.manager, self.parameter);
      ok = KFSetPropertyMatch(self.manager, self.parameter, !enabled, NULL);
      if (ok)
        [self refreshItem:sender];
      else
        NSBeep();
    } @finally {
      [undo endUndoGroup];
    }
  } @finally {
    [action endAction:view];
    KFPropertyMenuActionFinished(menu, ok);
  }
}
@end
@interface KFNativeLinkMenuTarget : NSObject
@property(nonatomic, strong) id<PROAPIAccessing> manager;
@property(nonatomic, weak) NSView *sender;
@property UInt32 source;
@property UInt32 partner;
@property CMTime time;
@property BOOL linked;
- (void)refreshItem:(NSMenuItem *)item;
- (void)applyToggle:(NSMenuItem *)sender menu:(NSMenu *)menu;
@end
@implementation KFNativeLinkMenuTarget
- (void)refreshItem:(NSMenuItem *)item {
  NSDictionary *source = KFTarget(KFEntries(self.manager, self.source), self.time);
  BOOL sourceUnkeyed = !KFEntries(self.manager, self.source).firstObject[@"nativeTime"];
  BOOL partnerUnkeyed = !KFEntries(self.manager, self.partner).firstObject[@"nativeTime"];
  item.enabled = CMTIME_IS_NUMERIC(self.time) && (source != nil ||
      (sourceUnkeyed && (partnerUnkeyed || KFTarget(KFEntries(self.manager, self.partner), self.time))));
  ((NSControl *)item.view).enabled = item.enabled;
  self.linked = NO;
  for (NSDictionary *member in KFMembers(self.manager, KFLink(source[@"pose"])))
    if ([member[@"parameter"] unsignedIntValue] == self.partner) self.linked = YES;
  item.state = self.linked ? NSControlStateValueOn : NSControlStateValueOff;
  item.view.needsDisplay = YES;
}
- (void)toggle:(NSMenuItem *)sender {
  NSMenu *menu=sender.menu; KFPropertyMenuActionScheduled(menu);
  // Return the ViewBridge button callback before asking the host for keyframes.
  // Use the main dispatch queue, as with history; the callback has no named
  // run-loop mode, so a mode-specific run-loop block can wait for mouse input.
  dispatch_async(dispatch_get_main_queue(), ^{
    [self applyToggle:sender menu:menu];
  });
}
- (void)applyToggle:(NSMenuItem *)sender menu:(NSMenu *)menu {
  // A click is committed even if its menu closes before dispatch. The weak
  // inspector view prevents applying it after the owning control is destroyed.
  NSView *view = self.sender;
  if (!view)
    return;
  id<FxCustomParameterActionAPI_v4> action =
      [self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action) { KFPropertyMenuActionFinished(menu,NO); return; }
  BOOL ok=NO;
  [action startAction:view];
  @try {
    id<FxUndoAPI> undo = [self.manager apiForProtocol:@protocol(FxUndoAPI)];
    if (![undo startUndoGroup:@"Link keyposes"])
      return;
    @try {
      [self refreshItem:sender];
      ok=KFSetNativePropertyLink(self.manager, self.source, self.partner,self.time,!self.linked);
      if (ok) {
        for (NSMenuItem *item in menu.itemArray)
          if ([item.target isKindOfClass:KFNativeLinkMenuTarget.class])
            [(KFNativeLinkMenuTarget *)item.target refreshItem:item];
      } else NSBeep();
    } @finally {
      [undo endUndoGroup];
    }
  } @finally {
    [action endAction:view];
    KFPropertyMenuActionFinished(menu,ok);
  }
}
@end
NSMenu *KFNativePropertyMenu(id<PROAPIAccessing> m, NSView *sender,
                             UInt32 parameter) {
  NSMenu *menu = KFResetParameterMenu(m, sender, parameter);
  menu.autoenablesItems = NO;
  __weak NSMenu *weakMenu=menu;
  KFPropertyMenuSetStateHandler(menu, ^{
    NSMenu *activeMenu=weakMenu;
    if (!activeMenu) return;
    for (NSMenuItem *item in activeMenu.itemArray) {
      KFRefreshSettingMenuItem(item);
      if ([item.target isKindOfClass:KFNativeLinkMenuTarget.class]) [(KFNativeLinkMenuTarget *)item.target refreshItem:item];
      if ([item.target isKindOfClass:KFMatchMenuTarget.class]) [(KFMatchMenuTarget *)item.target refreshItem:item];
    }
  });
  // A property that owns an on-screen control offers its visibility toggle.
  KFPropertyLane *lane = KFPropertyLaneForParameter(parameter);
  if (lane.visibilityToggleID) {
    NSString *undoName = [NSString stringWithFormat:@"Toggle %@ On-Screen Control", lane.displayName];
    [menu addItem:KFSettingMenuItem(m, sender, lane.visibilityToggleID, @"On-Screen Control", undoName)];
    [menu addItem:NSMenuItem.separatorItem];
  }
  KFMatchMenuTarget *match = [KFMatchMenuTarget new];
  match.manager = m;
  match.sender = sender;
  match.parameter = parameter;
  NSMenuItem *matchItem = [[NSMenuItem alloc] initWithTitle:@"Match In/Out"
                                                    action:@selector(toggle:)
                                             keyEquivalent:@""];
  matchItem.target = match;
  matchItem.representedObject = match;
  matchItem.enabled = NO;
  [menu addItem:matchItem];
  [menu addItem:NSMenuItem.separatorItem];
  NSMenuItem *header = [NSMenuItem sectionHeaderWithTitle:@"LINK WITH"];
  [menu addItem:header];
  id<FxCustomParameterActionAPI_v4> action =
      [m apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action)
    return menu;
  [action startAction:sender];
  @try {
    // Reading the toggles and the cached keys needs the action scope, like the
    // link items below.
    for (NSMenuItem *item in menu.itemArray) KFRefreshSettingMenuItem(item);
    [match refreshItem:matchItem];
    CMTime now = [action currentTime];
    NSDictionary *source = KFTarget(KFEntries(m, parameter), now);
    NSArray *members = KFMembers(m, KFLink(source[@"pose"]));
    for (NSNumber *p in KFProperties())
      if (p.unsignedIntValue != parameter) {
        BOOL linked = NO;
        for (NSDictionary *member in members)
          if ([member[@"parameter"] isEqual:p])
            linked = YES;
        KFNativeLinkMenuTarget *target = [KFNativeLinkMenuTarget new];
        target.manager = m;
        target.sender = sender;
        target.source = parameter;
        target.partner = p.unsignedIntValue;
        NSDictionary *destination = source;
        if (!destination && !KFEntries(m, parameter).firstObject[@"nativeTime"])
          destination = KFTarget(KFEntries(m, p.unsignedIntValue), now);
        BOOL bothUnkeyed = !KFEntries(m, parameter).firstObject[@"nativeTime"] &&
            !KFEntries(m, p.unsignedIntValue).firstObject[@"nativeTime"];
        target.time = now;
        target.linked = linked;
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:KFPropertyDisplayName(p.unsignedIntValue)
                                                      action:@selector(toggle:)
                                               keyEquivalent:@""];
        item.target = target;
        item.representedObject = target;
        item.state = linked ? NSControlStateValueOn : NSControlStateValueOff;
        item.enabled = CMTIME_IS_NUMERIC(now) && (destination != nil || bothUnkeyed);
        item.indentationLevel = 1;
        item.view = [[ICMenuToggleView alloc] initWithMenuItem:item];
        ((NSControl *)item.view).enabled = item.enabled;
        [menu addItem:item];
      }
  } @finally {
    [action endAction:sender];
  }
  return menu;
}
