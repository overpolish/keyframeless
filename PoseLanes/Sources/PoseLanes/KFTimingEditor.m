/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFTimingEditor+Editing.h"
#import "KFTimingEditor+Keyposes.h"
#import "KFTimingEditor+Refresh.h"
#import "KFTimingEditor_Private.h"
#import "KFPropertyLane.h"
#import "KFViewCaches.h"

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
  _map = [KFKeyposeMap new];
  _map.accessibilityLabel = @"Keypose map";
  _map.onSelect = ^(CMTime time) { [weakEditor movePlayheadToKeypose:time]; };
  _map.onScrub = ^(double fraction) { [weakEditor scrubMapToFraction:fraction]; };
  _map.onScrubEnd = ^{ [weakEditor refresh]; };
  _map.onRetimeDrag = ^NSString *(NSInteger index, CMTime proposed) {
    return [weakEditor retimeLabelForIndex:index proposed:proposed];
  };
  _map.onRetimeCommit = ^(NSInteger index, CMTime proposed) {
    [weakEditor commitRetimeIndex:index proposed:proposed];
  };
  _map.menuProvider = ^NSMenu *(NSInteger index, CMTime time) {
    return [weakEditor keyposeMenuForIndex:index time:time];
  };
  [self addSubview:_map];
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
  return NSMakeSize(NSViewNoIntrinsicMetric, 284);
}
- (void)layout {
  [super layout];
  CGFloat width = NSWidth(self.bounds), right = MAX(140, width - 22),
          content = MAX(0, right - 21);
  self.gapLabel.frame = NSMakeRect(21, 258, content, 18);
  self.graph.frame = NSMakeRect(21, 156, content, 96);
  // Inset from the graph's extent and clear of its edge, so the map cannot read
  // as that graph's axis.
  self.map.frame = NSMakeRect(27, 122, MAX(0, content - 12), 30);
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
// The band the Added Motion controls occupy, from the menu row to the values.
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (self.motionTracking) [self removeTrackingArea:self.motionTracking];
  self.motionTracking = [[NSTrackingArea alloc]
      initWithRect:NSMakeRect(0, 0, NSWidth(self.bounds), 49)
           options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways
             owner:self
          userInfo:nil];
  [self addTrackingArea:self.motionTracking];
}
- (void)mouseEntered:(NSEvent *)event {
  if (event.trackingArea != self.motionTracking) return;
  self.motionHovered = YES;
  self.map.sourceHighlighted = [self motionControlsEngaged];
}
- (void)mouseExited:(NSEvent *)event {
  if (event.trackingArea != self.motionTracking) return;
  self.motionHovered = NO;
  self.map.sourceHighlighted = [self motionControlsEngaged];
}
- (BOOL)motionControlsEngaged {
  return self.motionHovered || self.motionRow.interacting || self.motionMenu.interacting;
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
@end
