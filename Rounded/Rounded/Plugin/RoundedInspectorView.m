/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "RoundedInspectorView.h"
#import "RoundedInspectorView+Guides.h"
#import "RoundedInspectorView_Private.h"
#import <KeyframelessKit/KKTokens.h>

static const CGFloat kInspectorHeight = 200.0;

@implementation RoundedInspectorView

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                       loopEnabled:(BOOL)loopEnabled
                         activeTab:(NSInteger)activeTab
                    availableLanes:(NSArray<KKLane *> *)availableLanes
                          timeline:(KKTimeline *)timeline {
  self = [super initWithFrame:NSMakeRect(0, 0, 0, kInspectorHeight)];
  if (self) {
    _apiManager = apiManager;
    _availableLanes = [availableLanes copy];
    _selectedTab = (RoundedTab)activeTab;
    self.autoresizingMask =
        NSViewWidthSizable | NSViewHeightSizable | NSViewMinYMargin;

    NSView *box = [[NSView alloc] init];
    box.translatesAutoresizingMaskIntoConstraints = NO;
    box.wantsLayer = YES;
    box.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.08].CGColor;
    box.layer.borderColor = NSColor.separatorColor.CGColor;
    box.layer.borderWidth = 1.0;
    box.layer.cornerRadius = 8.0;
    [self addSubview:box];

    NSArray<NSImage *> *tabIcons = @[
      [NSImage imageWithSystemSymbolName:@"sparkles"
                accessibilityDescription:nil],
      [NSImage imageWithSystemSymbolName:@"timeline.selection"
                accessibilityDescription:nil],
    ];
    _tabBar =
        [[KKPillToggleRowView alloc] initWithLabels:@[ @"Basic", @"Advanced" ]
                                              icons:tabIcons];
    _tabBar.translatesAutoresizingMaskIntoConstraints = NO;
    _tabBar.radioMode = YES;
    _tabBar.grouped = YES;
    [_tabBar setState:(_selectedTab == RoundedTabBasic)
              atIndex:RoundedTabBasic];
    [_tabBar setState:(_selectedTab == RoundedTabAdvanced)
              atIndex:RoundedTabAdvanced];
    [self addSubview:_tabBar];

    _constantsButton = [[_RoundedConstantsButton alloc] init];
    _constantsButton.translatesAutoresizingMaskIntoConstraints = NO;
    _constantsButton.hidden = (timeline.lanes.count >= availableLanes.count);
    [self addSubview:_constantsButton];

    _detachButton = [[_RoundedDetachButton alloc] init];
    _detachButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_detachButton];

    __weak typeof(self) weak = self;

    _tabBar.onToggled = ^(NSInteger index, BOOL isOn) {
      if (!isOn)
        return;
      __strong typeof(weak) strong = weak;
      if (!strong)
        return;
      [strong _selectTab:(RoundedTab)index];
    };

    _detachButton.onTapped = ^{
      __strong typeof(weak) strong = weak;
      if (!strong)
        return;
      if (strong.onToggleDetached)
        strong.onToggleDetached();
    };

    NSView *headerRow = [[NSView alloc] init];
    headerRow.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:headerRow];

    _loopButton = [[_RoundedLoopButton alloc] init];
    _loopButton.translatesAutoresizingMaskIntoConstraints = NO;
    _loopButton.on = loopEnabled;
    [headerRow addSubview:_loopButton];

    _loopButton.onToggled = ^(BOOL isOn) {
      __strong typeof(weak) strong = weak;
      if (!strong)
        return;
      if (strong.onLoopToggled)
        strong.onLoopToggled(isOn);
    };

    _contentView = [[NSView alloc] init];
    _contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:_contentView];

    _basicView =
        [[KKTimelineLanesView alloc] initWithAvailableLanes:availableLanes
                                                   timeline:timeline];
    _basicView.translatesAutoresizingMaskIntoConstraints = NO;
    _basicView.managePopoverSpotlightLabel = @"Radius";
    [_contentView addSubview:_basicView];

    // Capture weakBasic and weakConstants AFTER _basicView is assigned.
    __weak _RoundedConstantsButton *weakConstants = _constantsButton;
    __weak KKTimelineLanesView *weakBasic = _basicView;

    _constantsButton.onTapped = ^{
      __strong KKTimelineLanesView *basic = weakBasic;
      __strong _RoundedConstantsButton *btn = weakConstants;
      if (basic && btn)
        [basic showStaticValuesPopoverFromView:btn];
    };

    _basicView.onTimelineMutated = ^(KKTimeline *updated) {
      __strong typeof(weak) strong = weak;
      __strong KKTimelineLanesView *basic = weakBasic;
      __strong _RoundedConstantsButton *btn = weakConstants;
      if (!strong)
        return;
      if (basic && btn)
        btn.hidden = !basic.hasUnoptedLanes;
      if (strong.onTimelineMutated)
        strong.onTimelineMutated(updated);
    };

    CGFloat h = KKInspectorHorizontalInset;
    [NSLayoutConstraint activateConstraints:@[
      [_tabBar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                            constant:h],
      [_tabBar.topAnchor constraintEqualToAnchor:self.topAnchor
                                        constant:KKPaddingMD],

      [_constantsButton.trailingAnchor
          constraintEqualToAnchor:self.trailingAnchor
                         constant:-h],
      [_constantsButton.centerYAnchor
          constraintEqualToAnchor:_tabBar.centerYAnchor],

      [_detachButton.leadingAnchor
          constraintEqualToAnchor:_tabBar.trailingAnchor
                         constant:KKPaddingMD],
      [_detachButton.centerYAnchor
          constraintEqualToAnchor:_tabBar.centerYAnchor],

      [box.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:h],
      [box.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                         constant:-h],
      [box.topAnchor constraintEqualToAnchor:_tabBar.bottomAnchor
                                    constant:KKPaddingMD],
      [box.bottomAnchor constraintEqualToAnchor:self.bottomAnchor
                                       constant:-KKPaddingLG],

      [headerRow.leadingAnchor constraintEqualToAnchor:box.leadingAnchor],
      [headerRow.trailingAnchor constraintEqualToAnchor:box.trailingAnchor],
      [headerRow.topAnchor constraintEqualToAnchor:box.topAnchor],
      [headerRow.heightAnchor constraintEqualToConstant:28.0],

      [_loopButton.leadingAnchor constraintEqualToAnchor:headerRow.leadingAnchor
                                                constant:KKPaddingMD],
      [_loopButton.centerYAnchor
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
      [_basicView.bottomAnchor
          constraintEqualToAnchor:_contentView.bottomAnchor],
    ]];
  }
  return self;
}

