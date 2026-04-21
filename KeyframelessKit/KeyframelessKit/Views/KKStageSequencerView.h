/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>

@class KKTimingLane;
@class KKTimingSegment;

NS_ASSUME_NONNULL_BEGIN

@interface KKStageSequencerView : NSView

/// Lane data to render. Each lane becomes a horizontal track.
/// Per-lane selection is read from each lane's selectedSegment property.
@property(nonatomic, copy) NSArray<KKTimingLane *> *lanes;

/// Effect duration in seconds (for timecode ruler labels).
@property(nonatomic, assign) double effectDuration;

/// Current playhead position as a fraction of clip duration (0–1).
@property(nonatomic, assign) double playheadFraction;

/// Callbacks.
@property(nonatomic, copy, nullable) void (^onSegmentSelected)
    (NSInteger laneIndex, NSInteger segmentIndex);
@property(nonatomic, copy, nullable) void (^onLaneToggled)
    (NSInteger laneIndex, BOOL enabled);
/// Called when boundary drag changes segment positions.
/// The callback receives the full updated lane (caller should persist).
@property(nonatomic, copy, nullable) void (^onLaneChanged)
    (NSInteger laneIndex, KKTimingLane *updatedLane);
/// Called when user double-clicks to add a segment.
@property(nonatomic, copy, nullable) void (^onSegmentAdded)
    (NSInteger laneIndex, double position);
/// Called when user requests segment removal (right-click / Cmd-click).
@property(nonatomic, copy, nullable) void (^onSegmentRemoved)
    (NSInteger laneIndex, NSInteger segmentIndex);
/// Called when user clicks/drags the ruler to scrub the playhead.
/// Fraction is 0–1 of clip duration.
@property(nonatomic, copy, nullable) void (^onPlayheadScrub)(double fraction);

/// Re-render the lanes image.
- (void)renderLanes;

@end

NS_ASSUME_NONNULL_END
