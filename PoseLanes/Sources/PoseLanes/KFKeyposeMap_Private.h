/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import "KFKeyposeMap.h"

// Shared by the map's drawing and its interaction category. Geometry stays
// with the drawing that defines it, so the interaction source asks for
// positions and times rather than restating the layout.

@interface KFKeyposeMap ()
@property(nonatomic) NSInteger hoveredIndex;
@property(nonatomic, strong) NSTrackingArea *tracking;
// The keypose being dragged, the accepted pointer position it is previewed at
// and the timecode the editor accepted for it. -1 when no drag is live.
@property(nonatomic) NSInteger dragIndex;
@property(nonatomic) CGFloat dragPosition;
@property(nonatomic, copy) NSString *dragLabel;
// The keypose a press landed on, which becomes a drag once the pointer moves.
@property(nonatomic) NSInteger pressedIndex;
@property(nonatomic) CGFloat pressedPosition;
@property(nonatomic) BOOL scrubbing;

- (void)hoverAtPoint:(NSPoint)point;
- (void)endDrag;
// Ordinal fraction across the whole map, clamped to it.
- (double)fractionAtX:(CGFloat)x;
// Whether a point can start a playhead drag: the rail, not the label band.
- (BOOL)isScrubPoint:(NSPoint)point;
// A drag is confined to the corridor between the keypose's neighbours, so it
// can never cross one. End keyposes have a corridor on one side only.
- (CGFloat)draggablePosition:(CGFloat)x forIndex:(NSInteger)index;
// The time a dragged keypose's position falls on. The map is ordinal, so each
// half of the corridor carries its own neighbouring gap's real duration.
- (CMTime)timeAtPosition:(CGFloat)x forIndex:(NSInteger)index;
// The time a rail position falls on, taken from the gap it lands in. Invalid
// until the lane has two keyposes for the axis to span.
- (CMTime)timeAtPosition:(CGFloat)x;
@end
