/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKGLSLTranspiler.h"

// The seams between the GLSL -> MSL pipeline's stages. Public API stays in
// KKGLSLTranspiler.h; this is what the stages call across file boundaries:
//
//   KKGLSLShims.m           dialect detection + rewriting, before any wrapping
//   KKGLSLWrapper.m         the core-450 GLSL the user's source is embedded in
//   KKGLSLTranspiler.mm     glslang + SPIRV-Cross + the memo cache
//   KKGLSLTranspileResult.m the result object + its error-log parsing
//   KKGLSLMetalResources.m  the textures / samplers / pipelines the render
//   binds
//
// C linkage: the core is ObjC++ (glslang/SPIRV-Cross are C++ headers) and every
// other stage is plain ObjC.

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// Does this source speak the gl-transitions.com dialect? The `vec4
// transition(vec2 ...)` signature is the tell - nothing else declares it. Both
// the shim and the wrapper's preamble gate on it, so `progress` stays a usable
// local name in every other shader.
BOOL KKLooksLikeGLTransition(NSString *src);

// Does this source carry `// #alpha` (its own alpha is authoritative)?
BOOL KKWantsAlphaOutput(NSString *src);

// Fold a gl-transitions.com shader into the image-shader convention.
NSString *KKShimGLTransition(NSString *src);

// Fold a raw WebGL / three.js / glslCanvas shader into the image-shader
// convention. Bails on a source that already has `mainImage`, so it composes
// after KKShimGLTransition (which supplies one).
NSString *KKShimRawGLSL(NSString *src);

// Rename GLSL identifiers that are reserved OPERATOR tokens in MSL (Metal is
// C++-based) to `kk_<name>`. Line-count preserving.
NSString *KKRenameReservedIdentifiers(NSString *src);

// Which iChannels the WRAPPED shader declares - what the render must bind.
//
// Not the same as what the user's source references: a generator that never
// samples iChannel0 still gets it declared, so its alpha can composite over the
// footage (see `honorAlpha` in the wrapper). Binding follows the declaration,
// so this is the set that matters; reporting the user's set instead left
// channel 0 declared but its sampler never created, and the draw bound nil.
NSUInteger KKDeclaredChannelMask(NSUInteger channelMask, KKGLSLPassKind pass);

// Embed a (already shimmed) GLSL image-shader body in a full core-450 unit:
// uniform block, `// #` directive members + defines, iChannel declarations, the
// grain/sRGB helpers, and the main() that drives flipY / sRGB / alpha.
// `outUserLineOffset` receives the number of lines prepended, so a glslang
// error at wrapped line L maps back to the editor as L - offset.
NSString *KKWrapGLSL(NSString *userSource, NSUInteger channelMask,
                     NSInteger *_Nullable outUserLineOffset,
                     KKGLSLPassKind pass);

#ifdef __cplusplus
}
#endif

@interface KKGLSLTranspileResult (Internal)
// Record the MSL texture/sampler indices SPIRV-Cross assigned to iChannel<ch>.
- (void)setTexture:(NSInteger)t sampler:(NSInteger)sm forChannel:(NSUInteger)ch;
@end

NS_ASSUME_NONNULL_END
