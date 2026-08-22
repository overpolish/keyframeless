/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <Foundation/Foundation.h>

#import "Constants.h"
#import "KKGLSLTranspiler.h"
#import "KKGLSLTranspiler_Internal.h"
#import "MirageShaderModel.h"

// The real glslang + SPIRV-Cross transpile, run over hand-written cases and
// then over every installed template. A template is the only place the shipped
// grading library is exercised end to end, so a wrapper change that breaks one
// shows up here rather than in Final Cut.

// MirageShaderModel reaches into the kit for a slot lane key. The transpile
// never looks at the result, so the harness supplies one rather than linking
// the framework.
NSString *KKSlotLaneKey(NSString *groupName, NSString *instanceID,
                        NSString *control);
NSString *KKSlotLaneKey(NSString *groupName, NSString *instanceID,
                        NSString *control) {
  return
      [NSString stringWithFormat:@"%@/%@/%@", groupName, instanceID, control];
}

static int gFailures = 0;

static void KKExpectCompiles(NSString *label, NSString *src) {
  KKGLSLTranspileResult *r = KKTranspileGLSL(src);
  if (r.errorLog.length || !r.msl.length) {
    NSLog(@"FAIL: %@\n%@", label, r.errorLog ?: @"(no MSL produced)");
    gFailures++;
    return;
  }
  NSLog(@"ok: %@", label);
}

static void KKExpectBufferCompiles(NSString *label, NSString *src) {
  KKGLSLTranspileResult *r = KKTranspileGLSLBuffer(src);
  if (r.errorLog.length || !r.msl.length) {
    NSLog(@"FAIL: %@\n%@", label, r.errorLog ?: @"(no MSL produced)");
    gFailures++;
    return;
  }
  NSLog(@"ok: %@", label);
}

static void KKExpectMSLContains(NSString *label, NSString *src,
                                NSString *needle, BOOL wanted) {
  KKGLSLTranspileResult *r = KKTranspileGLSL(src);
  if (r.errorLog.length) {
    NSLog(@"FAIL: %@ did not compile\n%@", label, r.errorLog);
    gFailures++;
    return;
  }
  BOOL found = [r.msl rangeOfString:needle].location != NSNotFound;
  if (found != wanted) {
    NSLog(@"FAIL: %@ - expected '%@' %@ in the MSL", label, needle,
          wanted ? @"present" : @"absent");
    gFailures++;
    return;
  }
  NSLog(@"ok: %@", label);
}

static void KKRunGradingLibraryTests(void) {
  NSString *callsAll =
      @"void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n"
      @"  vec2 uv = fragCoord / iResolution.xy;\n"
      @"  vec3 lin = decodeToLinear(texture(iChannel0, uv).rgb);\n"
      @"  vec3 lab = linearToOklab(lin);\n"
      @"  lab.yz *= 1.2;\n"
      @"  vec3 back = oklabToLinear(lab) * balanceGain(10.0, -5.0);\n"
      @"  fragColor = vec4(encodeFromLinear(back), 1.0);\n}\n";
  KKExpectCompiles(@"a shader that only CALLS the grading helpers", callsAll);

  NSString *callsNone =
      @"void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n"
      @"  fragColor = vec4(fragCoord / iResolution.xy, 0.0, 1.0);\n}\n";
  KKExpectMSLContains(@"an unrelated shader carries no grading library",
                      callsNone, @"oklabToLinearRaw", NO);

  NSString *ownsThem =
      @"vec3 decodeToLinear(vec3 c) { return c * c; }\n"
      @"vec3 encodeFromLinear(vec3 c) { return sqrt(max(c, 0.0)); }\n"
      @"void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n"
      @"  vec2 uv = fragCoord / iResolution.xy;\n"
      @"  vec3 lin = decodeToLinear(texture(iChannel0, uv).rgb);\n"
      @"  fragColor = vec4(encodeFromLinear(lin), 1.0);\n}\n";
  KKExpectCompiles(@"a shader carrying its own copy is not redefined",
                   ownsThem);

  // `return decodeToLinear(c);` reads as a definition to a naive rule, which
  // would skip injection and leave the call undefined.
  NSString *tailCall =
      @"vec3 grade(vec3 c) {\n"
      @"  return decodeToLinear(c);\n}\n"
      @"void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n"
      @"  vec2 uv = fragCoord / iResolution.xy;\n"
      @"  fragColor = vec4(grade(texture(iChannel0, uv).rgb), 1.0);\n}\n";
  KKExpectCompiles(@"a call in return position still gets the helper",
                   tailCall);
}

static void KKRunTransitionLibraryTests(void) {
  NSString *callsBoth =
      @"void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n"
      @"  vec2 uv = fragCoord / iResolution.xy;\n"
      @"  vec4 a = texture(iChannel0, uv);\n"
      @"  vec4 b = texture(iChannel1, uv);\n"
      @"  vec4 m = mixTransitionColors(a, b, iProgress);\n"
      @"  fragColor = compositeTransitionLayer(a, m);\n}\n";
  KKExpectCompiles(@"a shader that only CALLS the transition helpers",
                   callsBoth);

  NSString *callsNone =
      @"void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n"
      @"  fragColor = vec4(fragCoord / iResolution.xy, 0.0, 1.0);\n}\n";
  KKExpectMSLContains(@"an unrelated shader carries no transition library",
                      callsNone, @"mixTransitionColors", NO);

  // The two are separate families: a shader owning one must still be handed the
  // other, which a single combined family would suppress.
  NSString *ownsMixOnly =
      @"vec4 mixTransitionColors(vec4 a, vec4 b, float t) { return mix(a, b, "
      @"t); }\n"
      @"void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n"
      @"  vec2 uv = fragCoord / iResolution.xy;\n"
      @"  vec4 a = texture(iChannel0, uv);\n"
      @"  vec4 b = texture(iChannel1, uv);\n"
      @"  fragColor = compositeTransitionLayer(a, mixTransitionColors(a, b, "
      @"iProgress));\n}\n";
  KKExpectCompiles(@"owning one transition helper still injects the other",
                   ownsMixOnly);
}

