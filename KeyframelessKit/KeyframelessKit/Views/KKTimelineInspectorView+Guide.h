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

/// Guide-only: when YES the play button accent is driven deterministically by
/// taps (each tap toggles it) and the poll-inferred `setPlaying:` is ignored.
/// A guide owns the playhead scenario, so the inferred play state - which
/// flickers under FCP's bursty currentTime - must not touch the button. Set
/// YES for the duration of a guide that walks the play control; restore NO on
/// completion.
@property(nonatomic) BOOL guideOwnsPlayState;

/// Guide-only: fired on every raw play-button tap (one per click,
/// deterministic). Use this to advance a step on the *click* rather than the
/// poll-inferred play state. Drives nothing on its own.
@property(nonatomic, copy, nullable) void (^onPlaybackToggleTapped)(void);

/// Guide-only: set the play button accent directly, bypassing the
/// `guideOwnsPlayState` guard. For the guide to reflect a play state it caused
/// itself (e.g. an auto-pause), not a user tap.
- (void)guideSetPlayingAccent:(BOOL)on;

/// Guide-only: fired AFTER the tab actually changes (in addition to the
/// host's `onTabChanged`, which the plugin owns for blob persistence). Lets
/// a joyride step advance on a tab switch without taking over the host
/// callback.
@property(nonatomic, copy, nullable) void (^onGuideTabChanged)(NSInteger tab);

@end

NS_ASSUME_NONNULL_END
