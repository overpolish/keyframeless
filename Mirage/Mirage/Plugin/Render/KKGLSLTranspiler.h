/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <simd/simd.h>

/// Longest dimension (px) a FEEDBACK sim buffer is capped to.
/// Reaction-diffusion / fluid patterns are a few cells wide, so they only
/// develop at a coarse grid; this also cuts per-pass cost + checkpoint memory.
/// The main render and the mini-viewer share it so a feedback shader looks the
/// same in both.
#define KK_FEEDBACK_SIM_MAXDIM 360

NS_ASSUME_NONNULL_BEGIN

// Uniform block bound at buffer(0) for a transpiled custom shader. Every member
// is a vec4, so the std140 layout SPIRV-Cross emits maps 1:1 onto this struct
// with no packing ambiguity to reconcile on the fill side.
typedef struct KKGLSLUniforms {
  simd_float4 resTime; // xyz = iResolution, w = iTime
  simd_float4 mouse;   // iMouse
  simd_float4 date;    // iDate
  simd_float4 extra;   // x=iTimeDelta, y=float(iFrame), z=flipY, w=encodeSRGB
  simd_float4 grain;   // x=grain 0..1, y=grainSize px (shared core film grain)
  simd_float4 chanRes[4]; // iChannelResolution[0..3]: xyz = px size, z = 1
  // x = iProgress (0..1 over the effect's window); y = iMotionBlur (0..1
  // shutter, non-zero only for a `// #motionblur native` shader); z =
  // iMotionBlurSamples (as float); w = iTransitionMode (0 Transition, 1 In,
  // 2 Out).
  simd_float4 transition;
  // A shader's `// #color` properties append their vec4s to this block's std140
  // tail (see KKWrapGLSL); the render supplies those bytes right after this
  // struct at bind time.
} KKGLSLUniforms;

/// How a shader wants motion blur handled, declared by a `// #motionblur
/// <mode>` directive in its source (default = accumulate). The end-user Motion
/// Blur popover (enabled / shutter / samples) is unchanged; this only decides
/// who consumes those settings.
typedef enum MirageMotionBlurMode {
  /// Plugin re-renders N sub-frame samples and averages them. The default.
  /// Works multi-pass too: a non-feedback buffer chain is encoded ONCE and
  /// every sample re-runs only the image pass. A FEEDBACK chain cannot be
  /// shared that way (its state is a function of history) and is rejected by
  /// validation.
  MirageMotionBlurModeAccumulate = 0,
  /// The shader owns its own blur (feedback trails / an internal loop). The
  /// plugin renders once and exposes the popover settings as iMotionBlur (0..1
  /// shutter) + iMotionBlurSamples. Works for single AND multi-pass.
  MirageMotionBlurModeNative = 1,
  /// No motion blur for this shader: render once, iMotionBlur = 0.
  MirageMotionBlurModeOff = 2,
} MirageMotionBlurMode;

/// Which variant of a source to transpile. The two differ only in what `main()`
/// writes: display pixels, or raw buffer data a later pass samples.
typedef enum KKGLSLPassKind {
  KKGLSLPassImage = 0,
  KKGLSLPassBuffer = 1,
} KKGLSLPassKind;

// Result of transpiling a GLSL image-shader body to a full MSL unit.
@interface KKGLSLTranspileResult : NSObject
// Complete MSL (the SPIRV-Cross fragment plus an appended full-screen vertex),
// or nil when transpilation failed - then errorLog explains why.
@property(nonatomic, copy, nullable) NSString *msl;
// First 128 bits of SHA-256(msl) as hex, nil when msl is. Use this as the
// content key for pipeline-state caches - NSString.hash is collision-prone and
// a collision there silently renders the wrong shader.
@property(nonatomic, copy, nullable) NSString *mslDigest;
@property(nonatomic, copy) NSString *fragmentName; // MSL fragment function name
@property(nonatomic, copy) NSString *vertexName;   // MSL vertex function name
@property(nonatomic, copy, nullable) NSString *errorLog;
// YES when the raw-GL compatibility shim rewrote a non-image-shader entry point
// (main()/gl_FragColor) into the mainImage convention. Used to turn an
// otherwise cryptic "undeclared identifier" into a hint that an unusual host
// uniform name went unmapped and needs a hand edit to iChannel0 / iResolution /
// iTime.
@property(nonatomic) BOOL shimmedFromRawGL;
// Lines the wrapper prepends before the user's source, so a glslang error line
// (wrapped coordinates) maps back to the editor as `wrappedLine - offset`.
@property(nonatomic) NSInteger userLineOffset;
// Parse the first glslang error into a user-space line (1-based, 0 when unknown
// or in the wrapper) and a cleaned one-line message. Returns NO when there is
// no error (a successful transpile).
- (BOOL)firstError:(NSString *_Nullable *_Nullable)outMessage
              line:(NSInteger *_Nullable)outLine;
