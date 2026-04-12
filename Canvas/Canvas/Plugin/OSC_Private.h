/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import "OSC.h"
#import <CoreGraphics/CGEventSource.h>
#import <FxPlug/FxPlugSDK.h>

NSCursor *cursorFromBundle(NSString *name, NSPoint hotSpot);
NSUInteger selKey(NSUInteger pathIdx, NSUInteger ptIdx);

@interface CanvasOSC (Private)

- (CGPoint)canvasPointForBezierPoint:(KKBezierPoint)pt;
- (CGPoint)canvasPointForBezierPoint:(KKBezierPoint)pt
                      inHandleOffset:(BOOL)useIn;
- (BOOL)isPointSelected:(NSUInteger)pathIdx point:(NSUInteger)ptIdx;
- (double)strokeHitRadius;
- (NSInteger)pathIndexNearX:(double)x y:(double)y radius:(double)radius;
- (NSInteger)segmentIndexNearX:(double)x
                             y:(double)y
                        radius:(double)radius
                        inPath:(KKBezierPath *)path;

@end
