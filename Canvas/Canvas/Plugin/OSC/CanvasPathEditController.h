/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "CanvasPenController.h" // CanvasPenSurface + CanvasPenModifiers
#import <Foundation/Foundation.h>

@class KKBezierPath;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CanvasPathEditHit) {
  CanvasPathEditHitNone = 0,
  CanvasPathEditHitAnchor,
  CanvasPathEditHitHandle,
};

/// Surface-agnostic editing of the SELECTED path's anchors + tangent handles
/// (drag to reshape), shared by the viewer OSC and the mini. Reuses the same
/// CanvasPenSurface the pen controller does (coordinate conversion, blob I/O),
/// plus the projection helpers to map under any layer transform. Coords are
/// SURFACE points.
@interface CanvasPathEditController : NSObject
- (instancetype)initWithSurface:(id<CanvasPenSurface>)surface;
@property(nonatomic, readonly) BOOL dragging;
/// Indices of the currently-selected anchors (drawn in the host accent).
@property(nonatomic, readonly) NSIndexSet *selectedAnchors;
/// Drop the anchor selection (e.g. when switching to the pen tool, where a
/// multi-point selection is meaningless and the lingering accent is confusing).
- (void)clearSelection;
/// Apply a selection received from the OTHER surface (cross-process sync). Sets
/// the indices WITHOUT re-publishing, so it can't feed back into a loop.
- (void)setSelectedAnchorIndexes:(NSIndexSet *)indexes;
/// YES while a marquee rubber-band is being dragged.
@property(nonatomic, readonly) BOOL marqueeActive;
/// The marquee rectangle in SURFACE points (valid while marqueeActive).
@property(nonatomic, readonly) CGRect marqueeSurfaceRect;
/// Cmd-snap alignment guides (live only during an anchor drag): YES when the
/// grabbed anchor is aligned to another anchor on that axis, with the guide's
/// object-space (Y-up [0,1]) coordinate. The draw code paints an accent line at
/// `snapGuideObjX` (vertical) / `snapGuideObjY` (horizontal) when set.
@property(nonatomic, readonly) BOOL snapGuideShowX;
@property(nonatomic, readonly) BOOL snapGuideShowY;
@property(nonatomic, readonly) double snapGuideObjX;
@property(nonatomic, readonly) double snapGuideObjY;
/// Whether the corner-radius widgets are active (drawn + grabbable). Mirrors the
/// "Corners" OSC element's visibility; the surface sets it each draw so a hidden
/// widget can't be grabbed. Default YES.
@property(nonatomic) BOOL cornerWidgetsActive;
/// What's under a surface point (for the cursor + deciding whether to claim).
- (CanvasPathEditHit)hitTestAtX:(double)x y:(double)y;
/// YES if a marquee could start here: cursor over the editable selected path's
/// empty area (no anchor/handle under it). Lets the surface claim an empty drag
/// for rubber-band selection instead of layer-pick / pan.
- (BOOL)canMarqueeAtX:(double)x y:(double)y;
/// YES if the point is over the selected path's curve (a segment between
/// anchors), clear of any anchor / handle. Used to show the pen's "add point"
/// cursor.
- (BOOL)segmentHitAtX:(double)x y:(double)y;
/// YES if a live-corner radius widget is under the point (for the hover cursor).
- (BOOL)cornerWidgetHitAtX:(double)x y:(double)y;
/// Pen tool: if the point is over a segment, insert an anchor there preserving
/// the curve (de Casteljau split) and begin dragging the new anchor
/// (press-insert-drag; mouseUp commits one undo). Returns YES if it consumed
/// the press; the surface then routes the ongoing drag / up to this controller
/// (like a normal edit).
- (BOOL)penInsertAtX:(double)x y:(double)y;
/// Remove the anchor under the point (an anchor hit only, not a handle), with
/// the auto-delete cascade. One undo. YES if an anchor was removed.
- (BOOL)removeAnchorAtX:(double)x y:(double)y;
/// Remove the given anchor indices (e.g. the current selection on Delete), with
/// the auto-delete cascade: a keypose that drops below 2 points is removed, and
/// a path left with no viable geometry deletes its layer. One undo. YES if
/// removed. Smart (pen-style) delete: neighbours reconnect, the closed flag is
/// preserved.
- (BOOL)removeAnchorsAtIndexes:(NSIndexSet *)indexes;
/// As above but `breakPath` selects the DESTRUCTIVE (cursor / Direct-Selection)
/// delete: removing an anchor from a closed path OPENS it at that gap (matches
/// Illustrator), rather than reconnecting the neighbours.
- (BOOL)removeAnchorsAtIndexes:(NSIndexSet *)indexes breakPath:(BOOL)breakPath;
/// Toggle the anchor under the point between corner (no handles) and smooth
/// (auto-generated tangents from its neighbours). One undo. YES if an anchor
/// was toggled. Used by the surfaces' double-click (the mini's native one; the
/// viewer detects the double-click by timing inside -mouseDownAtX:).
- (BOOL)toggleSmoothAtX:(double)x y:(double)y;
/// Grab the anchor / handle under the point, or begin a marquee on empty. YES
/// if the controller consumed the press.
- (BOOL)mouseDownAtX:(double)x y:(double)y modifiers:(CanvasPenModifiers)mods;
- (void)mouseDraggedAtX:(double)x
                      y:(double)y
              modifiers:(CanvasPenModifiers)mods;
- (void)mouseUp;
@end

NS_ASSUME_NONNULL_END