- (KKTimelineLanesView *)basicLanesView {
  return _basicView;
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (_isDetachedCopy) {
    if (self.window) {
      _detachedAttached = YES;
    } else if (_detachedAttached) {
      _detachedAttached = NO;
      [_detachedOwner handleDetachedWindowClosed];
    }
    return;
  }
  [self _maybeAutostartIntroGuide];
}

- (void)setLoopEnabled:(BOOL)enabled {
  _loopButton.on = enabled;
  [_loopButton setNeedsDisplay:YES];
  [_detachedView setLoopEnabled:enabled];
}

- (void)applyTimeline:(KKTimeline *)timeline {
  [_basicView applyTimeline:timeline];
  _constantsButton.hidden = !_basicView.hasUnoptedLanes;
  [_detachedView applyTimeline:timeline];
}

- (void)_selectTab:(RoundedTab)tab {
  _selectedTab = tab;
  [_tabBar setState:(tab == RoundedTabBasic) atIndex:RoundedTabBasic];
  [_tabBar setState:(tab == RoundedTabAdvanced) atIndex:RoundedTabAdvanced];
  if (_onTabChanged)
    _onTabChanged(tab);
}

- (void)setActiveTab:(NSInteger)tab {
  _selectedTab = (RoundedTab)tab;
  [_tabBar setState:(tab == RoundedTabBasic) atIndex:RoundedTabBasic];
  [_tabBar setState:(tab == RoundedTabAdvanced) atIndex:RoundedTabAdvanced];
  [_detachedView setActiveTab:tab];
}

- (BOOL)hasDetachedWindow {
  return _detachedView != nil;
}

- (RoundedInspectorView *)beginDetachedCopy {
  if (_isDetachedCopy || _detachedView)
    return _detachedView;
  RoundedInspectorView *copy = [[RoundedInspectorView alloc]
      initWithAPIManager:_apiManager
             loopEnabled:_loopButton.on
               activeTab:_selectedTab
          availableLanes:_availableLanes
                timeline:_basicView.currentTimeline];
  copy->_isDetachedCopy = YES;
  copy->_detachedOwner = self;
  copy->_detachButton.hidden = YES;
  copy.onLoopToggled = self.onLoopToggled;
  copy.onTabChanged = self.onTabChanged;
  copy.onTimelineMutated = self.onTimelineMutated;
  copy.effectHeaderRectProvider = self.effectHeaderRectProvider;
  _detachedView = copy;
  _detachButton.on = YES;
  [_detachButton setNeedsDisplay:YES];
  return copy;
}

// Called when the remote window has closed (the plugin asked the host to, or
// the user closed it and the copy's window went nil). Deferred — we may be
// unwinding the copy's own -viewDidMoveToWindow; releasing inline is UAF.
- (void)handleDetachedWindowClosed {
  _detachButton.on = NO;
  [_detachButton setNeedsDisplay:YES];
  if (!_detachedView)
    return;
  RoundedInspectorView *dying = _detachedView;
  _detachedView = nil;
  dispatch_async(dispatch_get_main_queue(), ^{
    [dying removeFromSuperview];
    [dying release];
  });
}

- (void)dealloc {
  [_detachedView release];
  [_availableLanes release];
  [super dealloc];
}

- (CGSize)intrinsicContentSize {
  return NSMakeSize(NSViewNoIntrinsicMetric, kInspectorHeight);
}

@end
