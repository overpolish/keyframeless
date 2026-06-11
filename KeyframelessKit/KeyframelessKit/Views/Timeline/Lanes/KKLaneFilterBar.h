/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKTimingStage.h>

NS_ASSUME_NONNULL_BEGIN

// Horizontal lane-visibility filter bar shown above the Advanced timeline.
// Opted-in lanes are grouped into capsules by category - a categorised run is
// [CategoryName | lane | lane ...] where the leading category segment is a
// master toggle for the whole group; an uncategorised lane is its own single
// segment capsule (e.g. MagicMove [Position] [Scale] [Opacity]). Toggling
// hides/shows lanes in the timeline. Order follows the lanes passed in
// (parameter order). Click-drag paints across capsules; option-click solos a
// lane or group (drawn in the warning tint). Every lane may be hidden - the
// host shows an empty-state message. Visibility is view state, not serialized.
@interface KKLaneFilterBar : NSView
- (instancetype)initWithLanes:(NSArray<KKLane *> *)lanes;
/// Rebuild only if the opted-in lane set/order changed; visibility of lanes
/// that survive is preserved, newly-added lanes default to visible.
- (void)applyLanes:(NSArray<KKLane *> *)lanes;
- (NSSet<NSString *> *)hiddenLabels;
/// Clear any solo and make every current lane visible (emits a visibility
/// change). Used when a guide takes over the timeline so its steps aren't
/// fighting a user-hidden lane.
- (void)showAllLanes;
/// Clear any solo and set visibility so exactly `hidden` (matched against the
/// current lanes) is hidden, the rest visible. Used to restore a snapshot the
/// guide took before it ran (emits a visibility change).
- (void)applyHiddenLabels:(NSSet<NSString *> *)hidden;
@property(nonatomic, copy, nullable) void (^onVisibilityChanged)
    (NSSet<NSString *> *hiddenLabels);
/// Fired only on a real user pill click/solo - not on the programmatic
/// showAllLanes / applyHiddenLabels mutators. Lets a guide advance its
/// "try the filter" step without the guide's own setup tripping it.
@property(nonatomic, copy, nullable) void (^onUserToggled)(void);
@end

NS_ASSUME_NONNULL_END
