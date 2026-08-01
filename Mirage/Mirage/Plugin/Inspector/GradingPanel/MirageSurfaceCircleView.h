/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

#import "MirageColorSurfaceProps.h"

NS_ASSUME_NONNULL_BEGIN

/// One draggable puck. A shader declaring `puck={"Shadows", "moon"}` on its
/// mappings gets one of these per name, all in the same circle, so a three-way
/// correction is three handles you can see at once rather than a mode control
/// that shows you one at a time.
@interface MirageSurfacePuck : NSObject
/// The `puck=` name, empty for a shader that declared none.
@property(nonatomic, copy) NSString *name;
/// Drawn inside the handle, when the `puck=` symbol named one this Mac has.
@property(nonatomic, strong, nullable) NSImage *icon;
/// Drawn inside the handle when there is no `icon`: the symbol slot's text
/// taken literally, at most two characters. An author who wants "S" or "3" on a
/// handle should not have to find an SF Symbol that happens to look like it,
/// and a mistyped symbol name reads as itself rather than vanishing.
///
/// Also where the defaults land - a slot instance's number, `G` for a shader's
/// single unnamed puck - so an undecorated wheel still tells its handles apart.
/// Nil draws a plain handle.
@property(nonatomic, copy, nullable) NSString *textGlyph;
/// Position in -1..1 per axis, derived from this puck's own controls.
@property(nonatomic) NSPoint position;
/// From `track=0.72`: the fraction of the radius this puck is pinned to, so it
/// can only be rotated. 0 leaves it free to move anywhere in the disc.
///
/// The track is drawn, because a constraint you can only discover by fighting
/// it is worse than no constraint: the circle it rides is visible before you
/// touch it.
@property(nonatomic) CGFloat trackRadius;
@end

/// The cursor in `view`'s own coordinates, taken from the CGEvent rather than
/// the NSEvent's window-relative location: inside a plugin's ViewBridge the
/// drag stream is addressed to other windows, so it arrives through monitors
/// where `locationInWindow` means nothing to the view being dragged in. Global
/// display space is unambiguous. Every surface's drag needs it, so there is one
/// copy.
FOUNDATION_EXPORT NSPoint MirageSurfaceCursorInView(NSEvent *event,
                                                    NSView *view);

/// The radius the handle is drawn at. A puck carrying a glyph - symbol or text
/// - is bigger, since the glyph needs room to read at all, and a surface has to
/// know that before it can reserve the travel its pucks fit in.
FOUNDATION_EXPORT CGFloat
MirageSurfacePuckRadius(MirageSurfacePuck *_Nullable puck);

/// Draw one handle, centred at `at` in the calling view's coordinates.
///
/// `pinned` is for a puck the values have pushed past full deflection, which
/// the circle asks of the disc. `backingScale` is the drawing window's, for the
/// icon's snap.
FOUNDATION_EXPORT void MirageDrawSurfacePuck(MirageSurfacePuck *puck,
                                             BOOL active, BOOL pinned,
                                             NSPoint at, CGFloat backingScale);

/// The Grading surface's circle: a puck you drag toward what the image needs,
/// with the ring acting as both legend and scope.
///
/// The puck has no state of its own. Its position is DERIVED from the shader's
/// real controls, so hand-editing Threshold in the inspector moves it, and it
/// can never disagree with the values it is showing.
@interface MirageSurfaceCircleView : NSView

/// What the ring paints, from `ring=` on the `#color-surface` line.
@property(nonatomic) MirageColorSurfaceRing ring;

/// Axis labels drawn at the compass points, each `@[negative, positive]`, or
/// nil for an unlabelled direction.
@property(nonatomic, copy, nullable) NSArray<NSString *> *xAxisLabels;
@property(nonatomic, copy, nullable) NSArray<NSString *> *yAxisLabels;

/// The pucks to draw, in the shader's own order. Setting this replaces them
/// all; during a drag the dragged one keeps following the cursor.
@property(nonatomic, copy) NSArray<MirageSurfacePuck *> *pucks;

