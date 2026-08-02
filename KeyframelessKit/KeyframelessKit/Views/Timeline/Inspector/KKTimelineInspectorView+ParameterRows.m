/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLocalized.h"
#import "KKTimelineInspectorView+Guide.h"
#import "KKTimelineInspectorView.h"
#import "KKTimelineInspectorView_Private.h"

#import "KKCheckboxView.h"
#import "KKConstants.h"
#import "KKLabelView.h"
#import "KKLaneCategoryNav.h"
#import "KKLog.h"
#import "KKMiniViewerView.h"
#import "KKOSCChecklistView.h"
#import "KKPaddedScrollView.h"
#import "KKParameterRowView.h"
#import "KKPillBar.h"
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

// Cap the reorder list height; beyond this it scrolls inside
// KKPaddedScrollView.
static const CGFloat kParamOrderMaxListH = 200.0;

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
                                 strong->_mbSamples, strong->_mbTechnique);
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

// label -> owning layerKey, the row-level lookup the owner nav filters on.
static NSDictionary<NSString *, NSString *> *
_kkParamOrderLayerByLabel(NSArray<KKLane *> *lanes) {
  NSMutableDictionary<NSString *, NSString *> *byLabel =
      [NSMutableDictionary dictionary];
  for (KKLane *l in lanes)
    if (l.key.length && l.layerKey.length)
      byLabel[l.key] = l.layerKey;
  return byLabel;
}

