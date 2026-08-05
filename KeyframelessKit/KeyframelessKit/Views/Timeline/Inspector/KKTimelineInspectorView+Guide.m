/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKOSCChecklistView.h"
#import "KKPillToggleRowView.h"
#import "KKTimelineInspectorButtons.h"
#import "KKTimelineInspectorView+Guide.h"
#import "KKTimelineInspectorView_Private.h"
#import <KeyframelessKit/KKHelpSection.h> // KKHelpGuide completion marking
#import <KeyframelessKit/KKJoyrideGuideHost.h>
#import <KeyframelessKit/KKMiniViewerGuide.h>
#import <KeyframelessKit/KKOSCGuide.h>
#import <KeyframelessKit/KKOSCGuideBridge.h>
#import <KeyframelessKit/KKTimelineLanesView+Guide.h>
#import <KeyframelessKit/KKTimelineLanesView.h>
#import <KeyframelessKit/KKTimingGuide.h>

@implementation KKTimelineInspectorView (Guide)

- (void)guideSetActiveTab:(NSInteger)tab {
  // UI-only tab switch for a guide pin/restore: changes the visible tab WITHOUT
  // persisting (no `onTabChanged`), so the saved `activeTab` in the UI-state
  // blob never changes. Persisting it would make the plugin's parameterChanged
  // re-apply the pinned tab, racing the end-of-guide restore into an infinite
  // Basic<->Advanced loop. Bypasses the `_guideOwnsTab` guard (the guide owns
  // this call).
  _selectedTab = (KKTimelineTab)tab;
  [_tabBar setState:(tab == KKTimelineTabBasic) atIndex:KKTimelineTabBasic];
  [_tabBar setState:(tab == KKTimelineTabAdvanced)
            atIndex:KKTimelineTabAdvanced];
  [_basicView setActiveTab:tab];
  [_detachedView setActiveTab:tab];
}

@dynamic onGuideTabChanged;

- (void (^)(NSInteger))onGuideTabChanged {
  return _onGuideTabChanged;
}

- (void)setOnGuideTabChanged:(void (^)(NSInteger))block {
  _onGuideTabChanged = [block copy];
}

@dynamic guideOSCKeepLabels;

- (NSArray<NSString *> *)guideOSCKeepLabels {
  return _guideOSCKeepLabels;
}

- (void)setGuideOSCKeepLabels:(NSArray<NSString *> *)labels {
  _guideOSCKeepLabels = [labels copy];
}

static NSRect KKGuideScreenRectForView(NSView *v) {
  NSWindow *w = v.window;
  if (!v || !w)
    return NSZeroRect;
  return [w convertRectToScreen:[v convertRect:v.bounds toView:nil]];
}

@dynamic onGuideOSCMasterToggled;

- (void (^)(BOOL))onGuideOSCMasterToggled {
  return _onGuideOSCMasterToggled;
}

- (void)setOnGuideOSCMasterToggled:(void (^)(BOOL))block {
  _onGuideOSCMasterToggled = [block copy];
}

@dynamic onGuideOSCSettingsPopoverWillOpen;

- (void (^)(NSView *))onGuideOSCSettingsPopoverWillOpen {
  return _onGuideOSCSettingsPopoverWillOpen;
}

- (void)setOnGuideOSCSettingsPopoverWillOpen:(void (^)(NSView *))block {
  _onGuideOSCSettingsPopoverWillOpen = [block copy];
}

@dynamic onGuideOSCElementToggled;

- (void (^)(NSString *, BOOL))onGuideOSCElementToggled {
  return _onGuideOSCElementToggled;
}

- (void)setOnGuideOSCElementToggled:(void (^)(NSString *, BOOL))block {
  _onGuideOSCElementToggled = [block copy];
}

- (NSRect)guideOSCCheckboxScreenRect {
  return KKGuideScreenRectForView((NSView *)_oscCheckbox);
}

- (NSRect)guideOSCSettingsButtonScreenRect {
  return KKGuideScreenRectForView((NSView *)_oscSettingsButton);
}

- (NSRect)guideOSCSettingsPillBarScreenRect {
  return KKGuideScreenRectForView((NSView *)_oscPillBar);
}

