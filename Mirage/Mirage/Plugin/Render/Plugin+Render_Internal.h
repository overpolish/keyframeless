/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "KKGLSLTranspiler.h"
#import "MirageStateBlob.h" // MirageStateBlobEntry
#import "MirageTypes.h"
#import "Plugin_Private.h"
#import <KeyframelessKit/KKMotionBlur.h> // KKMotionBlurState

// The seams of the (Render) category, split across:
//
//   Plugin+Render.m           scheduleInputs: + renderDestinationImage:
//   Plugin+RenderState.m      pluginState: + the lane -> MiragePluginState eval
//   Plugin+RenderPipeline.m   transpile -> MSL -> cached MTLRenderPipelineState
//   Plugin+RenderMultipass.m  the Buffer A-D + feedback render
//   Plugin+RenderRack.m       the multi-entry chain (Shader Rack)
//
// Runtime-compiled user shaders are the only render path. The user writes a
// GLSL Image shader (`void mainImage(out vec4, in vec2)`, bare iTime /
// iResolution / iChannelN); KKGLSLTranspiler wraps and transpiles it to MSL
// with glslang + SPIRV-Cross, so the real GLSL dialect (not a regex
// approximation) drives the result.

NS_ASSUME_NONNULL_BEGIN

@class MirageShaderModel;

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

/// Cleared code = passthrough (show the source unchanged), not the plasma
/// default. Also what a rack renders when the user has switched every entry
/// off.
FOUNDATION_EXPORT NSString *const kMiragePassthroughSource;

/// The fixed uniform block for one frame (or one motion-blur sub-sample).
/// `mediaW/H` are the output dimensions, which drive iResolution; `encodeSRGB`
/// describes the TARGET, so a chain intermediate passes 1 (it stores gamma)
/// while the FxPlug destination passes whatever its surface wants.
KKGLSLUniforms MirageBuildUniforms(const MiragePluginState *base,
                                   CGFloat mediaW, CGFloat mediaH,
                                   float encodeSRGB);

/// The render's pixel scale (thumbnail vs full frame), from the SOURCE tile's
/// inversePixelTransform - FxTileableEffect exposes no render-scale API.
float MirageRenderScale(NSArray<FxImageTile *> *sourceImages);

/// Scale every RAW-pixel scalar in a filled pool, so a `units="px"` control
/// covers the same fraction of a thumbnail as of the full render.
void MirageScalePixelProps(MirageShaderModel *_Nullable model,
                           vector_float4 *pool, int poolCount, float scale);

/// The four buffer sources in fixed A, B, C, D order, each with Common already
/// prepended and an absent one left as an empty string so the index still names
/// the buffer. `*outAny` is YES when any buffer is present at all, which is
/// what selects the multi-pass path.
NSArray<NSString *> *
MirageBufferSourcesFromSections(NSDictionary<NSString *, NSString *> *sections,
                                NSString * (^withCommon)(NSString *),
                                BOOL *_Nullable outAny);

/// Role keys for the per-instance reusable gamma destinations. Neighbours
/// occupy `MirageGammaDestNeighbor0 + i`, so every converted texture in a
/// render has one stable slot and none of them is reallocated per frame.
typedef NS_ENUM(NSInteger, MirageGammaDestKey) {
  MirageGammaDestSource = 0,
  MirageGammaDestTo = 1,
  MirageGammaDestNeighbor0 = 100,
};

