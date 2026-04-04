/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <KeyframelessKit/KKOnScreenControl.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKOnScreenControl (KKCoordinateSpace)

/// Convert an object-space point to canvas-space.
- (CGPoint)canvasPointFromObjectPoint:(simd_float2)objectPoint;

/// Convert a canvas-space point to object-space.
- (simd_float2)objectPointFromCanvasPoint:(CGPoint)canvasPoint;

/// The smaller canvas dimension (width or height).
- (float)canvasMinDimension;

/// Read a 2D point parameter and return its canvas-space position.
- (CGPoint)canvasPositionForParam:(UInt32)paramID atTime:(CMTime)time;

/// Read a 2D point parameter and return its object-space position.
- (simd_float2)objectPositionForParam:(UInt32)paramID atTime:(CMTime)time;

/// Read a float parameter value at the given time.
- (float)floatValueForParam:(UInt32)paramID atTime:(CMTime)time;

@end

NS_ASSUME_NONNULL_END