static void KKRunRackAlphaTests(void) {
  NSString *filter =
      @"void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n"
      @"  fragColor = texture(iChannel0, fragCoord / iResolution.xy);\n"
      @"}\n";
  NSString *wrapped = KKWrapGLSL(
      KKGLSLSourcePreservingInputAlpha(filter), 1u, NULL, KKGLSLPassImage);
  BOOL preserves =
      [wrapped rangeOfString:@"float kkSourceAlpha = clamp(texture(iChannel0"]
          .location != NSNotFound &&
      [wrapped rangeOfString:@"kk_outColor = vec4(rgb, kkSourceAlpha)"]
          .location != NSNotFound;
  if (!preserves) {
    NSLog(@"FAIL: downstream rack filter does not preserve input alpha");
    gFailures++;
  } else {
    NSLog(@"ok: downstream rack filter preserves input alpha");
  }
}

static void KKRunFrameTests(void) {
  NSString *common = MirageFrameCommonSource();
  KKExpectCompiles(@"Frame image pass",
                   [common stringByAppendingString:MirageFrameShaderSource()]);
  KKExpectBufferCompiles(
      @"Frame Buffer B",
      [common stringByAppendingString:MirageFrameBufferBSource()]);
  KKExpectBufferCompiles(
      @"Frame Buffer C",
      [common stringByAppendingString:MirageFrameBufferCSource()]);
  KKExpectBufferCompiles(
      @"Frame Buffer D",
      [common stringByAppendingString:MirageFrameBufferDSource()]);
}

static void KKRunMagicMoveTests(void) {
  NSString *source = MirageMagicMoveShaderSource();
  KKExpectCompiles(@"Magic Move image pass", source);
  KKExpectBufferCompiles(@"Magic Move Buffer B",
                         MirageMagicMoveBufferBSource());
  const MirageOSCBlock *anchor =
      [[MirageShaderModel modelForSource:source]
          oscBlockForUniform:"uAnchor"];
  BOOL followsPosition =
      anchor && strcmp(anchor->primitive, "point") == 0 &&
      strcmp(anchor->style, "square") == 0 &&
      strcmp(anchor->forward,
             "uPosition + uAnchor - vec2(0.5)") == 0 &&
      strcmp(anchor->inverse,
             "pos - uPosition + vec2(0.5)") == 0;
  if (!followsPosition) {
    NSLog(@"FAIL: Magic Move Anchor OSC does not follow Position");
    gFailures++;
  } else {
    NSLog(@"ok: Magic Move Anchor OSC follows Position bidirectionally");
  }
}

static void KKRunInstalledTemplates(NSString *root) {
  NSFileManager *fm = NSFileManager.defaultManager;
  BOOL dir = NO;
  if (![fm fileExistsAtPath:root isDirectory:&dir] || !dir) {
    NSLog(@"skip: no installed templates at %@", root);
    return;
  }
  NSArray<NSString *> *uuids = [[fm contentsOfDirectoryAtPath:root error:nil]
      sortedArrayUsingSelector:@selector(compare:)];
  NSUInteger ran = 0;
  for (NSString *uuid in uuids) {
    NSString *folder = [root stringByAppendingPathComponent:uuid];
    NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:folder
                                                         error:nil];
    if (!files.count)
      continue;
    NSString *common = @"";
    if ([files containsObject:@"common.glsl"])
      common =
          [NSString stringWithContentsOfFile:
                        [folder stringByAppendingPathComponent:@"common.glsl"]
                                    encoding:NSUTF8StringEncoding
                                       error:nil]
              ?: @"";
    for (NSString *name in
         [files sortedArrayUsingSelector:@selector(compare:)]) {
      if (![name.pathExtension isEqualToString:@"glsl"] ||
          [name isEqualToString:@"common.glsl"])
        continue;
      NSString *path = [folder stringByAppendingPathComponent:name];
      NSString *src = [NSString stringWithContentsOfFile:path
                                                encoding:NSUTF8StringEncoding
                                                   error:nil];
      if (!src.length)
        continue;
      if (common.length)
        src = [NSString stringWithFormat:@"%@\n%@", common, src];
      BOOL image = [name isEqualToString:@"image.glsl"];
      KKGLSLTranspileResult *r =
          image ? KKTranspileGLSL(src) : KKTranspileGLSLBuffer(src);
      ran++;
      if (r.errorLog.length || !r.msl.length) {
        NSLog(@"FAIL: %@/%@\n%@", uuid, name, r.errorLog ?: @"(no MSL)");
        gFailures++;
      }
    }
  }
  NSLog(@"ok: %lu installed template passes transpiled", (unsigned long)ran);
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    NSString *root =
        argc > 1 ? @(argv[1])
                 : [NSHomeDirectory()
                       stringByAppendingPathComponent:
                           @"Library/Application Support/Keyframeless/Shaders"];
    KKRunGradingLibraryTests();
    KKRunTransitionLibraryTests();
    KKRunRackAlphaTests();
    KKRunMagicMoveTests();
    KKRunFrameTests();
    KKRunInstalledTemplates(root);
    if (gFailures) {
      NSLog(@"FAILED: %d", gFailures);
      return 1;
    }
    NSLog(@"all Mirage transpile tests passed");
    return 0;
  }
}