// Bit i set when the wrapped shader DECLARES iChannel<i>, and so must have a
// texture AND sampler bound for it. Wider than what the user's source
// references: a generator that never samples iChannel0 still gets it declared
// so its alpha composites over the footage. Bind against this, not against what
// the source mentions - Metal tolerates a nil sampler, Metal API Validation
// aborts.
@property(nonatomic) NSUInteger declaredChannelMask;
// The MSL [[texture(n)]] / [[sampler(n)]] index SPIRV-Cross assigned to
// iChannel<ch>, or NSNotFound when that channel is unused.
- (NSInteger)textureIndexForChannel:(NSUInteger)ch;
- (NSInteger)samplerIndexForChannel:(NSUInteger)ch;
// How many `// #frames` neighbour samplers (iNeighbor0..N-1) the wrapped shader
// declares. 0 for a shader with no `#frames` directive, and for every Buffer
// pass. The render binds this many time-shifted source frames, in the order the
// directive listed its offsets.
@property(nonatomic) NSInteger neighborCount;
// Same as the channel pair, for iNeighbor<i>. NSNotFound when the shader
// declared the offset but never sampled it (SPIRV-Cross strips it).
- (NSInteger)textureIndexForNeighbor:(NSUInteger)i;
- (NSInteger)samplerIndexForNeighbor:(NSUInteger)i;
@end