- (NSRect)guideOSCSettingsPillScreenRectForLabel:(NSString *)label {
  if (!_oscPillBar || !label)
    return NSZeroRect;
  NSArray<NSArray<NSString *> *> *compounds = self.oscVisibilityCompounds;
  for (NSInteger ci = 0; ci < (NSInteger)compounds.count; ci++) {
    if (compounds[ci].count &&
        [compounds[ci].firstObject isEqualToString:label])
      return [_oscPillBar screenRectForCompoundIndex:ci];
  }
  return NSZeroRect;
}

- (void)guideCloseOSCSettingsPopover {
  [_oscPopover close];
}

- (NSRect)guidePlayButtonScreenRect {
  KKPlayButton *btn = [self _guidePlayButton];
  NSWindow *w = btn.window;
  if (!btn || !w)
    return NSZeroRect;
  return [w convertRectToScreen:[btn convertRect:btn.bounds toView:nil]];
}

- (NSRect)guideMaintainTimingButtonScreenRect {
  if (_maintainTimingButton.hidden)
    return NSZeroRect;
  return KKGuideScreenRectForView(_maintainTimingButton);
}

- (NSRect)guideTabSegmentScreenRectForTab:(NSInteger)tab {
  KKPillToggleRowView *bar = [self _guideTabBar];
  if (!bar)
    return NSZeroRect;
  return [bar guidePillScreenRectAtIndex:tab];
}

- (BOOL)guideOwnsPlayState {
  return _guideOwnsPlayState;
}

- (void)setGuideOwnsPlayState:(BOOL)owns {
  _guideOwnsPlayState = owns;
}

- (BOOL)guideOwnsTab {
  return _guideOwnsTab;
}

- (void)setGuideOwnsTab:(BOOL)owns {
  _guideOwnsTab = owns;
}

- (void (^)(void))onPlaybackToggleTapped {
  return _onPlaybackToggleTapped;
}

- (void)setOnPlaybackToggleTapped:(void (^)(void))block {
  _onPlaybackToggleTapped = [block copy];
}

- (void)guideSetPlayingAccent:(BOOL)on {
  [self _guidePlayButton].playing = on;
}

@dynamic onGuideCompleted;

- (void (^)(void))onGuideCompleted {
  return _onGuideCompleted;
}

- (void)setOnGuideCompleted:(void (^)(void))block {
  _onGuideCompleted = [block copy];
}

- (KKJoyrideGuideHost *)timingGuideHost {
  if (_timingGuideHost)
    return _timingGuideHost;
  _timingGuideHost =
      [[KKJoyrideGuideHost alloc] initWithHostView:self
                                         lanesView:self.basicLanesView];
  __weak typeof(self) weak = self;
  _timingGuideHost.currentTimelineProvider = ^KKTimeline * {
    return weak.basicLanesView.currentTimeline;
  };
  _timingGuideHost.timelineApplier = ^(KKTimeline *tl) {
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    // Route through the inspector's -applyTimeline: (NOT basicLanesView's) so
    // the seed gets the SAME processing an ordinary edit / shader-load does:
    // re-derive the source-declared lanes AND (for a plugin that overrides it)
    // re-wire the source-derived OSC set. A shader guide seed drops the code
    // lane and falls back to the default shader, so its directive lanes + OSC
    // controls load instead of showing the previous clip's. The teardown
    // restore runs through this same applier, so the user's shader comes back.
    [s applyTimeline:tl];
    if (s.onTimelineMutated)
      s.onTimelineMutated(tl);
    // Nudge a re-render after the seed (and any guide re-apply). Plugin-owned,
    // no-op if unset.
    if (s.onBoundaryPreviewNeedsRender)
      s.onBoundaryPreviewNeedsRender();
  };
  _timingGuideHost.onGuideCompleted = ^{
    __strong typeof(weak) s = weak;
    if (s.onGuideCompleted)
      s.onGuideCompleted();
  };
  return _timingGuideHost;
}

