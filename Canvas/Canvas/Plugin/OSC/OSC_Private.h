/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "OSC.h"
#import "ObjectParams.h"
#import <CoreGraphics/CGEventSource.h>
#import <FxPlug/FxPlugSDK.h>

NS_ASSUME_NONNULL_BEGIN

NSCursor *cursorFromBundle(NSString *name, NSPoint hotSpot);
NSUInteger selKey(NSUInteger pathIdx, NSUInteger ptIdx);
NSIndexSet *KKDescendantIndices(NSUInteger groupIdx,
                                NSArray<KKBezierPath *> *paths);

@interface CanvasOSC (Snap)

- (float)snapThresholdForCanvasPixels:(float)pixels;
- (simd_float2)snapToGridPosition:(simd_float2)objPos;
- (simd_float2)alignSnapDelta:(simd_float2)delta
             forSelectedPaths:(NSIndexSet *)selected;
- (simd_float2)alignSnapPoint:(simd_float2)point
               excludingPaths:(nullable NSIndexSet *)excluded
              excludingPoints:(nullable NSIndexSet *)excludedPoints;
- (void)resetAlignSnap;

@end

@interface CanvasOSC (Drag)

@end

@interface CanvasOSC (Private)

- (CGPoint)canvasPointForBezierPoint:(KKBezierPoint)pt;
- (CGPoint)canvasPointForBezierPoint:(KKBezierPoint)pt
                      inHandleOffset:(BOOL)useIn;
- (BOOL)isPointSelected:(NSUInteger)pathIdx point:(NSUInteger)ptIdx;
- (double)strokeWidth;
- (double)strokeHitRadius;

@end

@interface CanvasOSC (Geometry)

- (NSInteger)pathIndexNearX:(double)x y:(double)y radius:(double)radius;
- (NSInteger)segmentIndexNearX:(double)x
                             y:(double)y
                        radius:(double)radius
                        inPath:(KKBezierPath *)path;
- (void)boundsOfPath:(KKBezierPath *)path
                 min:(simd_float2 *)outMin
                 max:(simd_float2 *)outMax;
- (BOOL)boundsOfSelectedPaths:(simd_float2 *)outMin max:(simd_float2 *)outMax;
/// Object-space union of a group's descendants' bbox (recurses into
/// sub-groups). Returns NO when the group has no renderable descendants.
- (BOOL)boundsOfGroup:(KKBezierPath *)group
                  min:(simd_float2 *)outMin
                  max:(simd_float2 *)outMax;
/// Object-space center of a path's axis-aligned bbox. For groups,
/// uses `boundsOfGroup:`.
- (simd_float2)bboxCenterOfPath:(KKBezierPath *)path;
/// The single currently-selected layer eligible for transform editing
/// (selection count == 1, not locked, transform enabled). Groups are
/// allowed; their bbox is derived from descendants.
- (nullable KKBezierPath *)selectedTransformablePath;
- (CGPoint)cornerRadiusHandlePosition:(NSInteger)corner
                              forPath:(KKBezierPath *)path;
- (CGPoint)resizeHandlePosition:(NSInteger)index
                       topRight:(CGPoint)tr
                     bottomLeft:(CGPoint)bl;

@end

@interface CanvasOSC (Transform)

- (void)dragCornerRadiusAtX:(double)positionX
                          y:(double)positionY
                  modifiers:(NSUInteger)modifiers
                forceUpdate:(BOOL *)forceUpdate;
- (void)dragResizeAtX:(double)positionX
                    y:(double)positionY
            modifiers:(NSUInteger)modifiers
          forceUpdate:(BOOL *)forceUpdate;
- (void)dragRotateAtX:(double)positionX
                    y:(double)positionY
            modifiers:(NSUInteger)modifiers
          forceUpdate:(BOOL *)forceUpdate;

@end

@interface CanvasOSC (ShapeCreation)

- (void)finalizeMarqueeAtX:(double)positionX
                         y:(double)positionY
                 modifiers:(NSUInteger)modifiers;
- (void)finalizeRect;
- (void)finalizeEllipse;
- (void)finalizeLine;
- (void)resetDragState;

@end

@interface CanvasOSC (DrawPaths)

- (void)drawFilledPath:(KKBezierPath *)path
                 color:(simd_float4)color
      destinationImage:(FxImageTile *)dest;
