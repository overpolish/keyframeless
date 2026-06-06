/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLocalized.h"
#import "KKTimelineInspectorView+Guide.h"
#import "KKTimelineInspectorView.h"
#import "KKTimelineInspectorView_Private.h"

#import "KKCheckboxView.h"
#import "KKCompoundPillBar.h"
#import "KKConstants.h"
#import "KKLabelView.h"
#import "KKMiniViewerView.h"
#import "KKParameterRowView.h"
#import "KKPillToggleRowView.h"
#import "KKPopoverHeaderView.h"
#import "KKPopupSelectView.h"
#import "KKReorderListView.h"
#import "KKShaderTypes.h"
#import "KKSliderView.h"
#import "KKTimelineCompatBannerView.h"
#import "KKTimelineInspectorButtons.h"
#import "KKTimelineLanesView_Private.h"
#import "KKTimelineMotionBlurSettingsView.h"
#import "KKTokens.h"
#import "KKValueTextField.h"
#import "NSColor+KKColors.h"
#import <KeyframelessKit/KKJoyrideGuideHost.h>
#import <KeyframelessKit/KKTimingCompat.h>

@implementation KKTimelineInspectorView (ParameterRows)

- (KKParameterRowView *)
    _buildTickGearRowWithParameterID:(UInt32)parameterID
                          iconSymbol:(NSString *)iconSymbol
                               title:(NSString *)title
                   gearAccessibility:(NSString *)gearAccessibility
                          gearAction:(SEL)gearAction
                        showCheckbox:(BOOL)showCheckbox
                            checkbox:
                                (KKCheckboxView *__strong _Nullable *_Nullable)
                                    outCheckbox
                          gearButton:
                              (NSButton *__strong _Nonnull *_Nonnull)outGear {
  KKParameterRowView *row =
      [[KKParameterRowView alloc] initWithFrame:NSZeroRect
                                     apiManager:_apiManager
                                    parameterId:parameterID];
  row.translatesAutoresizingMaskIntoConstraints = NO;

  // KKLabelView carries the native label inset/styling so the gutter lines up
  // with FCP's other param rows.
  NSImage *icon = [NSImage imageWithSystemSymbolName:iconSymbol
                            accessibilityDescription:title];
  row.leftView = [[KKLabelView alloc] initWithText:title icon:icon];

  // rightView must be a container (KKParameterRowView contract), not a bare
  // control. Checkbox sits in the native control gutter (same as
  // KKCustomGroupHeaderView); the settings gear sits just to its left.
  NSView *controls = [[NSView alloc] initWithFrame:NSZeroRect];
  KKCheckboxView *checkbox = nil;
  if (showCheckbox) {
    checkbox = [[KKCheckboxView alloc] initWithFrame:NSZeroRect];
    checkbox.translatesAutoresizingMaskIntoConstraints = NO;
    [controls addSubview:checkbox];
  }

  NSImage *gear = [NSImage imageWithSystemSymbolName:@"gearshape"
                            accessibilityDescription:gearAccessibility];
  NSButton *gearButton = [NSButton buttonWithImage:gear
                                            target:self
                                            action:gearAction];
  gearButton.bezelStyle = NSBezelStyleAccessoryBarAction;
  gearButton.bordered = NO;
  gearButton.contentTintColor = [NSColor accentMatchingHost];
  gearButton.translatesAutoresizingMaskIntoConstraints = NO;
  [controls addSubview:gearButton];

  NSMutableArray<NSLayoutConstraint *> *cs = [NSMutableArray array];
  if (checkbox) {
    [cs addObjectsFromArray:@[
      [checkbox.trailingAnchor constraintEqualToAnchor:controls.trailingAnchor
                                              constant:-kMBCheckboxTrailing],
      [checkbox.centerYAnchor constraintEqualToAnchor:controls.centerYAnchor],
      [checkbox.widthAnchor constraintEqualToConstant:12.0],
      [checkbox.heightAnchor constraintEqualToConstant:12.0],
      [gearButton.trailingAnchor constraintEqualToAnchor:checkbox.leadingAnchor
                                                constant:-KKSpacingMD],
    ]];
  } else {
    // No checkbox: center the 18pt gear on the 12pt checkbox column above it
    // (offset the trailing edge by half the width difference) so the glyphs
    // share a centerline rather than just a trailing edge.
    [cs addObject:[gearButton.trailingAnchor
                      constraintEqualToAnchor:controls.trailingAnchor
                                     constant:-(kMBCheckboxTrailing -
                                                (18.0 - 12.0) / 2.0)]];
  }
  [cs addObjectsFromArray:@[
    [gearButton.centerYAnchor constraintEqualToAnchor:controls.centerYAnchor],
    [gearButton.widthAnchor constraintEqualToConstant:18.0],
    [gearButton.heightAnchor constraintEqualToConstant:18.0],
  ]];
  [NSLayoutConstraint activateConstraints:cs];
  row.rightView = controls;

  if (outCheckbox)
    *outCheckbox = checkbox;
  *outGear = gearButton;
  return row;
}