- (KKTimingGuideConfig *)makeTimingGuideConfig {
  __weak typeof(self) weak = self;
  KKTimingGuideConfig *cfg = [[KKTimingGuideConfig alloc] init];
  cfg.lanesView = self.basicLanesView;
  cfg.inspectorView = self;
  cfg.playButtonScreenRect = ^NSRect {
    __strong typeof(weak) s = weak;
    return s ? [s guidePlayButtonScreenRect] : NSZeroRect;
  };
  cfg.tabSegmentScreenRect = ^NSRect(NSInteger tab) {
    __strong typeof(weak) s = weak;
    return s ? [s guideTabSegmentScreenRectForTab:tab] : NSZeroRect;
  };
  cfg.constantsButtonView = ^NSView * {
    __strong typeof(weak) s = weak;
    return s.constantsButton;
  };
  cfg.scrubToFraction = ^(double fraction) {
    __strong typeof(weak) s = weak;
    // Guide-driven scrubs do not originate in either graph, so they must push
    // the local playhead explicitly before asking the host to seek. Otherwise
    // the seeded timeline renders at the user's stale pre-guide fraction until
    // FCP eventually echoes the seek back.
    [s setPlayheadFraction:fraction];
    if (s.onScrub)
      s.onScrub(fraction);
  };
  cfg.togglePlayback = ^{
    __strong typeof(weak) s = weak;
    if (s.onTogglePlayback)
      s.onTogglePlayback();
  };
  cfg.setPlayingAccent = ^(BOOL playing) {
    __strong typeof(weak) s = weak;
    [s guideSetPlayingAccent:playing];
  };
  cfg.requestPreviewRender = ^{
    __strong typeof(weak) s = weak;
    if (s.onBoundaryPreviewNeedsRender)
      s.onBoundaryPreviewNeedsRender();
  };
  // Only expose a help-button rect (and so the intro guide's closing Help step)
  // when the plugin has wired a provider.
  if (_guideHelpButtonScreenRectProvider) {
    cfg.helpButtonScreenRect = ^NSRect {
      __strong typeof(weak) s = weak;
      NSRect (^p)(void) = s.guideHelpButtonScreenRectProvider;
      return p ? p() : NSZeroRect;
    };
  }
  return cfg;
}

@dynamic timingGuideConfigProvider;

- (KKTimingGuideConfig * (^)(void))timingGuideConfigProvider {
  return _timingGuideConfigProvider;
}

- (void)setTimingGuideConfigProvider:(KKTimingGuideConfig * (^)(void))block {
  _timingGuideConfigProvider = [block copy];
}

@dynamic guideHelpButtonScreenRectProvider;

- (NSRect (^)(void))guideHelpButtonScreenRectProvider {
  return _guideHelpButtonScreenRectProvider;
}

- (void)setGuideHelpButtonScreenRectProvider:(NSRect (^)(void))block {
  _guideHelpButtonScreenRectProvider = [block copy];
}

- (void)restartBasicTimingGuide {
  KKTimingGuideConfig * (^provider)(void) = _timingGuideConfigProvider;
  if (!provider)
    return;
  // Any launch of the Introduction guide - autostart OR a manual click of the
  // Help window's "Introduction" row - counts as "shown", so the first-apply
  // autostart can never spring it again afterwards.
  [self _markIntroSeenAndDisarmAutostart];
  [self runBasicTimingGuideWithConfig:provider()];
}

- (void)restartAdvancedTimingGuide {
  KKTimingGuideConfig * (^provider)(void) = _timingGuideConfigProvider;
  if (!provider)
    return;
  [self runAdvancedTimingGuideWithConfig:provider()];
}

- (void)restartMiniViewerGuide {
  KKTimingGuideConfig * (^provider)(void) = _timingGuideConfigProvider;
  if (!provider)
    return;
  [self runMiniViewerGuideWithConfig:provider()];
}

- (void)restartOSCGuide {
  KKTimingGuideConfig * (^provider)(void) = _timingGuideConfigProvider;
  if (!provider)
    return;
  [self runOSCGuideWithConfig:provider()];
}

