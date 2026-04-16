/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import "ShaderTypes.h"
#import <Foundation/Foundation.h>
#import <simd/simd.h>

/// Maximum extra vertices a single marker can emit.
static const NSUInteger kMarkerMaxVertices = 128;

/// Returns the arc-length pullback distance for a marker type.
/// The stroke should be shortened by this amount at the marked endpoint.
float KKMarkerPullback(uint8_t markerType, float markerSize);

/// Tessellate a marker at a path endpoint.
/// markerType: 0=none, 1=arrow, 2=circle, 3=square.
/// endpoint: pixel-space position of the path endpoint (centered coordinates).
/// tangent: unit tangent pointing outward from the path at the endpoint.
/// normal: unit normal perpendicular to the tangent.
/// markerSize: size of the marker (typically strokeWidth * 3).
/// Returns the number of vertices written.
NSUInteger KKTessellateMarker(uint8_t markerType, simd_float2 endpoint,
                              simd_float2 tangent, simd_float2 normal,
                              float markerSize, float strokeWidth,
                              CanvasVertex *vertices);

/// Sketch-style marker with jittered edges. Same fan tessellation as the
/// clean marker but with subdivided, roughened outlines.
NSUInteger KKTessellateSketchMarker(uint8_t markerType, simd_float2 endpoint,
                                    simd_float2 tangent, simd_float2 normal,
                                    float markerSize, float strokeWidth,
                                    float roughness, uint32_t seed,
                                    CanvasVertex *vertices);
