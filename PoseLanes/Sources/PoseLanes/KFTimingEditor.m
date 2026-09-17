/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFCreationDefaults.h"
#import "KFTimingEditor.h"
#import "KFViewCaches.h"
#import "KFPropertyMenu.h"
#import "KFHostSettings.h"
#import "KFShortcut.h"
#import "KFPropertyLane.h"
#import "KFResetParameter.h"
#import "KFTimingEditorModel.h"
@import InspectorControls;

// Menu-item images use NSPopUpButton's native image support. Curve semantics
// stay in the plugin; InspectorControls remains independent of motion types.
static NSImage *KFTimingMenuGlyph(BOOL addedMotion, NSInteger type) {
  double startValue=addedMotion ? 1 : 0, endValue=1;
  MTDestination poses[2]={
    {.arrival=0,.values=&startValue,.addedMotion=addedMotion ? (MTAddedMotion)type : MTAddedMotionNone},
    {.arrival=1,.duration=addedMotion ? 0 : 1,.values=&endValue,.easing=addedMotion ? MTEasingSmooth : (MTEasing)type}
  };
  NSMutableArray<NSNumber *> *samples=[NSMutableArray new];
  double low=INFINITY,high=-INFINITY;
  for (NSUInteger i=0;i<65;i++) {
    double value=0;
    MTSample(poses,2,1,(double)i/64,&value);
    [samples addObject:@(value)];
    low=fmin(low,value); high=fmax(high,value);
  }
  double span=high-low;
  NSImage *image=[NSImage imageWithSize:NSMakeSize(28,16) flipped:NO drawingHandler:^BOOL(NSRect rect) {
    NSBezierPath *line=[NSBezierPath bezierPath];
    line.lineWidth=1.25;
    line.lineCapStyle=NSLineCapStyleRound;
    line.lineJoinStyle=NSLineJoinStyleRound;
    for (NSUInteger i=0;i<samples.count;i++) {
      double y=span>1e-6 ? (samples[i].doubleValue-low)/span : 0.5;
      NSPoint point=NSMakePoint(2+(NSWidth(rect)-4)*i/(samples.count-1),3+(NSHeight(rect)-6)*y);
      if (i) [line lineToPoint:point]; else [line moveToPoint:point];
    }
    [NSColor.blackColor setStroke]; [line stroke]; return YES;
  }];
  image.template=YES;
  return image;
}
static NSString *KFTimingPropertyName(UInt32 parameter) {
  return KFPropertyDisplayName(parameter) ?: KFPropertyLanes().firstObject.displayName;
}

