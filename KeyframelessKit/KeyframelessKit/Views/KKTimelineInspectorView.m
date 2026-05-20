/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineInspectorView.h"
#import "KKTimelineInspectorView_Private.h"

#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
#import "KKMiniCanvasView.h"
#import "KKPillToggleRowView.h"
#import "KKTimelineInspectorButtons.h"

static const CGFloat kInspectorHeight = 200.0;
static const CGFloat kHeaderRowHeight = 28.0;

@implementation KKTimelineInspectorView {
  id<PROAPIAccessing> _apiManager;
  KKTimelineTab _selectedTab;
  KKPillToggleRowView *_tabBar;
  KKPlayButton *_playButton;
  KKResetZoomButton *_resetButton;
  KKLoopButton *_loopButton;
  KKConstantsButton *_constantsButton;
  KKDetachButton *_detachButton;
  NSView *_contentView;
  KKTimelineLanesView *_basicView;
  NSArray<KKLane *> *_availableLanes;
  BOOL _isDetachedCopy;
  BOOL _detachedAttached;
  __weak KKTimelineInspectorView *_detachedOwner;
  KKTimelineInspectorView *_detachedView;
}

@synthesize basicLanesView = _basicView;
@synthesize constantsButton = _constantsButton;
@synthesize isDetachedCopy = _isDetachedCopy;

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                       loopEnabled:(BOOL)loopEnabled
                         activeTab:(NSInteger)activeTab
                    availableLanes:(NSArray<KKLane *> *)availableLanes
                          timeline:(KKTimeline *)timeline {
  self = [super initWithFrame:NSMakeRect(0, 0, 0, kInspectorHeight)];
  if (!self)
    return nil;
  _apiManager = apiManager;
  _availableLanes = [availableLanes copy];
  _selectedTab = (KKTimelineTab)activeTab;
  _constantsButtonTitle = @"Constants";
  self.autoresizingMask =
      NSViewWidthSizable | NSViewHeightSizable | NSViewMinYMargin;

  NSView *box = [self _buildBox];
  [self _buildTabBar];
  [self _buildHeaderButtons:loopEnabled];
  NSView *headerRow = [self _buildHeaderRow:box];
  [self _buildContentArea:box availableLanes:availableLanes timeline:timeline];
  [self _installConstraints:box headerRow:headerRow];
  return self;
}

#pragma mark - Construction

- (NSView *)_buildBox {
  NSView *box = [[NSView alloc] init];
  box.translatesAutoresizingMaskIntoConstraints = NO;
  box.wantsLayer = YES;
  box.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.08].CGColor;
  box.layer.borderColor = NSColor.separatorColor.CGColor;
  box.layer.borderWidth = 1.0;
  box.layer.cornerRadius = 8.0;
  [self addSubview:box];
  return box;
}

- (void)_buildTabBar {
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
  [_tabBar setState:(_selectedTab == KKTimelineTabBasic)
            atIndex:KKTimelineTabBasic];
  [_tabBar setState:(_selectedTab == KKTimelineTabAdvanced)
            atIndex:KKTimelineTabAdvanced];
  [self addSubview:_tabBar];

  __weak typeof(self) weak = self;
  _tabBar.onToggled = ^(NSInteger index, BOOL isOn) {
    if (!isOn)
      return;
    [weak _selectTab:(KKTimelineTab)index];
  };
}

- (void)_buildHeaderButtons:(BOOL)loopEnabled {
  __weak typeof(self) weak = self;

  _constantsButton = [[KKConstantsButton alloc] init];
  _constantsButton.translatesAutoresizingMaskIntoConstraints = NO;
  // Authoritative visibility is set from `_basicView.hasUnoptedLanes` once
  // it exists — a count-based check would wrongly hide this on reboot when
  // the persisted blob already has the (constant) lanes.
  _constantsButton.hidden = YES;
  [self addSubview:_constantsButton];

  _detachButton = [[KKDetachButton alloc] init];
  _detachButton.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:_detachButton];
  _detachButton.onTapped = ^{
    if (weak.onToggleDetached)
      weak.onToggleDetached();
  };

  _playButton = [[KKPlayButton alloc] init];
  _playButton.translatesAutoresizingMaskIntoConstraints = NO;
  _playButton.onTapped = ^{
    if (weak.onTogglePlayback)
      weak.onTogglePlayback();
  };

  _loopButton = [[KKLoopButton alloc] init];
  _loopButton.translatesAutoresizingMaskIntoConstraints = NO;
  _loopButton.on = loopEnabled;
  _loopButton.onToggled = ^(BOOL isOn) {
    if (weak.onLoopToggled)
      weak.onLoopToggled(isOn);
  };

  _resetButton = [[KKResetZoomButton alloc] init];
  _resetButton.translatesAutoresizingMaskIntoConstraints = NO;
  _resetButton.onTapped = ^{
    [weak.basicLanesView resetZoom];
  };
}

