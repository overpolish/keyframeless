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

/// Fired AFTER `setPlaying:` actually crosses — only on real transitions,
/// not on equal-state pushes. Guide-only.
@property(nonatomic, copy, nullable) void (^onPlayingChanged)(BOOL playing);

@end

NS_ASSUME_NONNULL_END
