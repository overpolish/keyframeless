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
} KKGLSLUniforms;

// Result of transpiling a GLSL image-shader body to a full MSL unit.
@interface KKGLSLTranspileResult : NSObject
// Complete MSL (the SPIRV-Cross fragment plus an appended full-screen vertex),
// or nil when transpilation failed - then errorLog explains why.
@property(nonatomic, copy, nullable) NSString *msl;
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
// Bit i set when iChannel<i> is referenced (and so needs a bound texture).
@property(nonatomic) NSUInteger usedChannelMask;
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

// Buffer-pass variant: emits the raw `mainImage` output (all four components,
// no grain / sRGB-encode / clamp / forced-opaque), because a Buffer A-D pass
// stores DATA a later pass samples, not display pixels. Memoised separately
// from the display variant.
KKGLSLTranspileResult *KKTranspileGLSLBuffer(NSString *userGLSL);

// A repeating value-noise texture / repeat-linear sampler for the iChannelN a
// shader samples (the common "iChannel = noise" default). Both cached per
// device. Shared by the main render and the mini-viewer.
id<MTLTexture> KKCustomChannelNoiseTexture(id<MTLDevice> device);
id<MTLSamplerState> KKCustomChannelSampler(id<MTLDevice> device);
// A clamp-to-edge / linear sampler for the source clip bound to iChannel0, so
// footage doesn't wrap when the shader samples outside [0,1]. Cached per
// device.
id<MTLSamplerState> KKCustomSourceSampler(id<MTLDevice> device);
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
