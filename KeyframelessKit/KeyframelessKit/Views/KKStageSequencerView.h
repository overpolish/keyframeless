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
/// Called when user requests segment removal (Cmd-click).
@property(nonatomic, copy, nullable) void (^onSegmentRemoved)
    (NSInteger laneIndex, NSInteger segmentIndex);
/// Called when user right-clicks a segment to toggle its type
/// (hold ↔ transition).
@property(nonatomic, copy, nullable) void (^onSegmentTypeToggled)
    (NSInteger laneIndex, NSInteger segmentIndex);
/// Called when the edit button above a segment is clicked. The anchor rect
/// is in this view's coordinate space — use it to anchor a popover.
@property(nonatomic, copy, nullable) void (^onSegmentEditRequested)
    (NSInteger laneIndex, NSInteger segmentIndex, NSRect anchorRect);
/// Called when user clicks/drags the ruler to scrub the playhead.
/// Fraction is 0–1 of clip duration.
@property(nonatomic, copy, nullable) void (^onPlayheadScrub)(double fraction);

/// Horizontal zoom factor (1.0 = fit all, higher = zoomed in). Exposed so a
/// paired ruler view can mirror this value.
@property(nonatomic, assign) CGFloat zoom;

/// Visible start as a fraction 0–1. Exposed so a paired ruler view can mirror
/// this value.
@property(nonatomic, assign) CGFloat panOffset;

/// Fires whenever the user zooms or pans the lane area. The container wires
/// this to the paired ruler view so both stay in sync.
@property(nonatomic, copy, nullable) void (^onZoomPanChanged)
    (CGFloat zoom, CGFloat panOffset);

/// Re-render the lanes image.
- (void)renderLanes;

/// Computes the height the view needs in order to render `laneCount` lanes
/// without squishing its content. Use this to size the parent container.
+ (CGFloat)heightForLaneCount:(NSUInteger)laneCount;

@end

NS_ASSUME_NONNULL_END