- (void)_buildMotionBlurRow {
  // figure.walk.motion = the walking figure with motion lines, the same icon
  // the old native MB group header used.
  _mbRow = [self
      _buildTickGearRowWithParameterID:kKKParamMotionBlurData
                            iconSymbol:@"figure.walk.motion"
                                 title:KKLoc(@"Motion Blur",
                                             @"Section title: motion blur.")
                     gearAccessibility:KKLoc(@"Motion Blur settings",
                                             @"Accessibility: motion blur "
                                             @"settings.")
                            gearAction:@selector(_mbSettingsClicked:)
                          showCheckbox:YES
                              checkbox:&_mbCheckbox
                            gearButton:&_mbSettingsButton];

  __weak typeof(self) weak = self;
  _mbCheckbox.onToggle = ^(BOOL isChecked) {
    KKTimelineInspectorView *strong = weak;
    if (!strong)
      return;
    strong->_mbSettingsButton.enabled = isChecked;
    if (strong.onMotionBlurChanged)
      strong.onMotionBlurChanged(isChecked, strong->_mbShutterAngle,
                                 strong->_mbSamples, strong->_mbMode);
  };

  [self addSubview:_mbRow];
}

- (void)_buildOSCVisibilityRow {
  _oscRow = [self
      _buildTickGearRowWithParameterID:0
                            iconSymbol:@"scope"
                                 title:KKLoc(@"On-Screen Controls",
                                             @"Section title: viewer on-screen "
                                             @"controls visibility.")
                     gearAccessibility:KKLoc(@"On-screen control settings",
                                             @"Accessibility: per-element OSC "
                                             @"visibility settings.")
                            gearAction:@selector(_oscSettingsClicked:)
                          showCheckbox:YES
                              checkbox:&_oscCheckbox
                            gearButton:&_oscSettingsButton];
  _oscCheckbox.isChecked = YES;

  __weak typeof(self) weak = self;
  _oscCheckbox.onToggle = ^(BOOL isChecked) {
    KKTimelineInspectorView *strong = weak;
    if (!strong)
      return;
    // Per-element pills are moot when everything is hidden - mirror the
    // motion-blur gear, which disables while the effect is off.
    strong->_oscSettingsButton.enabled = isChecked;
    if (strong.onOSCVisibleToggled)
      strong.onOSCVisibleToggled(isChecked);
    if (strong.onGuideOSCMasterToggled)
      strong.onGuideOSCMasterToggled(isChecked);
  };

  [self addSubview:_oscRow];
}

- (void)_buildParamOrderRow {
  KKCheckboxView *unused = nil;
  _paramOrderRow = [self
      _buildTickGearRowWithParameterID:0
                            iconSymbol:@"arrow.up.arrow.down"
                                 title:KKLoc(
                                           @"Parameter Order",
                                           @"Section title: parameter display "
                                           @"order in the timeline.")
                     gearAccessibility:KKLoc(@"Reorder parameters",
                                             @"Accessibility: drag-to-reorder "
                                             @"the parameter list.")
                            gearAction:@selector(_paramOrderClicked:)
                          showCheckbox:NO
                              checkbox:&unused
                            gearButton:&_paramOrderButton];
  [self addSubview:_paramOrderRow];
}

