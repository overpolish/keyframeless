/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "CanvasHachure.h" // CanvasHachureLine
#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Jittered (hand-drawn, rough.js-style) copy of a path for sketch rendering:
/// anchor positions + bezier handles are randomised, linear segments get a
/// perpendicular bow, and `strokes` >= 2 appends a half-jitter overlay pass as
/// a disjoint subpath so the line reads as double-drawn. `roughness`/`bowing`
/// are 0-3; `seed` fixes the randomness (stable across frames); `strokeWidth`
/// (px) + canvas dims scale the jitter so it tracks the stroke. Returns the
/// original path unchanged when roughness ~0 or the path is degenerate.
KKBezierPath *CanvasSketchPath(KKBezierPath *path, float roughness,
                               float bowing, uint32_t seed, uint8_t strokes,
                               float strokeWidth, float canvasWidth,
                               float canvasHeight);

/// Jitter hachure fill lines to look hand-drawn: each straight segment is
/// replaced by several small segments approximating a jittered bezier. Replaces
/// `*lines`/`*count` in place (frees the old buffer, mallocs the new one - the
/// caller frees it). No-op when roughness ~0.
void CanvasSketchifyHachureLines(CanvasHachureLine *_Nonnull *_Nonnull lines,
                                 NSUInteger *count, float roughness,
                                 float bowing, uint32_t seed, float canvasWidth,
                                 float canvasHeight);

NS_ASSUME_NONNULL_END
