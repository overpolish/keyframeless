/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFHostSettings.h"
#import "KFPropertyMenu.h"

// The plugin registers its refresh-token parameter and, for settings that are
// also creation preferences, the writer that records them.
static UInt32 KFHostRefreshParameter;
static void (^KFBoolSettingPreference)(UInt32 parameter, BOOL value);

void KFSetHostRefreshParameter(UInt32 parameter) { KFHostRefreshParameter=parameter; }
void KFSetBoolSettingPreferenceWriter(void (^writer)(UInt32 parameter, BOOL value)) {
  KFBoolSettingPreference=[writer copy];
}
// A saved, non-animatable scratch value invalidates the host's cached frame, so
// a menu action repaints without waiting for pointer movement. The caller owns
// the host action and any undo group.
BOOL KFRequestHostRefresh(id<PROAPIAccessing> manager, CMTime time) {
  if(!KFHostRefreshParameter || !CMTIME_IS_NUMERIC(time)) return NO;
  id<FxParameterSettingAPI_v5> set=[manager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  return [set setCustomParameterValue:NSUUID.UUID.UUIDString toParameter:KFHostRefreshParameter atTime:time];
}

BOOL KFReadBoolSetting(id<PROAPIAccessing> manager, NSView *sender, UInt32 parameter, BOOL *value) {
  id<FxCustomParameterActionAPI_v4> action=[manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if(!action) return NO;
  [action startAction:sender];
  @try {
    id<FxParameterRetrievalAPI_v6> get=[manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    CMTime time=[action currentTime];
    return CMTIME_IS_NUMERIC(time) && [get getBoolValue:value fromParameter:parameter atTime:time];
  } @finally { [action endAction:sender]; }
}
BOOL KFToggleBoolSetting(id<PROAPIAccessing> manager, NSView *sender, UInt32 parameter, NSString *undoName) {
  id<FxCustomParameterActionAPI_v4> action=[manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if(!action) return NO;
  [action startAction:sender];
  @try {
    id<FxParameterRetrievalAPI_v6> get=[manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> set=[manager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    CMTime time=[action currentTime]; BOOL value=NO;
    if(!set || !CMTIME_IS_NUMERIC(time) || ![get getBoolValue:&value fromParameter:parameter atTime:time]) return NO;
    id<FxUndoAPI> undo=[manager apiForProtocol:@protocol(FxUndoAPI)];
    BOOL grouped=[undo startUndoGroup:undoName];
    @try {
      if(![set setBoolValue:!value toParameter:parameter atTime:time]) return NO;
      // Some settings are also remembered as the creation preference; the
      // plugin owns which ones and where they are stored.
      if(KFBoolSettingPreference) KFBoolSettingPreference(parameter,!value);
      return KFRequestHostRefresh(manager,time);
    } @finally { if(grouped) [undo endUndoGroup]; }
  } @finally { [action endAction:sender]; }
}

@interface KFSettingMenuTarget : NSObject
@property(nonatomic, strong) id<PROAPIAccessing> manager;
@property(nonatomic, weak) NSView *sender;
@property(nonatomic) UInt32 parameter;
@property(nonatomic, copy) NSString *undoName;
@end
@implementation KFSettingMenuTarget
- (void)toggle:(NSMenuItem *)item {
  NSMenu *menu=item.menu;
  while(menu.supermenu) menu=menu.supermenu;
  KFPropertyMenuActionScheduled(menu);
  // Same reason as the reset item: leave menu tracking before a host action.
  CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopDefaultMode, ^{
    NSView *view=self.sender;
    if(!view) return;
    BOOL ok=KFToggleBoolSetting(self.manager,view,self.parameter,self.undoName);
    KFPropertyMenuActionFinished(menu,ok);
    if(!ok) NSBeep();
  });
  CFRunLoopWakeUp(CFRunLoopGetMain());
}
- (void)refreshItem:(NSMenuItem *)item {
  id<FxParameterRetrievalAPI_v6> get=[self.manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxCustomParameterActionAPI_v4> action=[self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  BOOL value=NO;
  item.enabled=get && action && [get getBoolValue:&value fromParameter:self.parameter atTime:[action currentTime]];
  if(item.enabled) item.state=value ? NSControlStateValueOn:NSControlStateValueOff;
}
@end
void KFRefreshSettingMenuItem(NSMenuItem *item) {
  if([item.target isKindOfClass:KFSettingMenuTarget.class]) [(KFSettingMenuTarget *)item.target refreshItem:item];
}
NSMenuItem *KFSettingMenuItem(id<PROAPIAccessing> manager, NSView *sender, UInt32 parameter,
                              NSString *title, NSString *undoName) {
  KFSettingMenuTarget *target=[KFSettingMenuTarget new];
  target.manager=manager; target.sender=sender; target.parameter=parameter;
  target.undoName=undoName;
  NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:title action:@selector(toggle:) keyEquivalent:@""];
  item.target=target; item.representedObject=target;
  // State is unknown until a host action is open, so the caller refreshes.
  item.enabled=NO;
  return item;
}
void KFRefreshSettingMenuItems(NSMenu *menu, id<PROAPIAccessing> manager, NSView *sender) {
  id<FxCustomParameterActionAPI_v4> action=[manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if(!action) return;
  [action startAction:sender];
  @try {
    for(NSMenuItem *item in menu.itemArray) KFRefreshSettingMenuItem(item);
  } @finally { [action endAction:sender]; }
}
