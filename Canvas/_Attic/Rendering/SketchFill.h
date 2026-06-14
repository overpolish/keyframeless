/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KeyframelessKit.h>

/// A single hachure line segment in pixel space.
typedef struct {
  simd_float2 a;
  simd_float2 b;
} KKHachureLine;

/// Generate hachure fill lines for a path.
/// Returns an array of KKHachureLine (caller must free).
/// lineCount is set to the number of lines generated.
/// Coordinates are in pixel space (already scaled by outputWidth/Height).
///
/// fillStyle: 1=hachure, 2=cross-hatch, 3=zigzag, 4=dots
/// gap: spacing between scanlines in points
/// angle: hachure angle in degrees
/// roughness/seed: when roughness > 0, scanline spacing is randomised
NSUInteger KKGenerateHachureLines(KKBezierPath *path, float outputWidth,
                                  float outputHeight, uint8_t fillStyle,
                                  float gap, float angle, float roughness,
                                  uint32_t seed, KKHachureLine **outLines);