- (void)_paramOrderClicked:(id)sender {
  if (_paramOrderPopover.isShown) {
    [_paramOrderPopover close];
    return;
  }
  NSArray<NSString *> *labels = [_basicView orderedParamLabels];
  if (labels.count < 2)
    return;
  NSMutableArray<NSString *> *titles =
      [NSMutableArray arrayWithCapacity:labels.count];
  for (NSString *label in labels)
    [titles addObject:KKLocalizedParamName(label)];

  KKReorderListView *list = [[KKReorderListView alloc] initWithItemIDs:labels
                                                                titles:titles];
  list.translatesAutoresizingMaskIntoConstraints = NO;
  __weak typeof(self) weak = self;
  list.onReorder = ^(NSArray<NSString *> *newOrder) {
    KKTimelineInspectorView *strong = weak;
    [strong->_basicView applyParamOrder:newOrder];
  };

  // Wrap in the lanes-view popover content view for the macOS 26 liquid-glass
  // double-border fix (same as the motion-blur / OSC popovers).
  _KKLVPopoverContentView *content = [[_KKLVPopoverContentView alloc] init];
  KKPopoverHeaderView *header = [[KKPopoverHeaderView alloc]
      initWithTitle:KKLoc(@"Parameter Order",
                          @"Section title: parameter display order in the "
                          @"timeline.")
             detail:KKLoc(@"Drag to reorder",
                          @"Popover hint: drag rows to reorder parameters.")
         symbolName:@"arrow.up.arrow.down"];
  header.translatesAutoresizingMaskIntoConstraints = NO;
  [content addSubview:header];
  [content addSubview:list];
  [NSLayoutConstraint activateConstraints:@[
    [header.leadingAnchor constraintEqualToAnchor:content.leadingAnchor
                                         constant:KKPaddingMD],
    [header.trailingAnchor constraintEqualToAnchor:content.trailingAnchor
                                          constant:-KKPaddingMD],
    [header.topAnchor constraintEqualToAnchor:content.topAnchor
                                     constant:KKPaddingMD],
    [list.leadingAnchor constraintEqualToAnchor:content.leadingAnchor
                                       constant:KKPaddingMD],
    [list.trailingAnchor constraintEqualToAnchor:content.trailingAnchor
                                        constant:-KKPaddingMD],
    [list.topAnchor constraintEqualToAnchor:header.bottomAnchor
                                   constant:KKPaddingSM],
    [list.bottomAnchor constraintEqualToAnchor:content.bottomAnchor
                                      constant:-KKPaddingMD],
  ]];

  NSViewController *vc = [[NSViewController alloc] init];
  vc.view = content;
  _paramOrderPopover = [[NSPopover alloc] init];
  _paramOrderPopover.behavior = NSPopoverBehaviorTransient;
  _paramOrderPopover.contentViewController = vc;
  _paramOrderPopover.contentSize = content.fittingSize;
  [_paramOrderPopover showRelativeToRect:_paramOrderButton.bounds
                                  ofView:_paramOrderButton
                           preferredEdge:NSRectEdgeMinY];
}

