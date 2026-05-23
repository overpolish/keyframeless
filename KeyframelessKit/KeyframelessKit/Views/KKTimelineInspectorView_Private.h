/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "KKTimelineInspectorView.h"

@class KKPlayButton;
@class KKPillToggleRowView;

NS_ASSUME_NONNULL_BEGIN

@interface KKTimelineInspectorView () {
@package
  /// Guide-only: fired AFTER `setActiveTab:` actually changes the tab,
  /// alongside (not replacing) the host's `onTabChanged`. The +Guide
  /// category stores/reads this.
  void (^_onGuideTabChanged)(NSInteger tab);
  /// Guide-only: when YES the play button accent is driven deterministically
  /// by taps (each tap toggles it) and the poll-inferred `setPlaying:` is
  /// ignored. A guide owns the playhead scenario, so the inferred state
  /// (which flickers under FCP's bursty currentTime) must not touch the
  /// button. The +Guide category sets this; the .m reads it.
  BOOL _guideOwnsPlayState;
  /// Guide-only: fired on every raw play-button tap (one per click,
  /// deterministic). The +Guide category stores/reads this.
  void (^_onPlaybackToggleTapped)(void);
}

/// Internal accessor so the +Guide category can read the play-button view
/// without exposing it on the public header.
- (nullable KKPlayButton *)_guidePlayButton;

/// Internal accessor so the +Guide category can resolve the tab bar's per-
/// segment screen rects.
- (nullable KKPillToggleRowView *)_guideTabBar;

/// Total custom-UI height including the motion-blur section when shown.
- (CGFloat)_totalHeight;
/// Builds the motion-blur parameter row (called from init when shown).
- (void)_buildMotionBlurRow;

@end

NS_ASSUME_NONNULL_END
