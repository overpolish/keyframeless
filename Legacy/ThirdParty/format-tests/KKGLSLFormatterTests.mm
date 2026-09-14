/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Regression set for KKFormatGLSL (the Shader GLSL formatter: astyle + the
// whitespace tidy pass). Compiles the SHIPPING KKGLSLFormatter.mm directly, so
// the tests exercise the real code and can't drift. Run via
// ThirdParty/run-format-tests.sh. Exits non-zero on any failure.
//
// Three kinds of check:
//   expectEqual      - exact output. Used for the whitespace-tidy rules we own
//                      and keep editing. Inputs are TOP-LEVEL statements so the
//                      house style adds no indentation (expected has no tabs).
//   expectIdempotent - format(format(x)) == format(x). The critical property
//                      for auto-format-on-publish; asserted over diverse, messy,
//                      and even malformed inputs.
//   expectContains   - a light house-style sanity check (Allman brace, tab
//                      indent) without pinning a brittle multi-line golden.

#import <Foundation/Foundation.h>

#import "KKGLSLFormatter.h"

static int gPass = 0;
static int gFail = 0;

static NSString *KKEsc(NSString *s) {
  s = [s stringByReplacingOccurrencesOfString:@"\t" withString:@"\\t"];
  return [s stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
}

static void expectEqual(NSString *name, NSString *input, NSString *expected) {
  NSString *got = KKFormatGLSL(input);
  if ([got isEqualToString:expected]) {
    gPass++;
    return;
  }
  gFail++;
  printf("FAIL  %s\n  in : %s\n  exp: %s\n  got: %s\n", name.UTF8String,
         KKEsc(input).UTF8String, KKEsc(expected).UTF8String,
         KKEsc(got).UTF8String);
}

static void expectIdempotent(NSString *name, NSString *input) {
  NSString *once = KKFormatGLSL(input);
  NSString *twice = KKFormatGLSL(once);
  if (once.length > 0 && [once isEqualToString:twice]) {
    gPass++;
    return;
  }
  gFail++;
  printf("FAIL(idem)  %s\n  once : %s\n  twice: %s\n", name.UTF8String,
         KKEsc(once).UTF8String, KKEsc(twice).UTF8String);
}

static void expectContains(NSString *name, NSString *input, NSString *needle) {
  NSString *got = KKFormatGLSL(input);
  if ([got rangeOfString:needle].location != NSNotFound) {
    gPass++;
    return;
  }
  gFail++;
  printf("FAIL(contains)  %s\n  want substring: %s\n  got: %s\n",
         name.UTF8String, KKEsc(needle).UTF8String, KKEsc(got).UTF8String);
}

int main(void) {
  @autoreleasepool {
    // Whitespace tidy - exact. Top-level statements => no indentation.
    expectEqual(@"space before ;", @"float x = 0.5    ;\n", @"float x = 0.5;\n");
    expectEqual(@"space before ,", @"vec2 p = vec2(1.0 , 2.0);\n",
                @"vec2 p = vec2(1.0, 2.0);\n");
    expectEqual(@"collapse internal runs", @"int   x   =   3;\n",
                @"int x = 3;\n");
    expectEqual(@"member dot - space after", @"float y = iResolution.   xy;\n",
                @"float y = iResolution.xy;\n");
    expectEqual(@"member dot - space before", @"float y = res .xy;\n",
                @"float y = res.xy;\n");
    expectEqual(@"member dot - chained", @"float v = a . b . c;\n",
                @"float v = a.b.c;\n");
    expectEqual(@"subscript brackets", @"float w = arr[ 2 ];\n",
                @"float w = arr[2];\n");

    // Float safety - these must NOT be treated as member dots / changed.
    expectEqual(@"float forms untouched", @"float f = 0.5 + .25 - 2.;\n",
                @"float f = 0.5 + .25 - 2.;\n");
    expectEqual(@"decimal is not a member dot", @"float g = 1. + 2.;\n",
                @"float g = 1. + 2.;\n");

    // Comment protection: code normalizes, the comment's insides stay verbatim
    // (its `.`, `;`, and runs of spaces are all preserved).
    expectEqual(@"line comment verbatim", @"int x = 1;  // a . b   ; c\n",
                @"int x = 1; // a . b   ; c\n");

    // Idempotency - the publish-safety invariant, over diverse inputs.
    expectIdempotent(@"idem: full shader",
                     @"void mainImage( out vec4 O,in vec2 U ){\n"
                     @"vec2 uv=U/iResolution.xy;\nfloat d=length(uv-0.5);\n"
                     @"if(d<0.25){O=vec4(1.0);}else{O=vec4(uv,0.5,1.0);}\n}\n");
    expectIdempotent(@"idem: preprocessor",
                     @"#version 300 es\n#define PI   3.14159\n"
                     @"#define SQ(x) ((x) * (x))\nfloat r = SQ(PI) ;\n");
    expectIdempotent(@"idem: macro line-continuation",
                     @"#define LONG(a, b) \\\n    ((a) +   (b))\n"
                     @"float z = LONG(1.0, 2.0);\n");
    expectIdempotent(@"idem: struct + layout",
                     @"struct Light{\nvec3 pos ;\nfloat intensity;\n};\n"
                     @"layout(location = 0) in vec2 vUV;\n");
    expectIdempotent(@"idem: arrays",
                     @"float w[3] = float[](0.1,   0.2, 0.3);\n"
                     @"float s = w[0] + w[ 1 ];\n");
    expectIdempotent(@"idem: ternary + bitops",
                     @"int f = (a > b) ? x : y;\nint m = (h << 2) | (l & 3);\n");
    expectIdempotent(@"idem: fragment with no entry point",
                     @"float hash(vec2 p){\n"
                     @"return fract(sin(dot(p , vec2(1.0,2.0))) * 43758.5453);\n"
                     @"}\n");
    // Malformed (unbalanced brace) must degrade gracefully, not crash or churn.
    expectIdempotent(@"idem: malformed unbalanced brace",
                     @"void mainImage(out vec4 O, in vec2 U){\n"
                     @"float x = 1.0 ;\n// missing close brace\n");
    expectIdempotent(@"idem: block comment spacing preserved",
                     @"/*  keep   the   spacing\n   across   lines  */\n"
                     @"float a = 1.0;\n");

    // House-style sanity (astyle side) without a brittle full golden.
    expectContains(@"Allman brace on its own line",
                   @"void f(){int x=1;}\n", @")\n{");
    expectContains(@"tab indentation", @"void f(){int x=1;}\n", @"\tint");

    printf("\n%d passed, %d failed\n", gPass, gFail);
    return gFail == 0 ? 0 : 1;
  }
}
