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
#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
