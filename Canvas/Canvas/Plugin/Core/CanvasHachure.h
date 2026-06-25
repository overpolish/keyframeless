/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKShaderTypes.h> // KKVertex2D
#import <simd/simd.h>

@class KKBezierPath;

/// One hachure fill line segment in CENTERED-PIXEL object space ((norm - 0.5) *
/// (w, h)) - the same space the fill fan + model matrix use.
typedef struct {
  simd_float2 a;
  simd_float2 b;
} CanvasHachureLine;

/// Generate the hachure fill lines for a path (scanline-clipped to the shape,
/// so the segments already lie inside it). `fillStyle` 1 = hachure, 2 =
/// cross-hatch (a second perpendicular set), 3 = zigzag (each line replaced by
/// a zig wave), 4 = dots (the caller places dots along the returned hachure
/// lines). `gap` is the scanline spacing (px), `angle` the hachure angle
/// (radians). Returns the line count and mallocs `*outLines` (CANVAS-side
/// cached + copied; the caller frees the copy). Returns 0 (and NULL) when the
/// path is too small / gap < 1.
NSUInteger CanvasGenerateHachureLines(KKBezierPath *path, float outputWidth,
                                      float outputHeight, uint8_t fillStyle,
                                      float gap, float angle,
                                      CanvasHachureLine **outLines);

/// Build a triangle LIST for the hachure lines: each line -> a `weight`-wide
/// quad (hachure / cross-hatch / zigzag), or - for dots (style 4) - small
/// squares spaced `gap` along each line. Centered-pixel space; each vert bakes
/// its object-space position into textureCoordinate so a gradient-mode fill
/// samples per-pixel. Returns the vertex count; mallocs `*outVerts` (caller
/// frees).
NSUInteger CanvasHachureTriangles(const CanvasHachureLine *lines,
                                  NSUInteger lineCount, uint8_t style, float gap,
                                  float weight, KKVertex2D **outVerts);