- (void)drawPathSegmentsWithWidth:(KKBezierPath *)path
                            color:(simd_float4)color
                        halfWidth:(float)halfWidth
                 destinationImage:(FxImageTile *)dest;
- (void)drawPathSegments:(KKBezierPath *)path
                   color:(simd_float4)color
        destinationImage:(FxImageTile *)dest;
- (BOOL)isPointVisuallySelected:(NSUInteger)pathIndex
                          point:(NSUInteger)i
                    canvasPoint:(CGPoint)ptCanvas;

@end

@interface CanvasOSC (DrawHandles)

- (void)drawPathControls:(KKBezierPath *)path
               pathIndex:(NSUInteger)pathIndex
              activePart:(NSInteger)activePart
                   color:(simd_float4)color
        destinationImage:(FxImageTile *)dest
                  atTime:(CMTime)atTime;
- (void)drawBoundingBoxWithMin:(simd_float2)bmin
                           max:(simd_float2)bmax
                    activePart:(NSInteger)activePart
              destinationImage:(FxImageTile *)dest
                        atTime:(CMTime)atTime;
- (void)drawCornerRadiusHandles:(KKBezierPath *)path
                     activePart:(NSInteger)activePart
               destinationImage:(FxImageTile *)dest
                         atTime:(CMTime)atTime;
- (void)drawRotatedBoundingBoxWithDestinationImage:(FxImageTile *)dest
                                            atTime:(CMTime)atTime;
- (void)drawRectPreview:(simd_float4)color destinationImage:(FxImageTile *)dest;
- (void)drawEllipsePreview:(simd_float4)color
          destinationImage:(FxImageTile *)dest;
- (void)drawDashedRectFrom:(CGPoint)a
                        to:(CGPoint)b
          destinationImage:(FxImageTile *)dest;

@end

@interface CanvasOSC (PenTool)

- (void)setHandle:(simd_float2)offset
          atIndex:(NSInteger)idx
             isIn:(BOOL)isIn
    breakSymmetry:(BOOL)breakSymmetry
           onPath:(KKBezierPath *)path;
- (void)penClosePath:(KKBezierPath *)active forceUpdate:(BOOL *)forceUpdate;
- (void)penDeletePoint:(NSInteger)activePart
                active:(KKBezierPath *)active
           forceUpdate:(BOOL *)forceUpdate;
- (void)penClickPoint:(NSInteger)activePart
               active:(KKBezierPath *)active
          forceUpdate:(BOOL *)forceUpdate;
- (void)penClickHandle:(NSInteger)activePart forceUpdate:(BOOL *)forceUpdate;
- (void)penInsertOnSegment:(NSInteger)activePart
                 positionX:(double)positionX
                 positionY:(double)positionY
                    active:(KKBezierPath *)active
               forceUpdate:(BOOL *)forceUpdate;
- (void)penAddPointX:(double)positionX
                   y:(double)positionY
              active:(KKBezierPath *)active
         forceUpdate:(BOOL *)forceUpdate;
- (void)selectActivePath;
- (void)toggleBezierAtIndex:(NSInteger)ptIdx onPath:(KKBezierPath *)path;
- (void)restoreImageAspectRatio:(KKBezierPath *)path;
- (void)handleCursorMouseDownX:(double)positionX
                             y:(double)positionY
                     modifiers:(NSUInteger)modifiers
                   forceUpdate:(BOOL *)forceUpdate;
- (void)mouseDownOnCornerRadius:(NSInteger)cornerIdx
                      positionX:(double)positionX
                      positionY:(double)positionY
                         active:(KKBezierPath *)active
                    forceUpdate:(BOOL *)forceUpdate;
- (void)mouseDownOnResizeHandle:(NSInteger)handleIndex
                         active:(KKBezierPath *)active
                    forceUpdate:(BOOL *)forceUpdate;
- (void)mouseDownOnRotateHandle:(double)positionX
                              y:(double)positionY
                    forceUpdate:(BOOL *)forceUpdate;

@end

@interface CanvasOSC (DrawGuides)

- (void)drawGridWithDestinationImage:(FxImageTile *)destinationImage;
- (void)drawGridSnapIndicatorForCursorMode:(BOOL)isCursorMode
                          destinationImage:(FxImageTile *)destinationImage;
- (void)drawAlignmentGuidesWithDestinationImage:(FxImageTile *)destinationImage;
- (void)drawSpacingGuidesWithDestinationImage:(FxImageTile *)destinationImage;

