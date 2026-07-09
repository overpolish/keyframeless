/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <simd/simd.h>

// Shared by the FCP render (Plugin+Render.m), the mini-viewer renderer
// (MeshMiniViewerRenderer.m), and the Metal shader (Mesh.metal). The mesh
// gradient is a freeform set of `count` colour points, each with a position
// (normalized 0..1) and a colour; the shader blends them by distance. Colours
// are carried in OKLab so the blend is perceptual, converted to sRGB at the end.
#define KK_MESH_MAX_VERTS 25

typedef struct MeshGridUniforms {
    int count;                                    // number of colour points
    int _pad0;                                    // keep points[] 8-byte aligned
    vector_float2 points[KK_MESH_MAX_VERTS];      // normalized 0..1
    vector_float4 colorsOklab[KK_MESH_MAX_VERTS]; // (L, a, b, alpha)
    float spreads[KK_MESH_MAX_VERTS];             // Gaussian falloff size (0..1)
    float grain;                                  // final grain-overlay amount 0..1
} MeshGridUniforms;

typedef enum MeshFragmentIndex {
    MeshFragmentIndex_Grid = 0,
    // 1 => gamma-encode the output (8-bit unorm target, e.g. the mini-viewer or
    // an SDR 8-bit FCP buffer); 0 => leave it linear (FCP float working buffers
    // are linear-light, so an sRGB-encoded value there reads as washed out).
    MeshFragmentIndex_EncodeSRGB = 1
} MeshFragmentIndex;
