/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineInspectorView.h"
#import "KKLocalized.h"
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
#import <KeyframelessKit/KKTimingCompat.h>

// 260 base + 30 reserved for the lane-filter pill bar above the Advanced
// timeline (matches kLaneFilterBarH in KKTimelineLanesView+Helpers.m). The
// FxPlug custom-UI height is fixed at init, so the strip is reserved
// unconditionally; the graph absorbs it when the bar is hidden (Basic / <2
// lanes), so there is no empty gap.
static const CGFloat kInspectorHeight = 260.0 + 30.0;
const CGFloat kHeaderRowHeight = 28.0;
// The motion-blur parameter row sits in its own section below the box. The
// custom-UI height is fixed at init, so we reserve this once up front.
const CGFloat kMotionBlurRowHeight = 24.0;
// The on-screen-control visibility row mirrors the motion-blur row's section
// below the box; same fixed height reserved up front.
const CGFloat kOSCVisibilityRowHeight = 24.0;
// The property-order row mirrors the same section; gear-only (no checkbox).
const CGFloat kParamOrderRowHeight = 24.0;
// The presets row mirrors the same section; gear-only (no checkbox).
const CGFloat kPresetsRowHeight = 24.0;
// Trailing margin that lands the checkbox on the native control gutter, same
// value KKCustomGroupHeaderView uses.
const CGFloat kMBCheckboxTrailing = 23.0;

@implementation KKTimelineInspectorView

@synthesize basicLanesView = _basicView;
@synthesize constantsButton = _constantsButton;
@synthesize isDetachedCopy = _isDetachedCopy;

