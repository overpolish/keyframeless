/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <simd/simd.h>

/// The crop lane model is `[w, h, x, y]`: `w`/`h` are the crop size as a
/// fraction of the image; `x`/`y` are the crop centre offset from the image
/// centre as a fraction of the image, with **+y up**.
///
/// Converts that to the shader's `cropCenter` / `cropSize` (pixels, in
/// Y-down screen space where `boxCenter = imageCenter + cropCenter`), for an
/// `imageSize` in pixels. Single source of truth shared by every render
/// path (the per-frame effect render and the mini-viewer preview) so a crop
/// looks identical everywhere.
static inline void KKCropModelToShader(double w, double h, double x, double y, simd_float2 imageSize,
                                       simd_float2 *outCenter, simd_float2 *outSize) {
    *outSize = (simd_float2){(float)w * imageSize.x, (float)h * imageSize.y};
    // Model +y is up; shader space is Y-down → negate y.
    *outCenter = (simd_float2){(float)x * imageSize.x, -(float)y * imageSize.y};
}
