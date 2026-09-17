/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFTimingEditor+Editing.h"
#import "KFTimingEditor+Refresh.h"
#import "KFTimingEditor_Private.h"
#import "KFCreationDefaults.h"
#import "KFHostSettings.h"
#import "KFPropertyLane.h"
#import "KFPropertyMenu.h"

@implementation KFTimingEditor (Editing)
- (void)randomizeMotionSeed:(id)sender {
  (void)sender;
  [self writeSetting:KFInspectorMotionSeed value:arc4random()];
}
- (NSMenu *)motionContextMenu:(BOOL)controls {
  UInt32 parameter=self.displayedParameter;
  NSUInteger count=KFPropertyLaneForParameter(parameter) ? KFPropertyLaneForParameter(parameter).componentCount : 2;
  if (!controls && count<2) return nil;
  id<FxCustomParameterActionAPI_v4> action=[self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action) return nil;
  CMTime time; KFInspectorGap *gap;
  [action startAction:self];
  @try { time=[action currentTime]; gap=KFReadInspectorGap(self.manager,parameter,time); }
  @finally { [action endAction:self]; }
  NSMenu *menu=KFCreatePropertyMenu(self.manager,self); menu.autoenablesItems=NO;
  KFPoseTiming *timing=[gap.sourcePose timing];
  NSValue *boxedTime=[NSValue valueWithBytes:&time objCType:@encode(CMTime)];
  void (^add)(NSMenu *,NSString *,KFInspectorSetting,double,BOOL)=^(NSMenu *destination,NSString *title,KFInspectorSetting setting,double value,BOOL checked) {
    NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:title action:@selector(motionContextAction:) keyEquivalent:@""];
    item.target=self; item.enabled=gap!=nil;
    item.state=checked ? NSControlStateValueOn : NSControlStateValueOff;
    item.representedObject=@{@"parameter":@(parameter),@"time":boxedTime,@"setting":@(setting),@"value":@(value)};
    [destination addItem:item];
  };
  if (controls) {
    add(menu,@"Reset Parameter",KFInspectorResetMotionControls,0,NO);
    [self appendDefaults:menu setting:KFInspectorAmount gap:gap];
  }
  else {
    add(menu,@"Independent Motion",KFInspectorMotionLinked,!timing.motionLinked,!timing.motionLinked);
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[NSMenuItem sectionHeaderWithTitle:@"PARAMETERS"]];
    NSArray *names=@[@"X",@"Y",@"Z"];
    for (NSUInteger i=0;i<count;i++) {
      add(menu,names[i],KFInspectorMotionMask,timing.motionComponentMask ^ (UINT32_C(1)<<i),(timing.motionComponentMask & (UINT32_C(1)<<i))!=0);
      menu.itemArray.lastObject.indentationLevel=1;
    }
  }
  return menu;
}
- (void)appendDefaults:(NSMenu *)menu setting:(KFInspectorSetting)setting gap:(KFInspectorGap *)gap {
  NSString *key; NSDictionary *value;
  if (setting==KFInspectorDuration) {
    key=@"duration"; value=@{@"value":@([[gap.destinationPose timing] duration])};
  } else if (setting==KFInspectorEasing) {
    key=@"easing"; value=@{@"value":@([gap.destinationPose easing])};
  } else {
    MTAddedMotion type=[gap.sourcePose addedMotion];
    if (!gap || type==MTAddedMotionNone) return;
    key=KFMotionDefaultKey(type);
    value=@{@"amount":@([[gap.sourcePose timing] amount]),@"speed":@([[gap.sourcePose timing] speed])};
  }
  if (setting==KFInspectorDuration || setting==KFInspectorEasing) {
    NSMenuItem *reset=[[NSMenuItem alloc] initWithTitle:@"Reset Parameter" action:@selector(motionContextAction:) keyEquivalent:@""];
    CMTime target=gap ? gap.destinationTime : kCMTimeInvalid;
    reset.target=self; reset.enabled=gap!=nil;
    reset.representedObject=@{@"parameter":@(gap.parameterID),
        @"time":[NSValue valueWithBytes:&target objCType:@encode(CMTime)],
        @"setting":@(setting),@"value":KFReadDefault(key)[@"value"]};
    [menu addItem:reset];
  }
  ICAppendDefaultMenuItems(menu,self,@selector(defaultContextAction:),@{@"key":key,@"value":value},gap!=nil);
}
- (NSMenu *)defaultContextMenu:(KFInspectorSetting)setting {
  id<FxCustomParameterActionAPI_v4> action=[self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action) return nil;
  KFInspectorGap *gap;
  [action startAction:self];
  @try { gap=KFReadInspectorGap(self.manager,self.displayedParameter,[action currentTime]); }
  @finally { [action endAction:self]; }
  NSMenu *menu=KFCreatePropertyMenu(self.manager,self); menu.autoenablesItems=NO;
  [self appendDefaults:menu setting:setting gap:gap];
  return menu;
}
- (void)defaultContextAction:(NSMenuItem *)item {
  NSDictionary *request=item.representedObject;
  if (item.tag) KFRestoreFactoryDefault(request[@"key"]);
  else KFSaveDefault(request[@"key"],request[@"value"]);
  // No host edit was made. The shared menu lifecycle still refreshes after closing.
}
- (void)motionContextAction:(NSMenuItem *)item {
  NSDictionary *request=item.representedObject;
  NSMenu *menu=item.menu; while (menu.supermenu) menu=menu.supermenu;
  KFPropertyMenuActionScheduled(menu);
  __weak KFTimingEditor *weakSelf=self;
  CFRunLoopPerformBlock(CFRunLoopGetMain(),kCFRunLoopDefaultMode,^{
    KFTimingEditor *editor=weakSelf; if (!editor.window) return;
    CMTime time; [request[@"time"] getValue:&time];
    [editor writeSetting:[request[@"setting"] integerValue] value:[request[@"value"] doubleValue]
        parameter:[request[@"parameter"] unsignedIntValue] time:time refreshHost:YES];
  });
  CFRunLoopWakeUp(CFRunLoopGetMain());
}
- (void)menuChanged:(NSPopUpButton *)menu {
  [self writeSetting:menu.tag value:menu.indexOfSelectedItem];
}
- (void)availableChanged:(NSButton *)button {
  [self writeSetting:KFInspectorAvailable
               value:button.state == NSControlStateValueOn];
}
- (void)beginScrub {
  id<FxCustomParameterActionAPI_v4> action =
      [self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action)
    return;
  [action startAction:self];
  @try {
    id<FxUndoAPI> undo = [self.manager apiForProtocol:@protocol(FxUndoAPI)];
    if ([undo startUndoGroup:@"Change Motion"])
      self.scrubUndo = undo;
  } @finally {
    [action endAction:self];
  }
}
- (void)endScrub {
  if (!self.scrubUndo)
    return;
  id<FxCustomParameterActionAPI_v4> action =
      [self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [action startAction:self];
  @try {
    [self.scrubUndo endUndoGroup];
  } @finally {
    self.scrubUndo = nil;
    [action endAction:self];
  }
}
- (void)writeSetting:(KFInspectorSetting)setting value:(double)value {
  [self writeSetting:setting value:value parameter:self.displayedParameter time:kCMTimeInvalid refreshHost:NO];
}
- (void)writeSetting:(KFInspectorSetting)setting value:(double)value parameter:(UInt32)parameter time:(CMTime)time refreshHost:(BOOL)refreshHost {
  id<FxCustomParameterActionAPI_v4> action =
      [self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action)
    return;
  self.writingSetting=YES;
  [action startAction:self];
  @try {
    id<FxUndoAPI> undo =
        self.scrubUndo ? nil
                       : [self.manager apiForProtocol:@protocol(FxUndoAPI)];
    BOOL grouped = [undo startUndoGroup:@"Change Motion"];
    @try {
      CMTime now=CMTIME_IS_NUMERIC(time) ? time : [action currentTime];
      if (!KFWriteInspectorSetting(self.manager, parameter,
                                   now, setting, value))
        NSBeep();
      if (refreshHost) {
        KFRequestHostRefresh(self.manager,now);
      }
    } @finally {
      if (grouped)
        [undo endUndoGroup];
    }
  } @finally {
    [action endAction:self];
    self.writingSetting=NO;
  }
  [self refresh];
}
@end
