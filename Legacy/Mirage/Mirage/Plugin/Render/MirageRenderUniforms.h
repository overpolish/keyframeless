/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The fixed KKGLSLUniforms block layout, shared by the FCP render
// (Plugin+Render.m) and the mini-viewer preview (MirageMiniViewerRenderer.m) so
// the CPU<->shader uniform CONTRACT lives in exactly one place and the two
// paths can't silently drift. Every field is identical between the paths except
// the two the callers pass in:
//   - `progress`   : main = MiragePluginState.common.progress; mini = playhead
//                    fraction (matches the frame the feed publishes). Both are
//                    the fraction AFTER the transition's Easing lane.
//   - `chan0Res`   : main = the source clip resolution {W,H,1,0}; mini = the
//                    256x256 preview convention. (If the mini's is ever found to
//                    be a bug, it changes at the ONE mini call site.)
// `iTime` / `grain` / `grainSize` share the same formula but different inputs,
// so each caller computes them and passes them in.

#pragma once

#import "KKGLSLTranspiler.h" // KKGLSLUniforms
#import <simd/simd.h>

static inline KKGLSLUniforms MirageMakeUniforms(float W, float H, float iTime, float grain, float grainSize,
                                                float progress, float encodeSRGB, simd_float4 chan0Res) {
    KKGLSLUniforms u;
    u.resTime = (simd_float4){W, H, 1.0f, iTime};
    u.mouse = (simd_float4){0, 0, 0, 0};
    u.date = (simd_float4){0, 0, 0, 0};
    u.extra = (simd_float4){1.0f / 60.0f, iTime * 60.0f, 0.0f, encodeSRGB};
    u.grain = (simd_float4){grain, grainSize, 0.0f, 0.0f};
    u.chanRes[0] = chan0Res;
    for (int c = 1; c < 4; c++)
        u.chanRes[c] = (simd_float4){256.0f, 256.0f, 1.0f, 0.0f};
    u.transition = (simd_float4){progress, 0.0f, 0.0f, 0.0f};
    return u;
}
