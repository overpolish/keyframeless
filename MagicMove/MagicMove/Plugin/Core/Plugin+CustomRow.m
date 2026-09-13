/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "Plugin_Private.h"
#import "Constants.h"
#import "MMCombinedPose.h"
#import "MMScalePose.h"
#import "MMScalarPose.h"
#import "MMPropertyRow.h"
#import "MMRotationPose.h"
#import "MMInspectorColors.h"
#import "MMShortcut.h"
#import "MMTimingEditor.h"
#import "MMResetParameter.h"
#import "MMNativeLinks.h"
@import InspectorControls;
#import <Cocoa/Cocoa.h>

// Opt-in layout painting for host diagnostics; never enabled in Release builds.
#ifndef MM_INSPECTOR_DEBUG_PAINT
#define MM_INSPECTOR_DEBUG_PAINT 0
#endif


// KKPlugin implements the view host in a private category.
@interface KKPlugin (MMCustomRowHost)
- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED;
@end

// Position and Scale inspector checkpoint. Native keyframe controls remain host-provided.
@interface MMCustomRow : ICInspectorRow
@property(nonatomic, strong) id<PROAPIAccessing> manager;
@property(nonatomic, strong) NSTimer *refreshTimer;
@property(nonatomic, strong) id selectionObserver;
@property(nonatomic, strong) MMCombinedPoseCache *poseCache;
@property(nonatomic, strong) MMScalePoseCache *scaleCache;
@property(nonatomic) BOOL scaleRow;
@property(nonatomic, weak) MagicMovePlugin *owner;
@property(nonatomic) NSSize pixelSize;
@property(nonatomic, copy) CGSize (^imageSizeProvider)(void);
@property(nonatomic, strong) id<FxUndoAPI> scrubUndo;
- (instancetype)initWithManager:(id<PROAPIAccessing>)manager;
- (instancetype)initWithManager:(id<PROAPIAccessing>)manager scale:(BOOL)scale;
@end