/// SHADER RACK: where one entry of a chain sits in the frame.
///
/// nil everywhere the plugin renders a single template, and every field's nil /
/// NO reading is the pre-rack behaviour - which is how the one-entry path stays
/// literally the code it was.
@interface MirageRackChainSlot : NSObject
/// The previous ENABLED entry's output, already in the chain's gamma-encoded
/// space. nil for the head entry (and for every entry a disabled predecessor
/// skipped past), which then takes the clip exactly as a lone template does.
@property(nonatomic, strong, nullable) id<MTLTexture> input;
/// Where this entry's image pass draws. nil = the FxPlug destination, which is
/// the final enabled entry and the only pass in the frame that waits.
@property(nonatomic, strong, nullable) id<MTLTexture> output;
/// The frame's ONE queue. Every entry commits to it without waiting, so commit
/// order alone chains them and the final entry's mandatory wait covers the lot.
@property(nonatomic, strong, nullable) id<MTLCommandQueue> queue;
/// Namespaces this entry's persistent feedback set: two entries each running a
/// Buffer feedback chain hold separate history instead of stamping on one
/// another's.
@property(nonatomic, copy, nullable) NSString *entryID;
/// Whether the FxPlug SURFACE is linear float. Normally implied by the output
/// encode flag (`u.extra.w == 0`), but an intermediate always stores gamma
/// while the surface may be either, so the chain states it outright.
@property(nonatomic) BOOL surfaceLinear;
@end

@interface MiragePlugin (RenderInternal)

/// A reusable RGBA16Float conversion destination for `key`, rebuilt only when
/// the required size changes. Never a per-frame allocation.
- (nullable id<MTLTexture>)reusableGammaDestinationForKey:(NSInteger)key
                                                   device:(id<MTLDevice>)device
                                                    width:(NSUInteger)width
                                                   height:(NSUInteger)height;

/// SHADER RACK: the reusable RGBA16F intermediate one entry renders into and
/// the next samples. Keyed by entry id (never by position - a disabled entry
/// changes positions without changing what any entry holds) and rebuilt only
/// when the size changes. Never a per-frame allocation.
- (nullable id<MTLTexture>)reusableChainTextureForEntry:(NSString *)entryID
                                                 device:(id<MTLDevice>)device
                                                  width:(NSUInteger)width
                                                 height:(NSUInteger)height;

/// Plan the gamma match for a resolved neighbour set: hand back the textures to
/// BIND, and encode nothing yet. The returned block does the encoding when it
/// is handed a command buffer, so the conversions ride the render's own buffer
/// instead of paying a commit + wait each.
///
/// Entries are converted by index; an `NSNull` (an offset FCP could not
/// deliver) passes through untouched, so the binder still substitutes the
/// current frame. `outEncode` is nil when there is nothing to convert.
- (NSArray *)gammaMatchNeighbors:(NSArray *)neighbors
                          decode:(BOOL)decode
                          device:(id<MTLDevice>)device
                          encode:(void (^_Nullable *_Nullable)(
                                     id<MTLCommandBuffer>))outEncode;

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

/// `chain` nil is the single-template render, unchanged in every particular.
/// Non-nil rebinds three things and nothing else: iChannel0 comes from the
/// previous entry, the image pass targets an intermediate texture on the
/// frame's shared queue (committed, never waited on), and the feedback set is
/// keyed per entry.
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
                                    chain:(nullable MirageRackChainSlot *)chain
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

/// As above, additionally answering every RACK entry's states + per-sample
/// enabled flags at the same instants. `*outRackEntries` is nil when the
/// timeline holds the implicit single entry - the pre-rack answer, for which
/// `outStates` is already the whole story.
- (BOOL)buildStates:(MiragePluginState *)outStates
            atTimes:(const CMTime *)times
              count:(NSInteger)count
        rackEntries:(NSArray<MirageStateBlobEntry *> *_Nullable *_Nullable)
                        outRackEntries
              error:(NSError **)error;

/// SHADER RACK: render the chain the blob carries. Every enabled entry runs its
/// own full pipeline (gamma planning, buffer passes, image pass) into a cached
/// RGBA16F intermediate, the next entry binds that as iChannel0, and the last
/// one draws into the FxPlug destination carrying the frame's only wait.
/// Called only when the blob holds more than one entry.
- (BOOL)renderRackChainForDestinationImage:(FxImageTile *)destinationImage
                              sourceImages:
                                  (NSArray<FxImageTile *> *)sourceImages
                               pluginState:(NSData *)pluginState
                                    atTime:(CMTime)renderTime
                                    mediaW:(CGFloat)mediaW
                                    mediaH:(CGFloat)mediaH
                                encodeSRGB:(float)encodeSRGB;

@end

NS_ASSUME_NONNULL_END