- (NSView *)_buildHeaderRow:(NSView *)box {
  NSView *headerRow = [[NSView alloc] init];
  headerRow.translatesAutoresizingMaskIntoConstraints = NO;
  [box addSubview:headerRow];
  [headerRow addSubview:_playButton];
  [headerRow addSubview:_loopButton];
  [headerRow addSubview:_resetButton];
  return headerRow;
}

- (void)_buildContentArea:(NSView *)box
           availableLanes:(NSArray<KKLane *> *)availableLanes
                 timeline:(KKTimeline *)timeline {
  _contentView = [[NSView alloc] init];
  _contentView.translatesAutoresizingMaskIntoConstraints = NO;
  [box addSubview:_contentView];

  _basicView =
      [[KKTimelineLanesView alloc] initWithAvailableLanes:availableLanes
                                                 timeline:timeline];
  _basicView.translatesAutoresizingMaskIntoConstraints = NO;
  [_contentView addSubview:_basicView];

  _constantsButton.hidden = !_basicView.hasUnoptedLanes;

  __weak typeof(self) weak = self;
  __weak KKConstantsButton *weakConstants = _constantsButton;
  __weak KKTimelineLanesView *weakBasic = _basicView;
  _constantsButton.onTapped = ^{
    KKTimelineLanesView *basic = weakBasic;
    KKConstantsButton *btn = weakConstants;
    if (basic && btn)
      [basic showStaticValuesPopoverFromView:btn];
  };
  _basicView.onTimelineMutated = ^(KKTimeline *updated) {
    KKTimelineInspectorView *strong = weak;
    KKTimelineLanesView *basic = weakBasic;
    KKConstantsButton *btn = weakConstants;
    if (basic && btn)
      btn.hidden = !basic.hasUnoptedLanes;
    if (strong.onTimelineMutated)
      strong.onTimelineMutated(updated);
  };
  _basicView.onDragBegin = ^{
    if (weak.onDragBegin)
      weak.onDragBegin();
  };
  _basicView.onDragEnd = ^{
    if (weak.onDragEnd)
      weak.onDragEnd();
  };
  _basicView.onScrub = ^(double frac) {
    if (weak.onScrub)
      weak.onScrub(frac);
  };
  _basicView.onZoomChanged = ^(BOOL zoomed) {
    KKTimelineInspectorView *strong = weak;
    strong->_resetButton.zoomed = zoomed;
  };
  _basicView.onBoundaryPreviewNeedsRender = ^{
    if (weak.onBoundaryPreviewNeedsRender)
      weak.onBoundaryPreviewNeedsRender();
  };
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
    [box.bottomAnchor constraintEqualToAnchor:self.bottomAnchor
                                     constant:-KKPaddingLG],

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
}

#pragma mark - Configuration propagation

- (void)setMiniCanvasDescriptorPath:(NSString *)path {
  _miniCanvasDescriptorPath = [path copy];
  _basicView.miniCanvasDescriptorPath = path;
}

- (void)setMiniCanvasRequestPath:(NSString *)path {
  _miniCanvasRequestPath = [path copy];
  _basicView.miniCanvasRequestPath = path;
}

- (void)setMiniCanvasDelegate:(id<KKMiniCanvasDelegate>)delegate {
  _miniCanvasDelegate = delegate;
  _basicView.miniCanvasDelegate = delegate;
}

- (void)setManagePopoverSpotlightLabel:(NSString *)label {
  _managePopoverSpotlightLabel = [label copy];
  _basicView.managePopoverSpotlightLabel = label;
}

#pragma mark - Tab + live push

- (void)_selectTab:(KKTimelineTab)tab {
  _selectedTab = tab;
  [_tabBar setState:(tab == KKTimelineTabBasic) atIndex:KKTimelineTabBasic];
  [_tabBar setState:(tab == KKTimelineTabAdvanced)
            atIndex:KKTimelineTabAdvanced];
  if (_onTabChanged)
    _onTabChanged(tab);
}