/// Which puck a click in open space moves, and which one is drawn emphasised.
/// The last one touched, so the wheel keeps working like a single-puck wheel
/// once you have picked up the handle you care about.
@property(nonatomic) NSUInteger activePuck;

/// YES when the shader maps its controls to the puck's DISTANCE and BEARING
/// (`surface="r:"` / `"a:"`) rather than to x and y. The guides change with it:
/// a cartesian crosshair would be telling you to read the wrong two numbers off
/// a control that works in polar.
@property(nonatomic) BOOL polarAxes;

/// NO for an axis no control responds to. Drawn as a dead direction rather than
/// implying it can be dragged, since the maths cannot derive it either.
@property(nonatomic) BOOL xAxisLive;
@property(nonatomic) BOOL yAxisLive;

/// The frame's chroma as a polar density grid - drawn INSIDE the circle as a
/// vectorscope cloud, in the same space as the puck, so a cast reads as a
/// lopsided cloud to pull against. Only meaningful for `ring=hue`. Empty draws
/// nothing.
///
/// `regionBins` is the same grid binned from the part of the frame the preview
/// is actually showing. When it is non-nil the circle draws TWO layers - the
/// whole frame faint underneath, the visible region at full strength on top -
/// so a zoomed grade reads its own patch without losing the context it sits in.
/// Nil draws the single cloud, unchanged, which is what an unzoomed preview
/// gets.
- (void)applyChromaCloud:(NSArray<NSNumber *> *)bins
                  region:(nullable NSArray<NSNumber *> *)regionBins
               angleBins:(NSUInteger)angleBins
              radiusBins:(NSUInteger)radiusBins;

/// The frame's luminance distribution, dark bin first - drawn INSIDE the circle
/// as horizontal bands, dark at the bottom and bright at the top, so it lines
/// up with the light ring around it the way the chroma cloud lines up with the
/// hue ring. Only meaningful for `ring=light`. Empty draws nothing.
/// `regionBins` is the visible-region layer, exactly as above.
- (void)applyToneCloud:(NSArray<NSNumber *> *)bins
                region:(nullable NSArray<NSNumber *> *)regionBins;

/// Where the frame's near-neutral pixels sit, in -1..1: the cast, drawn as a
/// small cross. Pull the puck the OPPOSITE way to correct it.
@property(nonatomic) NSPoint chromaCast;

/// NO when the frame has too few neutrals to judge a cast. The marker is then
/// hidden rather than parked at the centre, which would read as "balanced".
@property(nonatomic) BOOL castAvailable;

/// Drag reporting. `onPuckMovedTo` carries the puck's ABSOLUTE position in
/// -1..1 axis units, so the host sets each mapped control to what that position
/// means rather than nudging it by an offset. Absolute is what keeps the two
/// directions exact inverses: an offset applied to the values a drag started
/// from lands somewhere the derive then reads back differently, and the puck
/// jumps on release. Every callback carries the puck's index, since only that
/// puck's controls move.
@property(nonatomic, copy, nullable) void (^onDragBegan)(NSUInteger puckIndex);
@property(nonatomic, copy, nullable) void (^onPuckMovedTo)
    (NSUInteger puckIndex, NSPoint position);
@property(nonatomic, copy, nullable) void (^onDragEnded)(NSUInteger puckIndex);

/// Drop an in-progress drag WITHOUT reporting an end, for a host that is
/// closing the write group itself.
///
/// A drag whose mouse-up went to another application leaves this view latched
/// to the cursor with its monitors still installed. With two circles in the
/// panel that is not merely stale: a drag begun on the OTHER ring feeds this
/// view's monitors too, so a puck nobody is holding would follow the pointer
/// and write its controls. The host ends the group and drops the latch in one
/// move.
- (void)cancelDrag;

/// Double-click a puck: return ITS mapped controls to their declared
/// `default=`, which is what a centred puck means. The others are left alone.
@property(nonatomic, copy, nullable) void (^onResetToCentre)
    (NSUInteger puckIndex);

@end

NS_ASSUME_NONNULL_END