- (void)runOSCGuideWithConfig:(KKTimingGuideConfig *)cfg {
  NSInteger priorTab = self.activeTab;
  KKMiniViewerRenderMode priorRenderMode = self.basicLanesView.renderMode;
  self.basicLanesView.renderMode = KKMiniViewerRenderModeOff;
  KKJoyrideGuideHost *host = [self timingGuideHost];
  host.forwardsGestures =
      YES; // inspector checkbox / gear / pills are clickable
  // The mini-viewer OSC steps live in the Advanced sequencer's keypose popover,
  // so pin Advanced (UI-only, so the saved activeTab stays put) + own the tab
  // so the plugin's parameterChanged can't fight it. Restored on completion.
  [self guideSetActiveTab:KKTimelineTabAdvanced];
  self.guideOwnsTab = YES;
  // Force ALL on-screen controls visible at start (nil keep-set) so the user
  // has them to work with. Forcing doesn't block the user's own toggles during
  // the run - the checkbox / pill handlers update OSC state directly; the force
  // only stops an async refresh from reverting it. Restored on completion.
  self.guideOSCKeepLabels = nil;
  if (cfg.scrubToFraction)
    cfg.scrubToFraction(0.0);
  __weak typeof(self) weak = self;
  [host
      runWithSeed:^KKTimeline * {
        // An enabled (animatable) multi-keypose lane so the Advanced graph
        // shows the seeded animation. The viewer-drag step edits the keypose
        // nearest the playhead (via KKTimelineSettingValuesNearestFraction)
        // rather than collapsing the lane, so the other keyposes survive.
        // Restored to the user's timeline on end.
        return [KKMiniViewerGuide seedTimelineForConfig:cfg];
      }
      buildSteps:^NSArray<KKJoyrideStep *> *(KKJoyrideController *guide,
                                             KKJoyrideLanesBinder *binder) {
        // Reassert after the seed has landed. Applying the timeline can cause
        // a host render/current-time echo, and the viewer OSC must resolve the
        // first seeded keypose before its opening step is drawn.
        if (cfg.scrubToFraction)
          cfg.scrubToFraction(0.0);
        return [KKOSCGuide stepsForGuide:guide binder:binder config:cfg];
      }
      extraOnComplete:^{
        __strong typeof(weak) s = weak;
        if (!s)
          return;
        s.onGuideOSCMasterToggled = nil;
        s.onGuideOSCSettingsPopoverWillOpen = nil;
        s.onGuideOSCElementToggled = nil;
        [s guideCloseOSCSettingsPopover];
        [s.basicLanesView guideCloseContentPopover]; // the keypose mini-viewer
        s.basicLanesView.renderMode = priorRenderMode;
        s.guideOwnsTab = NO; // unlock before restoring the user's tab
        if (priorTab != s.activeTab)
          [s guideSetActiveTab:priorTab]; // UI-only, matches the pin
        // Disarm the OSC's guide mode so the viewer handle returns to tracking
        // the real value (not the guide-scoped one).
        KKOSCGuideBridge *b = cfg.oscGuideBridge ? cfg.oscGuideBridge() : nil;
        b.guideStep = 0;
      }];
}

- (void)runMiniViewerGuideWithConfig:(KKTimingGuideConfig *)cfg {
  NSInteger priorTab = self.activeTab;
  KKMiniViewerRenderMode priorRenderMode = self.basicLanesView.renderMode;
  // Start in Off so the first Filmstrip / Onion tap is a real mode change the
  // renderModeChanged trigger can catch.
  self.basicLanesView.renderMode = KKMiniViewerRenderModeOff;
  KKJoyrideGuideHost *host = [self timingGuideHost];
  host.forwardsGestures = YES;
  // The mini viewer (with all three modes) lives in the Advanced sequencer's
  // boundary value popover. Pin the tab, then own it so the plugin's
  // parameterChanged tab-restore can't fight it (the multi-keypose seed is
  // Basic-incompatible, so a stray switch to Basic would bounce endlessly).
  [self setActiveTab:KKTimelineTabAdvanced];
  self.guideOwnsTab = YES;
  if (cfg.scrubToFraction)
    cfg.scrubToFraction(0.0);

  self.guideOSCKeepLabels = cfg.oscKeepLabels;
  __weak typeof(self) weak = self;
  [host
      runWithSeed:^KKTimeline * {
        return [KKMiniViewerGuide seedTimelineForConfig:cfg];
      }
      buildSteps:^NSArray<KKJoyrideStep *> *(KKJoyrideController *guide,
                                             KKJoyrideLanesBinder *binder) {
        if (cfg.scrubToFraction)
          cfg.scrubToFraction(0.0);
        return [KKMiniViewerGuide stepsForGuide:guide binder:binder config:cfg];
      }
      extraOnComplete:^{
        __strong typeof(weak) s = weak;
        if (!s)
          return;
        [s.basicLanesView guideCloseContentPopover];
        s.basicLanesView.renderMode = priorRenderMode;
        s.guideOwnsTab = NO; // unlock before restoring the user's tab
        if (priorTab != s.activeTab)
          [s setActiveTab:priorTab];
      }];
}

