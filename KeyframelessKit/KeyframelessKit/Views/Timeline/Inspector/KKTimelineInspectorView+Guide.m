/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPillToggleRowView.h"
#import "KKTimelineInspectorButtons.h"
#import "KKTimelineInspectorView+Guide.h"
#import "KKTimelineInspectorView_Private.h"
#import <KeyframelessKit/KKJoyrideGuideHost.h>
#import <KeyframelessKit/KKMiniViewerGuide.h>
#import <KeyframelessKit/KKTimelineLanesView+Guide.h>
#import <KeyframelessKit/KKTimelineLanesView.h>
#import <KeyframelessKit/KKTimingGuide.h>

@implementation KKTimelineInspectorView (Guide)

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

- (NSRect)guidePlayButtonScreenRect {
  KKPlayButton *btn = [self _guidePlayButton];
  NSWindow *w = btn.window;
  if (!btn || !w)
    return NSZeroRect;
  return [w convertRectToScreen:[btn convertRect:btn.bounds toView:nil]];
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
    [s.basicLanesView applyTimeline:tl];
    if (s.onTimelineMutated)
      s.onTimelineMutated(tl);
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
  return cfg;
}

@dynamic timingGuideConfigProvider;

- (KKTimingGuideConfig * (^)(void))timingGuideConfigProvider {
  return _timingGuideConfigProvider;
}

- (void)setTimingGuideConfigProvider:(KKTimingGuideConfig * (^)(void))block {
  _timingGuideConfigProvider = [block copy];
}

- (void)restartBasicTimingGuide {
  KKTimingGuideConfig * (^provider)(void) = _timingGuideConfigProvider;
  if (!provider)
    return;
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

- (void)runMiniViewerGuideWithConfig:(KKTimingGuideConfig *)cfg {
  NSInteger priorTab = self.activeTab;
  KKMiniCanvasRenderMode priorRenderMode = self.basicLanesView.renderMode;
  // Start in Off so the first Filmstrip / Onion tap is a real mode change the
  // renderModeChanged trigger can catch.
  self.basicLanesView.renderMode = KKMiniCanvasRenderModeOff;
  KKJoyrideGuideHost *host = [self timingGuideHost];
  host.forwardsGestures = YES;
  // The mini viewer (with all three modes) lives in the Advanced sequencer's
  // boundary value popover. Pin the tab, then own it so the plugin's
  // parameterChanged tab-restore can't fight it (the multi-keypose seed is
  // Basic-incompatible, so a stray switch to Basic would bounce endlessly).
  [self setActiveTab:KKTimelineTabAdvanced];
  self.guideOwnsTab = YES;
  if (self.onScrub)
    self.onScrub(0.0);

  self.guideOSCKeepLabels = cfg.oscKeepLabels;
  __weak typeof(self) weak = self;
  [host
      runWithSeed:^KKTimeline * {
        return [KKMiniViewerGuide seedTimelineForConfig:cfg];
      }
      buildSteps:^NSArray<KKJoyrideStep *> *(KKJoyrideController *guide,
                                             KKJoyrideLanesBinder *binder) {
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

- (void)runBasicTimingGuideWithConfig:(KKTimingGuideConfig *)cfg {
  // Force Basic tab - the guide assumes Basic-mode UI. Snapshot to restore.
  NSInteger priorTab = self.activeTab;
  [self setActiveTab:KKTimelineTabBasic];
  // Single-frame mini-viewer during the guide; restore the user's choice on
  // completion (plain setter, no persistence).
  KKMiniCanvasRenderMode priorRenderMode = self.basicLanesView.renderMode;
  self.basicLanesView.renderMode = KKMiniCanvasRenderModeOff;
  KKJoyrideGuideHost *host = [self timingGuideHost];
  // forwardsGestures: the panel captures clicks/drags and feeds them to the
  // spotlight blocks (mini-canvas edit) instead of letting them reach FCP and
  // the popover natively at the same time.
  host.forwardsGestures = YES;
  // The guide owns the play accent for its duration so FCP's bursty
  // currentTime can't flicker it. Restored on completion.
  self.guideOwnsPlayState = YES;
  if (self.onScrub)
    self.onScrub(0.0);

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
  KKMiniCanvasRenderMode priorRenderMode = self.basicLanesView.renderMode;
  self.basicLanesView.renderMode = KKMiniCanvasRenderModeOff;
  KKJoyrideGuideHost *host = [self timingGuideHost];
  host.forwardsGestures = YES; // cmd-click + drag must reach the lane view

  // Start visually on Basic so the user sees the tab switch in step 1.
  [self setActiveTab:KKTimelineTabBasic];
  if (self.onScrub)
    self.onScrub(0.0);

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
        if (priorTab != s.activeTab)
          [s setActiveTab:priorTab];
      }];
}

- (void)autostartIntroGuideOnceWithSeenKey:(NSString *)seenKey {
  __weak typeof(self) weak = self;
  [[self timingGuideHost] autostartOnceWithSeenKey:seenKey
      precondition:^BOOL {
        __strong typeof(weak) s = weak;
        return s && !s.isDetachedCopy &&
               s.basicLanesView.currentTimeline.lanes.count == 0;
      }
      start:^{
        __strong typeof(weak) s = weak;
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:seenKey];
        [NSUserDefaults.standardUserDefaults synchronize];
        [s restartBasicTimingGuide];
      }];
}

@end
