/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KKTimelineInspectorView.h>

NS_ASSUME_NONNULL_BEGIN

/// Guide-only surface on the inspector toolbar: screen-rect lookups for
/// header buttons (play, etc.) and extra observation hooks a Joyride step
/// needs.
@interface KKTimelineInspectorView (Guide)

/// Screen rect of the play button in the inspector header row. NSZeroRect
/// if not on screen. Used by joyride steps that cutout the play control.
- (NSRect)guidePlayButtonScreenRect;

/// Screen rect of the Basic (0) or Advanced (1) segment in the tab bar.
/// NSZeroRect if not on screen. Used by joyride steps that cutout a single
/// tab segment.
- (NSRect)guideTabSegmentScreenRectForTab:(NSInteger)tab;

/// Fired AFTER `setPlaying:` actually crosses — only on real transitions,
/// not on equal-state pushes. Guide-only.
@property(nonatomic, copy, nullable) void (^onPlayingChanged)(BOOL playing);

/// Guide-only: fired AFTER the tab actually changes (in addition to the
/// host's `onTabChanged`, which the plugin owns for blob persistence). Lets
/// a joyride step advance on a tab switch without taking over the host
/// callback.
@property(nonatomic, copy, nullable) void (^onGuideTabChanged)(NSInteger tab);

@end

NS_ASSUME_NONNULL_END
