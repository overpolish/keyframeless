/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMPropertyRow.h"
#import "MMScalarPose.h"
#import "Plugin_Private.h"
#import "Constants.h"
#import "MMShortcut.h"
#import "MMInspectorColors.h"

@interface MMPropertyRowBinding : NSObject
@property(nonatomic, weak) ICInspectorRow *row;
@property(nonatomic, weak) ICSliderView *slider;
- (instancetype)initWithRow:(ICInspectorRow *)row slider:(ICSliderView *)slider plugin:(MagicMovePlugin *)plugin lane:(MMPropertyLane *)lane label:(NSString *)label;
- (void)attach;
- (void)refreshValues;
- (void)activate;
@property(nonatomic, weak) MagicMovePlugin *plugin;
@property(nonatomic, strong) id<PROAPIAccessing> manager;
@property(nonatomic, strong) MMPropertyLane *lane;
@property(nonatomic, strong) MMPropertyPoseCache *cache;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) id selectionObserver;
@property(nonatomic, strong) id<FxUndoAPI> scrubUndo;
@property(nonatomic, copy) NSString *undoName;
@end
@implementation MMPropertyRowBinding
- (instancetype)initWithRow:(ICInspectorRow *)row slider:(ICSliderView *)slider plugin:(MagicMovePlugin *)plugin lane:(MMPropertyLane *)lane label:(NSString *)label {
  if((self=[super init])) {
    _row=row; _slider=slider; _plugin=plugin; _manager=plugin.apiManager; _lane=lane; _cache=[lane createCache];
    _undoName=[@"Change " stringByAppendingString:label];
    row.componentColors=MMInspectorColors(lane.parameterID);
    slider.minValue=lane.minimum; slider.maxValue=lane.maximum; slider.enabled=NO;
    for(ICValueTextField *field in row.fields) {
      NSNumberFormatter *formatter=(NSNumberFormatter *)field.formatter;
      formatter.minimum=lane.boundsValues ? @(lane.minimum) : nil;
      formatter.maximum=lane.boundsValues ? @(lane.maximum) : nil;
    }
    __weak MMPropertyRowBinding *weakSelf=self;
    row.onValueCommit=^(ICValueTextField *field) { [weakSelf writeField:field]; };
    row.onScrubBegin=^{ [weakSelf beginScrub]; }; row.onScrubEnd=^{ [weakSelf endScrub]; };
    id<FxCustomParameterActionAPI_v4> action=[_manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    if(action) {
      [action startAction:row];
      @try { id<FxParameterSettingAPI_v5> set=[_manager apiForProtocol:@protocol(FxParameterSettingAPI_v5)]; [set setStringParameterValue:_cache.token toParameter:lane.cacheTokenID]; }
      @finally { [action endAction:row]; }
    }
  }
  return self;
}
- (void)attach {
  [self.timer invalidate]; self.timer=nil;
  if(self.selectionObserver) [NSNotificationCenter.defaultCenter removeObserver:self.selectionObserver]; self.selectionObserver=nil;
  [[MMShortcutCapture sharedCapture] detachView:self.row];
  if(!self.row.window) return;
  __weak MMPropertyRowBinding *weakSelf=self;
  self.selectionObserver=[NSNotificationCenter.defaultCenter addObserverForName:@"MMActiveRowChanged" object:self.plugin queue:nil usingBlock:^(NSNotification *note) { [weakSelf updateSelection]; }];
  [self updateSelection];
  [[MMShortcutCapture sharedCapture] attachView:self.row action:^BOOL {
    MMPropertyRowBinding *row=weakSelf; if(!row || row.row.interacting || NSEvent.pressedMouseButtons) return NO;
    dispatch_async(dispatch_get_main_queue(),^{ MMPropertyRowBinding *target=weakSelf;
      if(!target.row.window.isVisible || target.row.hiddenOrHasHiddenAncestor) return;
      @try { if(!MMToggleMotionBlur(target.manager,target.row)) NSBeep(); } @catch(NSException *exception) { NSBeep(); }
    }); return YES;
  }];
  [self refreshValues];
  self.timer=[NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
    MMPropertyRowBinding *row=weakSelf; if(!row) { [timer invalidate]; return; } [row refreshValues];
  }];
  [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (void)refreshValues {
  if(!self.row.window || self.row.hiddenOrHasHiddenAncestor || self.row.interacting) return;
  for(ICValueTextField *field in self.row.fields) field.enabled=NO;
  self.slider.enabled=NO;
  id<FxCustomParameterActionAPI_v4> action=[self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)]; if(!action) return;
  [action startAction:self.row];
  @try {
    CMTime time=[action currentTime]; BOOL explicit=NO;
    id<FxParameterRetrievalAPI_v6> get=[self.manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    if(![get getBoolValue:&explicit fromParameter:MMExplicitCreation atTime:time]) return;
    NSArray *entries=[self.cache snapshotEntries];
    if(explicit) {
      if(!entries.count || !entries[0][@"nativeTime"]) return;
      NSDictionary *destination=entries.lastObject;
      for(NSDictionary *entry in entries) if(CMTimeGetSeconds(time)<=[entry[@"time"] doubleValue]+1e-6) { destination=entry; break; }
      [destination[@"nativeTime"] getValue:&time];
    }
    id<MMPropertyPose> pose=[self.lane sampleEntries:entries time:time]; if(!pose) return;
    NSArray<NSNumber *> *values=pose.values;
    if(values.count!=self.row.fields.count) return;
    for(NSUInteger i=0;i<values.count;i++) {
      ICValueTextField *field=self.row.fields[i]; field.enabled=YES;
      if(!field.objectValue || field.doubleValue!=values[i].doubleValue) field.doubleValue=values[i].doubleValue;
    }
    self.slider.enabled=YES;
    if(self.slider && self.slider.doubleValue!=pose.value) self.slider.doubleValue=pose.value;
  } @finally { [action endAction:self.row]; }
}
- (void)updateSelection {
  self.row.selected=self.plugin && self.plugin.activeInspectorParameterID==self.lane.parameterID;
}
- (void)beginScrub {
  id<FxCustomParameterActionAPI_v4> action=[self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)]; if(!action) return;
  [action startAction:self.row];
  @try { id<FxUndoAPI> undo=[self.manager apiForProtocol:@protocol(FxUndoAPI)]; if([undo startUndoGroup:self.undoName]) self.scrubUndo=undo; }
  @finally { [action endAction:self.row]; }
}
- (void)endScrub {
  id<FxCustomParameterActionAPI_v4> action=[self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [action startAction:self.row];
  @try { [self.scrubUndo endUndoGroup]; } @finally { self.scrubUndo=nil; [action endAction:self.row]; }
}
- (void)writeField:(ICValueTextField *)field {
  NSUInteger component=[self.row.fields indexOfObjectIdenticalTo:field];
  if(component==NSNotFound) return;
  id<FxCustomParameterActionAPI_v4> action=[self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)]; if(!action) return;
  [action startAction:self.row];
  @try {
    id<FxUndoAPI> undo=self.scrubUndo ? nil:[self.manager apiForProtocol:@protocol(FxUndoAPI)];
    BOOL grouped=[undo startUndoGroup:self.undoName];
    @try {
      CMTime time=[action currentTime]; BOOL explicit=NO;
      id<FxParameterRetrievalAPI_v6> get=[self.manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      if(![get getBoolValue:&explicit fromParameter:MMExplicitCreation atTime:time] || ![self.lane writeComponent:component value:field.doubleValue manager:self.manager cache:self.cache time:time explicit:explicit]) NSBeep();
    } @finally { if(grouped) [undo endUndoGroup]; }
  } @finally { [action endAction:self.row]; }
}
- (void)activate {
  self.plugin.activeInspectorParameterID=self.lane.parameterID;
  [NSNotificationCenter.defaultCenter postNotificationName:@"MMActiveRowChanged" object:self.plugin];
  [[MMShortcutCapture sharedCapture] activateView:self.row];
}
- (void)dealloc {
  [self.timer invalidate];
  if(self.selectionObserver) [NSNotificationCenter.defaultCenter removeObserver:self.selectionObserver];
  [[MMShortcutCapture sharedCapture] detachView:self.row];
}
@end

static BOOL MMRowHostRegion(ICInspectorRow *row,NSPoint point) {
  NSPoint local=[row convertPoint:point fromView:row.superview];
  return local.x>=NSMaxX(row.bounds)-ICInspectorHostGutter;
}
static void MMDrawRowSelection(ICInspectorRow *row) {
  if(!row.selected) return;
  NSRect rect=row.bounds; rect.size.width=MAX(0,rect.size.width-ICInspectorHostGutter);
  if(NSWidth(rect)>4) {
    [[ICInspectorTokens.accentMatchingHost colorWithAlphaComponent:0.12] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect,2,1) xRadius:3 yRadius:3] fill];
  }
}

