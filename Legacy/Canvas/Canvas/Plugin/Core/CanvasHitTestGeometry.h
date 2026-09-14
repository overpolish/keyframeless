/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// Leaf math for the alpha-aware image hit-test, split out of
// CanvasLayerHitTest.m: the inverse-bilinear quad solve (screen point -> image
// UV) and the CPU alpha-mask sampler. Internal, not a public API.

#import <Foundation/Foundation.h>
#import <simd/simd.h>

/// Inverse bilinear: where is `p` inside the quad whose corners map to UV
/// a=(0,0) b=(1,0) c=(1,1) d=(0,1)? Writes the UV to `outUV` and returns YES,
/// or NO when `p` is outside (u or v beyond [0,1]). Standard Inigo-Quilez
/// solution; handles the parallelogram degenerate case linearly. Under
/// perspective this is the bilinear approximation of the projective UV -
/// precise enough for alpha hit-testing.
BOOL CanvasInvBilinear(simd_float2 p, simd_float2 a, simd_float2 b,
                       simd_float2 c, simd_float2 d, simd_float2 *outUV);

/// CPU alpha at image UV (u in [0,1] left->right, v in [0,1] top->bottom,
/// matching the render's UVs) for the image at `imagePath`. Decodes to a capped
/// upright 8-bit alpha buffer cached per path. Returns 1.0 (opaque) when the
/// image has no decodable alpha, so opaque formats (JPEG) hit across their
/// whole quad.
float CanvasSampleImageAlpha(NSString *imagePath, float u, float v);