- (void)setGapPopoverExtraRows:
    (NSArray<NSView *> * (^)(KKGapPopoverPhase, NSString *, KKInterval *,
                             KKGapIntervalReader, KKGapIntervalMutator))block {
  _gapPopoverExtraRows = [block copy];
  _basicView.gapPopoverExtraRows = block;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                       loopEnabled:(BOOL)loopEnabled
             maintainTimingEnabled:(BOOL)maintainTimingEnabled
                         activeTab:(NSInteger)activeTab
                    availableLanes:(NSArray<KKLane *> *)availableLanes
                          timeline:(KKTimeline *)timeline {
  self = [super initWithFrame:NSMakeRect(0, 0, 0, kInspectorHeight)];
  if (!self)
    return nil;
  _apiManager = apiManager;
  _availableLanes = [availableLanes copy];
  _selectedTab = (KKTimelineTab)activeTab;
  _constantsButtonTitle =
      KKLoc(@"Constants", @"Constants editor tab/section header.");
  // Read the subclass hooks once; the custom-UI height can't change after init.
  _showsMotionBlurRow = [self showsMotionBlurRow];
  _showsOSCVisibilityRow = [self showsOSCVisibilityRow];
  // Reordering is moot with 0/1 properties.
  _showsParamOrderRow = (_availableLanes.count >= 2);
  _showsPresetsRow = [self showsPresetsRow];
  _mbShutterAngle = 180.0; // the natural shutter
  _mbSamples = 16;
  _mbMode = KKMotionBlurModeTransitionsOnly; // default; cheapest
  [self setFrameSize:NSMakeSize(0, [self _totalHeight])];
  self.autoresizingMask =
      NSViewWidthSizable | NSViewHeightSizable | NSViewMinYMargin;

  NSView *box = [self _buildBox];
  [self _buildTabBar];
  [self _buildHeaderButtons:loopEnabled maintainTiming:maintainTimingEnabled];
  NSView *headerRow = [self _buildHeaderRow:box];
  [self _buildContentArea:box availableLanes:availableLanes timeline:timeline];
  if (_showsMotionBlurRow)
    [self _buildMotionBlurRow];
  if (_showsOSCVisibilityRow)
    [self _buildOSCVisibilityRow];
  if (_showsParamOrderRow)
    [self _buildParamOrderRow];
  if (_showsPresetsRow)
    [self _buildPresetsRow];
  [self _installConstraints:box headerRow:headerRow];
  return self;
}

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
  _tabBar = [[KKPillToggleRowView alloc] initWithLabels:@[
    KKLoc(@"Basic", @"Timeline mode tab: basic."),
    KKLoc(@"Advanced", @"Timeline mode tab: advanced.")
  ]
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

- (void)_buildHeaderButtons:(BOOL)loopEnabled
             maintainTiming:(BOOL)maintainTimingEnabled {
  __weak typeof(self) weak = self;

  _constantsButton = [[KKConstantsButton alloc] init];
  _constantsButton.translatesAutoresizingMaskIntoConstraints = NO;
  // Authoritative visibility is set from `_basicView.hasUnoptedLanes` once
  // it exists - a count-based check would wrongly hide this on reboot when
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
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    // During a guide the inspector owns the play accent: each tap is a
    // deterministic toggle, so flip it locally instead of waiting on the
    // poll-inferred `setPlaying:` (which flickers under FCP's bursty
    // currentTime). The tap hook lets a Joyride step advance on the click.
    if (s->_guideOwnsPlayState)
      s->_playButton.playing = !s->_playButton.playing;
    if (s->_onPlaybackToggleTapped)
      s->_onPlaybackToggleTapped();
    if (s.onTogglePlayback)
      s.onTogglePlayback();
  };

  _loopButton = [[KKLoopButton alloc] init];
  _loopButton.translatesAutoresizingMaskIntoConstraints = NO;
  _loopButton.on = loopEnabled;
  _loopButton.onToggled = ^(BOOL isOn) {
    if (weak.onLoopToggled)
      weak.onLoopToggled(isOn);
  };

  _maintainTimingButton = [[KKMaintainTimingButton alloc] init];
  _maintainTimingButton.translatesAutoresizingMaskIntoConstraints = NO;
  _maintainTimingButton.on = maintainTimingEnabled;
  // Advanced-only: Basic parks the first/last keypose at the clip edges, so a
  // retimed (off-edge) keypose isn't a representable Basic state.
  _maintainTimingButton.hidden = (_selectedTab != KKTimelineTabAdvanced);
  _maintainTimingButton.toolTip =
      KKLoc(@"Maintain Timing",
            @"Toolbar toggle: pin the animation to absolute time so trimming "
            @"or splitting the clip keeps each keypose where it is.");
  _maintainTimingButton.onToggled = ^(BOOL isOn) {
    if (weak.onMaintainTimingToggled)
      weak.onMaintainTimingToggled(isOn);
  };

  _resetButton = [[KKResetZoomButton alloc] init];
  _resetButton.translatesAutoresizingMaskIntoConstraints = NO;
  _resetButton.onTapped = ^{
    [weak.basicLanesView resetZoom];
  };

  _accessoryStack = [[NSStackView alloc] init];
  _accessoryStack.translatesAutoresizingMaskIntoConstraints = NO;
  _accessoryStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  _accessoryStack.spacing = KKSpacingSM;
  _accessoryStack.alignment = NSLayoutAttributeCenterY;
}

- (void)_remountAccessoryButtons {
  for (NSView *v in [_accessoryStack.arrangedSubviews copy]) {
    [_accessoryStack removeArrangedSubview:v];
    [v removeFromSuperview];
  }
  for (NSView *v in _basicView.accessoryButtons)
    [_accessoryStack addArrangedSubview:v];
}

- (NSView *)_buildHeaderRow:(NSView *)box {
  NSView *headerRow = [[NSView alloc] init];
  headerRow.translatesAutoresizingMaskIntoConstraints = NO;
  [box addSubview:headerRow];
  [headerRow addSubview:_playButton];
  [headerRow addSubview:_loopButton];
  [headerRow addSubview:_maintainTimingButton];
  [headerRow addSubview:_accessoryStack];
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
  [_basicView setActiveTab:_selectedTab];
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
  _basicView.onAccessoryButtonsChanged = ^{
    [weak _remountAccessoryButtons];
  };
  // Render-mode pill lives inside the keypose-value popover header (owned
  // by _basicView's lanes view); forward picks back to the inspector's own
  // onRenderModeChanged. _basicView.renderMode is pushed from the host via
  // -setRenderMode: below.
  _basicView.onRenderModeChanged = ^(KKMiniViewerRenderMode mode) {
    KKTimelineInspectorView *strong = weak;
    if (strong.onRenderModeChanged)
      strong.onRenderModeChanged(mode);
  };
  [self _remountAccessoryButtons];

  _compatBanner = [[_KKCompatBannerView alloc] init];
  _compatBanner.translatesAutoresizingMaskIntoConstraints = NO;
  _compatBanner.hidden = YES;
  _compatBanner.wantsLayer = YES;
  _compatBanner.layer.cornerRadius = KKRadiusMD;
  _compatBanner.layer.masksToBounds = YES;
  [_contentView addSubview:_compatBanner
                positioned:NSWindowAbove
                relativeTo:_basicView];
  [NSLayoutConstraint activateConstraints:@[
    [_compatBanner.leadingAnchor
        constraintEqualToAnchor:_contentView.leadingAnchor],
    [_compatBanner.trailingAnchor
        constraintEqualToAnchor:_contentView.trailingAnchor],
    [_compatBanner.topAnchor constraintEqualToAnchor:_contentView.topAnchor],
    [_compatBanner.bottomAnchor
        constraintEqualToAnchor:_contentView.bottomAnchor],
  ]];
  _compatBanner.onCancel = ^{
    [weak _dismissCompatBanner];
  };
  _compatBanner.onConfirm = ^{
    [weak _confirmCompatSwitch];
  };
}

- (BOOL)showsMotionBlurRow {
  return YES;
}

- (BOOL)showsOSCVisibilityRow {
  return NO;
}

- (BOOL)showsPresetsRow {
  return YES;
}

- (CGFloat)_totalHeight {
  return kInspectorHeight +
         (_showsMotionBlurRow ? kMotionBlurRowHeight + KKPaddingXS : 0.0) +
         (_showsOSCVisibilityRow ? kOSCVisibilityRowHeight + KKPaddingXS
                                 : 0.0) +
         (_showsParamOrderRow ? kParamOrderRowHeight + KKPaddingXS : 0.0) +
         (_showsPresetsRow ? kPresetsRowHeight + KKPaddingXS : 0.0);
}

// Builds one of the optional rows below the box - a labeled left view plus a
// 12pt checkbox in the native control gutter and an 18pt settings gear to its
// left. The motion-blur and on-screen-control rows share this so their layout
// can't drift; the caller wires the checkbox's `onToggle` (the gear's action is
// passed in). The checkbox/gear are returned through the out-params.

- (void)setMiniViewerDescriptorPath:(NSString *)path {
  _miniViewerDescriptorPath = [path copy];
  _basicView.miniViewerDescriptorPath = path;
}

- (void)setMiniViewerRequestPath:(NSString *)path {
  _miniViewerRequestPath = [path copy];
  _basicView.miniViewerRequestPath = path;
}

- (void)setMiniViewerDelegate:(id<KKMiniViewerDelegate>)delegate {
  _miniViewerDelegate = delegate;
  _basicView.miniViewerDelegate = delegate;
}

- (void)setManagePopoverSpotlightLabel:(NSString *)label {
  _managePopoverSpotlightLabel = [label copy];
  _basicView.managePopoverSpotlightLabel = label;
}

- (void)_selectTab:(KKTimelineTab)tab {
  // While the compat banner is up the tab bar tentatively shows Basic, but the
  // real mode is still Advanced. Clicking Advanced cancels (same as the
  // banner's Cancel button); re-clicking Basic just keeps it tentatively
  // selected.
  if (!_compatBanner.hidden) {
    if (tab == KKTimelineTabAdvanced)
      [self _dismissCompatBanner];
    else
      [_tabBar setState:YES atIndex:KKTimelineTabBasic];
    return;
  }
  // Advanced → Basic with incompatible structure: tentatively SELECT Basic and
  // show the overlay; the real switch waits for "Switch anyway". Selecting
  // Basic (not reverting to Advanced) is what lets a click on Advanced read as
  // a tab change and cancel the pending switch.
  if (tab == KKTimelineTabBasic && _selectedTab != KKTimelineTabBasic &&
      !KKTimelineIsBasicCompatible(_basicView.currentTimeline,
                                   [self _outEndFrac])) {
    [_tabBar setState:YES atIndex:KKTimelineTabBasic];
    [_tabBar setState:NO atIndex:KKTimelineTabAdvanced];
    _compatBanner.hidden = NO;
    [_basicView setOverlayBlockingInteractions:YES];
    return;
  }
  _selectedTab = tab;
  _maintainTimingButton.hidden = (tab != KKTimelineTabAdvanced);
  [_tabBar setState:(tab == KKTimelineTabBasic) atIndex:KKTimelineTabBasic];
  [_tabBar setState:(tab == KKTimelineTabAdvanced)
            atIndex:KKTimelineTabAdvanced];
  [_basicView setActiveTab:tab];
  if (_onTabChanged)
    _onTabChanged(tab);
  if (_onGuideTabChanged)
    _onGuideTabChanged(tab);
}

- (void)_dismissCompatBanner {
  _compatBanner.hidden = YES;
  [_basicView setOverlayBlockingInteractions:NO];
  // The banner tentatively showed Basic; restore the tab bar to the real mode
  // (Advanced) now that the pending switch is cancelled.
  [_tabBar setState:(_selectedTab == KKTimelineTabBasic)
            atIndex:KKTimelineTabBasic];
  [_tabBar setState:(_selectedTab == KKTimelineTabAdvanced)
            atIndex:KKTimelineTabAdvanced];
}

// Basic parks the lane-end at `outEndFrac` (one frame before clip end), not at
// 1.0. Both the compat check (is the final keypose there?) and the reseed
// (place the produced end there) need this, so they share one source of truth.
// Falls back to 1.0 until the clip/frame duration is known.
- (double)_outEndFrac {
  if (_clipDurationSeconds > 0.0 && _frameDurationSeconds > 0.0 &&
      _frameDurationSeconds < _clipDurationSeconds)
    return (_clipDurationSeconds - _frameDurationSeconds) /
           _clipDurationSeconds;
  return 1.0;
}

- (void)_confirmCompatSwitch {
  KKTimeline *reseeded =
      KKTimelineReseedToBasic(_basicView.currentTimeline, [self _outEndFrac]);
  [_basicView applyTimeline:reseeded];
  [_detachedView applyTimeline:reseeded];
  if (_onTimelineMutated)
    _onTimelineMutated(reseeded);
  _compatBanner.hidden = YES;
  [_basicView setOverlayBlockingInteractions:NO];
  [self _selectTab:KKTimelineTabBasic];
}

- (NSInteger)activeTab {
  return (NSInteger)_selectedTab;
}

- (void)setRenderMode:(KKMiniViewerRenderMode)mode {
  _basicView.renderMode = mode;
}

- (KKMiniViewerRenderMode)renderMode {
  return _basicView.renderMode;
}

- (void)setActiveTab:(NSInteger)tab {
  BOOL changed = (_selectedTab != (KKTimelineTab)tab);
  // A guide that pins the tab ignores external switches (e.g. the plugin's
  // parameterChanged re-applying the saved tab), which would otherwise fight
  // the guide into a Basic<->Advanced loop. The guide's own pin / restore set
  // _guideOwnsTab around their setActiveTab calls.
  if (changed && _guideOwnsTab)
    return;
  _selectedTab = (KKTimelineTab)tab;
  _maintainTimingButton.hidden = (tab != KKTimelineTabAdvanced);
  [_tabBar setState:(tab == KKTimelineTabBasic) atIndex:KKTimelineTabBasic];
  [_tabBar setState:(tab == KKTimelineTabAdvanced)
            atIndex:KKTimelineTabAdvanced];
  [_basicView setActiveTab:tab];
  [_detachedView setActiveTab:tab];
  // Mirror the user-tap path so external switches (guides, restore-from-
  // saved-state on a remount) also persist via the host's onTabChanged.
  if (changed && _onTabChanged)
    _onTabChanged(tab);
  if (changed && _onGuideTabChanged)
    _onGuideTabChanged(tab);
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

- (void)setMaintainTimingEnabled:(BOOL)enabled {
  _maintainTimingButton.on = enabled;
  [_detachedView setMaintainTimingEnabled:enabled];
}

- (void)setClipDurationSeconds:(double)seconds {
  _clipDurationSeconds = seconds;
  [_basicView setClipDurationSeconds:seconds];
  [_detachedView setClipDurationSeconds:seconds];
}

- (void)setFrameDurationSeconds:(double)seconds {
  _frameDurationSeconds = seconds;
  [_basicView setFrameDurationSeconds:seconds];
  [_detachedView setFrameDurationSeconds:seconds];
}

- (void)setPlayheadFraction:(double)frac {
  [_basicView setPlayheadFraction:frac];
  [_detachedView setPlayheadFraction:frac];
}

- (void)setPlaying:(BOOL)playing {
  // A guide drives the accent deterministically from taps; ignore the
  // poll-inferred state so it can't flicker the button mid-guide.
  if (_guideOwnsPlayState)
    return;
  _playButton.playing = playing;
  [_detachedView setPlaying:playing];
}

- (KKPlayButton *)_guidePlayButton {
  return _playButton;
}

- (KKPillToggleRowView *)_guideTabBar {
  return _tabBar;
}

- (BOOL)hasDetachedWindow {
  return _detachedView != nil;
}

- (instancetype)beginDetachedCopy {
  if (_isDetachedCopy || _detachedView)
    return _detachedView;
  KKTimelineInspectorView *copy =
      [[[self class] alloc] initWithAPIManager:_apiManager
                                   loopEnabled:_loopButton.on
                         maintainTimingEnabled:_maintainTimingButton.on
                                     activeTab:_selectedTab
                                availableLanes:_availableLanes
                                      timeline:_basicView.currentTimeline];
  copy->_isDetachedCopy = YES;
  copy->_detachedOwner = self;
  copy->_detachButton.hidden = YES;
  // Propagate plugin-supplied configuration so the copy matches the source.
  copy.miniViewerDescriptorPath = _miniViewerDescriptorPath;
  copy.miniViewerRequestPath = _miniViewerRequestPath;
  copy.miniViewerDelegate = _miniViewerDelegate;
  copy.managePopoverSpotlightLabel = _managePopoverSpotlightLabel;
  copy.constantsButtonTitle = _constantsButtonTitle;
  copy.presetPluginKey = self.presetPluginKey;
  // Propagate standard callbacks (subclasses propagate any extras after
  // calling super).
  copy.onLoopToggled = _onLoopToggled;
  copy.onMaintainTimingToggled = _onMaintainTimingToggled;
  copy.onTabChanged = _onTabChanged;
  copy.onMotionBlurChanged = _onMotionBlurChanged;
  [copy setMotionBlurEnabled:_mbCheckbox.isChecked];
  [copy setMotionBlurShutterAngle:_mbShutterAngle samples:_mbSamples];
  [copy setMotionBlurMode:_mbMode];
  copy.onRenderModeChanged = _onRenderModeChanged;
  copy.renderMode = _basicView.renderMode;
  copy.onTimelineMutated = _onTimelineMutated;
  copy.onDragBegin = _onDragBegin;
  copy.onDragEnd = _onDragEnd;
  copy.onScrub = _onScrub;
  copy.onTogglePlayback = _onTogglePlayback;
  copy.onBoundaryPreviewNeedsRender = _onBoundaryPreviewNeedsRender;
  _detachedView = copy;
  // Bidirectional Advanced selection mirror - selection lives per-view, not
  // in the timeline blob, so without this clicks in the detached window
  // wouldn't reflect in the inspector and vice versa. Each side's
  // applyAdvancedSelectionPillKeys: no-ops on equal sets, breaking the
  // would-be ping-pong.
  __weak KKTimelineInspectorView *weakSelf = self;
  __weak KKTimelineInspectorView *weakCopy = copy;
  _basicView.onAdvancedSelectionChanged =
      ^(NSSet<NSString *> *pills, NSSet<NSString *> *gaps) {
        KKTimelineInspectorView *c = weakCopy;
        [c.basicLanesView applyAdvancedSelectionPillKeys:pills gapKeys:gaps];
      };
  copy.basicLanesView.onAdvancedSelectionChanged =
      ^(NSSet<NSString *> *pills, NSSet<NSString *> *gaps) {
        KKTimelineInspectorView *s = weakSelf;
        [s.basicLanesView applyAdvancedSelectionPillKeys:pills gapKeys:gaps];
      };
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
  // Deferred - we may be unwinding the copy's own `-viewDidMoveToWindow`;
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
  return NSMakeSize(NSViewNoIntrinsicMetric, [self _totalHeight]);
}

@end