- (void)_paramOrderClicked:(id)sender {
  if (_paramOrderPopover.isShown) {
    [_paramOrderPopover close];
    return;
  }
  // Full parameter universe, not the selected layer's seeded subset - the
  // reorder popover edits a global ordering and must list every param (Fill /
  // Stroke etc.) regardless of which layer is currently selected.
  NSArray<NSString *> *labels = [_basicView allOrderedParamLabels];
  if (labels.count < 2)
    return;

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
  [NSLayoutConstraint activateConstraints:@[
    [header.leadingAnchor constraintEqualToAnchor:content.leadingAnchor
                                         constant:KKPaddingMD],
    [header.trailingAnchor constraintEqualToAnchor:content.trailingAnchor
                                          constant:-KKPaddingMD],
    [header.topAnchor constraintEqualToAnchor:content.topAnchor
                                     constant:KKPaddingMD],
  ]];

  // The owner nav comes first: each owner declares its own categories, so the
  // category pills below are a statement about the SELECTED owner. Resolved off
  // the lanes view's live host selection - the same resolution the Animated
  // dropdown uses - so both popovers open on the entry the user came from.
  // Every open builds a fresh content view, so the previous one's rows are dead
  // references - dropped here rather than only where they are rebuilt, since a
  // re-open with fewer owners (a rack emptied down to one entry) builds no
  // layer bar at all and would otherwise pin the list under a detached view.
  _paramOrderLayerBar = nil;
  _paramOrderCategoryBar = nil;
  _paramOrderScrollTop = nil;

  NSArray<NSString *> *layerKeys = KKLaneLayerKeys(_availableLanes);
  _paramOrderLayerByLabel = _kkParamOrderLayerByLabel(_availableLanes);
  _paramOrderSelectedLayer =
      layerKeys.count > 1
          ? ([self.basicLanesView hostSelectedLayerKeyIn:_availableLanes]
                 ?: layerKeys.firstObject)
          : nil;
  if (_paramOrderSelectedLayer.length &&
      ![layerKeys containsObject:_paramOrderSelectedLayer])
    _paramOrderSelectedLayer = layerKeys.firstObject;
  _paramOrderLabels = labels;
  _paramOrderCatByLabel = KKLaneCategoryByLabel(_availableLanes);
  _paramOrderContent = content;
  _paramOrderHeader = header;

  NSArray<NSString *> *categoryKeys =
      KKLaneCategoryKeys([self _paramOrderScopedLanes]);
  __weak typeof(self) weak = self;

  if (categoryKeys.count > 0 || layerKeys.count > 1) {
    // Category pills filter the reorder list to one category at a time; the
    // category blocks themselves stay in the plugin's order. Dragging reorders
    // within the shown category, merged back into the full order on each
    // change.
    _paramOrderCategoryKeys = categoryKeys;
    _paramOrderSelectedCategory = categoryKeys.firstObject;

    if (layerKeys.count > 1) {
      KKPillToggleRowView *layerPill = KKMakeLaneLayerPill(
          _availableLanes, _paramOrderSelectedLayer, ^(NSString *layerKey) {
            [weak _paramOrderSelectLayer:layerKey];
          });
      _paramOrderLayerBar = [self _paramOrderPillBarFor:layerPill
                                              belowEdge:header.bottomAnchor];
    }

    NSView *listContainer = [[NSView alloc] initWithFrame:NSZeroRect];
    listContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _paramOrderListContainer = listContainer;
    // Cap the reorder list and let it scroll (with top/bottom fade shadows)
    // rather than ballooning the popover when there are many params.
    KKPaddedScrollView *scroll =
        [[KKPaddedScrollView alloc] initWithDocumentView:listContainer
                                                 padding:0.0];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:scroll];
    _paramOrderScroll = scroll;
    _paramOrderScrollHeight =
        [scroll.heightAnchor constraintEqualToConstant:kParamOrderMaxListH];
    // The reorder list has a fixed intrinsic width that used to drive the
    // popover width; pinned inside the scroll it no longer does, so carry that
    // width up to the scroll explicitly (set from the list in the rebuild).
    _paramOrderScrollWidth = [scroll.widthAnchor constraintEqualToConstant:0.0];

    [NSLayoutConstraint activateConstraints:@[
      [scroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor
                                           constant:KKPaddingMD],
      [scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor
                                            constant:-KKPaddingMD],
      [scroll.bottomAnchor constraintEqualToAnchor:content.bottomAnchor
                                          constant:-KKPaddingMD],
      _paramOrderScrollHeight,
      _paramOrderScrollWidth,
    ]];
    // Builds the category bar (when the owner has categories) and pins the
    // scroll under whichever row ends up above it. Re-run on an owner switch.
    [self _installParamOrderCategoryBar];
    [self _rebuildParamOrderList];
  } else {
    NSMutableArray<NSString *> *titles =
        [NSMutableArray arrayWithCapacity:labels.count];
    for (NSString *label in labels)
      [titles addObject:[self _paramOrderTitleForLabel:label]];
    KKReorderListView *list =
        [[KKReorderListView alloc] initWithItemIDs:labels titles:titles];
    list.translatesAutoresizingMaskIntoConstraints = NO;
    list.onReorder = ^(NSArray<NSString *> *newOrder) {
      KKTimelineInspectorView *strong = weak;
      [strong->_basicView applyParamOrder:newOrder];
    };
    [content addSubview:list];
    [NSLayoutConstraint activateConstraints:@[
      [list.leadingAnchor constraintEqualToAnchor:content.leadingAnchor
                                         constant:KKPaddingMD],
      [list.trailingAnchor constraintEqualToAnchor:content.trailingAnchor
                                          constant:-KKPaddingMD],
      [list.topAnchor constraintEqualToAnchor:header.bottomAnchor
                                     constant:KKPaddingSM],
      [list.bottomAnchor constraintEqualToAnchor:content.bottomAnchor
                                        constant:-KKPaddingMD],
    ]];
  }

  // Give the content a concrete size so the presenter sizes the popover to it
  // (it reads content.bounds); the category rebuild resizes it thereafter.
  content.frame =
      NSMakeRect(0, 0, content.fittingSize.width, content.fittingSize.height);
  // Present as an option picker on the lanes view: reliable outside-click
  // dismiss, closing on any click outside itself; its toggle button closes it.
  _paramOrderPopover =
      [self.basicLanesView showOptionPopover:content
                                    fromView:_paramOrderButton
                               preferredEdge:NSRectEdgeMinY
                                     onClose:^{
                                       KKTimelineInspectorView *strong = weak;
                                       if (strong)
                                         strong->_paramOrderPopover = nil;
                                     }];
}

// The lanes the category nav + the rows are scoped to: the selected owner's
// when there is an owner nav, every lane for a plugin that carries no layer
// info (which is every single-owner plugin, including Canvas).
- (NSArray<KKLane *> *)_paramOrderScopedLanes {
  if (_paramOrderSelectedLayer.length == 0)
    return _availableLanes;
  NSMutableArray<KKLane *> *out = [NSMutableArray array];
  for (KKLane *l in _availableLanes)
    if ([l.layerKey isEqualToString:_paramOrderSelectedLayer])
      [out addObject:l];
  return out;
}