@interface MMScalarRow ()
@property(nonatomic,strong) MMPropertyRowBinding *binding;
@end
@implementation MMScalarRow
- (instancetype)initWithPlugin:(MagicMovePlugin *)plugin lane:(MMPropertyLane *)lane label:(NSString *)label {
  if((self=[super initWithLabel:label identifier:lane.parameterID fractionDigits:1]))
    _binding=[[MMPropertyRowBinding alloc] initWithRow:self slider:self.sliderView plugin:plugin lane:lane label:label];
  return self;
}
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; [self.binding attach]; }
- (void)refreshValues { [self.binding refreshValues]; }
- (NSView *)hitTest:(NSPoint)point {
  if(MMRowHostRegion(self,point)) return nil;
  NSView *hit=[super hitTest:point];
  if(hit && NSApp.currentEvent.type==NSEventTypeLeftMouseDown) [self.binding activate];
  return hit;
}
- (void)drawRect:(NSRect)dirtyRect { MMDrawRowSelection(self); [super drawRect:dirtyRect]; }
@end

@interface MMVectorRow ()
@property(nonatomic,strong) MMPropertyRowBinding *binding;
@end
@implementation MMVectorRow
- (instancetype)initWithPlugin:(MagicMovePlugin *)plugin lane:(MMPropertyLane *)lane label:(NSString *)label components:(NSArray<ICInspectorComponent *> *)components {
  if((self=[super initWithLabel:label components:components showsLink:NO]))
    _binding=[[MMPropertyRowBinding alloc] initWithRow:self slider:nil plugin:plugin lane:lane label:label];
  return self;
}
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; [self.binding attach]; }
- (void)refreshValues { [self.binding refreshValues]; }
- (NSView *)hitTest:(NSPoint)point {
  if(MMRowHostRegion(self,point)) return nil;
  NSView *hit=[super hitTest:point];
  if(hit && NSApp.currentEvent.type==NSEventTypeLeftMouseDown) [self.binding activate];
  return hit;
}
- (void)drawRect:(NSRect)dirtyRect { MMDrawRowSelection(self); [super drawRect:dirtyRect]; }
@end