- (void)runCustomAdvancedGuideWithSeed:(KKTimeline * (^)(void))seedBlock
                            buildSteps:(NSArray<KKJoyrideStep *> * (^)(
                                           KKJoyrideController *,
                                           KKJoyrideLanesBinder *))buildSteps
                         oscKeepLabels:(NSArray<NSString *> *)oscKeepLabels {
  if (!seedBlock || !buildSteps)
    return;
  NSInteger priorTab = self.activeTab;
  KKMiniViewerRenderMode priorRenderMode = self.basicLanesView.renderMode;
  self.basicLanesView.renderMode = KKMiniViewerRenderModeOff;
  KKJoyrideGuideHost *host = [self timingGuideHost];
  host.forwardsGestures = YES;
  // Pin Advanced + own the tab: the seed gains a 3rd Position keypose mid-run,
  // which is Basic-incompatible, so a stray parameterChanged tab-restore would
  // bounce. Mirrors the mini-viewer guide.
  [self setActiveTab:KKTimelineTabAdvanced];
  self.guideOwnsTab = YES;
  // The guide owns the play accent for its duration so FCP's bursty currentTime
  // can't flicker it, and so a watch-back step's setPlayingAccent takes.
  // Mirrors the Basic/Advanced timing runners. Restored on completion.
  self.guideOwnsPlayState = YES;
  // Custom guides do not carry a config, so mirror config.scrubToFraction:
  // update the local playhead as well as asking FCP to seek.
  [self setPlayheadFraction:0.0];
  if (self.onScrub)
    self.onScrub(0.0);

  self.guideOSCKeepLabels = oscKeepLabels;
  __weak typeof(self) weak = self;
  [host
      runWithSeed:^KKTimeline * {
        return seedBlock();
      }
      buildSteps:^NSArray<KKJoyrideStep *> *(KKJoyrideController *guide,
                                             KKJoyrideLanesBinder *binder) {
        __strong typeof(weak) s = weak;
        if (!s)
          return @[];
        // Forward play-button taps to the binder so a watch-back step's
        // binder.playToggleTapped machine fires (otherwise it never advances).
        __weak KKJoyrideLanesBinder *wb = binder;
        s.onPlaybackToggleTapped = ^{
          [wb notifyPlaybackToggleTapped];
        };
        return buildSteps(guide, binder);
      }
      extraOnComplete:^{
        __strong typeof(weak) s = weak;
        if (!s)
          return;
        s.onPlaybackToggleTapped = nil;
        s.guideOwnsPlayState = NO;
        [s.basicLanesView guideCloseContentPopover];
        s.basicLanesView.renderMode = priorRenderMode;
        s.guideOwnsTab = NO;
        if (priorTab != s.activeTab)
          [s setActiveTab:priorTab];
      }];
}

- (void)runBasicTimingGuideWithConfig:(KKTimingGuideConfig *)cfg {
  // Force Basic tab - the guide assumes Basic-mode UI. Snapshot to restore.
  NSInteger priorTab = self.activeTab;
  [self setActiveTab:KKTimelineTabBasic];
  // Single-frame mini-viewer during the guide; restore the user's choice on
  // completion (plain setter, no persistence).
  KKMiniViewerRenderMode priorRenderMode = self.basicLanesView.renderMode;
  self.basicLanesView.renderMode = KKMiniViewerRenderModeOff;
  KKJoyrideGuideHost *host = [self timingGuideHost];
  // forwardsGestures: the panel captures clicks/drags and feeds them to the
  // spotlight blocks (mini-viewer edit) instead of letting them reach FCP and
  // the popover natively at the same time.
  host.forwardsGestures = YES;
  // The guide owns the play accent for its duration so FCP's bursty
  // currentTime can't flicker it. Restored on completion.
  self.guideOwnsPlayState = YES;
  if (cfg.scrubToFraction)
    cfg.scrubToFraction(0.0);

  self.guideOSCKeepLabels = cfg.oscKeepLabels;
  __weak typeof(self) weak = self;
  [host
      runWithSeed:^KKTimeline * {
        return [KKTimingGuide basicSeedTimelineForConfig:cfg];
      }
      buildSteps:^NSArray<KKJoyrideStep *> *(KKJoyrideController *guide,
                                             KKJoyrideLanesBinder *binder) {
        __strong typeof(weak) s = weak;
        if (!s)
          return @[];
        // Forward play-button taps to the binder so the kit's watch-back
        // machine (binder.playToggleTapped) can run the auto-pause timer.
        __weak KKJoyrideLanesBinder *wb = binder;
        s.onPlaybackToggleTapped = ^{
          [wb notifyPlaybackToggleTapped];
        };
        if (cfg.scrubToFraction)
          cfg.scrubToFraction(0.0);
        return [KKTimingGuide basicStepsForGuide:guide
                                          binder:binder
                                          config:cfg];
      }
      extraOnComplete:^{
        __strong typeof(weak) s = weak;
        if (!s)
          return;
        s.onPlaybackToggleTapped = nil;
        s.guideOwnsPlayState = NO;
        s.basicLanesView.renderMode = priorRenderMode;
        if (priorTab != KKTimelineTabBasic)
          [s setActiveTab:priorTab];
      }];
}

