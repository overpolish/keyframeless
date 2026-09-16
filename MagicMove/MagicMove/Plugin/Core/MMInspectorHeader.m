/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMInspectorHeader.h"
#import "Constants.h"
#import "MMResetParameter.h"
#import "MMShortcut.h"

// A fresh menu reads host state on each right-click, including after undo.
@interface MMHeaderMenuButton : NSButton
@property(nonatomic,copy) NSMenu *(^contextMenuProvider)(void);
@end
@implementation MMHeaderMenuButton
- (NSMenu *)menuForEvent:(NSEvent *)event {
  return self.contextMenuProvider ? self.contextMenuProvider() : [super menuForEvent:event];
}
@end

NSNotificationName const MMHeaderSettingsChanged=@"MMHeaderSettingsChanged";
@interface MMInspectorHeader ()
@property(nonatomic,strong) id<PROAPIAccessing> manager;
@property(nonatomic,strong) NSButton *blurButton;
@property(nonatomic,strong) id settingsObserver;
@end
@implementation MMInspectorHeader
- (instancetype)initWithManager:(id<PROAPIAccessing>)manager {
  NSBundle *bundle=[NSBundle bundleForClass:self.class];
  NSString *path=[bundle pathForResource:@"keyframeless-logo" ofType:@"png"];
  NSImage *logo=path ? [[NSImage alloc] initWithContentsOfFile:path]:nil;
  self=[super initWithLogo:logo];
  if(!self) return nil;
  _manager=manager;
  _blurButton=[MMHeaderMenuButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"figure.walk.motion" accessibilityDescription:@"Motion Blur"] target:self action:@selector(toggleBlur:)];
  _blurButton.bordered=NO;
  _blurButton.toolTip=[NSString stringWithFormat:@"Motion Blur (%@)",MMMotionBlurShortcutDisplay()];
  _blurButton.accessibilityLabel=@"Motion Blur";
  self.accessoryButtons=@[_blurButton];
  __weak MMInspectorHeader *weakSelf=self;
  self.menuProvider=^NSMenu *{ return [weakSelf settingsMenu]; };
  ((MMHeaderMenuButton *)_blurButton).contextMenuProvider=^NSMenu *{ return [weakSelf motionBlurMenu]; };
  _settingsObserver=[NSNotificationCenter.defaultCenter addObserverForName:MMHeaderSettingsChanged object:manager queue:nil usingBlock:^(NSNotification *note) {
    // Native callbacks may arrive during a host action or on its worker thread.
    dispatch_async(dispatch_get_main_queue(),^{ if(weakSelf.window) [weakSelf refreshSettings]; });
  }];
  return self;
}
- (MMShortcutCapture *)shortcutCapture { return MMShortcutCapture.sharedCapture; }
- (void)dealloc {
  if(_settingsObserver) [NSNotificationCenter.defaultCenter removeObserver:_settingsObserver];
  [[self shortcutCapture] detachView:self];
}
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  [[self shortcutCapture] detachView:self];
  if(!self.window) return;
  __weak MMInspectorHeader *weakSelf=self;
  [[self shortcutCapture] attachView:self effect:self.manager action:^BOOL {
    MMInspectorHeader *header=weakSelf;
    if(!header || NSEvent.pressedMouseButtons) return NO;
    // Match property rows: host work must never block the input event tap.
    dispatch_async(dispatch_get_main_queue(),^{
      MMInspectorHeader *target=weakSelf;
      if(!target.window.isVisible || target.hiddenOrHasHiddenAncestor) return;
      @try { [target toggleBlur:nil]; }
      @catch(NSException *exception) { NSBeep(); }
    });
    return YES;
  }];
  [self refreshSettings];
}
- (NSView *)hitTest:(NSPoint)point {
  NSView *hit=[super hitTest:point];
  NSEventType type=NSApp.currentEvent.type;
  if(hit && (type==NSEventTypeLeftMouseDown || type==NSEventTypeRightMouseDown))
    [[self shortcutCapture] activateView:self];
  return hit;
}
- (BOOL)readSetting:(UInt32)parameter value:(BOOL *)value {
  return MMReadBoolSetting(self.manager,self,parameter,value);
}
- (void)refreshSettings {
  BOOL blur=NO;
  self.blurButton.enabled=[self readSetting:MMMotionBlur value:&blur];
  if(self.blurButton.enabled) self.blurButton.state=blur ? NSControlStateValueOn:NSControlStateValueOff;
  self.blurButton.contentTintColor=!self.blurButton.enabled ? ICInspectorTokens.disabledTextColor : self.blurButton.state ? ICInspectorTokens.accentMatchingHost:ICInspectorTokens.labelColor;
}
- (BOOL)toggleSetting:(UInt32)parameter {
  if(parameter!=MMExplicitCreation && parameter!=MMMotionBlur) return NO;
  return MMToggleBoolSetting(self.manager,self,parameter,
      parameter==MMMotionBlur ? @"Toggle Motion Blur":@"Toggle Explicit Keyframe Editing");
}
- (void)toggleBlur:(id)sender {
  [[self shortcutCapture] activateView:self];
  [self toggleSetting:MMMotionBlur]; [self refreshSettings];
}
- (void)toggleMenuSetting:(NSMenuItem *)item {
  NSMenu *menu=item.menu; UInt32 parameter=(UInt32)item.tag;
  MMPropertyMenuActionScheduled(menu);
  CFRunLoopPerformBlock(CFRunLoopGetMain(),kCFRunLoopDefaultMode,^{
    BOOL refreshed=[self toggleSetting:parameter];
    MMPropertyMenuActionFinished(menu,refreshed);
    [self refreshSettings];
  });
  CFRunLoopWakeUp(CFRunLoopGetMain());
}
- (BOOL)writeBlurSetting:(UInt32)parameter value:(NSInteger)value {
  if(parameter!=MMMotionBlurSamples && parameter!=MMMotionBlurShutterAngle) return NO;
  NSInteger minimum=parameter==MMMotionBlurSamples ? MMMotionBlurMinSamples:MMMotionBlurMinShutterAngle;
  NSInteger maximum=parameter==MMMotionBlurSamples ? MMMotionBlurMaxSamples:MMMotionBlurMaxShutterAngle;
  if(value<minimum || value>maximum) return NO;
  id<FxCustomParameterActionAPI_v4> action=[self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if(!action) return NO;
  [action startAction:self];
  @try {
    CMTime time=[action currentTime];
    if(!CMTIME_IS_NUMERIC(time)) return NO;
    id<FxParameterSettingAPI_v5> set=[self.manager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    if(!set) return NO;
    id<FxUndoAPI> undo=[self.manager apiForProtocol:@protocol(FxUndoAPI)];
    BOOL grouped=[undo startUndoGroup:parameter==MMMotionBlurSamples ? @"Change Motion Blur Samples":@"Change Shutter Angle"];
    @try {
      if(![set setIntValue:(int)value toParameter:parameter atTime:time]) return NO;
      return [set setCustomParameterValue:NSUUID.UUID.UUIDString toParameter:MMHostRefreshToken atTime:time];
    } @finally { if(grouped) [undo endUndoGroup]; }
  } @finally { [action endAction:self]; }
}
- (void)chooseBlurSetting:(NSMenuItem *)item {
  NSMenu *menu=item.menu;
  while(menu.supermenu) menu=menu.supermenu;
  UInt32 parameter=(UInt32)item.tag;
  NSInteger value=[item.representedObject integerValue];
  MMPropertyMenuActionScheduled(menu);
  CFRunLoopPerformBlock(CFRunLoopGetMain(),kCFRunLoopDefaultMode,^{
    MMPropertyMenuActionFinished(menu,[self writeBlurSetting:parameter value:value]);
  });
  CFRunLoopWakeUp(CFRunLoopGetMain());
}
- (NSMenuItem *)blurChoices:(UInt32)parameter title:(NSString *)title values:(NSArray<NSNumber *> *)values suffix:(NSString *)suffix {
  int current=parameter==MMMotionBlurSamples ? MMMotionBlurDefaultSamples:MMMotionBlurDefaultShutterAngle;
  BOOL readable=NO;
  id<FxCustomParameterActionAPI_v4> action=[self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if(action) {
    [action startAction:self];
    @try {
      id<FxParameterRetrievalAPI_v6> get=[self.manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      readable=[get getIntValue:&current fromParameter:parameter atTime:[action currentTime]];
    } @finally { [action endAction:self]; }
  }
  NSMenuItem *parent=[[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%@: %d%@",title,current,suffix] action:NULL keyEquivalent:@""];
  NSMenu *choices=[[NSMenu alloc] initWithTitle:title]; choices.autoenablesItems=NO;
  for(NSNumber *number in values) {
    NSMenuItem *choice=[[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%@%@",number,suffix] action:@selector(chooseBlurSetting:) keyEquivalent:@""];
    choice.target=self; choice.tag=parameter; choice.representedObject=number;
    choice.state=current==number.intValue ? NSControlStateValueOn:NSControlStateValueOff;
    choice.enabled=readable;
    [choices addItem:choice];
  }
  parent.submenu=choices;
  parent.enabled=readable;
  return parent;
}
- (NSMenuItem *)itemForSetting:(UInt32)parameter title:(NSString *)title {
  NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:title action:@selector(toggleMenuSetting:) keyEquivalent:@""];
  item.target=self; item.tag=parameter;
  BOOL value=NO;
  item.enabled=[self readSetting:parameter value:&value];
  item.state=value ? NSControlStateValueOn:NSControlStateValueOff;
  return item;
}
- (void)observeSettingsInMenu:(NSMenu *)menu {
  __weak MMInspectorHeader *weakSelf=self;
  __weak NSMenu *weakMenu=menu;
  MMPropertyMenuSetStateHandler(menu,^{
    MMInspectorHeader *header=weakSelf; NSMenu *current=weakMenu;
    if(!header || !current) return;
    // The shared menu lifecycle has already entered a host action.
    id<FxCustomParameterActionAPI_v4> action=[header.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    id<FxParameterRetrievalAPI_v6> get=[header.manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    CMTime time=[action currentTime];
    for(NSMenuItem *item in current.itemArray) {
      MMRefreshSettingMenuItem(item);
      if(item.tag!=MMMotionBlur && item.tag!=MMExplicitCreation) continue;
      BOOL value=NO;
      item.enabled=[get getBoolValue:&value fromParameter:(UInt32)item.tag atTime:time];
      if(item.enabled) item.state=value ? NSControlStateValueOn:NSControlStateValueOff;
    }
  });
}
- (NSMenu *)settingsMenu {
  [[self shortcutCapture] activateView:self];
  NSMenu *menu=MMCreatePropertyMenu(self.manager,self);
  menu.autoenablesItems=NO;
  [self observeSettingsInMenu:menu];
  NSMenuItem *item=[self itemForSetting:MMExplicitCreation title:@"Explicit Keyframe Editing"];
  item.subtitle=@"Prevents automatic keyframe creation when changing values.";
  [menu addItem:item];
  [menu addItem:NSMenuItem.separatorItem];
  [menu addItem:[NSMenuItem sectionHeaderWithTitle:@"ON-SCREEN CONTROLS"]];
  [menu addItem:MMOSCVisibilityMenuItem(self.manager,self,MMShowPositionOSC,@"Position Box")];
  [menu addItem:MMOSCVisibilityMenuItem(self.manager,self,MMShowScaleOSC,@"Scale Handles")];
  MMRefreshSettingMenuItems(menu,self.manager,self);
  return menu;
}
- (NSMenu *)motionBlurMenu {
  [[self shortcutCapture] activateView:self];
  NSMenu *menu=MMCreatePropertyMenu(self.manager,self);
  menu.autoenablesItems=NO;
  [self observeSettingsInMenu:menu];
  NSMenuItem *item=[self itemForSetting:MMMotionBlur title:@"Motion Blur"];
  item.keyEquivalent=MMMotionBlurShortcutKey();
  item.keyEquivalentModifierMask=MMMotionBlurShortcutModifiers();
  [menu addItem:item];
  [menu addItem:NSMenuItem.separatorItem];
  [menu addItem:[self blurChoices:MMMotionBlurSamples title:@"Samples" values:@[@2,@4,@8,@16,@32,@64,@128] suffix:@""]];
  [menu addItem:[self blurChoices:MMMotionBlurShutterAngle title:@"Shutter Angle" values:@[@0,@45,@90,@180,@270,@360] suffix:@"°"]];
  return menu;
}
@end