// A label belongs on the current page when it has no owner (a plugin that mixes
// owned and unowned params keeps the latter reachable everywhere) or its owner
// is the selected one.
- (BOOL)_paramOrderLabelInScope:(NSString *)label {
  NSString *layer = _paramOrderLayerByLabel[label];
  return _paramOrderSelectedLayer.length == 0 || layer.length == 0 ||
         [layer isEqualToString:_paramOrderSelectedLayer];
}

// A pill run wrapped in an edge-faded horizontal scroll so a long row stays on
// one line instead of forcing the popover wide. nil `pill` (fewer than two
// segments) installs nothing and returns nil.
- (NSView *)_paramOrderPillBarFor:(KKPillToggleRowView *)pill
                        belowEdge:(NSLayoutYAxisAnchor *)topEdge {
  if (!pill)
    return nil;
  KKPillBar *pillBar = [[KKPillBar alloc] initWithPillRow:pill];
  pillBar.translatesAutoresizingMaskIntoConstraints = NO;
  // Hug content when it fits, but a near-zero compression resistance lets it
  // shrink so the inner scroll takes over on overflow (vs clipping).
  [pillBar setContentHuggingPriority:NSLayoutPriorityRequired - 1
                      forOrientation:NSLayoutConstraintOrientationHorizontal];
  [pillBar
      setContentCompressionResistancePriority:1
                               forOrientation:
                                   NSLayoutConstraintOrientationHorizontal];
  [_paramOrderContent addSubview:pillBar];
  [NSLayoutConstraint activateConstraints:@[
    [pillBar.centerXAnchor
        constraintEqualToAnchor:_paramOrderContent.centerXAnchor],
    [pillBar.leadingAnchor
        constraintGreaterThanOrEqualToAnchor:_paramOrderContent.leadingAnchor
                                    constant:KKPaddingMD],
    [pillBar.trailingAnchor
        constraintLessThanOrEqualToAnchor:_paramOrderContent.trailingAnchor
                                 constant:-KKPaddingMD],
    [pillBar.heightAnchor constraintEqualToConstant:24.0],
    [pillBar.topAnchor constraintEqualToAnchor:topEdge constant:KKPaddingSM],
  ]];
  return pillBar;
}

// (Re)build the category nav for the CURRENT owner and re-pin the list under
// whatever row now sits above it. Torn down and rebuilt rather than refilled
// because each owner declares its own categories - a rack entry running a
// different shader has a different set entirely.
- (void)_installParamOrderCategoryBar {
  [_paramOrderCategoryBar removeFromSuperview];
  _paramOrderCategoryBar = nil;
  _paramOrderScrollTop.active = NO;

  NSArray<KKLane *> *scoped = [self _paramOrderScopedLanes];
  _paramOrderCategoryKeys = KKLaneCategoryKeys(scoped);
  _paramOrderSelectedCategory =
      [_paramOrderCategoryKeys containsObject:_paramOrderSelectedCategory]
          ? _paramOrderSelectedCategory
          : _paramOrderCategoryKeys.firstObject;

  NSView *above = _paramOrderLayerBar ?: _paramOrderHeader;
  if (_paramOrderCategoryKeys.count > 0) {
    __weak typeof(self) weak = self;
    KKPillToggleRowView *pill = KKMakeLaneCategoryPill(
        scoped, _paramOrderSelectedCategory, ^(NSString *categoryKey) {
          KKTimelineInspectorView *strong = weak;
          if (!strong)
            return;
          strong->_paramOrderSelectedCategory = categoryKey;
          [strong _rebuildParamOrderList];
        });
    _paramOrderCategoryBar = [self _paramOrderPillBarFor:pill
                                               belowEdge:above.bottomAnchor];
    if (_paramOrderCategoryBar)
      above = _paramOrderCategoryBar;
  }
  _paramOrderScrollTop =
      [_paramOrderScroll.topAnchor constraintEqualToAnchor:above.bottomAnchor
                                                  constant:KKPaddingSM];
  _paramOrderScrollTop.active = YES;
}

// Picking an owner re-scopes the category nav and, through it, the rows.
- (void)_paramOrderSelectLayer:(NSString *)layerKey {
  if (layerKey.length == 0 ||
      [layerKey isEqualToString:_paramOrderSelectedLayer])
    return;
  _paramOrderSelectedLayer = [layerKey copy];
  [self _installParamOrderCategoryBar];
  [self _rebuildParamOrderList];
}

