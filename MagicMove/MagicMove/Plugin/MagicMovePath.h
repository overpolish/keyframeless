/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Foundation/Foundation.h>
#import <simd/simd.h>

typedef enum : uint32_t {
  MagicMovePathPointLinear = 0,
  MagicMovePathPointBezier = 1,
} MagicMovePathPointType;

typedef struct {
  float x, y;
  float inX, inY;
  float outX, outY;
  uint32_t type;
} MagicMovePathPoint;

NS_ASSUME_NONNULL_BEGIN

@interface MagicMovePath : NSObject

/// Number of intermediate control points (excludes start/end).
@property(nonatomic, readonly) NSUInteger count;

/// Number of path segments (count + 1).
@property(nonatomic, readonly) NSUInteger segmentCount;

+ (instancetype)pathWithData:(nullable NSData *)data;
- (NSData *)dataRepresentation;

- (MagicMovePathPoint)pointAtIndex:(NSUInteger)index;

- (void)insertAtIndex:(NSUInteger)index position:(simd_float2)pos;
- (void)removeAtIndex:(NSUInteger)index;
- (void)moveAtIndex:(NSUInteger)index to:(simd_float2)pos;
- (void)setInHandle:(simd_float2)offset atIndex:(NSUInteger)index;
- (void)setOutHandle:(simd_float2)offset atIndex:(NSUInteger)index;
- (void)toggleTypeAtIndex:(NSUInteger)index
                    start:(simd_float2)start
                      end:(simd_float2)end;

/// Evaluate a single path segment at local t (0-1).
- (simd_float2)evaluateSegment:(NSUInteger)segIndex
                           atT:(float)t
                         start:(simd_float2)start
                           end:(simd_float2)end;

/// Arc-length parameterized position along the full path at global t (0-1).
- (simd_float2)positionAtT:(float)t
                     start:(simd_float2)start
                       end:(simd_float2)end;

@end

NS_ASSUME_NONNULL_END