- (void)_oscSettingsClicked:(id)sender {
  if (_oscPopover.isShown) {
    [_oscPopover close];
    return;
  }
  NSArray<NSArray<NSString *> *> *compounds = self.oscVisibilityCompounds;
  if (!compounds.count)
    return;

  // Localize the display label of each segment (its last dot-separated
  // component, so @"Rotation.X" reads as "X").
  NSMutableArray<NSArray<NSString *> *> *labels = [NSMutableArray array];
  for (NSArray<NSString *> *compound in compounds) {
    NSMutableArray<NSString *> *group = [NSMutableArray array];
    for (NSString *key in compound) {
      NSString *leaf = [key componentsSeparatedByString:@"."].lastObject ?: key;
      [group addObject:KKLocalizedParamName(leaf)];
    }
    [labels addObject:group];
  }

  KKCompoundPillBar *bar = [[KKCompoundPillBar alloc] initWithCompounds:labels];
  bar.translatesAutoresizingMaskIntoConstraints = NO;
  _oscPillBar = bar; // guide spotlight anchor (weak; lives in the popover)
  NSArray<NSArray<NSNumber *> *> *states =
      self.oscVisibilityElementStates ? self.oscVisibilityElementStates() : nil;
  if (states.count == compounds.count)
    bar.states = states;
  __weak typeof(self) weak = self;
  bar.onToggled = ^(NSInteger compoundIdx, NSInteger segIdx, BOOL isOn) {
    KKTimelineInspectorView *strong = weak;
    if (strong.oscVisibilityElementToggled)
      strong.oscVisibilityElementToggled(compoundIdx, segIdx, isOn);
    // Guide observation: report the raw element key (not the localized leaf).
    if (strong.onGuideOSCElementToggled) {
      NSArray<NSArray<NSString *> *> *cmp = strong.oscVisibilityCompounds;
      NSString *key =
          (compoundIdx >= 0 && compoundIdx < (NSInteger)cmp.count &&
           segIdx >= 0 && segIdx < (NSInteger)cmp[compoundIdx].count)
              ? cmp[compoundIdx][segIdx]
              : nil;
      strong.onGuideOSCElementToggled(key ?: @"", isOn);
    }
  };

  // Wrap in the lanes-view popover content view so the macOS 26 liquid-glass
  // double-border fix applies (same as the motion-blur / curve popovers).
  _KKLVPopoverContentView *content = [[_KKLVPopoverContentView alloc] init];
  [content addSubview:bar];
  [NSLayoutConstraint activateConstraints:@[
    [bar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor
                                      constant:KKPaddingMD],
    [bar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor
                                       constant:-KKPaddingMD],
    [bar.topAnchor constraintEqualToAnchor:content.topAnchor
                                  constant:KKPaddingMD],
    [bar.bottomAnchor constraintEqualToAnchor:content.bottomAnchor
                                     constant:-KKPaddingMD],
  ]];

  NSViewController *vc = [[NSViewController alloc] init];
  vc.view = content;
  _oscPopover = [[NSPopover alloc] init];
  // While a guide is running, ViewBridge-routed clicks (the joyride overlay
  // forwarding a pill click) target the inspector window, not the popover -
  // Transient reads that as an outside click and dismisses before the pill
  // toggles. ApplicationDefined keeps it open; the guide owns its lifecycle
  // (it closes the popover on its opt-click step and on completion).
  _oscPopover.behavior = _timingGuideHost.isActive
                             ? NSPopoverBehaviorApplicationDefined
                             : NSPopoverBehaviorTransient;
  _oscPopover.contentViewController = vc;
  _oscPopover.contentSize = content.fittingSize;
  [_oscPopover showRelativeToRect:_oscSettingsButton.bounds
                           ofView:_oscSettingsButton
                    preferredEdge:NSRectEdgeMinY];
  // Guide observation: let the OSC guide grab the live popover (passthrough
  // window + pill spotlight) once it has settled into a window and laid out.
  if (self.onGuideOSCSettingsPopoverWillOpen) {
    __weak typeof(self) weakSelf = self;
    __weak NSView *weakContent = content;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          KKTimelineInspectorView *s = weakSelf;
          NSView *c = weakContent;
          if (s.onGuideOSCSettingsPopoverWillOpen && c)
            s.onGuideOSCSettingsPopoverWillOpen(c);
        });
  }
}

- (void)setOSCVisible:(BOOL)visible {
  _oscCheckbox.isChecked = visible;
  _oscSettingsButton.enabled = visible;
}

- (void)setMotionBlurEnabled:(BOOL)enabled {
  _mbCheckbox.isChecked = enabled;
  _mbSettingsButton.enabled = enabled;
}