// Rebuild the reorder list to show only the selected category's params (in
// their current relative order) and resize the popover to fit. Dragging within
// the list merges the new sub-order back into the full order.
// A label's category for the reorder UI: its own categoryKey, or the first
// category when uncategorised (so stray params stay reachable in one place
// rather than vanishing from every category page).
- (NSString *)_paramOrderEffectiveCategory:(NSString *)label {
  NSString *c = _paramOrderCatByLabel[label];
  return c.length ? c : _paramOrderCategoryKeys.firstObject;
}

// Whether `label` shows on `category`'s page. An owner with no categories at
// all has no category nav either, so every one of its labels shows.
- (BOOL)_paramOrderShowsLabel:(NSString *)label
                   inCategory:(NSString *)category {
  if (_paramOrderCategoryKeys.count == 0)
    return YES;
  return [[self _paramOrderEffectiveCategory:label] isEqualToString:category];
}

// The reorder ROW title is the user-facing display name (a dynamic plugin's
// separate identity vs label - e.g. a shader uniform's "Center"), while the row
// ID stays the stable `label`. Resolve from the templates since the display
// label lives there.
- (NSString *)_paramOrderTitleForLabel:(NSString *)label {
  for (KKLane *l in _availableLanes)
    if ([l.key isEqualToString:label])
      return KKLocalizedParamName(l.displayName);
  return KKLocalizedParamName(label);
}

- (void)_rebuildParamOrderList {
  if (!_paramOrderListContainer)
    return;
  [_paramOrderList removeFromSuperview];

  NSMutableArray<NSString *> *ids = [NSMutableArray array];
  NSMutableArray<NSString *> *titles = [NSMutableArray array];
  for (NSString *label in _paramOrderLabels)
    if ([self _paramOrderLabelInScope:label] &&
        [self _paramOrderShowsLabel:label
                         inCategory:_paramOrderSelectedCategory]) {
      [ids addObject:label];
      [titles addObject:[self _paramOrderTitleForLabel:label]];
    }

  KKReorderListView *list = [[KKReorderListView alloc] initWithItemIDs:ids
                                                                titles:titles];
  list.translatesAutoresizingMaskIntoConstraints = NO;
  __weak typeof(self) weak = self;
  NSString *category = _paramOrderSelectedCategory;
  list.onReorder = ^(NSArray<NSString *> *newOrder) {
    [weak _applyParamSubOrder:newOrder forCategory:category];
  };
  [_paramOrderListContainer addSubview:list];
  [NSLayoutConstraint activateConstraints:@[
    [list.leadingAnchor
        constraintEqualToAnchor:_paramOrderListContainer.leadingAnchor],
    [list.trailingAnchor
        constraintEqualToAnchor:_paramOrderListContainer.trailingAnchor],
    [list.topAnchor constraintEqualToAnchor:_paramOrderListContainer.topAnchor],
    [list.bottomAnchor
        constraintEqualToAnchor:_paramOrderListContainer.bottomAnchor],
  ]];
  _paramOrderList = list;

  // Size the scroll to the list's content, capped - beyond the cap the list
  // scrolls inside KKPaddedScrollView (with fade shadows) instead of growing
  // the popover.
  _paramOrderScrollHeight.constant =
      MIN(list.intrinsicContentSize.height, kParamOrderMaxListH);
  _paramOrderScrollWidth.constant = list.intrinsicContentSize.width;

  [_paramOrderContent layoutSubtreeIfNeeded];
  if (_paramOrderPopover.isShown)
    _paramOrderPopover.contentSize = _paramOrderContent.fittingSize;
}

// Splice the reordered sub-order back into the full param order: the block of
// items the popover was SHOWING - `category`, and within the selected owner
// when there is an owner nav - is replaced in place (at its first occurrence),
// every other label keeps its position. Persists via applyParamOrder.
- (void)_applyParamSubOrder:(NSArray<NSString *> *)subOrder
                forCategory:(NSString *)category {
  NSMutableArray<NSString *> *result = [NSMutableArray array];
  BOOL inserted = NO;
  for (NSString *label in _paramOrderLabels) {
    if ([self _paramOrderLabelInScope:label] &&
        [self _paramOrderShowsLabel:label inCategory:category]) {
      if (!inserted) {
        [result addObjectsFromArray:subOrder];
        inserted = YES;
      }
      continue; // this category's items are represented by subOrder
    }
    [result addObject:label];
  }
  if (!inserted)
    [result addObjectsFromArray:subOrder];
  _paramOrderLabels = result;
  [_basicView applyParamOrder:result];
}

