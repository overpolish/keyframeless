/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <simd/simd.h>

// Shared by the FCP render (Plugin+Render.m), the mini-viewer renderer
// (MirageMiniViewerRenderer.m), and the Metal shader (Mirage.metal).

// Max colour spots (legacy built-in gradient array width).
#define KK_SHADER_GRAD_COLORS 10

// Absolute ceiling for a single `// #color` array property's swatch count
// (slider/field cap + swatch visibility in the catalog).
#define KK_SHADER_MAX_COLORS 32

// Total vec4 slots shared by EVERY directive-driven value: `// #color` (1 each,
// or N+1 for an array), scalars (1 each), `#audio` (N band vec4s + flow) and
// `#gradient` (stops + midpoints + count). The std140 tail appended to the
// transpiled shader's uniform block.
//
// Self-imposed, not a hardware limit - a Metal constant buffer is 64KB and this
// is 1.5KB. What it actually costs is `MiragePluginState`, which motion blur
// allocates ONE OF PER SUB-FRAME SAMPLE, plus a stack copy in the mini viewer.
// The state blob memcpys that struct, so this size is baked into its byte
// layout - safe to change because the blob is FxPlug's per-render handoff
// (produced in -pluginState:atTime:, consumed by the render on the same tick),
// not project data. The persisted timeline is a separate parameter.
//
// Raised 48 -> 96 for headroom: audio and gradients are the greedy ones (two
// `#audio` spectra at [16] would be 34 slots on their own), and Frame already
// uses 26. Overflow is at least honest - the parsers stop and validation
// reports it rather than dropping controls silently.
#define KK_SHADER_COLOR_POOL 96

// Shared params common to every Type, passed in their own fragment buffer
// (MirageFragmentIndex_Common) so the per-Type uniform structs don't each
// re-declare them. Filled once per render. `grain` is the core film-grain
// overlay (also anti-banding); `grainScale` is the per-Type multiplier so e.g.
// Grainy reads stylistically grainy by default while others stay subtle.
typedef struct MirageCommonUniforms {
    // Shared transforms + timing (identical for every Type, read once per render).
    vector_float2 origin; // field centre (normalized; 0.5,0.5 = centre)
    vector_float2 scale;  // common zoom factor per axis (1 = 100%)
    float rotation;       // common rotation, radians
    float time;           // clip seconds
    float speed;          // time multiplier (motion rate)
    float seed;           // start-time offset (shared)
    // 0..1 across the effect's own window, before Speed/Seed. In a Motion
    // transition template that window IS the transition, so this is the
    // GL-Transitions `progress`. Exposed to shaders as iProgress.
    float progress;
    // Core film grain.
    float grain;              // 0..1 core film-grain amount (nonzero default = anti-band)
    float grainSize;          // grain cell size in reference pixels (higher = coarser)
    float grainScale;         // per-Type multiplier applied to `grain` (set at build)
    vector_float2 resolution; // destination pixel dims (for reference-res grain + supersample)
} MirageCommonUniforms;

// The full render state packed into pluginState. The plugin is Custom-only
// (runtime-compiled GLSL), so this now carries just the shared params; the user
// shader source rides in the blob tail after this struct.
typedef struct MiragePluginState {
    MirageCommonUniforms common;
    // The transpiled shader's colour-block tail: one vec4 per single `// #color`
    // property, N + 1 (swatches + count meta) per array property, in directive
    // order. Evaluated from the timeline at build time; appended after the fixed
    // uniforms at bind time. `colorPoolCount` is the number of vec4s used.
    vector_float4 colorPool[KK_SHADER_COLOR_POOL];
    int colorPoolCount;
    int _colorPad;
} MiragePluginState;

typedef enum MirageFragmentIndex {
    MirageFragmentIndex_Grid = 0,
    // 1 => gamma-encode the output (8-bit unorm target, e.g. the mini-viewer or
    // an SDR 8-bit FCP buffer); 0 => leave it linear (FCP float working buffers
    // are linear-light, so an sRGB-encoded value there reads as washed out).
    MirageFragmentIndex_EncodeSRGB = 1,
    // Shared params (MirageCommonUniforms) - grain + time, common to all Types.
    MirageFragmentIndex_Common = 2
} MirageFragmentIndex;