@end

@interface CanvasOSC (DrawPreview)

- (BOOL)shouldShowBooleanPreview:(BOOL)isCursorMode;
- (void)drawBooleanPreviewWithDestinationImage:(FxImageTile *)destinationImage;

@end

@interface CanvasOSC (Input)

@end

@interface CanvasOSC (PositionPath)

/// Generic: lane named `label` scoped to the currently-selected
/// transformable layer's group. Future per-layer transform properties
/// (rotation, scale) reuse this — only the label changes.
- (nullable KKTimingLane *)laneForSelectedLayerProperty:(NSString *)label;
/// The Position lane scoped to the currently-selected single layer, or nil.
- (nullable KKTimingLane *)positionLaneForSelectedLayer;

/// Whether the position-path overlay is currently visible (Show OSC eye on
/// for the selected layer's Position lane).
- (BOOL)isPositionPathVisibleAtTime:(CMTime)time;

- (void)drawPositionPathsAtTime:(CMTime)time
               destinationImage:(FxImageTile *)dest;

/// Hit-test against any path point/handle/curve. Returns 0 (no hit) or one
/// of the kkOSCPositionPath* parts. Updates cursor when a hit is found.
- (NSInteger)hitTestPositionPathAtX:(double)x y:(double)y atTime:(CMTime)time;

/// Returns YES if it consumed the event.
- (BOOL)mouseDownOnPositionPathPart:(NSInteger)part
                          positionX:(double)positionX
                          positionY:(double)positionY
                          modifiers:(NSUInteger)modifiers
                        forceUpdate:(BOOL *)forceUpdate
                             atTime:(CMTime)time;
- (BOOL)mouseDraggedOnPositionPathAtX:(double)positionX
                                    y:(double)positionY
                            modifiers:(NSUInteger)modifiers
                               atTime:(CMTime)time;

@end

@interface CanvasOSC (TransformOSC)

/// YES when the per-layer transform position OSC arc should be visible.
/// Requires: a single non-image, non-group, non-locked, transform-enabled
/// layer is selected, that layer's `transformOSCVisible` is YES, and the
/// global Hide OSC toggle is OFF.
- (BOOL)isTransformPositionOSCVisibleAtTime:(CMTime)time;

/// Canvas-space position of the transform OSC arc (the layer's bbox center
/// offset by its translateX/Y).
- (CGPoint)transformPositionCanvasPointAtTime:(CMTime)time;

/// Canvas-space position of the layer's anchor (the pivot for scale/rotate),
/// resolved through the active path's parent group transforms.
- (CGPoint)transformAnchorCanvasPointAtTime:(CMTime)time;

/// Per-axis pixel-space radii of the scale ring at the current scale —
/// `canvas-min-dimension × 0.1 × scale` per axis, floored at 0.05 so the
/// ring stays grabbable when scale collapses to zero.
- (void)getScaleRingRadiiAtTime:(CMTime)time
                             rx:(CGFloat *)outRx
                             ry:(CGFloat *)outRy;

/// YES when the scale ring OSC should be visible — gated by the same layer
/// preconditions as Position plus either the "Scale X" or "Scale Y"
/// per-lane OSC toggle.
- (BOOL)isScaleRingOSCVisibleAtTime:(CMTime)time;

/// YES when the anchor square OSC should be visible — gated by the layer
/// preconditions plus the "Anchor" per-lane OSC toggle.
- (BOOL)isAnchorOSCVisibleAtTime:(CMTime)time;

/// YES when the Rotation Z OSC should be visible — gated by the layer
/// preconditions plus the "Rot Z" per-lane OSC toggle.
- (BOOL)isRotZOSCVisibleAtTime:(CMTime)time;

/// YES when Rot X / Rot Y rings' per-lane OSC toggle is on. The MM-style
/// `optHeld || hovering || dragging` overrides are layered on top by the
/// caller so the rings can still be grabbed even when the toggle is off.
- (BOOL)isRotXRingOSCVisibleAtTime:(CMTime)time;
- (BOOL)isRotYRingOSCVisibleAtTime:(CMTime)time;

- (void)drawTransformOSCWithDestinationImage:(FxImageTile *)dest
                                      atTime:(CMTime)time;

@end

NS_ASSUME_NONNULL_END