- (void)setActiveTab:(NSInteger)tab {
  _selectedTab = (KKTimelineTab)tab;
  [_tabBar setState:(tab == KKTimelineTabBasic) atIndex:KKTimelineTabBasic];
  [_tabBar setState:(tab == KKTimelineTabAdvanced)
            atIndex:KKTimelineTabAdvanced];
  [_detachedView setActiveTab:tab];
}

- (void)applyTimeline:(KKTimeline *)timeline {
  [_basicView applyTimeline:timeline];
  _constantsButton.hidden = !_basicView.hasUnoptedLanes;
  [_detachedView applyTimeline:timeline];
}

- (void)setLoopEnabled:(BOOL)enabled {
  _loopButton.on = enabled;
  [_loopButton setNeedsDisplay:YES];
  [_detachedView setLoopEnabled:enabled];
}

- (void)setClipDurationSeconds:(double)seconds {
  [_basicView setClipDurationSeconds:seconds];
  [_detachedView setClipDurationSeconds:seconds];
}

- (void)setFrameDurationSeconds:(double)seconds {
  [_basicView setFrameDurationSeconds:seconds];
  [_detachedView setFrameDurationSeconds:seconds];
}

- (void)setPlayheadFraction:(double)frac {
  [_basicView setPlayheadFraction:frac];
  [_detachedView setPlayheadFraction:frac];
}

- (void)setPlaying:(BOOL)playing {
  BOOL was = _playButton.playing;
  _playButton.playing = playing;
  [_detachedView setPlaying:playing];
  if (was != playing && _onPlayingChanged)
    _onPlayingChanged(playing);
}

- (KKPlayButton *)_guidePlayButton {
  return _playButton;
}

#pragma mark - Detached copy

- (BOOL)hasDetachedWindow {
  return _detachedView != nil;
}

- (instancetype)beginDetachedCopy {
  if (_isDetachedCopy || _detachedView)
    return _detachedView;
  KKTimelineInspectorView *copy =
      [[[self class] alloc] initWithAPIManager:_apiManager
                                   loopEnabled:_loopButton.on
                                     activeTab:_selectedTab
                                availableLanes:_availableLanes
                                      timeline:_basicView.currentTimeline];
  copy->_isDetachedCopy = YES;
  copy->_detachedOwner = self;
  copy->_detachButton.hidden = YES;
  // Propagate plugin-supplied configuration so the copy matches the source.
  copy.miniCanvasDescriptorPath = _miniCanvasDescriptorPath;
  copy.miniCanvasRequestPath = _miniCanvasRequestPath;
  copy.miniCanvasDelegate = _miniCanvasDelegate;
  copy.managePopoverSpotlightLabel = _managePopoverSpotlightLabel;
  copy.constantsButtonTitle = _constantsButtonTitle;
  // Propagate standard callbacks (subclasses propagate any extras after
  // calling super).
  copy.onLoopToggled = _onLoopToggled;
  copy.onTabChanged = _onTabChanged;
  copy.onTimelineMutated = _onTimelineMutated;
  copy.onDragBegin = _onDragBegin;
  copy.onDragEnd = _onDragEnd;
  copy.onScrub = _onScrub;
  copy.onTogglePlayback = _onTogglePlayback;
  copy.onBoundaryPreviewNeedsRender = _onBoundaryPreviewNeedsRender;
  _detachedView = copy;
  _detachButton.on = YES;
  [_detachButton setNeedsDisplay:YES];
  return copy;
}

- (void)handleDetachedWindowClosed {
  _detachButton.on = NO;
  [_detachButton setNeedsDisplay:YES];
  if (!_detachedView)
    return;
  KKTimelineInspectorView *dying = _detachedView;
  _detachedView = nil;
  // Deferred — we may be unwinding the copy's own `-viewDidMoveToWindow`;
  // releasing inline is a use-after-free.
  dispatch_async(dispatch_get_main_queue(), ^{
    [dying removeFromSuperview];
  });
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (!_isDetachedCopy)
    return;
  if (self.window) {
    _detachedAttached = YES;
  } else if (_detachedAttached) {
    _detachedAttached = NO;
    [_detachedOwner handleDetachedWindowClosed];
  }
}

- (CGSize)intrinsicContentSize {
  return NSMakeSize(NSViewNoIntrinsicMetric, kInspectorHeight);
}

@end