- (void)setMotionBlurShutterAngle:(double)shutterAngle
                          samples:(NSInteger)samples {
  _mbShutterAngle = shutterAngle;
  _mbSamples = samples;
  [_mbSettingsView applyShutterAngle:shutterAngle samples:samples mode:_mbMode];
}

- (void)setMotionBlurMode:(KKMotionBlurMode)mode {
  _mbMode = mode;
  [_mbSettingsView applyShutterAngle:_mbShutterAngle
                             samples:_mbSamples
                                mode:mode];
}

- (void)_mbSettingsClicked:(id)sender {
  if (_mbPopover.isShown) {
    [_mbPopover close];
    return;
  }
  _KKMotionBlurSettingsView *content =
      [[_KKMotionBlurSettingsView alloc] initWithShutterAngle:_mbShutterAngle
                                                      samples:_mbSamples
                                                         mode:_mbMode];
  __weak typeof(self) weak = self;
  content.onChanged =
      ^(double shutterAngle, NSInteger samples, KKMotionBlurMode mode) {
        KKTimelineInspectorView *strong = weak;
        if (!strong)
          return;
        strong->_mbShutterAngle = shutterAngle;
        strong->_mbSamples = samples;
        strong->_mbMode = mode;
        if (strong.onMotionBlurChanged)
          strong.onMotionBlurChanged(strong->_mbCheckbox.isChecked,
                                     shutterAngle, samples, mode);
      };
  content.onDragBegin = ^{
    if (weak.onDragBegin)
      weak.onDragBegin();
  };
  content.onDragEnd = ^{
    if (weak.onDragEnd)
      weak.onDragEnd();
  };
  _mbSettingsView = content;

  // Reuse the lanes view's popover wrapper so the macOS 26 liquid-glass
  // double-border fix (CoreHostingView/ContentHolderView clear) applies here
  // too - same as the constants / curve popovers.
  _KKLVPopoverContentView *wrapper = [[_KKLVPopoverContentView alloc] init];
  wrapper.frame = content.bounds;
  content.translatesAutoresizingMaskIntoConstraints = NO;
  [wrapper addSubview:content];
  [NSLayoutConstraint activateConstraints:@[
    [content.leadingAnchor constraintEqualToAnchor:wrapper.leadingAnchor],
    [content.trailingAnchor constraintEqualToAnchor:wrapper.trailingAnchor],
    [content.topAnchor constraintEqualToAnchor:wrapper.topAnchor],
    [content.bottomAnchor constraintEqualToAnchor:wrapper.bottomAnchor],
  ]];

  NSViewController *vc = [[NSViewController alloc] init];
  vc.view = wrapper;
  _mbPopover = [[NSPopover alloc] init];
  _mbPopover.contentViewController = vc;
  _mbPopover.behavior = NSPopoverBehaviorTransient;
  _mbPopover.contentSize = content.frame.size;
  [_mbPopover showRelativeToRect:_mbSettingsButton.bounds
                          ofView:_mbSettingsButton
                   preferredEdge:NSRectEdgeMaxY];
}

