/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMTimingEditor.h"
#import "Constants.h"
#import "MMInspectorColors.h"
#import "MMTimingEditorModel.h"
#import "Plugin.h"
@import InspectorControls;

@interface MMGapGraph : NSView
@property(nonatomic, copy) NSArray<NSArray<NSNumber *> *> *points;
@property(nonatomic) double progress;
@property(copy) NSArray<NSBezierPath *> *curvePaths;
@property(nonatomic, copy) NSArray<NSColor *> *componentColors;
@property NSRect curveBounds;
- (void)prepareCurves;
@end
@implementation MMGapGraph
- (void)setPoints:(NSArray<NSArray<NSNumber *> *> *)points {
  if (_points == points)
    return;
  _points = [points copy];
  self.curvePaths = nil;
  self.needsDisplay = YES;
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
          NSMinX(plot) + NSWidth(plot) * i / (self.points.count - 1),
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
  [[NSColor colorWithWhite:1 alpha:0.08] setStroke];
  NSBezierPath *grid = [NSBezierPath bezierPath];
  for (int i = 0; i <= 4; i++) {
    CGFloat x = NSMinX(plot) + NSWidth(plot) * i / 4;
    [grid moveToPoint:NSMakePoint(x, NSMinY(plot))];
    [grid lineToPoint:NSMakePoint(x, NSMaxY(plot))];
  }
  [grid moveToPoint:NSMakePoint(NSMinX(plot), NSMidY(plot))];
  [grid lineToPoint:NSMakePoint(NSMaxX(plot), NSMidY(plot))];
  [grid stroke];
  if (self.points.count < 2)
    return;
  [self prepareCurves];
  for (NSUInteger axis = 0; axis < self.curvePaths.count; axis++) {
    [(axis<self.componentColors.count ? self.componentColors[axis]
           : ICInspectorTokens.accentMatchingHost) setStroke];
    [self.curvePaths[axis] stroke];
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
static BOOL MMGraphEntriesEqual(NSArray *a, NSArray *b) {
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
static void MMEnable(NSControl *control, BOOL enabled) {
  if (control.enabled != enabled)
    control.enabled = enabled;
}
static void MMText(NSTextField *field, NSString *text) {
  if (![field.stringValue isEqualToString:text])
    field.stringValue = text;
}
static void MMNumber(NSTextField *field, double value) {
  if (!field.objectValue || field.doubleValue != value)
    field.doubleValue = value;
}
static void MMSelect(NSPopUpButton *menu, NSInteger index) {
  if (menu.indexOfSelectedItem != index)
    [menu selectItemAtIndex:index];
}

@interface MMTimingEditor ()
@property(weak) MagicMovePlugin *plugin;
@property(strong) id<PROAPIAccessing> manager;
@property(strong) NSTimer *timer;
@property(strong) NSPopUpButton *easingMenu;
@property(strong) NSPopUpButton *motionMenu;
@property(strong) NSButton *available;
@property(strong) NSTextField *gapLabel;
@property(strong) NSNumberFormatter *gapTimeFormatter;
@property(strong) NSTextField *motionLabel;
@property(strong) MMGapGraph *graph;
@property(strong) ICInspectorRow *durationRow;
@property(strong) ICInspectorRow *motionRow;
@property(strong) id<FxUndoAPI> scrubUndo;
@property UInt32 displayedParameter;
@property(copy) NSArray<NSDictionary *> *plottedEntries;
@property UInt32 plottedParameter;
@property NSUInteger plottedDestination;
@property CGSize plottedSize;
@end
@implementation MMTimingEditor
- (NSTextField *)label:(NSString *)text {
  NSTextField *label = [NSTextField labelWithString:text];
  label.font = ICInspectorTokens.labelFont;
  label.textColor = ICInspectorTokens.labelColor;
  [self addSubview:label];
  return label;
}
- (NSPopUpButton *)menu:(NSArray<NSString *> *)items
                setting:(NSInteger)setting {
  NSPopUpButton *menu = [[NSPopUpButton alloc] initWithFrame:NSZeroRect
                                                   pullsDown:NO];
  menu.controlSize = NSControlSizeSmall;
  menu.font = ICInspectorTokens.labelFont;
  [menu addItemsWithTitles:items];
  menu.tag = setting;
  menu.target = self;
  menu.action = @selector(menuChanged:);
  [self addSubview:menu];
  return menu;
}
- (instancetype)initWithPlugin:(MagicMovePlugin *)plugin {
  if (!(self = [super initWithFrame:NSMakeRect(0, 0, 320, 256)]))
    return nil;
  _plugin = plugin;
  _manager = plugin.apiManager;
  self.autoresizingMask = NSViewWidthSizable;
  _gapLabel = [self label:@"Add two keyposes to edit motion"];
  _gapTimeFormatter=[NSNumberFormatter new];
  _gapTimeFormatter.numberStyle=NSNumberFormatterDecimalStyle;
  _gapTimeFormatter.usesGroupingSeparator=NO;
  _gapTimeFormatter.minimumFractionDigits=0;
  _gapTimeFormatter.maximumFractionDigits=2;
  _graph = [MMGapGraph new];
  _graph.accessibilityLabel = @"Evaluated motion preview";
  [self addSubview:_graph];
  _durationRow = [[ICInspectorRow alloc]
      initWithLabel:@"Duration"
         components:@[ [[ICInspectorComponent alloc]
                        initWithIdentifier:MMInspectorDuration
                                     label:@""
                                    suffix:@"s"
                            fractionDigits:2] ]
          showsLink:NO];
  [self addSubview:_durationRow];
  _available = [NSButton checkboxWithTitle:@"Use available time"
                                    target:self
                                    action:@selector(availableChanged:)];
  _available.font = ICInspectorTokens.labelFont;
  [self addSubview:_available];
  _easingMenu = [self menu:@[ @"Smooth", @"Linear", @"Ease In", @"Ease Out" ]
                   setting:MMInspectorEasing];
  _easingMenu.accessibilityLabel = @"Incoming easing";
  _motionLabel = [self label:@"Added motion"];
  _motionMenu = [self menu:@[ @"None", @"Wave", @"Wiggle", @"Handheld" ]
                   setting:MMInspectorMotion];
  _motionMenu.accessibilityLabel = @"Added motion type";
  _motionRow = [[ICInspectorRow alloc]
      initWithLabel:@"Added motion"
         components:@[
           [[ICInspectorComponent alloc] initWithIdentifier:MMInspectorAmount
                                                      label:@""
                                                     suffix:@"%"
                                             fractionDigits:0],
           [[ICInspectorComponent alloc] initWithIdentifier:MMInspectorSpeed
                                                      label:@""
                                                     suffix:@"×"
                                             fractionDigits:2]
         ]
          showsLink:NO];
  [self addSubview:_motionRow];
  __weak MMTimingEditor *weakSelf = self;
  for (ICInspectorRow *row in @[ _durationRow, _motionRow ]) {
    row.onValueCommit = ^(ICValueTextField *field) {
      [weakSelf writeSetting:field.tag
                       value:field.doubleValue /
                             (field.tag == MMInspectorAmount ? 100 : 1)];
    };
    row.onScrubBegin = ^{
      [weakSelf beginScrub];
    };
    row.onScrubEnd = ^{
      [weakSelf endScrub];
    };
    for (ICValueTextField *field in row.fields) {
      NSNumberFormatter *format = (id)field.formatter;
      format.minimum = field.tag == MMInspectorSpeed ? @0.05 : @0;
      format.maximum = field.tag == MMInspectorDuration ? @60
                       : field.tag == MMInspectorAmount ? @300
                                                        : @10;
      field.scrubStep = field.tag == MMInspectorAmount ? 1 : 0.01;
      field.accessibilityLabel =
          field.tag == MMInspectorAmount  ? @"Added motion amount"
          : field.tag == MMInspectorSpeed ? @"Added motion speed"
                                          : @"Incoming duration";
    }
  }
  _motionRow.fields[0].toolTip = @"Amount of added motion";
  _motionRow.fields[1].toolTip = @"Speed of added motion";
  [self setEditorsEnabled:NO];
  return self;
}
- (NSSize)intrinsicContentSize {
  return NSMakeSize(NSViewNoIntrinsicMetric, 256);
}
- (void)layout {
  [super layout];
  CGFloat width = NSWidth(self.bounds), right = MAX(140, width - 22),
          content = MAX(0, right - 21);
  self.gapLabel.frame = NSMakeRect(21, 230, content, 18);
  self.graph.frame = NSMakeRect(21, 110, content, 114);
  self.durationRow.frame = NSMakeRect(0, 81, width, 24);
  self.available.frame = NSMakeRect(21, 57, MIN(145, content), 20);
  self.easingMenu.frame =
      NSMakeRect(MAX(165, right - 120), 56, MIN(120, MAX(0, right - 165)), 22);
  self.motionLabel.frame = NSMakeRect(21, 34, MAX(0, content - 122), 18);
  self.motionMenu.frame =
      NSMakeRect(MAX(145, right - 120), 32, MIN(120, MAX(0, right - 145)), 22);
  self.motionRow.frame = NSMakeRect(0, 5, width, 24);
  self.motionRow.titleLabel.stringValue = @"Amount / Speed";
}
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  [self.timer invalidate];
  self.timer = nil;
  if (!self.window) {
    [self endScrub];
    return;
  }
  [self refresh];
  __weak MMTimingEditor *weakSelf = self;
  self.timer = [NSTimer timerWithTimeInterval:0.1
                                      repeats:YES
                                        block:^(NSTimer *timer) {
                                          MMTimingEditor *view = weakSelf;
                                          if (!view) {
                                            [timer invalidate];
                                            return;
                                          }
                                          [view refresh];
                                        }];
  [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (void)dealloc {
  [_timer invalidate];
}
- (void)setEditorsEnabled:(BOOL)enabled {
  MMEnable(self.available, enabled);
  MMEnable(self.easingMenu, enabled);
  MMEnable(self.motionMenu, enabled);
  for (ICInspectorRow *row in @[ self.durationRow, self.motionRow ])
    for (ICValueTextField *field in row.fields)
      MMEnable(field, enabled);
}
- (void)updateControlsForGap:(MMInspectorGap *)gap editing:(BOOL)editing {
  MMText(
      self.gapLabel,
      gap ? [NSString stringWithFormat:@"%@s → %@s",
                 [self.gapTimeFormatter stringFromNumber:@(CMTimeGetSeconds(gap.sourceTime))],
                 [self.gapTimeFormatter stringFromNumber:@(CMTimeGetSeconds(gap.destinationTime))]]
          : @"No keypose gap here");
  if (!gap) {
    [self setEditorsEnabled:NO];
    MMText(self.motionLabel, @"Added motion");
    return;
  }
  if (editing)
    return;
  MMPoseTiming *incoming = [gap.destinationPose timing],
               *outgoing = [gap.sourcePose timing];
  MMEnable(self.available, YES);
  MMEnable(self.easingMenu, YES);
  MMEnable(self.motionMenu, YES);
  MMEnable(self.durationRow.fields[0], !incoming.available);
  MMNumber(self.durationRow.fields[0], incoming.duration);
  NSControlStateValue available =
      incoming.available ? NSControlStateValueOn : NSControlStateValueOff;
  if (self.available.state != available)
    self.available.state = available;
  NSString *tip = [NSString
      stringWithFormat:@"Into pose %lu. Limited to the available %.2f s.",
                       (unsigned long)gap.destinationIndex + 1,
                       CMTimeGetSeconds(CMTimeSubtract(gap.destinationTime,
                                                       gap.sourceTime))];
  if (![self.durationRow.fields[0].toolTip isEqualToString:tip])
    self.durationRow.fields[0].toolTip = tip;
  MMSelect(self.easingMenu, [gap.destinationPose easing]);
  NSInteger motion = [gap.sourcePose addedMotion];
  MMSelect(self.motionMenu, motion);
  MMText(self.motionLabel,
         [NSString stringWithFormat:@"Added motion · from pose %lu",
                                    (unsigned long)gap.destinationIndex]);
  MMNumber(self.motionRow.fields[0], outgoing.amount * 100);
  MMNumber(self.motionRow.fields[1], outgoing.speed);
  for (ICValueTextField *field in self.motionRow.fields)
    MMEnable(field, motion != MTAddedMotionNone);
}
- (void)refresh {
  if (!self.window || self.hiddenOrHasHiddenAncestor)
    return;
  BOOL editing = self.durationRow.interacting || self.motionRow.interacting;
  id<FxCustomParameterActionAPI_v4> action =
      [self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action) {
    [self setEditorsEnabled:NO];
    return;
  }
  UInt32 parameter =
      editing ? self.displayedParameter
              : (self.plugin.activeInspectorParameterID ?: MMCustomControls);
  CMTime now;
  MMInspectorGap *gap;
  [action startAction:self];
  @try {
    now = [action currentTime];
    gap = MMReadInspectorGap(self.manager, parameter, now);
  } @finally {
    [action endAction:self];
  }
  // The host action covers only reads. Publish controls/playhead before curve
  // work.
  self.displayedParameter = parameter;
  self.graph.componentColors = MMInspectorColors(parameter);
  [self updateControlsForGap:gap editing:editing];
  self.graph.progress =
      gap ? CMTimeGetSeconds(CMTimeSubtract(now, gap.sourceTime)) /
                CMTimeGetSeconds(
                    CMTimeSubtract(gap.destinationTime, gap.sourceTime))
          : 0;
  CGSize size = parameter == MMCustomControls ? self.plugin.inspectorImageSize
                                              : CGSizeMake(100, 100);
  if (!MMGraphEntriesEqual(self.plottedEntries, gap.entries) ||
      self.plottedParameter != parameter ||
      self.plottedDestination != gap.destinationIndex ||
      !CGSizeEqualToSize(self.plottedSize, size)) {
    self.plottedEntries = gap.entries;
    self.plottedParameter = parameter;
    self.plottedDestination = gap.destinationIndex;
    self.plottedSize = size;
    NSArray *points = MMInspectorGraphComponents(gap, 1024);
    if (gap && parameter == MMCustomControls && size.width > 0 &&
        size.height > 0) {
      NSMutableArray *pixels = [NSMutableArray arrayWithCapacity:points.count];
      for (NSArray<NSNumber *> *point in points)
        [pixels addObject:@[@(point[0].doubleValue*size.width/100),@(point[1].doubleValue*size.height/100)]];
      points = pixels;
    }
    self.graph.points = points;
  }
}
- (void)menuChanged:(NSPopUpButton *)menu {
  [self writeSetting:menu.tag value:menu.indexOfSelectedItem];
}
- (void)availableChanged:(NSButton *)button {
  [self writeSetting:MMInspectorAvailable
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
- (void)writeSetting:(MMInspectorSetting)setting value:(double)value {
  id<FxCustomParameterActionAPI_v4> action =
      [self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action)
    return;
  [action startAction:self];
  @try {
    id<FxUndoAPI> undo =
        self.scrubUndo ? nil
                       : [self.manager apiForProtocol:@protocol(FxUndoAPI)];
    BOOL grouped = [undo startUndoGroup:@"Change Motion"];
    @try {
      CMTime now=[action currentTime];
      if (!MMWriteInspectorSetting(self.manager, self.displayedParameter,
                                   now, setting, value))
        NSBeep();
    } @finally {
      if (grouped)
        [undo endUndoGroup];
    }
  } @finally {
    [action endAction:self];
  }
  [self refresh];
}
@end
