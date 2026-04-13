/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Foundation/Foundation.h>
#import <simd/simd.h>

typedef enum : uint32_t {
  KKBezierPointLinear = 0,
  KKBezierPointBezier = 1,
} KKBezierPointType;

typedef struct {
  float x, y;
  float inX, inY;
  float outX, outY;
  uint32_t type;
} KKBezierPoint;

NS_ASSUME_NONNULL_BEGIN

@interface KKBezierPath : NSObject

/// Number of points.
@property(nonatomic, readonly) NSUInteger count;

/// Number of path segments (count + 1 for MagicMove, count for closed paths).
@property(nonatomic, readonly) NSUInteger segmentCount;

/// Whether the path forms a closed loop (last point connects to first).
@property(nonatomic, assign) BOOL closed;

/// Whether the path was created as a rectangle (enables corner radius handles).
@property(nonatomic, assign) BOOL isRect;

/// Whether the path is hidden in the canvas.
@property(nonatomic, assign) BOOL hidden;

/// Per-corner radius fractions 0–1 (TL, TR, BR, BL). 0 = sharp, 1 = max.
@property(nonatomic, assign) float cornerRadiusTL;
@property(nonatomic, assign) float cornerRadiusTR;
@property(nonatomic, assign) float cornerRadiusBR;
@property(nonatomic, assign) float cornerRadiusBL;

+ (instancetype)pathWithData:(nullable NSData *)data;
- (NSData *)dataRepresentation;

+ (NSMutableArray<KKBezierPath *> *)pathsFromBlob:(nullable NSData *)blob;
+ (NSData *)blobFromPaths:(NSArray<KKBezierPath *> *)paths;

- (KKBezierPoint)pointAtIndex:(NSUInteger)index;

- (void)insertAtIndex:(NSUInteger)index position:(simd_float2)pos;
- (void)removeAtIndex:(NSUInteger)index;
- (void)moveAtIndex:(NSUInteger)index to:(simd_float2)pos;
- (void)setInHandle:(simd_float2)offset atIndex:(NSUInteger)index;
- (void)setOutHandle:(simd_float2)offset atIndex:(NSUInteger)index;
- (void)setType:(KKBezierPointType)type atIndex:(NSUInteger)index;
- (void)translateBy:(simd_float2)delta;

/// Rebuild this path as a rounded rectangle with per-corner fractions.
/// Each fraction 0–1: 0 = sharp, 1 = max radius for that corner.
- (void)setRoundedRectWithMin:(simd_float2)min
                          max:(simd_float2)max
                   fractionTL:(float)tl
                   fractionTR:(float)tr
                   fractionBR:(float)br
                   fractionBL:(float)bl
                  canvasWidth:(float)canvasW
                 canvasHeight:(float)canvasH;
- (void)toggleTypeAtIndex:(NSUInteger)index
                    start:(simd_float2)start
                      end:(simd_float2)end;

/// Evaluate a single path segment at local t (0-1).
/// start/end are the anchor points for MagicMove-style relative paths.
- (simd_float2)evaluateSegment:(NSUInteger)segIndex
                           atT:(float)t
                         start:(simd_float2)start
                           end:(simd_float2)end;

/// Evaluate the cubic bezier between point at index and index+1 at t (0-1).
/// Uses absolute coordinates (no start/end anchors).
- (simd_float2)evaluatePointAtIndex:(NSUInteger)index
                          nextIndex:(NSUInteger)nextIndex
                                atT:(float)t;

/// Evaluate the tangent between point at index and index+1 at t (0-1).
- (simd_float2)evaluateTangentAtIndex:(NSUInteger)index
                            nextIndex:(NSUInteger)nextIndex
                                  atT:(float)t;

/// Arc-length parameterized position along the full path at global t (0-1).
- (simd_float2)positionAtT:(float)t
                     start:(simd_float2)start
                       end:(simd_float2)end;

@end

NS_ASSUME_NONNULL_END