@interface KFGapGraph : NSView
@property(nonatomic, copy) NSArray<NSArray<NSNumber *> *> *points;
@property(nonatomic) double progress;
@property(nonatomic,copy) NSArray<NSNumber *> *startFractions;
@property(copy) NSArray<NSBezierPath *> *curvePaths;
@property(nonatomic, copy) NSArray<NSColor *> *componentColors;
@property NSRect curveBounds;
@property(nonatomic) BOOL scrubbing;
@property(copy) void (^onScrub)(double fraction);
@property(copy) void (^onScrubEnd)(void);
- (void)prepareCurves;
@end
@implementation KFGapGraph
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)scrubEvent:(NSEvent *)event {
  NSRect plot=NSInsetRect(self.bounds,8,8);
  if (NSWidth(plot)<=0 || !self.onScrub) return;
  NSPoint point=[self convertPoint:event.locationInWindow fromView:nil];
  self.onScrub(fmax(0,fmin(1,(point.x-NSMinX(plot))/NSWidth(plot))));
}
- (void)mouseDown:(NSEvent *)event {
  if (self.points.count<2 || !self.onScrub) return;
  self.scrubbing=YES;
  [self scrubEvent:event];
}
- (void)mouseDragged:(NSEvent *)event {
  if (self.scrubbing) [self scrubEvent:event];
}
- (void)mouseUp:(NSEvent *)event {
  if (!self.scrubbing) return;
  [self scrubEvent:event];
  self.scrubbing=NO;
  if (self.onScrubEnd) self.onScrubEnd();
}
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (!self.window) self.scrubbing=NO;
}
- (void)setPoints:(NSArray<NSArray<NSNumber *> *> *)points {
  if (_points == points)
    return;
  _points = [points copy];
  self.curvePaths = nil;
  self.needsDisplay = YES;
}
- (void)setStartFractions:(NSArray<NSNumber *> *)starts {
  if ([_startFractions isEqualToArray:starts]) return;
  _startFractions=[starts copy]; self.curvePaths=nil; self.needsDisplay=YES;
}
- (void)setComponentColors:(NSArray<NSColor *> *)componentColors {
  if([_componentColors isEqualToArray:componentColors]) return;
  _componentColors=[componentColors copy]; self.needsDisplay=YES;
}
- (void)setProgress:(double)progress {
  if (_progress == progress)
    return;
  _progress = progress;
  self.needsDisplay = YES;
}
- (void)prepareCurves {
  if (self.curvePaths && NSEqualRects(self.curveBounds, self.bounds))
    return;
  self.curveBounds = self.bounds;
  NSMutableArray *paths = [NSMutableArray array];
  NSRect plot = NSInsetRect(self.bounds, 8, 8);
  if (self.points.count < 2) {
    self.curvePaths = paths;
    return;
  }
  double low = INFINITY, high = -INFINITY;
  for(NSArray<NSNumber *> *sample in self.points) for(NSNumber *value in sample) {
    low=fmin(low,value.doubleValue); high=fmax(high,value.doubleValue);
  }
  double span = high - low;
  if (span < 1e-6) {
    low -= 0.5;
    span = 1;
  }
  low -= span * 0.08;
  span *= 1.16;
  for (NSUInteger axis = 0; axis < self.points.firstObject.count; axis++) {
    NSBezierPath *line = [NSBezierPath bezierPath];
    line.lineWidth = 1.5;
    for (NSUInteger i = 0; i < self.points.count; i++) {
      double sample = self.points[i][axis].doubleValue;
      NSPoint p = NSMakePoint(
          NSMinX(plot) + NSWidth(plot) * ((axis<self.startFractions.count ? self.startFractions[axis].doubleValue : 0) +
              (1-(axis<self.startFractions.count ? self.startFractions[axis].doubleValue : 0))*i/(self.points.count-1)),
          NSMinY(plot) +
              NSHeight(plot) * (sample - low) / span);
      if (i)
        [line lineToPoint:p];
      else
        [line moveToPoint:p];
    }
    [paths addObject:line];
  }
  self.curvePaths = paths;
}
- (void)drawRect:(NSRect)dirtyRect {
  NSRect plot = NSInsetRect(self.bounds, 8, 8);
  [[NSColor colorWithWhite:0 alpha:0.15] setFill];
  [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:4
                                   yRadius:4] fill];
  [[NSColor colorWithWhite:1 alpha:0.04] setStroke];
  NSBezierPath *grid = [NSBezierPath bezierPath];
  const CGFloat spacing = 16;
  grid.lineWidth = 0.5;
  for (CGFloat x = NSMinX(plot); x <= NSMaxX(plot); x += spacing) {
    [grid moveToPoint:NSMakePoint(x, NSMinY(plot))];
    [grid lineToPoint:NSMakePoint(x, NSMaxY(plot))];
  }
  for (CGFloat y = NSMinY(plot); y < NSMaxY(plot); y += spacing) {
    [grid moveToPoint:NSMakePoint(NSMinX(plot), y)];
    [grid lineToPoint:NSMakePoint(NSMaxX(plot), y)];
  }
  // Close the top even when the plot height is not a multiple of the grid spacing.
  [grid moveToPoint:NSMakePoint(NSMinX(plot), NSMaxY(plot))];
  [grid lineToPoint:NSMakePoint(NSMaxX(plot), NSMaxY(plot))];
  [grid stroke];
  if (self.points.count < 2)
    return;
  [self prepareCurves];
  for (NSUInteger axis = 0; axis < self.curvePaths.count; axis++) {
    [(axis<self.componentColors.count ? self.componentColors[axis]
           : ICInspectorTokens.accentMatchingHost) setStroke];
    [self.curvePaths[axis] stroke];
    if (self.startFractions.count && self.curvePaths[axis].elementCount) {
      NSBezierPath *path=self.curvePaths[axis];
      NSPoint start,end;
      [path elementAtIndex:0 associatedPoints:&start];
      [path elementAtIndex:path.elementCount-1 associatedPoints:&end];
      [(axis<self.componentColors.count ? self.componentColors[axis] : ICInspectorTokens.accentMatchingHost) setFill];
      for (NSValue *value in @[[NSValue valueWithPoint:start],[NSValue valueWithPoint:end]]) {
        NSPoint point=value.pointValue;
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(point.x-2,point.y-2,4,4)] fill];
      }
    }
  }
  [NSColor.whiteColor setStroke];
  NSBezierPath *cursor = [NSBezierPath bezierPath];
  CGFloat x = NSMinX(plot) + NSWidth(plot) * fmax(0, fmin(1, self.progress));
  [cursor moveToPoint:NSMakePoint(x, NSMinY(plot))];
  [cursor lineToPoint:NSMakePoint(x, NSMaxY(plot))];
  [cursor stroke];
}
@end

