/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Sticky ruler that pairs with KKStageSequencerView. Renders the timecode
/// ruler and playhead knob; handles playhead scrub and forwards scroll-wheel /
/// pinch events so horizontal zoom/pan stays synchronised between ruler and
/// lanes.
@interface KKStageSequencerRulerView : NSView

@property(nonatomic, assign) double effectDuration;
@property(nonatomic, assign) double playheadFraction;
@property(nonatomic, assign) CGFloat zoom;
@property(nonatomic, assign) CGFloat panOffset;

/// Reflects the current loop-playback param state. Updates the loop button's
/// visual state only — does not trigger `onLoopToggled`.
@property(nonatomic, assign) BOOL loopEnabled;

/// Called when user clicks/drags the ruler. Fraction is 0–1.
@property(nonatomic, copy, nullable) void (^onPlayheadScrub)(double fraction);

/// Called when the user zooms or pans over the ruler. Container wires this to
/// the paired sequencer view so both stay in sync.
@property(nonatomic, copy, nullable) void (^onZoomPanChanged)
    (CGFloat zoom, CGFloat panOffset);

/// Called when the user clicks the loop toggle button. Receives the desired
/// new state. Container writes the loop param and refreshes all paired views.
@property(nonatomic, copy, nullable) void (^onLoopToggled)(BOOL newState);

/// Fixed height the ruler wants in a parent layout.
+ (CGFloat)preferredHeight;

@end

NS_ASSUME_NONNULL_END
