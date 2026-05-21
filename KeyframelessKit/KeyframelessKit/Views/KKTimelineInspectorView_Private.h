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
  /// Guide-only: fired AFTER the play state actually crosses, from inside
  /// `setPlaying:`. The +Guide category stores/reads this; production code
  /// keeps using setPlaying:/onTogglePlayback.
  void (^_onPlayingChanged)(BOOL playing);
  /// Guide-only: fired AFTER `setActiveTab:` actually changes the tab,
  /// alongside (not replacing) the host's `onTabChanged`. The +Guide
  /// category stores/reads this.
  void (^_onGuideTabChanged)(NSInteger tab);
}

/// Internal accessor so the +Guide category can read the play-button view
/// without exposing it on the public header.
- (nullable KKPlayButton *)_guidePlayButton;

/// Internal accessor so the +Guide category can resolve the tab bar's per-
/// segment screen rects.
- (nullable KKPillToggleRowView *)_guideTabBar;

@end

NS_ASSUME_NONNULL_END
