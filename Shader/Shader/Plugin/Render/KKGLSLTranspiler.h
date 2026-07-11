/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <simd/simd.h>

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
} KKGLSLUniforms;

// Result of transpiling a Shadertoy-style GLSL body to a full MSL unit.
@interface KKGLSLTranspileResult : NSObject
// Complete MSL (the SPIRV-Cross fragment plus an appended full-screen vertex),
// or nil when transpilation failed - then errorLog explains why.
@property(nonatomic, copy, nullable) NSString *msl;
@property(nonatomic, copy) NSString *fragmentName; // MSL fragment function name
@property(nonatomic, copy) NSString *vertexName;   // MSL vertex function name
@property(nonatomic, copy, nullable) NSString *errorLog;
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

// Transpile a Shadertoy-style GLSL body (mainImage + helpers +
// iTime/iResolution /iMouse/iChannelN globals) into a complete MSL translation
// unit via glslang (GLSL->SPIR-V) then SPIRV-Cross (SPIR-V->MSL). The pipeline
// is serialized behind a lock and glslang is process-initialized once. C
// linkage so the ObjC
// (.m) render path links against the ObjC++ (.mm) definition.
#ifdef __cplusplus
extern "C" {
#endif
KKGLSLTranspileResult *KKTranspileShadertoyGLSL(NSString *userGLSL);

// A repeating value-noise texture / repeat-linear sampler for the iChannelN a
// shader samples (Shadertoy's "iChannel = noise" default). Both cached per
// device. Shared by the main render and the mini-viewer.
id<MTLTexture> KKCustomChannelNoiseTexture(id<MTLDevice> device);
id<MTLSamplerState> KKCustomChannelSampler(id<MTLDevice> device);
// Bind the noise texture + sampler to every channel `tr` uses, at the MSL
// indices SPIRV-Cross assigned.
void KKBindCustomChannels(id<MTLRenderCommandEncoder> encoder,
                          KKGLSLTranspileResult *tr, id<MTLTexture> noise,
                          id<MTLSamplerState> sampler);
#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
