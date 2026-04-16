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

@interface CanvasOSC (Input)

- (void)setHandle:(simd_float2)offset
          atIndex:(NSInteger)idx
             isIn:(BOOL)isIn
    breakSymmetry:(BOOL)breakSymmetry
           onPath:(KKBezierPath *)path;
- (void)penInsertOnSegment:(NSInteger)activePart
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
