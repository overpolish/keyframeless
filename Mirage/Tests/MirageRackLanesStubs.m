/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The lane catalog's neighbours that the harness does not need REAL: the
// glslang/SPIRV-Cross transpiler and the astyle formatter (referenced only from
// the code lane's editor blocks, which no lane BUILD runs), and MiragePlugin
// itself (named once, for the bundle a schema-copy block reads). Everything the
// build actually consults - the directive parser, the slot grammar, the default
// shader - is compiled from real source.

#import <Foundation/Foundation.h>

#import "KKGLSLTranspiler.h"
#import "Plugin.h"

@implementation MiragePlugin
@end

NSString *KKFormatGLSL(NSString *source) { return source; }
BOOL KKLooksLikeTransitionShader(NSString *source) { return NO; }
KKGLSLTranspileResult *KKTranspileGLSL(NSString *source) { return nil; }
KKGLSLTranspileResult *KKTranspileGLSLBuffer(NSString *source) { return nil; }
MirageMotionBlurMode MirageMotionBlurModeForSource(NSString *source) {
  return MirageMotionBlurModeAccumulate;
}
