/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFPropertyRow.h"
#import "KFViewCaches.h"
#import "KFCreationDefaults.h"
#import "KFShortcut.h"
#import "KFResetParameter.h"
#import "KFNativeLinks.h"

// The row's keyboard shortcut belongs to the plugin; PoseLanes only routes it.
static BOOL (^KFRowShortcutAction)(id<PROAPIAccessing> manager, NSView *view);
void KFSetRowShortcutAction(BOOL (^action)(id<PROAPIAccessing> manager, NSView *view)) {
  KFRowShortcutAction=[action copy];
}

@interface KFPropertyRowBinding : NSObject <KFInspectorRefreshable>
@property(nonatomic, weak) ICInspectorRow *row;
@property(nonatomic, weak) ICSliderView *slider;
- (instancetype)initWithRow:(ICInspectorRow *)row slider:(ICSliderView *)slider plugin:(KFEffect *)plugin lane:(KFPropertyLane *)lane label:(NSString *)label;
- (void)attach;
- (void)refreshValues;
- (void)activate;
@property(nonatomic, weak) KFEffect *plugin;
@property(nonatomic, strong) id<PROAPIAccessing> manager;
@property(nonatomic, strong) KFPropertyLane *lane;
@property(nonatomic, readonly) KFPropertyPoseCache *cache;
@property(nonatomic, strong) id selectionObserver;
@property(nonatomic, strong) id<FxUndoAPI> scrubUndo;
@property(nonatomic, copy) NSString *undoName;
@end
@implementation KFPropertyRowBinding
- (instancetype)initWithRow:(ICInspectorRow *)row slider:(ICSliderView *)slider plugin:(KFEffect *)plugin lane:(KFPropertyLane *)lane label:(NSString *)label {
  if((self=[super init])) {
    _row=row; _slider=slider; _plugin=plugin; _manager=plugin.apiManager; _lane=lane;
    _undoName=[@"Change " stringByAppendingString:label];
    row.componentColors=lane.componentColors;
    slider.minValue=lane.minimum; slider.maxValue=lane.maximum; slider.enabled=NO;
    for(ICValueTextField *field in row.fields) {
      NSNumberFormatter *formatter=(NSNumberFormatter *)field.formatter;
      formatter.minimum=lane.boundsValues ? @(lane.minimum) : nil;
      formatter.maximum=lane.boundsValues ? @(lane.maximum) : nil;
    }
    __weak KFPropertyRowBinding *weakSelf=self;
    row.titleMenuProvider=^NSMenu *{ KFPropertyRowBinding *binding=weakSelf; return binding ? KFNativePropertyMenu(binding.manager,binding.row,binding.lane.parameterID):nil; };
    row.onValueCommit=^(ICValueTextField *field) { [weakSelf writeField:field]; };
    row.onScrubBegin=^{ [weakSelf beginScrub]; }; row.onScrubEnd=^{ [weakSelf endScrub]; };
    if(lane.proportionalToggleID) row.onLinkToggle=^(NSButton *button) { [weakSelf toggleProportional]; };
  }
  return self;
}
// The plugin owns one cache per lane and publishes its token once, so a
// rebuilt row costs no host traffic here.
- (KFPropertyPoseCache *)cache { return [self.plugin sharedCacheForLane:self.lane]; }
- (void)attach {
  KFInspectorClock *clock=self.plugin.inspectorClock;
  [clock removeView:self];
  if(self.selectionObserver) [NSNotificationCenter.defaultCenter removeObserver:self.selectionObserver]; self.selectionObserver=nil;
  [[KFShortcutCapture sharedCapture] detachView:self.row];
  if(!self.row.window) return;
  __weak KFPropertyRowBinding *weakSelf=self;
  self.selectionObserver=[NSNotificationCenter.defaultCenter addObserverForName:KFInspectorPresentationChanged object:self.plugin queue:nil usingBlock:^(NSNotification *note) { [weakSelf updateSelection]; }];
  [self updateSelection];
  [[KFShortcutCapture sharedCapture] attachView:self.row effect:self.manager action:^BOOL {
    KFPropertyRowBinding *row=weakSelf; if(!row || row.row.interacting || NSEvent.pressedMouseButtons) return NO;
    dispatch_async(dispatch_get_main_queue(),^{ KFPropertyRowBinding *target=weakSelf;
      if(!target.row.window.isVisible || target.row.hiddenOrHasHiddenAncestor) return;
      @try { if(KFRowShortcutAction && !KFRowShortcutAction(target.manager,target.row)) NSBeep(); }
      @catch(NSException *exception) { NSBeep(); }
    }); return YES;
  }];
  [self refreshValues];
  [clock addView:self];
}
// Standalone refresh for direct callers; the clock uses the action-scoped body.
- (void)refreshValues {
  id<FxCustomParameterActionAPI_v4> action=[self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)]; if(!action) return;
  [action startAction:self.row];
  @try { [self refreshInspectorValuesInAction:action]; }
  @finally { [action endAction:self.row]; }
  [self.row displayIfNeeded];
}
- (NSView *)inspectorRefreshView { return self.row; }
- (void)refreshInspectorValuesInAction:(id<FxCustomParameterActionAPI_v4>)action {
  if(!self.row.window || self.row.hiddenOrHasHiddenAncestor || self.row.interacting) return;
  self.row.enabled=NO;
  self.slider.enabled=NO;
  CMTime time=[action currentTime]; BOOL explicit=NO;
  self.row.keyposeLinkColor=KFNativePropertyLinkColor(self.manager,self.lane.parameterID,time);
  self.row.keyposeLinked=self.row.keyposeLinkColor!=nil;
  id<FxParameterRetrievalAPI_v6> get=[self.manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if(!KFExplicitCreationEnabled(self.manager,time,&explicit)) return;
  NSArray *entries=[self.cache snapshotEntries];
  if(explicit) {
    if(!entries.count) return;
    if(entries[0][@"nativeTime"]) {
      NSDictionary *destination=entries.lastObject;
      for(NSDictionary *entry in entries) if(CMTimeGetSeconds(time)<=[entry[@"time"] doubleValue]+1e-6) { destination=entry; break; }
      [destination[@"nativeTime"] getValue:&time];
    }
  }
  id<KFPropertyPose> pose=[self.lane sampleEntries:entries time:time]; if(!pose) return;
  NSArray<NSNumber *> *values=pose.values;
  if(values.count!=self.row.fields.count) return;
  if(self.lane.proportionalToggleID) {
    BOOL coupled=YES;
    self.row.linkButton.enabled=[get getBoolValue:&coupled fromParameter:self.lane.proportionalToggleID atTime:time];
    self.row.linkButton.state=coupled ? NSControlStateValueOn:NSControlStateValueOff;
    self.row.linkButton.contentTintColor=coupled ? ICInspectorTokens.accentMatchingHost:ICInspectorTokens.inactiveControlColor;
  }
  self.row.enabled=YES;
  for(NSUInteger i=0;i<values.count;i++) {
    ICValueTextField *field=self.row.fields[i];
    double value=values[i].doubleValue;
    if(self.lane.percentOfImage) {
      double dimension=[self dimensionForComponent:i];
      if(!(dimension>0)) { self.row.enabled=NO; return; }
      value=value*dimension/100.0;
      NSNumberFormatter *formatter=(NSNumberFormatter *)field.formatter;
      formatter.minimum=@(self.lane.minimum*dimension/100.0);
      formatter.maximum=@(self.lane.maximum*dimension/100.0);
    }
    if(!field.objectValue || field.doubleValue!=value) field.doubleValue=value;
  }
  self.slider.enabled=YES;
  if(self.slider && self.slider.doubleValue!=pose.value) self.slider.doubleValue=pose.value;
}
- (void)updateSelection {
  self.row.selected=self.plugin && self.plugin.activeInspectorParameterID==self.lane.parameterID;
  self.row.componentColorsVisible=[self.plugin.graphedInspectorParameters containsObject:@(self.lane.parameterID)];
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
// The coupling toggle is a document setting, not a keyframed value.
- (void)toggleProportional {
  if(!self.lane.proportionalToggleID) return;
  [self.row.window makeFirstResponder:nil];
  id<FxCustomParameterActionAPI_v4> action=[self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)]; if(!action) return;
  [action startAction:self.row];
  @try {
    id<FxParameterRetrievalAPI_v6> get=[self.manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    BOOL coupled=YES;
    if(![get getBoolValue:&coupled fromParameter:self.lane.proportionalToggleID atTime:[action currentTime]]) return;
    id<FxUndoAPI> undo=[self.manager apiForProtocol:@protocol(FxUndoAPI)];
    BOOL grouped=[undo startUndoGroup:[NSString stringWithFormat:@"Link %@ Proportions",self.lane.displayName]];
    @try {
      id<FxParameterSettingAPI_v5> set=[self.manager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      if(![set setBoolValue:!coupled toParameter:self.lane.proportionalToggleID atTime:[action currentTime]]) NSBeep();
    } @finally { if(grouped) [undo endUndoGroup]; }
  } @finally { [action endAction:self.row]; }
  [self refreshValues];
}
// Pixel display for percent-of-image lanes; the pose itself stays in percent.
- (double)dimensionForComponent:(NSUInteger)component {
  CGSize size=self.plugin.inspectorImageSize;
  return component==0 ? size.width:size.height;
}
// The coupled pair a proportional lane should write, or nil when the lane has
// no coupling or its toggle is off.
- (NSArray<NSNumber *> *)proportionalValuesForComponent:(NSUInteger)component
                                                  value:(double)value
                                                 atTime:(CMTime)time {
  if(!self.lane.proportionalToggleID || self.lane.componentCount!=2) return nil;
  id<FxParameterRetrievalAPI_v6> get=[self.manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  BOOL proportional=YES;
  if(![get getBoolValue:&proportional fromParameter:self.lane.proportionalToggleID atTime:time]) return nil;
  if(!proportional) return nil;
  id<KFPropertyPose> pose=[self.lane sampleEntries:[self.cache snapshotEntries] time:time];
  if(!pose || pose.values.count!=2) return nil;
  NSUInteger partner=1-component;
  double old=pose.values[component].doubleValue, other=pose.values[partner].doubleValue;
  // A zero axis cannot scale, so it follows the same displacement instead.
  NSMutableArray<NSNumber *> *values=[pose.values mutableCopy];
  values[component]=@(value);
  values[partner]=@(old==0 ? other+(value-old):other*(value/old));
  // Keep the ratio when either axis leaves the range, rather than clamping one.
  double factor=1;
  for(NSNumber *axis in values)
    if(axis.doubleValue>self.lane.maximum) factor=fmin(factor,self.lane.maximum/axis.doubleValue);
  for(NSNumber *axis in values)
    if(axis.doubleValue<self.lane.minimum) factor=0;
  if(factor<1)
    for(NSUInteger i=0;i<values.count;i++)
      values[i]=@(factor>0 ? values[i].doubleValue*factor:self.lane.minimum);
  return values;
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
      self.row.keyposeLinkColor=KFNativePropertyLinkColor(self.manager,self.lane.parameterID,time);
      self.row.keyposeLinked=self.row.keyposeLinkColor!=nil;
      if(!KFExplicitCreationEnabled(self.manager,time,&explicit)) { NSBeep(); return; }
      double value=field.doubleValue;
      if(self.lane.percentOfImage) {
        double dimension=[self dimensionForComponent:component];
        if(!(dimension>0) || !isfinite(value)) { NSBeep(); return; }
        value=fmax(self.lane.minimum,fmin(self.lane.maximum,value*100.0/dimension));
      }
      NSArray<NSNumber *> *coupled=[self proportionalValuesForComponent:component value:value atTime:time];
      BOOL ok=coupled ? [self.lane writeValues:coupled manager:self.manager cache:self.cache time:time explicit:explicit]
                      : [self.lane writeComponent:component value:value manager:self.manager cache:self.cache time:time explicit:explicit];
      if(!ok) { NSBeep(); return; }
      // The successful write published the pair, so show the coupled axis too.
      if(coupled)
        for(NSUInteger i=0;i<self.row.fields.count;i++) {
          ICValueTextField *other=self.row.fields[i];
          if(other==field || other.icEditing || other.currentEditor) continue;
          other.doubleValue=coupled[i].doubleValue;
        }
    } @finally { if(grouped) [undo endUndoGroup]; }
  } @finally { [action endAction:self.row]; }
}
- (void)activate {
  self.plugin.activeInspectorParameterID=self.lane.parameterID;
  [NSNotificationCenter.defaultCenter postNotificationName:KFInspectorPresentationChanged object:self.plugin];
  [[KFShortcutCapture sharedCapture] activateView:self.row];
}
- (void)dealloc {
  // Weak clock registration drops itself; the observer and shortcut do not.
  if(self.selectionObserver) [NSNotificationCenter.defaultCenter removeObserver:self.selectionObserver];
  [[KFShortcutCapture sharedCapture] detachView:self.row];
}
@end

static BOOL KFRowHostRegion(ICInspectorRow *row,NSPoint point) {
  NSPoint local=[row convertPoint:point fromView:row.superview];
  return local.x>=NSMaxX(row.bounds)-ICInspectorHostGutter;
}
static void KFDrawRowSelection(ICInspectorRow *row) {
  if(!row.selected) return;
  NSRect rect=row.bounds; rect.size.width=MAX(0,rect.size.width-ICInspectorHostGutter);
  if(NSWidth(rect)>4) {
    [[ICInspectorTokens.accentMatchingHost colorWithAlphaComponent:0.12] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect,2,1) xRadius:3 yRadius:3] fill];
  }
}