// Render callbacks recreate arrays and pose objects even when no key changed.
// Compare the values used by the evaluator, not snapshot object identity.
static BOOL KFGraphEntriesEqual(NSArray *a, NSArray *b) {
  if (a == b)
    return YES;
  if (!a || !b || a.count != b.count)
    return NO;
  for (NSUInteger i = 0; i < a.count; i++)
    if (![a[i][@"time"] isEqual:b[i][@"time"]] ||
        ![a[i][@"pose"] isEqual:b[i][@"pose"]])
      return NO;
  return YES;
}
static void KFEnable(NSControl *control, BOOL enabled) {
  if (control.enabled != enabled)
    control.enabled = enabled;
}
static void KFText(NSTextField *field, NSString *text) {
  if (![field.stringValue isEqualToString:text])
    field.stringValue = text;
}
static void KFNumber(NSTextField *field, double value) {
  if (!field.objectValue || field.doubleValue != value)
    field.doubleValue = value;
}
static void KFSelect(NSPopUpButton *menu, NSInteger index) {
  if (menu.indexOfSelectedItem != index)
    [menu selectItemAtIndex:index];
}

@interface KFTimingEditor () <KFInspectorRefreshable>
@property(weak) KFEffect *plugin;
@property(strong) id<PROAPIAccessing> manager;
@property(strong) ICPopUpButton *easingMenu;
@property(strong) ICPopUpButton *motionMenu;
@property(strong) NSButton *available;
@property(strong) NSButton *seedButton;
@property(strong) NSTextField *gapLabel;
@property(strong) NSNumberFormatter *gapTimeFormatter;
@property(strong) NSTextField *motionLabel;
@property(strong) NSTextField *easingLabel;
@property(strong) KFGapGraph *graph;
@property(strong) ICInspectorRow *durationRow;
@property(strong) ICInspectorRow *motionRow;
@property(strong) id<FxUndoAPI> scrubUndo;
@property UInt32 displayedParameter;
@property BOOL writingSetting;
@property(copy) NSArray<KFInspectorGap *> *plottedGaps;
@property UInt32 plottedParameter;
@property CGSize plottedSize;
@end
@implementation KFTimingEditor
- (NSTextField *)label:(NSString *)text {
  NSTextField *label = [ICMenuTextField labelWithString:text];
  label.font = ICInspectorTokens.labelFont;
  label.textColor = ICInspectorTokens.labelColor;
  [self addSubview:label];
  return label;
}
- (ICPopUpButton *)menu:(NSArray<NSString *> *)items
                setting:(NSInteger)setting {
  ICPopUpButton *menu = [[ICPopUpButton alloc] initWithFrame:NSZeroRect
                                                   pullsDown:NO];

  [menu addItemsWithTitles:items];
  for (NSUInteger i=0;i<menu.numberOfItems;i++)
    [menu itemAtIndex:i].image=KFTimingMenuGlyph(setting==KFInspectorMotion,(NSInteger)i);
  menu.tag = setting;
  menu.target = self;
  menu.action = @selector(menuChanged:);
  [self addSubview:menu];
  return menu;
}
- (instancetype)initWithEffect:(KFEffect *)plugin {
  if (!(self = [super initWithFrame:NSMakeRect(0, 0, 320, 252)]))
    return nil;
  _plugin = plugin;
  _manager = plugin.apiManager;
  self.autoresizingMask = NSViewWidthSizable;
  _gapLabel = [self label:@"Add two keyframes to edit motion"];
  _gapTimeFormatter=[NSNumberFormatter new];
  _gapTimeFormatter.numberStyle=NSNumberFormatterDecimalStyle;
  _gapTimeFormatter.usesGroupingSeparator=NO;
  _gapTimeFormatter.minimumFractionDigits=0;
  _gapTimeFormatter.maximumFractionDigits=2;
  _graph = [KFGapGraph new];
  _graph.accessibilityLabel = @"Evaluated motion preview";
  __weak KFTimingEditor *weakEditor=self;
  _graph.onScrub=^(double fraction) { [weakEditor scrubGraphToFraction:fraction]; };
  _graph.onScrubEnd=^{ [weakEditor refresh]; };
  [self addSubview:_graph];
  _durationRow = [[ICInspectorRow alloc]
      initWithLabel:@"Duration"
         components:@[ [[ICInspectorComponent alloc]
                        initWithIdentifier:KFInspectorDuration
                                     label:@""
                                    suffix:@"s"
                            fractionDigits:2] ]
          showsLink:NO];
  _durationRow.titleMenuProvider=^{ return [weakEditor defaultContextMenu:KFInspectorDuration]; };
  _durationRow.fields.firstObject.contextMenuProvider=_durationRow.titleMenuProvider;
  [self addSubview:_durationRow];
  _available = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"arrow.left.and.right"
      accessibilityDescription:@"Use available time"] target:self action:@selector(availableChanged:)];
  [_available setButtonType:NSButtonTypeToggle];
  _available.bordered=NO;
  _available.imageScaling=NSImageScaleProportionallyDown;
  _available.contentTintColor=ICInspectorTokens.decorationColor;
  _available.toolTip=@"Use all available time between keyframes.";
  [self addSubview:_available];
  _easingLabel=[self label:@"Easing"];
  _easingMenu = [self menu:@[ @"Smooth", @"Linear", @"Ease In", @"Ease Out" ]
                   setting:KFInspectorEasing];
  ((ICMenuTextField *)_easingLabel).menuProvider=^{ return [weakEditor defaultContextMenu:KFInspectorEasing]; };
  ((ICPopUpButton *)_easingMenu).contextMenuProvider=((ICMenuTextField *)_easingLabel).menuProvider;
  _easingMenu.accessibilityLabel = @"Incoming easing";
  _motionLabel = [self label:@"Position Added Motion"];
  ((ICMenuTextField *)_motionLabel).menuProvider=^{ return [weakEditor motionContextMenu:NO]; };
  _seedButton=[NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"dice" accessibilityDescription:@"Randomize Added Motion"] target:self action:@selector(randomizeMotionSeed:)];
  _seedButton.bordered=NO; _seedButton.imageScaling=NSImageScaleProportionallyDown;
  _seedButton.contentTintColor=ICInspectorTokens.decorationColor;
  [self addSubview:_seedButton];
  _motionMenu = [self menu:@[ @"None", @"Wave", @"Wiggle", @"Handheld" ]
                   setting:KFInspectorMotion];
  _motionMenu.accessibilityLabel = @"Added motion type";
  _motionRow = [[ICInspectorRow alloc]
      initWithLabel:@"Added motion"
         components:@[
           [[ICInspectorComponent alloc] initWithIdentifier:KFInspectorAmount
                                                      label:@""
                                                     suffix:@"%"
                                             fractionDigits:0],
           [[ICInspectorComponent alloc] initWithIdentifier:KFInspectorSpeed
                                                      label:@""
                                                     suffix:@"×"
                                             fractionDigits:2]
         ]
          showsLink:NO];
  _motionRow.titleMenuProvider=^{ return [weakEditor motionContextMenu:YES]; };
  for (ICValueTextField *field in _motionRow.fields)
    field.contextMenuProvider=_motionRow.titleMenuProvider;
  [self addSubview:_motionRow];
  __weak KFTimingEditor *weakSelf = self;
  for (ICInspectorRow *row in @[ _durationRow, _motionRow ]) {
    row.onValueCommit = ^(ICValueTextField *field) {
      [weakSelf writeSetting:field.tag
                       value:field.doubleValue /
                             (field.tag == KFInspectorAmount ? 100 : 1)];
    };
    row.onScrubBegin = ^{
      [weakSelf beginScrub];
    };
    row.onScrubEnd = ^{
      [weakSelf endScrub];
    };
    for (ICValueTextField *field in row.fields) {
      NSNumberFormatter *format = (id)field.formatter;
      format.minimum = field.tag == KFInspectorSpeed ? @0.05 : @0;
      format.maximum = field.tag == KFInspectorDuration ? @60
                       : field.tag == KFInspectorAmount ? @300
                                                        : @10;
      field.scrubStep = field.tag == KFInspectorAmount ? 1 : 0.01;
      field.accessibilityLabel =
          field.tag == KFInspectorAmount  ? @"Added motion amount"
          : field.tag == KFInspectorSpeed ? @"Added motion speed"
                                          : @"Incoming duration";
    }
  }
  _motionRow.fields[0].toolTip = @"Amount of added motion";
  _motionRow.fields[1].toolTip = @"Speed of added motion";
  [self setEditorsEnabled:NO];
  return self;
}
- (NSSize)intrinsicContentSize {
  return NSMakeSize(NSViewNoIntrinsicMetric, 252);
}
- (void)layout {
  [super layout];
  CGFloat width = NSWidth(self.bounds), right = MAX(140, width - 22),
          content = MAX(0, right - 21);
  self.gapLabel.frame = NSMakeRect(21, 226, content, 18);
  self.graph.frame = NSMakeRect(21, 124, content, 96);
  self.durationRow.frame = NSMakeRect(0, 95, width, 24);
  self.easingLabel.frame=NSMakeRect(21,74,140,18);
  [self.durationRow layoutSubtreeIfNeeded];
  CGFloat menuRight=NSMaxX(self.durationRow.unitLabels.lastObject.frame);
  self.easingMenu.frame =
      NSMakeRect(165, 74, MAX(0, menuRight - 165), 18);
  self.seedButton.frame=NSMakeRect(menuRight+4,31,16,18);
  NSTextField *unit=self.durationRow.unitLabels.lastObject;
  CGFloat suffixCenter=NSMinY(self.durationRow.frame)+NSMaxY(unit.frame)-unit.firstBaselineOffsetFromTop+unit.font.capHeight/2;
  self.available.frame=NSMakeRect(menuRight+4,round((suffixCenter-9)*2)/2,16,18);
  CGFloat motionLabelWidth=MIN(160,MAX(0,menuRight-21-115));
  self.motionLabel.frame=NSMakeRect(21,31,motionLabelWidth,18);
  self.motionMenu.frame=NSMakeRect(21+motionLabelWidth+4,31,MAX(0,menuRight-21-motionLabelWidth-4),18);
  self.motionRow.frame = NSMakeRect(0, 5, width, 24);
  self.motionRow.titleLabel.stringValue = @"Amount / Speed";
}
- (void)publishGraphParameters:(NSSet<NSNumber *> *)parameters {
  if (!self.plugin) return;
  if ([self.plugin.graphedInspectorParameters isEqualToSet:parameters]) return;
  self.plugin.graphedInspectorParameters=parameters;
  [NSNotificationCenter.defaultCenter postNotificationName:KFInspectorPresentationChanged object:self.plugin];
}
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  KFInspectorClock *clock = self.plugin.inspectorClock;
  [clock removeView:self];
  if (!self.window) {
    [self publishGraphParameters:[NSSet set]];
    [self endScrub];
    return;
  }
  [self refresh];
  [clock addView:self];
}
- (void)setEditorsEnabled:(BOOL)enabled {
  KFEnable(self.available, enabled);
  KFEnable(self.easingMenu, enabled);
  KFEnable(self.motionMenu, enabled);
  KFEnable(self.seedButton, enabled);
  for (ICInspectorRow *row in @[ self.durationRow, self.motionRow ])
    row.enabled = enabled;
  self.easingLabel.textColor = enabled ? ICInspectorTokens.labelColor : ICInspectorTokens.disabledTextColor;
  self.motionLabel.textColor = enabled ? ICInspectorTokens.labelColor : ICInspectorTokens.disabledTextColor;
}
- (void)updateControlsForGap:(KFInspectorGap *)gap editing:(BOOL)editing {
  KFText(self.motionLabel,[NSString stringWithFormat:@"%@ Added Motion",KFTimingPropertyName(self.displayedParameter)]);
  KFText(
      self.gapLabel,
      gap ? [NSString stringWithFormat:@"%@s → %@s",
                 [self.gapTimeFormatter stringFromNumber:@(CMTimeGetSeconds(gap.sourceTime))],
                 [self.gapTimeFormatter stringFromNumber:@(CMTimeGetSeconds(gap.destinationTime))]]
          : @"No keyframe gap here");
  if (!gap) {
    [self setEditorsEnabled:NO];
    return;
  }
  if (editing)
    return;
  KFPoseTiming *incoming = [gap.destinationPose timing],
               *outgoing = [gap.sourcePose timing];
  KFEnable(self.available, YES);
  KFEnable(self.easingMenu, YES);
  KFEnable(self.motionMenu, YES);
  KFEnable(self.seedButton, [gap.sourcePose addedMotion]!=MTAddedMotionNone);
  self.durationRow.enabled = !incoming.available;
  self.motionLabel.textColor = ICInspectorTokens.labelColor;
  self.easingLabel.textColor = ICInspectorTokens.labelColor;
  KFNumber(self.durationRow.fields[0], incoming.duration);
  NSControlStateValue available =
      incoming.available ? NSControlStateValueOn : NSControlStateValueOff;
  if (self.available.state != available)
    self.available.state = available;
  self.available.contentTintColor=incoming.available ? ICInspectorTokens.accentMatchingHost : ICInspectorTokens.decorationColor;
  NSString *tip = [NSString
      stringWithFormat:@"Into keyframe %lu. Limited to the available %.2f s.",
                       (unsigned long)gap.destinationIndex + 1,
                       CMTimeGetSeconds(CMTimeSubtract(gap.destinationTime,
                                                       gap.sourceTime))];
  if (![self.durationRow.fields[0].toolTip isEqualToString:tip])
    self.durationRow.fields[0].toolTip = tip;
  KFSelect(self.easingMenu, [gap.destinationPose easing]);
  NSInteger motion = [gap.sourcePose addedMotion];
  KFSelect(self.motionMenu, motion);
  KFNumber(self.motionRow.fields[0], outgoing.amount * 100);
  KFNumber(self.motionRow.fields[1], outgoing.speed);
  self.motionRow.enabled = motion != MTAddedMotionNone;
}
- (void)scrubGraphToFraction:(double)fraction {
  if (!self.window || self.hiddenOrHasHiddenAncestor || !self.plottedGaps.count || !isfinite(fraction)) return;
  CMTime start=KFInspectorGraphStart(self.plottedGaps);
  CMTime end=self.plottedGaps.firstObject.destinationTime;
  if (!CMTIME_IS_NUMERIC(start) || !CMTIME_IS_NUMERIC(end) || CMTimeCompare(end,start)<=0) return;
  fraction=fmax(0,fmin(1,fraction));
  CMTime target=fraction==0 ? start : fraction==1 ? end :
      CMTimeAdd(start,CMTimeMultiplyByFloat64(CMTimeSubtract(end,start),fraction));
  id<FxCustomParameterActionAPI_v4> action=[self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action) return;
  [action startAction:self];
  @try {
    id<FxCommandAPI_v2> command=[self.manager apiForProtocol:@protocol(FxCommandAPI_v2)];
    if (!command) return;
    // Native key times already use the host clock.
    // FCP can return NO even when the seek succeeds.
    [command movePlayheadToTime:target error:nil];
    self.graph.progress=fraction;
  } @finally { [action endAction:self]; }
}
// Standalone refresh for direct callers; the clock uses the action-scoped body.
- (void)refresh {
  id<FxCustomParameterActionAPI_v4> action =
      [self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action) {
    [self setEditorsEnabled:NO];
    return;
  }
  [action startAction:self];
  @try { [self refreshInspectorValuesInAction:action]; }
  @finally { [action endAction:self]; }
}
- (void)refreshInspectorValuesInAction:(id<FxCustomParameterActionAPI_v4>)action {
  if (!self.window || self.hiddenOrHasHiddenAncestor || self.writingSetting)
    return;
  // Native selection is provisional until its action finishes. Host snapshots
  // remain authoritative outside that interaction, including undo and scrubbing.
  BOOL editing = self.durationRow.interacting || self.motionRow.interacting ||
      self.easingMenu.interacting || self.motionMenu.interacting;
  UInt32 parameter =
      (editing || self.graph.scrubbing) ? self.displayedParameter
              : (self.plugin.activeInspectorParameterID ?: KFPropertyLanes().firstObject.parameterID);
  CMTime now = [action currentTime];
  KFInspectorGap *gap = KFReadInspectorGap(self.manager, parameter, now);
  NSArray<KFInspectorGap *> *graphGaps =
      self.graph.scrubbing ? self.plottedGaps : KFReadInspectorGraphGaps(self.manager,parameter,now);
  // The host action covers only reads. Publish controls/playhead before curve
  // work.
  self.displayedParameter = parameter;
  NSMutableArray *colors=[NSMutableArray new];
  for (KFInspectorGap *plotted in graphGaps)
    [colors addObjectsFromArray:KFPropertyLaneForParameter(plotted.parameterID).componentColors];
  self.graph.componentColors=graphGaps.count ? colors : KFPropertyLaneForParameter(parameter).componentColors;
  [self updateControlsForGap:gap editing:editing];
  CMTime graphStart=KFInspectorGraphStart(graphGaps);
  CMTime graphEnd=graphGaps.firstObject.destinationTime;
  if (!self.graph.scrubbing) self.graph.progress=graphGaps.count ? CMTimeGetSeconds(CMTimeSubtract(now,graphStart))/CMTimeGetSeconds(CMTimeSubtract(graphEnd,graphStart)) : 0;
  if (graphGaps.count)
    KFText(self.gapLabel,[NSString stringWithFormat:@"%@s → %@s",[self.gapTimeFormatter stringFromNumber:@(CMTimeGetSeconds(graphStart))],[self.gapTimeFormatter stringFromNumber:@(CMTimeGetSeconds(graphEnd))]]);
  CGSize size=self.plugin.inspectorImageSize;
  BOOL changed=self.plottedGaps.count!=graphGaps.count;
  for (NSUInteger i=0;!changed && i<graphGaps.count;i++) {
    KFInspectorGap *previous=self.plottedGaps[i], *next=graphGaps[i];
    changed=previous.parameterID!=next.parameterID || previous.destinationIndex!=next.destinationIndex ||
      !KFGraphEntriesEqual(previous.entries,next.entries);
  }
  if (changed || self.plottedParameter!=parameter || !CGSizeEqualToSize(self.plottedSize,size)) {
    self.plottedGaps=graphGaps;
    self.plottedParameter=parameter;
    self.plottedSize=size;
    self.graph.startFractions=graphGaps.count>1 ? KFInspectorGraphStartFractions(graphGaps) : @[];
    self.graph.points=KFInspectorCombinedGraphPoints(graphGaps,1024,size);
  }
  NSMutableSet *visible=[NSMutableSet new];
  if (self.graph.points.count>=2)
    for (KFInspectorGap *plotted in graphGaps) [visible addObject:@(plotted.parameterID)];
  [self publishGraphParameters:visible];
}
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
