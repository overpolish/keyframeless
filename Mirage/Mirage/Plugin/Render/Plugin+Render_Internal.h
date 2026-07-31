/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "KKGLSLTranspiler.h"
#import "MirageTypes.h"
#import "Plugin_Private.h"
#import <KeyframelessKit/KKMotionBlur.h> // KKMotionBlurState

// The seams of the (Render) category, split across:
//
//   Plugin+Render.m           scheduleInputs: + renderDestinationImage:
//   Plugin+RenderState.m      pluginState: + the lane -> MiragePluginState eval
//   Plugin+RenderPipeline.m   transpile -> MSL -> cached MTLRenderPipelineState
//   Plugin+RenderMultipass.m  the Buffer A-D + feedback render
//
// Runtime-compiled user shaders are the only render path. The user writes a
// GLSL Image shader (`void mainImage(out vec4, in vec2)`, bare iTime /
// iResolution / iChannelN); KKGLSLTranspiler wraps and transpiles it to MSL
// with glslang + SPIRV-Cross, so the real GLSL dialect (not a regex
// approximation) drives the result.

NS_ASSUME_NONNULL_BEGIN

/// The delivered tile carrying the CURRENT frame - what iChannel0 binds. With
/// boundary-preview and `// #frames` requests in flight there are several
/// effect-clip tiles in one delivery and FCP does not honour request order, so
/// this picks the one whose `mediaTime` is nearest the render time rather than
/// trusting index 0. Identical to `sourceImages[0]` when only the current frame
/// was requested.
FxImageTile *_Nullable MirageCurrentFrameTile(
    NSArray<FxImageTile *> *sourceImages, CMTime renderTime);

/// The `// #frames` neighbour textures for this render, in DIRECTIVE ORDER
/// (entry i is the sampler `iNeighbor` i). Empty when `source` declares no
/// offsets.
///
/// FCP does not honour request order, so each offset is paired to the delivered
/// effect-clip tile whose `mediaTime` is nearest its requested time, within
/// half a frame - the same nearest-mediaTime identification KKMotionBlur uses
/// for its sub-frame samples, which is why the two features can share one
/// delivery list without either claiming the other's frames.
///
/// An offset FCP could not deliver (before the clip start, past its end)
/// resolves to `fallback` - the current frame - so a temporal read CLAMPS at
/// the clip edge instead of sampling black or noise.
///
/// `convert` is the gamma treatment iChannel0 received on this render; passing
/// the same block is what keeps a neighbour frame in the same encoding as the
/// current one. nil leaves the textures untouched.
NSArray *MirageNeighborFrameTextures(
    NSString *source, NSArray<FxImageTile *> *sourceImages, CMTime renderTime,
    double frameDurSec, id<MTLDevice> device, id<MTLTexture> _Nullable fallback,
    id<MTLTexture> _Nullable (^_Nullable convert)(id<MTLTexture> tex));

/// Role keys for the per-instance reusable gamma destinations. Neighbours
/// occupy `MirageGammaDestNeighbor0 + i`, so every converted texture in a render
/// has one stable slot and none of them is reallocated per frame.
typedef NS_ENUM(NSInteger, MirageGammaDestKey) {
  MirageGammaDestSource = 0,
  MirageGammaDestTo = 1,
  MirageGammaDestNeighbor0 = 100,
};

@interface MiragePlugin (RenderInternal)

/// A reusable RGBA16Float conversion destination for `key`, rebuilt only when
/// the required size changes. Never a per-frame allocation.
- (nullable id<MTLTexture>)reusableGammaDestinationForKey:(NSInteger)key
                                                   device:(id<MTLDevice>)device
                                                    width:(NSUInteger)width
                                                   height:(NSUInteger)height;

/// Plan the gamma match for a resolved neighbour set: hand back the textures to
/// BIND, and encode nothing yet. The returned block does the encoding when it is
/// handed a command buffer, so the conversions ride the render's own buffer
/// instead of paying a commit + wait each.
///
/// Entries are converted by index; an `NSNull` (an offset FCP could not deliver)
/// passes through untouched, so the binder still substitutes the current frame.
/// `outEncode` is nil when there is nothing to convert.
- (NSArray *)gammaMatchNeighbors:(NSArray *)neighbors
                          decode:(BOOL)decode
                          device:(id<MTLDevice>)device
                          encode:(void (^_Nullable *_Nullable)
                                      (id<MTLCommandBuffer>))outEncode;

/// Display pipeline for the final Image pass: derives the pixel format from the
/// destination tile.
- (nullable id<MTLRenderPipelineState>)
    customPipelineForSource:(NSString *)userSource
           destinationImage:(FxImageTile *)destinationImage;

/// Build (or fetch the cached) runtime-compiled pipeline for `userSource` at an
/// explicit pixel format, cached per device+pixel-format keyed on the emitted
/// MSL hash. `pass` selects the wrapper variant: display or raw Buffer output.
/// Returns nil (and logs) on a bad shader; the caller draws the error pattern.
- (nullable id<MTLRenderPipelineState>)
    customPipelineForSource:(NSString *)userSource
                pixelFormat:(MTLPixelFormat)pf
                 registryID:(uint64_t)registryID
                       pass:(KKGLSLPassKind)pass;

/// Multi-pass Custom render with PERSISTENT (ping-pong) feedback buffers, made
/// deterministic under scrubbing by frame tracking. Channel routing (the common
/// image convention): iChannelN -> Buffer[N]; a buffer reading an EARLIER
/// buffer (index < its own) sees this frame, reading ITSELF or a LATER buffer
/// sees the previous frame (feedback). No buffer on a channel -> source clip
/// (ch0), To image (ch1), then noise. `bufferSources` is 4 entries (A,B,C,D),
/// empty = absent,
/// Common already prepended. `frameIndex` (-1 = unknown) + `dtPerFrame` (iTime
/// step) drive the determinism: a sequential frame advances ONE step (cheap),
/// the same frame is reused, a seek restores the nearest checkpoint and re-sims
/// from there.
/// Per-sample uniforms for accumulate motion blur over a multi-pass chain.
/// `sampleUniforms` is called once per sub-sample to fill that sample's
/// uniforms + colour pool for the IMAGE pass; the buffer chain is encoded once
/// and shared, which is the whole point (see the accumulate note below).
/// `mbState.enabled == NO` or a nil block renders a single image pass.
typedef void (^MirageSampleUniformsBlock)(
    NSInteger sampleIndex, KKGLSLUniforms *outU,
    const simd_float4 *_Nonnull *_Nonnull outPool, int *outPoolCount);

- (BOOL)renderCustomMultipassWithUniforms:(KKGLSLUniforms)u
                                colorPool:(const simd_float4 *)colorPool
                                poolCount:(int)poolCount
                              imageSource:(NSString *)imageSource
                            bufferSources:(NSArray<NSString *> *)bufferSources
                               frameIndex:(NSInteger)frameIndex
                               dtPerFrame:(float)dtPerFrame
                                  mbState:(KKMotionBlurState)mbState
                               renderTime:(CMTime)renderTime
                           sampleUniforms:(nullable MirageSampleUniformsBlock)
                                              sampleUniforms
                           transitionMode:(int)transitionMode
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
