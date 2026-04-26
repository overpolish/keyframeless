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

/// Optional mapping from `propertyLabel` to a `KKAnimatableParamKind` boxed
/// as `NSNumber`. Lets the renderer draw color/gradient lanes as a color
/// strip + single easing curve instead of plotting flat NSNumber values as
/// a multi-component line graph (which is meaningless for RGB/stop data).
/// Labels missing from the dict fall back to the scalar line rendering.
@property(nonatomic, copy, nullable)
    NSDictionary<NSString *, NSNumber *> *laneKindsByLabel;

/// Per-component value kinds, expanded so each entry corresponds to one
/// scalar in the segment's `values` array (e.g. a Point kind contributes
/// two `KKAnimatableParamKindPoint` entries). Used by the graph renderer
/// to skip non-numeric components like Bool.
@property(nonatomic, copy, nullable)
    NSDictionary<NSString *, NSArray<NSNumber *> *> *laneComponentKindsByLabel;

/// Property labels whose lanes have an associated on-screen control.
/// The sequencer stamps `lane.hasOSC` automatically whenever lanes are
/// assigned; plugins set this once at setup and never again.
@property(nonatomic, copy, nullable) NSSet<NSString *> *laneLabelsWithOSC;

/// Effect duration in seconds (for timecode ruler labels).
@property(nonatomic, assign) double effectDuration;

/// Current playhead position as a fraction of clip duration (0–1).
@property(nonatomic, assign) double playheadFraction;

/// Callbacks.
@property(nonatomic, copy, nullable) void (^onSegmentSelected)
    (NSInteger laneIndex, NSInteger segmentIndex);
/// Called when user shift-clicks a lane body. Selects one segment per lane —
/// the one containing the click fraction — so subsequent inspector edits
/// apply to the whole vertical slice.
@property(nonatomic, copy, nullable) void (^onAllLanesSegmentSelected)
    (double position);
@property(nonatomic, copy, nullable) void (^onLaneToggled)
    (NSInteger laneIndex, BOOL enabled);
/// Fired when the user clicks the lane's OSC visibility icon. Only fires
/// for lanes with `hasOSC = YES`.
@property(nonatomic, copy, nullable) void (^onLaneOSCVisibilityToggled)
    (NSInteger laneIndex, BOOL visible);
/// Called when boundary drag changes segment positions.
/// The callback receives the full updated lane (caller should persist).
@property(nonatomic, copy, nullable) void (^onLaneChanged)
    (NSInteger laneIndex, KKTimingLane *updatedLane);
/// Called after a bulk drag finishes. Provides every affected lane in one
/// shot so the plugin can persist the whole change in a single action —
/// avoids stale-read races between back-to-back `onLaneChanged` calls.
@property(nonatomic, copy, nullable) void (^onLanesChanged)
    (NSArray<NSNumber *> *laneIndexes, NSArray<KKTimingLane *> *updatedLanes);
/// Called when user double-clicks to add a segment.
@property(nonatomic, copy, nullable) void (^onSegmentAdded)
    (NSInteger laneIndex, double position);
/// Called when user shift+double-clicks to add a split across every lane at
/// the same fraction (snapped to the playhead when close).
@property(nonatomic, copy, nullable) void (^onAllLanesSegmentAdded)
    (double position);
/// Called when user requests segment removal (Cmd-click).
@property(nonatomic, copy, nullable) void (^onSegmentRemoved)
    (NSInteger laneIndex, NSInteger segmentIndex);
/// Called when user right-clicks a segment to toggle its type
/// (hold ↔ transition).
@property(nonatomic, copy, nullable) void (^onSegmentTypeToggled)
    (NSInteger laneIndex, NSInteger segmentIndex);
/// Called when user shift+right-clicks. Toggles the type (hold ↔ transition)
/// of the segment containing the click fraction in every lane, so each
/// segment flips independently rather than collapsing to one type.
@property(nonatomic, copy, nullable) void (^onAllLanesSegmentTypesToggled)
    (double position);
/// Called when user control-clicks a segment to toggle its duration lock.
/// `newLockedSeconds` is 0 to unlock, or the segment's current duration in
/// seconds to lock. The sequencer computes this from `effectDuration`, so the
/// plugin only has to persist the value.
@property(nonatomic, copy, nullable) void (^onSegmentLockToggled)
    (NSInteger laneIndex, NSInteger segmentIndex, double newLockedSeconds);
/// Called when user shift+control-clicks a segment to bulk-toggle locks
/// across every lane. `position` is the click fraction; `lock` is the
/// target state (YES = lock all lanes' segments under the fraction, NO =
/// unlock). Plugin computes per-lane locked duration from each segment's
/// own width × `effectDuration`.
@property(nonatomic, copy, nullable) void (^onAllLanesSegmentLockToggled)
    (double position, BOOL lock);
/// Called when the edit button above a segment is clicked. The anchor rect
/// is in this view's coordinate space — use it to anchor a popover.
@property(nonatomic, copy, nullable) void (^onSegmentEditRequested)
    (NSInteger laneIndex, NSInteger segmentIndex, NSRect anchorRect);
/// Called when the user shift+clicks an edit button. The popover should
/// apply changes to every same-type segment under the playhead (snapshot at
/// open time).
@property(nonatomic, copy, nullable) void (^onAllLanesSegmentEditRequested)
    (NSInteger laneIndex, NSInteger segmentIndex, NSRect anchorRect);
/// Called when the user opt-drags one segment onto another in the same lane.
/// The handler should copy `values` from the source segment to the destination
/// segment and leave everything else (type, easing, hold effect, intensity,
/// frequency, seed, start, end) intact.
@property(nonatomic, copy, nullable) void (^onSegmentValuesCopied)
    (NSInteger laneIndex, NSInteger srcSegmentIndex, NSInteger dstSegmentIndex);
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