// Transpile a GLSL image-shader body (mainImage + helpers +
// iTime/iResolution /iMouse/iChannelN globals) into a complete MSL translation
// unit via glslang (GLSL->SPIR-V) then SPIRV-Cross (SPIR-V->MSL). The pipeline
// is serialized behind a lock and glslang is process-initialized once. C
// linkage so the ObjC
// (.m) render path links against the ObjC++ (.mm) definition.
#ifdef __cplusplus
extern "C" {
#endif
KKGLSLTranspileResult *KKTranspileGLSL(NSString *userGLSL);

// The `// #motionblur <accumulate|native|off>` mode a source declares (default
// accumulate when the directive is absent or unrecognized).
MirageMotionBlurMode MirageMotionBlurModeForSource(NSString *userGLSL);

// Whether the source asks for motion blur to start ENABLED - a bare `on` after
// the mode word (`// #motionblur on`, `// #motionblur native on`). Applied when
// the shader is applied from the browser, not on every code commit, so a user
// who turns it off keeps it off. NO for a source with no `#motionblur` line:
// blur costs N renders per frame and most shaders should not opt every user in.
BOOL MirageMotionBlurDefaultsOnForSource(NSString *userGLSL);

// Bind the fixed KKGLSLUniforms at buffer(0), followed by a shader's `//
// #color` property pool (the std140 tail: `poolCount` vec4s) as one contiguous
// buffer. `poolCount <= 0` binds just the fixed struct.
void KKBindGLSLUniforms(id<MTLRenderCommandEncoder> encoder,
                        const KKGLSLUniforms *u, const simd_float4 *pool,
                        int poolCount);

// Buffer-pass variant: emits the raw `mainImage` output (all four components,
// no grain / sRGB-encode / clamp / forced-opaque), because a Buffer A-D pass
// stores DATA a later pass samples, not display pixels. Memoised separately
// from the display variant.
KKGLSLTranspileResult *KKTranspileGLSLBuffer(NSString *userGLSL);

// YES only for a shader declaring `// #template transition`. Shared by the
// inspector (to add its Transition/In/Out control) and render wrapper
// (two-input binding + authoritative alpha).
BOOL KKLooksLikeTransitionShader(NSString *src);
/// YES only for `// #template color-transform`. Technical transforms consume
/// the host/source code values directly instead of the Shadertoy compatibility
/// gamma round-trip used by ordinary authored filters.
BOOL KKLooksLikeColorTransformShader(NSString *src);

// A repeating value-noise texture / repeat-linear sampler for the iChannelN a
// shader samples (the common "iChannel = noise" default). Both cached per
// device. Shared by the main render and the mini-viewer.
id<MTLTexture> KKCustomChannelNoiseTexture(id<MTLDevice> device);
// A 1x1 transparent-black texture. Transition In/Out modes bind this explicitly
// for the absent side; leaving a channel unbound would invoke the noise
// fallback.
id<MTLTexture> KKCustomTransparentTexture(id<MTLDevice> device);
id<MTLSamplerState> KKCustomChannelSampler(id<MTLDevice> device);
// A clamp-to-edge / linear sampler for the source clip bound to iChannel0, so
// footage doesn't wrap when the shader samples outside [0,1]. Cached per
// device.
id<MTLSamplerState> KKCustomSourceSampler(id<MTLDevice> device);
// Gamma-encode (linear->sRGB) a LINEAR source texture into a new RGBA16F
// texture of the same size. A Shadertoy shader assumes its iChannel input is
// display / gamma space (Shadertoy never linearises); our output wrapper
// re-decodes with kkSrgbToLinear for a float dest. Feeding the shader FCP's
// linear source therefore double-decodes it and darkens the clip - so encode
// the source to gamma first and a passthrough round-trips exactly. Returns
// `src` unchanged on any failure. `OnBuffer` encodes onto an existing command
// buffer (the caller commits it); the queue form runs its own command buffer
// and blocks until done.
id<MTLTexture> _Nullable KKGammaEncodeSourceTextureOnBuffer(
    id<MTLCommandBuffer> commandBuffer, id<MTLTexture> _Nullable src);
id<MTLTexture> _Nullable KKGammaEncodeSourceTexture(
    id<MTLCommandQueue> queue, id<MTLTexture> _Nullable src);
// The exact inverse (sRGB->linear), for the one shader kind that wants the
// opposite of the Shadertoy contract: a `#template color-transform` consumes
// and produces LINEAR host values, so an 8-bit destination - whose source
// arrives gamma-encoded, and whose output the wrapper encodes on the way out -
// must have that source decoded first or the transform matrices operate on
// display-encoded numbers.
id<MTLTexture> _Nullable KKGammaDecodeSourceTextureOnBuffer(
    id<MTLCommandBuffer> commandBuffer, id<MTLTexture> _Nullable src);
id<MTLTexture> _Nullable KKGammaDecodeSourceTexture(
    id<MTLCommandQueue> queue, id<MTLTexture> _Nullable src);
// A destination for the gamma conversion, with exactly the descriptor the
// allocating variants above use. Exposed so a caller that converts the SAME
// sources every frame (a `// #frames` shader's neighbours) can hold one per
// slot and reuse it instead of allocating a full-resolution RGBA16Float per
// texture per frame.
id<MTLTexture> _Nullable KKGammaConvertDestinationTexture(id<MTLDevice> device,
                                                          NSUInteger width,
                                                          NSUInteger height);
// Encode the conversion into a CALLER-OWNED destination, returning NO when the
// pipeline is unavailable (the caller then binds the source unconverted, as the
// allocating variants do). Encodes one render pass onto `commandBuffer` and
// never waits, so a caller can batch many conversions into one buffer and pay a
// single round trip. The allocating variants are implemented on top of this, so
// the two cannot drift.
BOOL KKGammaConvertOnBufferInto(id<MTLCommandBuffer> commandBuffer,
                                id<MTLTexture> src, id<MTLTexture> dst,
                                BOOL decode);
// Whether the conversion pipeline exists on `device`. A caller that PLANS
// conversions before it has a command buffer asks first, so a missing pipeline
// makes it bind the sources unconverted - the same outcome the allocating
// variants produce - instead of binding a destination nothing wrote into.
BOOL KKGammaPipelineAvailable(id<MTLDevice> device, BOOL decode);
// Bind textures to every channel `tr` uses, at the MSL indices SPIRV-Cross
// assigned. iChannel0 gets `source` (the effect's clip) when non-nil, falling
// back to `noise`; iChannel1-3 always get `noise`.
void KKBindCustomChannels(id<MTLRenderCommandEncoder> encoder,
                          KKGLSLTranspileResult *tr,
                          id<MTLTexture> _Nullable source,
                          id<MTLSamplerState> _Nullable sourceSampler,
                          id<MTLTexture> noise, id<MTLSamplerState> sampler);
// Like KKBindCustomChannels but with an explicit per-channel texture array
// (`chTex` = 4 entries, NSNull = none -> noise). For multi-buffer routing
// (iChannel0->Buffer A, 1->B, ...). Shared by the FCP render and the
// mini-viewer.
void KKBindCustomChannelTextures(id<MTLRenderCommandEncoder> encoder,
                                 KKGLSLTranspileResult *tr, NSArray *chTex,
                                 id<MTLSamplerState> _Nullable sampler,
                                 id<MTLTexture> noise,
                                 id<MTLSamplerState> noiseSampler);
// Bind the `// #frames` neighbour samplers (iNeighbor0..N-1). `frameTextures`
// is in DIRECTIVE ORDER, one entry per declared offset; a short array or an
// NSNull entry (a frame FCP could not deliver) binds `fallback`, which the
// caller sets to the CURRENT frame so a temporal read clamps at the clip edge
// rather than sampling black. Same clamp/linear sampler as iChannel0.
void KKBindCustomNeighborTextures(id<MTLRenderCommandEncoder> encoder,
                                  KKGLSLTranspileResult *tr,
                                  NSArray *frameTextures,
                                  id<MTLSamplerState> _Nullable sampler,
                                  id<MTLTexture> _Nullable fallback);
#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