- (void)runAdvancedTimingGuideWithConfig:(KKTimingGuideConfig *)cfg {
  NSInteger priorTab = self.activeTab;
  KKMiniViewerRenderMode priorRenderMode = self.basicLanesView.renderMode;
  self.basicLanesView.renderMode = KKMiniViewerRenderModeOff;
  // Start with the Dynamic display OFF so the guide's Dynamic step demonstrates
  // turning it ON; restore the user's choice on completion (mirrors the tab /
  // render-mode restore - the setter persists, so this writes the prior value
  // back).
  BOOL priorDynamic = self.basicLanesView.advancedGraph.dynamicDisplay;
  [self.basicLanesView guideSetDynamicDisplay:NO];
  KKJoyrideGuideHost *host = [self timingGuideHost];
  host.forwardsGestures = YES; // cmd-click + drag must reach the lane view

  // Start visually on Basic so the user sees the tab switch in step 1.
  [self setActiveTab:KKTimelineTabBasic];
  if (cfg.scrubToFraction)
    cfg.scrubToFraction(0.0);

  self.guideOSCKeepLabels = cfg.oscKeepLabels;
  __weak typeof(self) weak = self;
  // Step 1 advances when the user actually flips the tab to Advanced.
  self.onGuideTabChanged = ^(NSInteger tab) {
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    KKJoyrideGuideHost *h = [s timingGuideHost];
    if (!h.isActive || tab != 1)
      return;
    KKJoyrideController *gc = h.currentGuide;
    if (gc.currentStepIndex != 0)
      return;
    [gc advance];
  };

  [host
      runWithSeed:^KKTimeline * {
        return [KKTimingGuide advancedSeedTimelineForConfig:cfg];
      }
      buildSteps:^NSArray<KKJoyrideStep *> *(KKJoyrideController *guide,
                                             KKJoyrideLanesBinder *binder) {
        if (cfg.scrubToFraction)
          cfg.scrubToFraction(0.0);
        return [KKTimingGuide advancedStepsForGuide:guide
                                             binder:binder
                                             config:cfg];
      }
      extraOnComplete:^{
        __strong typeof(weak) s = weak;
        if (!s)
          return;
        s.onGuideTabChanged = nil;
        s.basicLanesView.renderMode = priorRenderMode;
        [s.basicLanesView guideSetDynamicDisplay:priorDynamic];
        if (priorTab != s.activeTab)
          [s setActiveTab:priorTab];
      }];
}

// Interval of the autostart gate poll. The gate (the effect selected + its OSC
// drawn) has no "became eligible" event we observe here, so we poll - the same
// cadence the help window uses for its guide-enable refresh. Sub-second so the
// intro springs promptly once the viewer shows the control.
static const NSTimeInterval kKKIntroAutostartPollInterval = 0.5;

- (void)autostartIntroGuideOnceWithSeenKey:(NSString *)seenKey {
  if (seenKey.length == 0)
    return;
  // Detached copies (the pop-out timeline window) never autostart - only the
  // real inspector does.
  if (_isDetachedCopy)
    return;
  // Left the window (or never in one): drop any armed poll and wait to be
  // re-armed on the next -viewDidMoveToWindow.
  if (!self.window) {
    [self _teardownIntroAutostart];
    return;
  }
  // Already shown (this launch or a previous one) - nothing to do.
  if ([NSUserDefaults.standardUserDefaults boolForKey:seenKey])
    return;
  _introSeenKey = [seenKey copy];
  if (_introAutostartTimer)
    return; // already polling
  // Poll for the gate rather than firing here: this runs mid
  // -viewDidMoveToWindow (the OSC hasn't drawn yet on a fresh apply anyway), so
  // deferring to the timer keeps the guide from starting synchronously during
  // view attachment.
  _introAutostartTimer = [NSTimer
      scheduledTimerWithTimeInterval:kKKIntroAutostartPollInterval
                              target:self
                            selector:@selector(_introAutostartPollTick:)
                            userInfo:nil
                             repeats:YES];
}

