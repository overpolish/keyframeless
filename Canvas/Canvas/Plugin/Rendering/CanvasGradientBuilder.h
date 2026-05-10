/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "ShaderTypes.h"
#import <Foundation/Foundation.h>
#import <KeyframelessKit/KeyframelessKit.h>

/// Fills the gradient-sample fields of `out` (lut, useGradient, gradientType,
/// gradientAngle) from `path`'s stroke or fill gradient. Returns YES when
/// gradient mode is active; NO when caller should treat the result as solid.
/// Does not touch `solidColor`, `opacity`, `bboxMin`, or `bboxMax` — those
/// are set by the caller because their coordinate space varies (centered
/// framebuffer, padded JFA texture, raw image, etc.).
BOOL KKBuildCanvasGradientSamples(KKBezierPath *path, BOOL isStroke, CanvasGradientParams *out);

/// Path bbox in centered framebuffer-Y pixel space (matches the canvas
/// vertex shader's coordinates). `pad` expands the box on every side — pass
/// half the stroke width for stroke-aware bboxes, 0 for fill.
void KKCanvasPathBBoxCenteredPx(KKBezierPath *path, float outputWidth, float outputHeight, float pad,
                                simd_float2 *bbMin, simd_float2 *bbMax);
