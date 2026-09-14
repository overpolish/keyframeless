/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The cubic Bezier basis, shared by the geometry evaluators (KKBezierPath +
// KKPathMorph) so the one formula lives in one place. Point-based form:
// p0/p1 are the anchors, c0/c1 the control points. `t` in 0..1.
// (KKSpatialCurve keeps its own double-precision component-wise version - a
// different type, deliberately not unified here.)

#pragma once

#import <simd/simd.h>

static inline simd_float2 KKEvalCubic(simd_float2 p0, simd_float2 c0, simd_float2 c1, simd_float2 p1, float t) {
    float u = 1.0f - t;
    return u * u * u * p0 + 3.0f * u * u * t * c0 + 3.0f * u * t * t * c1 + t * t * t * p1;
}
