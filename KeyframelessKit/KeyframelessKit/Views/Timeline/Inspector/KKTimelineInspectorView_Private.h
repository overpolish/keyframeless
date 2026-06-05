/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "KKTimelineInspectorView.h"
#import <KeyframelessKit/KKMotionBlur.h> // KKMotionBlurMode

@protocol PROAPIAccessing;
@class KKPlayButton;
@class KKPillToggleRowView;
@class KKResetZoomButton;
@class KKLoopButton;
@class KKConstantsButton;
@class KKDetachButton;
@class KKTimelineLanesView;
@class KKParameterRowView;
@class KKCheckboxView;
@class KKLane;
@class _KKCompatBannerView;
@class _KKMotionBlurSettingsView;
@class KKJoyrideGuideHost;

NS_ASSUME_NONNULL_BEGIN

@interface KKTimelineInspectorView () {
@package
  /// Guide-only: fired AFTER `setActiveTab:` actually changes the tab,
  /// alongside (not replacing) the host's `onTabChanged`. The +Guide
  /// category stores/reads this.
  void (^_onGuideTabChanged)(NSInteger tab);
  /// Guide-only: OSC element labels to keep visible during the current guide
  /// run (the +Guide category stores/reads this; the plugin's OSC hook uses
  /// it).
  NSArray<NSString *> *_guideOSCKeepLabels;
  /// Guide-only: when YES the play button accent is driven deterministically
  /// by taps (each tap toggles it) and the poll-inferred `setPlaying:` is
  /// ignored. A guide owns the playhead scenario, so the inferred state
  /// (which flickers under FCP's bursty currentTime) must not touch the
  /// button. The +Guide category sets this; the .m reads it.
  BOOL _guideOwnsPlayState;
  /// Guide-only: when YES, external `setActiveTab:` calls that would change the
  /// tab are ignored. A guide that pins a tab (e.g. the mini-viewer runs in
  /// Advanced) sets this so the plugin's parameterChanged tab-restore can't
  /// fight it into an infinite Basic<->Advanced loop. The +Guide category sets
  /// it (after pinning its tab); the .m's setActiveTab reads it.
  BOOL _guideOwnsTab;
  /// Guide-only: fired on every raw play-button tap (one per click,
  /// deterministic). The +Guide category stores/reads this.
  void (^_onPlaybackToggleTapped)(void);
  /// Guide-only: fired by the shared guide host when a run reaches its final
  /// step (completed, not skipped). The plugin's help guide sets this to mark
  /// itself done. The +Guide category stores/reads this.
  void (^_onGuideCompleted)(void);
  /// Guide-only: the one shared KKJoyrideGuideHost serving the Basic + Advanced
  /// timing guides. Lazily built by -timingGuideHost in the +Guide category.
  KKJoyrideGuideHost *_timingGuideHost;
  /// Guide-only: the plugin's config builder, set once in
  /// createViewForParameterID. The kit's restart/autostart methods call it to
  /// get a fresh KKTimingGuideConfig (plugin data + the inspector bridges from
  /// -makeTimingGuideConfig). id-typed to avoid importing KKTimingGuide here.
  id _timingGuideConfigProvider;

  // Main inspector state (migrated off the @implementation block so the
  // +ParameterRows / layout categories can reach it).
  id<PROAPIAccessing> _apiManager;
  KKTimelineTab _selectedTab;
  KKPillToggleRowView *_tabBar;
  KKPlayButton *_playButton;
  KKResetZoomButton *_resetButton;
  NSStackView *_accessoryStack;
  KKLoopButton *_loopButton;
  KKConstantsButton *_constantsButton;
  KKDetachButton *_detachButton;
  NSView *_contentView;
  _KKCompatBannerView *_compatBanner;
  KKTimelineLanesView *_basicView;
  KKParameterRowView *_mbRow;
  KKCheckboxView *_mbCheckbox;
  NSButton *_mbSettingsButton;
  NSPopover *_mbPopover;
  __weak _KKMotionBlurSettingsView *_mbSettingsView;
  BOOL _showsMotionBlurRow;
  KKParameterRowView *_oscRow;
  KKCheckboxView *_oscCheckbox;
  NSButton *_oscSettingsButton;
  NSPopover *_oscPopover;
  BOOL _showsOSCVisibilityRow;
  KKParameterRowView *_paramOrderRow;
  NSButton *_paramOrderButton;
  NSPopover *_paramOrderPopover;
  BOOL _showsParamOrderRow;
  double _mbShutterAngle;
  NSInteger _mbSamples;
  KKMotionBlurMode _mbMode;
  NSArray<KKLane *> *_availableLanes;
  BOOL _isDetachedCopy;
  BOOL _detachedAttached;
  __weak KKTimelineInspectorView *_detachedOwner;
  KKTimelineInspectorView *_detachedView;
  double _clipDurationSeconds;
  double _frameDurationSeconds;
}

/// Internal accessor so the +Guide category can read the play-button view
/// without exposing it on the public header.
- (nullable KKPlayButton *)_guidePlayButton;

/// Internal accessor so the +Guide category can resolve the tab bar's per-
/// segment screen rects.
- (nullable KKPillToggleRowView *)_guideTabBar;

/// Total custom-UI height including the motion-blur section when shown.
- (CGFloat)_totalHeight;

@end

/// Private +ParameterRows helpers (called from init when shown). Declared in a
/// named category so the primary @implementation isn't expected to provide
/// them; implemented in KKTimelineInspectorView+ParameterRows.m.
@interface KKTimelineInspectorView (ParameterRowsInternal)
- (void)_buildMotionBlurRow;
- (void)_buildOSCVisibilityRow;
- (void)_buildParamOrderRow;
- (void)_installConstraints:(NSView *)box headerRow:(NSView *)headerRow;
@end

// Layout constants shared between the main .m and the +ParameterRows category.
FOUNDATION_EXPORT const CGFloat kHeaderRowHeight;
FOUNDATION_EXPORT const CGFloat kMotionBlurRowHeight;
FOUNDATION_EXPORT const CGFloat kOSCVisibilityRowHeight;
FOUNDATION_EXPORT const CGFloat kParamOrderRowHeight;
FOUNDATION_EXPORT const CGFloat kMBCheckboxTrailing;

NS_ASSUME_NONNULL_END