- (void)_oscSettingsClicked:(id)sender {
  if (_oscPopover.isShown) {
    [_oscPopover close];
    return;
  }
  NSArray<NSArray<NSString *> *> *compounds = self.oscVisibilityCompounds;
  if (!compounds.count)
    return;

  // The checklist derives each row's display label from the element key's leaf
  // (e.g. @"Rotation.X" -> "X") and localizes it itself.
  NSArray<NSArray<NSNumber *> *> *states =
      self.oscVisibilityElementStates ? self.oscVisibilityElementStates() : nil;
  // Map each element key to the lane's display name (e.g. a shader's stable
  // uniform-name key -> its "Center" label), else fall back to the key's leaf.
  NSArray<KKLane *> *avail = _availableLanes;
  KKOSCChecklistView *list = [[KKOSCChecklistView alloc]
      initWithCompounds:compounds
                 states:(states.count == compounds.count ? states : @[])
          displayForKey:^NSString *(NSString *key) {
            for (KKLane *l in avail)
              if ([l.key isEqualToString:key])
                return KKLocalizedParamName(l.displayName);
            // A Position OSC's motion-path element ("<lane> Path") has no lane
            // of its own; show "<display> Path" from the base lane's display
            // name (a dynamic plugin's key may be a uniform name, not "Path").
            if ([key hasSuffix:@" Path"]) {
              NSString *base = [key substringToIndex:key.length - 5];
              for (KKLane *l in avail)
                if ([l.key isEqualToString:base])
                  return [NSString
                      stringWithFormat:@"%@ %@",
                                       KKLocalizedParamName(l.displayName),
                                       KKLocalizedParamName(@"Path")];
            }
            return nil;
          }];
  list.translatesAutoresizingMaskIntoConstraints = NO;
  list.defaultsScope = self.oscDefaultsScope;
  // Owner nav: the same lane templates the display names came from also say
  // which owner each element belongs to, so a multi-owner element set (a shader
  // rack feeding every entry's controls) gets a pill row and opens on the entry
  // the host has selected - the resolution the Animated dropdown uses. A no-op
  // for a feed that resolves to one owner or none, which is every single-owner
  // plugin (Canvas's templates carry no layerKey, and its compounds are already
  // narrowed to the selected layer).
  [list applyLayerLanes:avail
       selectedLayerKey:[self.basicLanesView hostSelectedLayerKeyIn:avail]];
  _oscPillBar = list; // guide spotlight anchor (weak; lives in the popover)
  __weak typeof(self) weak = self;
  list.onToggled = ^(NSInteger compoundIdx, NSInteger segIdx, BOOL isOn) {
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

  // Present through the lanes view's companion-capable popover path (same
  // keep-alive outside-click handling as the value popovers) so a plugin's
  // companion side panel - Canvas's layer list - can attach beside it and
  // clicking that panel doesn't dismiss it. The presenter wraps `list` in the
  // liquid-glass content view (double-border fix) itself, so size + hand it the
  // checklist directly. `kind:@"osc"` tells the companion every layer is
  // selectable (like the constants kind).
  list.frame =
      NSMakeRect(0, 0, [KKOSCChecklistView preferredWidth], list.fittingHeight);
  __weak typeof(self) weakClose = self;
  _oscPopover = [self.basicLanesView
      showCompanionPopover:list
                  fromView:_oscSettingsButton
                      kind:@"osc"
                   onClose:^{
                     __strong typeof(weakClose) s = weakClose;
                     if (!s)
                       return;
                     s->_oscPopover = nil;
                     s->_oscPillBar = nil;
                   }];
  list.popover = _oscPopover; // so the search filter can re-fit the height
  // Guide observation: let the OSC guide grab the live popover (passthrough
  // window + pill spotlight) once it has settled into a window and laid out.
  if (self.onGuideOSCSettingsPopoverWillOpen) {
    __weak typeof(self) weakSelf = self;
    __weak NSView *weakContent = _oscPopover.contentViewController.view;
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

- (void)refreshOpenOSCChecklist {
  if (!_oscPopover.isShown || !_oscPillBar || !self.oscVisibilityElementStates)
    return;
  [_oscPillBar reloadStates:self.oscVisibilityElementStates()];
}

- (void)setOSCVisible:(BOOL)visible {
  _oscCheckbox.isChecked = visible;
  _oscSettingsButton.enabled = visible;
}

- (void)setMotionBlurEnabled:(BOOL)enabled {
  _mbCheckbox.isChecked = enabled;
  _mbSettingsButton.enabled = enabled;
  [self pushMotionBlurToMiniViewer];
}

- (void)setMotionBlurShutterAngle:(double)shutterAngle
                          samples:(NSInteger)samples {
  _mbShutterAngle = shutterAngle;
  _mbSamples = samples;
  [_mbSettingsView applyShutterAngle:shutterAngle
                             samples:samples
                           technique:_mbTechnique];
  [self pushMotionBlurToMiniViewer];
}

- (void)setMotionBlurTechnique:(KKMotionBlurTechnique)technique {
  // A host with no Fast support is always Accurate, whatever the blob says.
  _mbTechnique = [self motionBlurSupportsFastTechnique]
                     ? technique
                     : KKMotionBlurTechniqueAccurate;
  [_mbSettingsView applyShutterAngle:_mbShutterAngle
                             samples:_mbSamples
                           technique:_mbTechnique];
  [self pushMotionBlurToMiniViewer];
}

- (void)_mbSettingsClicked:(id)sender {
  if (_mbPopover.isShown) {
    [_mbPopover close];
    return;
  }
  _KKMotionBlurSettingsView *content = [[_KKMotionBlurSettingsView alloc]
      initWithShutterAngle:_mbShutterAngle
                   samples:_mbSamples
                 technique:_mbTechnique
              supportsFast:[self motionBlurSupportsFastTechnique]
            defaultSamples:[self motionBlurDefaultSamples]];
  __weak typeof(self) weak = self;
  content.onChanged = ^(double shutterAngle, NSInteger samples,
                        KKMotionBlurTechnique technique) {
    KKTimelineInspectorView *strong = weak;
    if (!strong)
      return;
    strong->_mbShutterAngle = shutterAngle;
    strong->_mbSamples = samples;
    strong->_mbTechnique = technique;
    if (strong.onMotionBlurChanged)
      strong.onMotionBlurChanged(strong->_mbCheckbox.isChecked, shutterAngle,
                                 samples, technique);
  };
  content.onDragBegin = ^{
    if (weak.onDragBegin)
      weak.onDragBegin();
  };
  content.onDragEnd = ^{
    if (weak.onDragEnd)
      weak.onDragEnd();
  };
  // The Samples row is removed in Fast, so the content height changes - resize
  // the open popover to match.
  content.onLayoutChanged = ^{
    KKTimelineInspectorView *strong = weak;
    // fittingSize, not frame.size: the view is pinned to the shared popover
    // wrapper (its frame tracks the popover), so ask autolayout for the new
    // intrinsic height after the Samples row is added/removed.
    if (strong && strong->_mbPopover.isShown)
      strong->_mbPopover.contentSize = strong->_mbSettingsView.fittingSize;
  };
  _mbSettingsView = content;
  // Give the content a concrete size so the presenter sizes the popover to it
  // (it reads content.bounds); autolayout resizes take over via
  // onLayoutChanged.
  content.frame =
      NSMakeRect(0, 0, content.fittingSize.width, content.fittingSize.height);

  // Present as an option picker on the lanes view: same reliable outside-click
  // dismiss (and liquid-glass wrapper) as the value popovers, closing on any
  // click outside itself. Its own toggle button is left to close it.
  _mbPopover =
      [self.basicLanesView showOptionPopover:content
                                    fromView:_mbSettingsButton
                               preferredEdge:NSRectEdgeMaxY
                                     onClose:^{
                                       KKTimelineInspectorView *strong = weak;
                                       if (strong)
                                         strong->_mbPopover = nil;
                                     }];
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
    [_maintainTimingButton.leadingAnchor
        constraintEqualToAnchor:_loopButton.trailingAnchor
                       constant:KKSpacingSM],
    [_maintainTimingButton.centerYAnchor
        constraintEqualToAnchor:headerRow.centerYAnchor],
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
                                           constant:-KKPaddingXS],
      ]];
      above = row;
    }
    [above.bottomAnchor constraintEqualToAnchor:self.bottomAnchor
                                       constant:-KKPaddingLG]
        .active = YES;
  }
}

@end
