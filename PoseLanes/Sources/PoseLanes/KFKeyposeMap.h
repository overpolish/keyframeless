/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>

// Internal to the timing editor sources.

// One keypose in the map: when it arrives, the timecode shown beneath it, its
// link-group tint and how much of its incoming segment its duration occupies.
@interface KFKeyposeStop : NSObject
@property(nonatomic) CMTime time;
// nil where the map leaves the keypose unlabelled.
@property(nonatomic, copy) NSString *label;
// nil when the keypose is not in a link group.
@property(nonatomic, strong) NSColor *linkColor;
// Trailing fraction of the incoming segment the transition occupies; the rest
// is hold. Zero for the first stop, which has no incoming gap.
@property(nonatomic) double transitionFraction;
@end

// Ordinal keypose map for one lane. Every gap gets the same width, so no
// authoring can bunch the keyposes together, and the hold/transition split is
// drawn to scale inside each one. The axis is deliberately not a time ruler,
// so the stops carry timecodes to show where the scale is compressed.
@interface KFKeyposeMap : NSView
@property(nonatomic, copy) NSArray<KFKeyposeStop *> *stops;
// Destination keypose of the gap holding the playhead, or -1 when the playhead
// sits outside the keyed range. Its incoming transition is the editable extent.
@property(nonatomic) NSInteger activeIndex;
// The keypose the playhead is sitting exactly on, or -1. Standing on a keypose
// makes it a write target, taking its value in explicit mode and its Added
// Motion when it is the active gap's source, even when the gap being edited
// arrives somewhere else, which is what the first keypose of a lane always does.
@property(nonatomic) NSInteger playheadIndex;
// Playhead position across the whole map, 0-1; negative hides the marker.
@property(nonatomic) double playheadFraction;
// The active gap's source keypose joins the highlight while the Added Motion
// controls are in use, since those settings are written to that pose.
@property(nonatomic) BOOL sourceHighlighted;
@property(copy) void (^onSelect)(CMTime time);
// Ordinal position across the map, for dragging the playhead along the rail
// the way the graph above scrubs its own gap.
@property(copy) void (^onScrub)(double fraction);
@property(copy) void (^onScrubEnd)(void);
// Live retime of one keypose. The view proposes the time its pointer position
// falls on between that keypose's neighbours; the editor answers with the
// label for the time it would really write, or nil to refuse the position and
// leave the preview where it was.
@property(copy) NSString *(^onRetimeDrag)(NSInteger index, CMTime proposed);
@property(copy) void (^onRetimeCommit)(NSInteger index, CMTime proposed);
// The keypose under the pointer, or -1 over the rail, with the time that
// position falls on so a menu can act where the pointer is.
@property(copy) NSMenu *(^menuProvider)(NSInteger index, CMTime time);
// Keypose under a point in this view's coordinates, or -1 for none.
- (NSInteger)indexAtPoint:(NSPoint)point;
// Whether a keypose is drawn filled, meaning it is the pose being edited.
- (BOOL)isFilledIndex:(NSInteger)index;
@end