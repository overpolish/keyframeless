/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import "OSC.h"
#import "ObjectParams.h"
#import <CoreGraphics/CGEventSource.h>
#import <FxPlug/FxPlugSDK.h>

NSCursor *cursorFromBundle(NSString *name, NSPoint hotSpot);
NSUInteger selKey(NSUInteger pathIdx, NSUInteger ptIdx);
NSIndexSet *KKDescendantIndices(NSUInteger groupIdx,
                                NSArray<KKBezierPath *> *paths);

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

@interface CanvasOSC (Input)

@end