- (void)_introAutostartPollTick:(NSTimer *)timer {
  [self _tryAutostartIntro];
}

// Returns YES once the poll should stop (fired, or no longer applicable); NO to
// keep waiting for the gate.
- (BOOL)_tryAutostartIntro {
  NSString *seenKey = _introSeenKey;
  if (seenKey.length == 0) {
    [self _teardownIntroAutostart];
    return YES;
  }
  // Shown via some other path (e.g. the Help window's Introduction row) - stop.
  if ([NSUserDefaults.standardUserDefaults boolForKey:seenKey]) {
    [self _teardownIntroAutostart];
    return YES;
  }
  // Not on screen yet, or became detached: keep the arm alive but don't fire.
  if (!self.window || _isDetachedCopy)
    return NO;
  // The user has already started animating - don't spring the intro on top of
  // their work. A freshly-applied effect still lists every property as a lane,
  // but all in the CONSTANT state (lane.enabled == NO); only an ENABLED
  // (animated) lane means the user has begun, so gate on that, not lane count.
  NSArray<KKLane *> *lanes = self.basicLanesView.currentTimeline.lanes;
  NSUInteger animatedCount = 0;
  for (KKLane *lane in lanes)
    if (lane.enabled)
      animatedCount++;
  if (animatedCount != 0) {
    [self _teardownIntroAutostart];
    return YES;
  }
  // Don't interrupt a guide the user launched themselves; wait for it to end.
  if ([self timingGuideHost].isActive)
    return NO;
  // The gate: the SAME condition as the help window's "guides disabled" warning
  // - the effect is selected/highlighted and its on-screen controls have a live
  // draw tick. Derived from the config's OSC bridge; a plugin with no bridge is
  // treated as always eligible.
  if (![self _introAutostartGateSatisfied])
    return NO;
  // Fire once. -restartBasicTimingGuide marks `seenKey` seen and tears the poll
  // down, so this can never run twice.
  // Mark the "Introduction" help guide completed when this run finishes. The
  // help-window row wires this in its onStart; the autostart bypasses that, so
  // set it here (same completion flag) or the row would never show "Completed"
  // after a first-apply run.
  self.onGuideCompleted = ^{
    [KKHelpGuide markIdentifierCompleted:KKTimingIntroGuideIdentifier];
  };
  [self restartBasicTimingGuide];
  return YES;
}

- (BOOL)_introAutostartGateSatisfied {
  KKOSCGuideBridge * (^bridgeProvider)(void) = _introAutostartBridge;
  if (!bridgeProvider) {
    KKTimingGuideConfig * (^provider)(void) = _timingGuideConfigProvider;
    if (!provider)
      return NO; // no config yet - can't run the guide anyway; keep waiting
    KKTimingGuideConfig *cfg = provider();
    if (!cfg)
      return NO;
    // Cache the bridge accessor so we don't rebuild a config every tick. A nil
    // accessor (plugin without a viewer control) stays nil and is re-resolved
    // next tick - harmless, since a nil bridge means "eligible now" and fires
    // this same tick.
    bridgeProvider = [cfg.oscGuideBridge copy];
    _introAutostartBridge = bridgeProvider;
  }
  KKOSCGuideBridge *bridge = bridgeProvider ? bridgeProvider() : nil;
  return bridge ? [bridge hasCanvasReference] : YES;
}

- (void)_markIntroSeenAndDisarmAutostart {
  if (_introSeenKey.length &&
      ![NSUserDefaults.standardUserDefaults boolForKey:_introSeenKey]) {
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:_introSeenKey];
    [NSUserDefaults.standardUserDefaults synchronize];
  }
  [self _teardownIntroAutostart];
}

- (void)_teardownIntroAutostart {
  [_introAutostartTimer invalidate];
  _introAutostartTimer = nil;
  _introAutostartBridge = nil;
  _introSeenKey = nil;
}

@end