- (void)_installConstraints:(NSView *)box headerRow:(NSView *)headerRow {
  CGFloat h = KKInspectorHorizontalInset;
  [NSLayoutConstraint activateConstraints:@[
    [_tabBar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                          constant:h],
    [_tabBar.topAnchor constraintEqualToAnchor:self.topAnchor
                                      constant:KKPaddingMD],

    [_constantsButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                    constant:-h],
    [_constantsButton.centerYAnchor
        constraintEqualToAnchor:_tabBar.centerYAnchor],

    [_detachButton.leadingAnchor constraintEqualToAnchor:_tabBar.trailingAnchor
                                                constant:KKPaddingMD],
    [_detachButton.centerYAnchor constraintEqualToAnchor:_tabBar.centerYAnchor],

    [box.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:h],
    [box.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                       constant:-h],
    [box.topAnchor constraintEqualToAnchor:_tabBar.bottomAnchor
                                  constant:KKPaddingMD],

    [headerRow.leadingAnchor constraintEqualToAnchor:box.leadingAnchor],
    [headerRow.trailingAnchor constraintEqualToAnchor:box.trailingAnchor],
    [headerRow.topAnchor constraintEqualToAnchor:box.topAnchor],
    [headerRow.heightAnchor constraintEqualToConstant:kHeaderRowHeight],

    [_playButton.leadingAnchor constraintEqualToAnchor:headerRow.leadingAnchor
                                              constant:KKPaddingMD],
    [_playButton.centerYAnchor constraintEqualToAnchor:headerRow.centerYAnchor],
    [_loopButton.leadingAnchor
        constraintEqualToAnchor:_playButton.trailingAnchor
                       constant:KKSpacingSM],
    [_loopButton.centerYAnchor constraintEqualToAnchor:headerRow.centerYAnchor],
    [_resetButton.trailingAnchor
        constraintEqualToAnchor:headerRow.trailingAnchor
                       constant:-KKPaddingMD],
    [_resetButton.centerYAnchor
        constraintEqualToAnchor:headerRow.centerYAnchor],
    [_accessoryStack.trailingAnchor
        constraintEqualToAnchor:_resetButton.leadingAnchor
                       constant:-KKSpacingSM],
    [_accessoryStack.centerYAnchor
        constraintEqualToAnchor:headerRow.centerYAnchor],

    [_contentView.leadingAnchor constraintEqualToAnchor:box.leadingAnchor],
    [_contentView.trailingAnchor constraintEqualToAnchor:box.trailingAnchor],
    [_contentView.topAnchor constraintEqualToAnchor:headerRow.bottomAnchor],
    [_contentView.bottomAnchor constraintEqualToAnchor:box.bottomAnchor],

    [_basicView.leadingAnchor
        constraintEqualToAnchor:_contentView.leadingAnchor],
    [_basicView.trailingAnchor
        constraintEqualToAnchor:_contentView.trailingAnchor],
    [_basicView.topAnchor constraintEqualToAnchor:_contentView.topAnchor],
    [_basicView.bottomAnchor constraintEqualToAnchor:_contentView.bottomAnchor],
  ]];

  // Optional parameter rows stack in their own section below the box,
  // top-to-bottom: OSC-visibility then motion-blur. Full width (no box inset):
  // KKParameterRowView aligns its own label gutter + control region to match
  // FCP's native param rows, which span edge to edge. With no extra rows the
  // box runs to the bottom of the view (original layout).
  NSMutableArray<NSView *> *bottomRows = [NSMutableArray array];
  NSMutableArray<NSNumber *> *bottomRowHeights = [NSMutableArray array];
  if (_showsOSCVisibilityRow && _oscRow) {
    [bottomRows addObject:_oscRow];
    [bottomRowHeights addObject:@(kOSCVisibilityRowHeight)];
  }
  if (_showsMotionBlurRow && _mbRow) {
    [bottomRows addObject:_mbRow];
    [bottomRowHeights addObject:@(kMotionBlurRowHeight)];
  }
  if (_showsParamOrderRow && _paramOrderRow) {
    [bottomRows addObject:_paramOrderRow];
    [bottomRowHeights addObject:@(kParamOrderRowHeight)];
  }
  if (_showsPresetsRow && _presetsRow) {
    [bottomRows addObject:_presetsRow];
    [bottomRowHeights addObject:@(kPresetsRowHeight)];
  }

  if (bottomRows.count == 0) {
    [box.bottomAnchor constraintEqualToAnchor:self.bottomAnchor
                                     constant:-KKPaddingLG]
        .active = YES;
  } else {
    NSView *above = box;
    for (NSInteger i = 0; i < (NSInteger)bottomRows.count; i++) {
      NSView *row = bottomRows[i];
      [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [row.heightAnchor
            constraintEqualToConstant:bottomRowHeights[i].doubleValue],
        [above.bottomAnchor constraintEqualToAnchor:row.topAnchor
                                           constant:-KKPaddingMD],
      ]];
      above = row;
    }
    [above.bottomAnchor constraintEqualToAnchor:self.bottomAnchor
                                       constant:-KKPaddingLG]
        .active = YES;
  }
}

@end
