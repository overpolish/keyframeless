/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "KKGLSLTranspiler.h"
#import "Plugin_Private.h"
#import "MirageTypes.h"

// The seams of the (Render) category, split across:
//
//   Plugin+Render.m           scheduleInputs: + renderDestinationImage:
//   Plugin+RenderState.m      pluginState: + the lane -> MiragePluginState eval
//   Plugin+RenderPipeline.m   transpile -> MSL -> cached MTLRenderPipelineState
//   Plugin+RenderMultipass.m  the Buffer A-D + feedback render
//
// Runtime-compiled user shaders are the only render path. The user writes a GLSL
// Image shader (`void mainImage(out vec4, in vec2)`, bare iTime / iResolution /
// iChannelN); KKGLSLTranspiler wraps and transpiles it to MSL with glslang +
// SPIRV-Cross, so the real GLSL dialect (not a regex approximation) drives the
// result.

NS_ASSUME_NONNULL_BEGIN

@interface MiragePlugin (RenderInternal)

/// Display pipeline for the final Image pass: derives the pixel format from the
/// destination tile.
- (nullable id<MTLRenderPipelineState>)
    customPipelineForSource:(NSString *)userSource
           destinationImage:(FxImageTile *)destinationImage;

/// Build (or fetch the cached) runtime-compiled pipeline for `userSource` at an
/// explicit pixel format, cached per device+pixel-format keyed on the emitted
/// MSL hash. `bufferMode` selects the raw-output wrapper for a Buffer pass.
/// Returns nil (and logs) on a bad shader; the caller draws the error pattern.
- (nullable id<MTLRenderPipelineState>)
    customPipelineForSource:(NSString *)userSource
                pixelFormat:(MTLPixelFormat)pf
                 registryID:(uint64_t)registryID
                 bufferMode:(BOOL)bufferMode;

/// Multi-pass Custom render with PERSISTENT (ping-pong) feedback buffers, made
/// deterministic under scrubbing by frame tracking. Channel routing (the common
/// image convention): iChannelN -> Buffer[N]; a buffer reading an EARLIER buffer
/// (index < its own) sees this frame, reading ITSELF or a LATER buffer sees the
/// previous frame (feedback). No buffer on a channel -> source clip (ch0) /
/// noise. `bufferSources` is 4 entries (A,B,C,D), empty = absent, Common already
/// prepended. `frameIndex` (-1 = unknown) + `dtPerFrame` (iTime step) drive the
/// determinism: a sequential frame advances ONE step (cheap), the same frame is
/// reused, a seek restores the nearest checkpoint and re-sims from there.
- (BOOL)renderCustomMultipassWithUniforms:(KKGLSLUniforms)u
                                colorPool:(const simd_float4 *)colorPool
                                poolCount:(int)poolCount
                              imageSource:(NSString *)imageSource
                            bufferSources:(NSArray<NSString *> *)bufferSources
                               frameIndex:(NSInteger)frameIndex
                               dtPerFrame:(float)dtPerFrame
                         destinationImage:(FxImageTile *)destinationImage
                             sourceImages:
                                 (NSArray<FxImageTile *> *)sourceImages;

/// Build N plugin states, one per requested time, refreshing the render cache /
/// timing ONCE. Motion-blur sample-accumulate evaluates several sub-frame times
/// per frame; times[0] should be the frame's renderTime. Runs where
/// FxParameterRetrievalAPI is valid (pluginState:), not at render time.
- (BOOL)buildStates:(MiragePluginState *)outStates
            atTimes:(const CMTime *)times
              count:(NSInteger)count
              error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