@implementation MMCustomRow
- (instancetype)initWithManager:(id<PROAPIAccessing>)manager {
  return [self initWithManager:manager scale:NO];
}
- (instancetype)initWithManager:(id<PROAPIAccessing>)manager scale:(BOOL)scale {
  NSArray *components=@[
    [[ICInspectorComponent alloc] initWithIdentifier:scale ? MMScaleX : MMPositionX
        label:@"X" suffix:scale ? @"%" : @"px" fractionDigits:scale ? 1 : 0],
    [[ICInspectorComponent alloc] initWithIdentifier:scale ? MMScaleY : MMPositionY
        label:@"Y" suffix:scale ? @"%" : @"px" fractionDigits:scale ? 1 : 0]
  ];
  self=[super initWithLabel:scale ? @"Scale" : @"Position" components:components showsLink:scale];
  if (!self) return nil;
  _manager=manager; _scaleRow=scale;
  self.componentColors=MMInspectorColors(scale ? MMScaleControls:MMCustomControls);

#if DEBUG && MM_INSPECTOR_DEBUG_PAINT
  // Opt-in visual diagnostics: actual field backgrounds, no overlay views,
  // tracking areas, constraints, or hit-test changes.
  for(NSTextField *label in [self.axisLabels arrayByAddingObject:self.titleLabel]) {
    label.drawsBackground=YES; label.backgroundColor=[NSColor.greenColor colorWithAlphaComponent:0.22];
  }
  for(NSTextField *field in self.fields) {
    field.drawsBackground=YES; field.backgroundColor=[NSColor.orangeColor colorWithAlphaComponent:0.28];
  }
  for(NSTextField *unit in self.unitLabels) {
    unit.drawsBackground=YES; unit.backgroundColor=[NSColor.purpleColor colorWithAlphaComponent:0.30];
  }
#endif
  __weak MMCustomRow *weakSelf=self;
  self.titleMenuProvider=^NSMenu *{ MMCustomRow *row=weakSelf; return row ? MMNativePropertyMenu(row.manager,row,row.scaleRow ? MMScaleControls:MMCustomControls):nil; };
  self.onValueCommit=^(ICValueTextField *field) { [weakSelf commitValue:field]; };
  self.onScrubBegin=^{ [weakSelf beginScrub]; };
  self.onScrubEnd=^{ [weakSelf endScrub]; };
  self.onLinkToggle=^(NSButton *button) { [weakSelf toggleProportional:button]; };
  if (scale) {
    _scaleCache=MMCreateScalePoseCache();
    self.linkButton.toolTip=@"Link X and Y (preserve proportions)";
    self.linkButton.accessibilityLabel=@"Proportional Scale";
  } else _poseCache=MMCreateCombinedPoseCache();
  id<FxCustomParameterActionAPI_v4> action = [manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (action) {
    [action startAction:self];
    @try {
      id<FxParameterSettingAPI_v5> set = [manager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      [set setStringParameterValue:scale ? _scaleCache.token : _poseCache.token
                      toParameter:scale ? MMScaleCacheToken : MMCombinedCacheToken];
    } @finally { [action endAction:self]; }
  }
  return self;
}
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  [self.refreshTimer invalidate]; self.refreshTimer = nil;
  if(self.selectionObserver) [NSNotificationCenter.defaultCenter removeObserver:self.selectionObserver];
  self.selectionObserver=nil;
  [[MMShortcutCapture sharedCapture] detachView:self];
  if (!self.window) return;
  __weak MMCustomRow *weakSelf = self;
  if(self.owner) self.selectionObserver=[NSNotificationCenter.defaultCenter
      addObserverForName:MMInspectorPresentationChanged object:self.owner queue:nil
      usingBlock:^(NSNotification *note) { [weakSelf updateSelection]; }];
  [self updateSelection];
  [[MMShortcutCapture sharedCapture] attachView:self action:^BOOL {
    MMCustomRow *view=weakSelf;
    if (!view || NSEvent.pressedMouseButtons) return NO;
    if (view.interacting) return NO;
    // Host actions must not block the event tap. Keep the selected owner for
    // this press, then verify its surface still exists before writing.
    dispatch_async(dispatch_get_main_queue(), ^{
      MMCustomRow *target=weakSelf;
      if (!target.window.isVisible || target.hiddenOrHasHiddenAncestor) return;
      @try { if (!MMToggleMotionBlur(target.manager,target)) NSBeep(); }
      @catch (NSException *exception) { NSBeep(); }
    });
    return YES;
  }];
  [self refreshValues];
  self.refreshTimer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
    MMCustomRow *view = weakSelf;
    if (!view) { [timer invalidate]; return; }
    [view refreshValues];
  }];
  [[NSRunLoop mainRunLoop] addTimer:self.refreshTimer forMode:NSRunLoopCommonModes];
}
- (void)updateSelection {
  UInt32 active=self.owner.activeInspectorParameterID ?: MMCustomControls;
  self.selected=self.owner && active==(self.scaleRow ? MMScaleControls:MMCustomControls);
  self.componentColorsVisible=[self.owner.graphedInspectorParameters containsObject:@(self.scaleRow ? MMScaleControls:MMCustomControls)];
}
- (NSView *)hitTest:(NSPoint)point {
  // Match KKParameterRowView's reserved host-controls region. A full-width
  // custom view must not claim clicks intended for native keyframe buttons.
  NSPoint local=[self convertPoint:point fromView:self.superview];
  BOOL hostRegion=local.x>=NSMaxX(self.bounds)-ICInspectorHostGutter;
  NSView *hit=hostRegion ? nil : [super hitTest:point];
  if(hostRegion) return nil;
  if (hit && NSApp.currentEvent.type==NSEventTypeLeftMouseDown) {
    self.owner.activeInspectorParameterID=self.scaleRow ? MMScaleControls : MMCustomControls;
    if(self.owner) [NSNotificationCenter.defaultCenter postNotificationName:MMInspectorPresentationChanged object:self.owner];
    [[MMShortcutCapture sharedCapture] activateView:self];
  }
  return hit;
}
- (void)drawRect:(NSRect)dirtyRect {

#if DEBUG && MM_INSPECTOR_DEBUG_PAINT
  // Paint the true row rectangle, then outline the frames occupied by its
  // actual controls. The red region is the reserved native-button gutter.
  [[NSColor.blueColor colorWithAlphaComponent:0.16] setFill];
  NSRectFillUsingOperation(self.bounds,NSCompositingOperationSourceOver);
  NSArray *groups=@[[self.axisLabels arrayByAddingObject:self.titleLabel],self.fields,self.unitLabels];
  NSArray *colors=@[NSColor.greenColor,NSColor.orangeColor,NSColor.purpleColor];
  for(NSUInteger i=0;i<groups.count;i++) {
    [colors[i] setStroke];
    for(NSView *part in groups[i]) {
      NSRect rect=part.superview ? [part convertRect:part.bounds toView:self] : part.frame;
      NSBezierPath *border=[NSBezierPath bezierPathWithRect:NSInsetRect(rect,0.5,0.5)];
      border.lineWidth=1; [border stroke];
    }
  }
  NSRect gutter=self.bounds;
  gutter.origin.x=MAX(NSMinX(self.bounds),NSMaxX(self.bounds)-ICInspectorHostGutter);
  gutter.size.width=NSMaxX(self.bounds)-NSMinX(gutter);
  [NSColor.redColor setStroke];
  NSBezierPath *hostBorder=[NSBezierPath bezierPathWithRect:NSInsetRect(gutter,0.5,0.5)];
  hostBorder.lineWidth=1; [hostBorder stroke];
#endif
  if(self.selected) {
    [[ICInspectorTokens.accentMatchingHost colorWithAlphaComponent:0.12] setFill];
    NSRect content=self.bounds;
    content.size.width=MAX(0,content.size.width-ICInspectorHostGutter);
    if(NSWidth(content)>4)
      [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(content,2,1) xRadius:3 yRadius:3] fill];
  }
  // Draw shared suffixes above the selection background.
  [super drawRect:dirtyRect];
}
- (void)dealloc {
  if(_selectionObserver) [NSNotificationCenter.defaultCenter removeObserver:_selectionObserver];
  [_refreshTimer invalidate];
  [[MMShortcutCapture sharedCapture] detachView:self];
}
- (void)refreshValues {
  // Cached sampling is read-only and may run while the host playhead is dragged.
  // Native linked-key writes still retain their separate mouse-up guard.
  if (!self.window || self.hiddenOrHasHiddenAncestor) return;
  if (self.interacting) return;
  // Preserve the last display while unavailable, but never allow stale edits.
  self.enabled = NO;
  id<FxCustomParameterActionAPI_v4> action = [self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action) return;
  [action startAction:self];
  @try {
    CGSize size = self.scaleRow ? CGSizeMake(100,100) : (self.imageSizeProvider ? self.imageSizeProvider() : CGSizeZero);
    if (!isfinite(size.width) || !isfinite(size.height) || size.width <= 0 || size.height <= 0) return;
    self.pixelSize = NSSizeFromCGSize(size);
    CMTime time = [action currentTime];
    self.keyposeLinkColor=MMNativePropertyLinkColor(self.manager,self.scaleRow ? MMScaleControls:MMCustomControls,time);
    self.keyposeLinked=self.keyposeLinkColor!=nil;
    id pose = self.scaleRow ? [self.scaleCache sampleAtTime:time] : [self.poseCache sampleAtTime:time];
    id<FxParameterRetrievalAPI_v6> get = [self.manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    BOOL explicit = NO;
    if (![get getBoolValue:&explicit fromParameter:MMExplicitCreation atTime:time]) return;
    if (self.scaleRow) {
      BOOL linked = YES;
      self.linkButton.enabled = [get getBoolValue:&linked fromParameter:MMScaleProportional atTime:time];
      self.linkButton.state = linked ? NSControlStateValueOn : NSControlStateValueOff;
      self.linkButton.contentTintColor = linked ? ICInspectorTokens.accentMatchingHost : ICInspectorTokens.inactiveControlColor;
    }
    if (explicit) {
      CMTime target;
      if (self.scaleRow)
        pose = [self.scaleCache valueTargetAtTime:time targetTime:&target] ? [self.scaleCache sampleAtTime:target] : nil;
      else pose = [self.poseCache valueTargetAtTime:time targetTime:&target] ? [self.poseCache sampleAtTime:target] : nil;
    }
    self.enabled = pose != nil;
    if (!pose) return;
    for (NSTextField *field in self.fields) {
      double dimension = field.tag == MMPositionX ? self.pixelSize.width : self.pixelSize.height;
      double value = self.scaleRow ? (field.tag == MMScaleX ? [(MMScalePose *)pose x] : [(MMScalePose *)pose y])
          : (field.tag == MMPositionX ? [(MMCombinedPose *)pose positionX] : [(MMCombinedPose *)pose positionY]) * dimension / 100.0;
      NSNumberFormatter *formatter = (NSNumberFormatter *)field.formatter;
      formatter.minimum = self.scaleRow ? @0 : @(-2 * dimension);
      formatter.maximum = self.scaleRow ? @400 : @(2 * dimension);
      if (!field.objectValue || field.doubleValue != value) {
        field.doubleValue = value;
      }
    }
  } @finally { [action endAction:self]; }
}
- (void)toggleProportional:(NSButton *)button {
  [self.window makeFirstResponder:nil];
  id<FxCustomParameterActionAPI_v4> action = [self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action) return;
  [action startAction:self];
  @try {
    id<FxParameterRetrievalAPI_v6> get = [self.manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    BOOL linked=YES;
    if (![get getBoolValue:&linked fromParameter:MMScaleProportional atTime:[action currentTime]]) return;
    id<FxUndoAPI> undo = [self.manager apiForProtocol:@protocol(FxUndoAPI)];
    BOOL grouped=[undo startUndoGroup:@"Link Scale Proportions"];
    @try {
      id<FxParameterSettingAPI_v5> set=[self.manager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      if (![set setBoolValue:!linked toParameter:MMScaleProportional atTime:[action currentTime]]) NSBeep();
    } @finally { if (grouped) [undo endUndoGroup]; }
  } @finally { [action endAction:self]; }
  [self refreshValues];
}
- (void)refreshScalePartnerOf:(ICValueTextField *)field atTime:(CMTime)time {
  // The successful write publishes a cache snapshot, including the linked axis.
  BOOL explicit=NO;
  id<FxParameterRetrievalAPI_v6> get=[self.manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (![get getBoolValue:&explicit fromParameter:MMExplicitCreation atTime:time]) return;
  CMTime target=time;
  if (explicit && ![self.scaleCache valueTargetAtTime:time targetTime:&target]) return;
  MMScalePose *pose=[self.scaleCache sampleAtTime:target];
  if (!pose) return;
  for (ICValueTextField *other in self.fields)
    if (!other.icEditing && !other.currentEditor) other.doubleValue=other.tag == MMScaleX ? pose.x : pose.y;
}
- (void)beginScrub {
  id<FxCustomParameterActionAPI_v4> action = [self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [action startAction:self];
  @try {
    id<FxUndoAPI> undo = [self.manager apiForProtocol:@protocol(FxUndoAPI)];
    if ([undo startUndoGroup:self.scaleRow ? @"Change Scale" : @"Change Position"]) self.scrubUndo = undo;
  } @finally { [action endAction:self]; }
}
- (void)endScrub {
  id<FxCustomParameterActionAPI_v4> action = [self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [action startAction:self];
  @try { [self.scrubUndo endUndoGroup]; }
  @finally { self.scrubUndo = nil; [action endAction:self]; }
}
- (void)commitValue:(ICValueTextField *)field {
  double dimension = field.tag == MMPositionX ? self.pixelSize.width : self.pixelSize.height;
  if (!(dimension > 0) || !isfinite(field.doubleValue)) return;
  id<FxCustomParameterActionAPI_v4> action = [self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action) { NSBeep(); return; }
  [action startAction:self];
  @try {
    id<FxUndoAPI> undo = self.scrubUndo ? nil : [self.manager apiForProtocol:@protocol(FxUndoAPI)];
    BOOL grouped = [undo startUndoGroup:self.scaleRow ? @"Change Scale" : @"Change Position"];
    @try {
      CMTime time = [action currentTime];
      BOOL ok = self.scaleRow ? MMWriteScaleComponent(self.manager,self.scaleCache,(UInt32)field.tag,field.doubleValue,time)
          : MMWriteCombinedComponent(self.manager,self.poseCache,(UInt32)field.tag,
              MAX(-200,MIN(200,field.doubleValue * 100.0 / dimension)),time);
      if (!ok) NSBeep();
      if (ok && self.scaleRow) [self refreshScalePartnerOf:field atTime:time];
    } @finally { if (grouped) [undo endUndoGroup]; }
  } @finally {
    [action endAction:self];
  }
}

@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation MagicMovePlugin (CustomRow)
- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == MMRotationControls) {
    NSMutableArray *components=[NSMutableArray array];
    NSArray *labels=@[@"X",@"Y",@"Z"];
    for(NSUInteger axis=0;axis<3;axis++)
      [components addObject:[[ICInspectorComponent alloc] initWithIdentifier:axis label:labels[axis] suffix:@"°" fractionDigits:1]];
    return [[MMVectorRow alloc] initWithPlugin:self lane:MMRotationLane() label:@"Rotation" components:components];
  }
  if (parameterID == MMOpacityControls) return [[MMScalarRow alloc] initWithPlugin:self lane:MMOpacityLane() label:@"Opacity"];
  if (parameterID == MMTimingControls) return [[MMTimingEditor alloc] initWithPlugin:self];
  if (parameterID == MMCustomControls || parameterID == MMScaleControls) {
    MMCustomRow *row = [[MMCustomRow alloc] initWithManager:self.apiManager scale:parameterID == MMScaleControls];
    row.owner=self;
    __weak MagicMovePlugin *plugin = self;
    row.imageSizeProvider = ^CGSize { return plugin.inspectorImageSize; };
    return row;
  }
  return [super createViewForParameterID:parameterID];
}
@end

#pragma clang diagnostic pop