@interface KFScalarRow ()
@property(nonatomic,strong) KFPropertyRowBinding *binding;
@end
@implementation KFScalarRow
- (instancetype)initWithEffect:(KFEffect *)effect lane:(KFPropertyLane *)lane {
  if((self=[super initWithLabel:lane.displayName identifier:lane.parameterID suffix:lane.unitSuffix
                 fractionDigits:lane.fractionDigits]))
    _binding=[[KFPropertyRowBinding alloc] initWithRow:self slider:self.sliderView plugin:effect lane:lane
                                                 label:lane.displayName];
  return self;
}
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; [self.binding attach]; }
- (void)refreshValues { [self.binding refreshValues]; }
- (NSView *)hitTest:(NSPoint)point {
  if(KFRowHostRegion(self,point)) return nil;
  NSView *hit=[super hitTest:point];
  if(hit && NSApp.currentEvent.type==NSEventTypeLeftMouseDown) [self.binding activate];
  return hit;
}
- (void)drawRect:(NSRect)dirtyRect { KFDrawRowSelection(self); [super drawRect:dirtyRect]; }
@end

@interface KFVectorRow ()
@property(nonatomic,strong) KFPropertyRowBinding *binding;
@end
@implementation KFVectorRow
- (instancetype)initWithEffect:(KFEffect *)effect lane:(KFPropertyLane *)lane {
  NSMutableArray<ICInspectorComponent *> *components=[NSMutableArray arrayWithCapacity:lane.componentCount];
  for(NSUInteger axis=0;axis<lane.componentCount;axis++)
    [components addObject:[[ICInspectorComponent alloc] initWithIdentifier:(NSInteger)axis
        label:lane.componentLabels[axis] suffix:lane.unitSuffix fractionDigits:lane.fractionDigits]];
  if((self=[super initWithLabel:lane.displayName components:components showsLink:lane.proportionalToggleID!=0])) {
    _binding=[[KFPropertyRowBinding alloc] initWithRow:self slider:nil plugin:effect lane:lane
                                                 label:lane.displayName];
    if(lane.proportionalToggleID) {
      self.linkButton.toolTip=[NSString stringWithFormat:@"Link %@ components (preserve proportions)",lane.displayName];
      self.linkButton.accessibilityLabel=[NSString stringWithFormat:@"Proportional %@",lane.displayName];
    }
  }
  return self;
}
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; [self.binding attach]; }
- (void)refreshValues { [self.binding refreshValues]; }
- (NSView *)hitTest:(NSPoint)point {
  if(KFRowHostRegion(self,point)) return nil;
  NSView *hit=[super hitTest:point];
  if(hit && NSApp.currentEvent.type==NSEventTypeLeftMouseDown) [self.binding activate];
  return hit;
}
- (void)drawRect:(NSRect)dirtyRect { KFDrawRowSelection(self); [super drawRect:dirtyRect]; }
@end
