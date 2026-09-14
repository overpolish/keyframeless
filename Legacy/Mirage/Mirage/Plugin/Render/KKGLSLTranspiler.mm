/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKGLSLTranspiler_Internal.h"
#import "MirageFrameOffsets.h"

#import <CommonCrypto/CommonDigest.h>

#include <string>
#include <vector>

#include "glslang/Include/glslang_c_interface.h"
#include "glslang/Public/resource_limits_c.h"
#include "spirv_cross/spirv_cross_c.h"

// The GLSL -> SPIR-V -> MSL core. The shim + wrap stages that produce its input
// live in KKGLSLShims.m / KKGLSLWrapper.m; this file is ObjC++ purely because
// glslang and SPIRV-Cross are C++ headers.

// Full-screen vertex appended after the SPIRV-Cross fragment: emits the quad and
// a window-space [[position]] that feeds the fragment's gl_FragCoord.
static NSString *const kKKVertexMSL =
    @"\nstruct KKVsOut { float4 position [[position]]; };\n"
    @"vertex KKVsOut kkVertex(uint vid [[vertex_id]]) {\n"
    @"  float2 corners[4] = { float2(-1.0, -1.0), float2(-1.0, 1.0), "
    @"float2(1.0, -1.0), float2(1.0, 1.0) };\n"
    @"  KKVsOut o; o.position = float4(corners[vid], 0.0, 1.0); return o;\n}\n";

// SPIRV-Cross's force-zero-init misses some loop-hoisted variables - a C-style
// `for (O *= i; i < n; i++)` leaves the counter as a bare `float i;`, the exact
// uninitialised-read UB that WebGL/ANGLE zero-inits. Backstop it: give
// every bare local declaration inside a function body a `= {}` initialiser.
// Struct members look identical, so skip them by tracking brace scope (SPIRV-
// Cross emits all structs before any function and puts braces on their own
// lines). Matrices are excluded from the pattern (their zero-init is handled and
// `{}` on a matrix is dicey).
static NSString *KKZeroInitLocals(NSString *msl) {
  static NSRegularExpression *decl;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    decl = [NSRegularExpression
        regularExpressionWithPattern:@"^(\\s+)(bool|u?char|u?short|u?int|float|"
                                     @"half)([234])?\\s+(\\w+);\\s*$"
                             options:0
                               error:nil];
  });
  NSArray<NSString *> *lines = [msl componentsSeparatedByString:@"\n"];
  NSMutableArray<NSString *> *out =
      [NSMutableArray arrayWithCapacity:lines.count];
  NSMutableArray<NSNumber *> *structStack = [NSMutableArray array];
  BOOL pendingStruct = NO;
  for (NSString *line in lines) {
    NSString *trimmed = [line
        stringByTrimmingCharactersInSet:[NSCharacterSet
                                            whitespaceCharacterSet]];
    if ([trimmed hasPrefix:@"struct"])
      pendingStruct = YES;
    BOOL inStruct = structStack.count && structStack.lastObject.boolValue;
    NSString *emit = line;
    if (structStack.count && !inStruct) {
      NSRange r = NSMakeRange(0, line.length);
      if ([decl firstMatchInString:line options:0 range:r])
        emit = [decl stringByReplacingMatchesInString:line
                                              options:0
                                                range:r
                                         withTemplate:@"$1$2$3 $4 = {};"];
    }
    [out addObject:emit];
    for (NSUInteger k = 0; k < trimmed.length; k++) {
      unichar c = [trimmed characterAtIndex:k];
      if (c == '{') {
        [structStack addObject:@(pendingStruct)];
        pendingStruct = NO;
      } else if (c == '}' && structStack.count) {
        [structStack removeLastObject];
      }
    }
  }
  return [out componentsJoinedByString:@"\n"];
}

// Blank out `//` and block comments, keeping the string the same length so any
// caller that also cares about offsets stays aligned. Only for TEXT SCANS that
// ask "does this shader really do X" - a mention in prose is not a use.
static NSString *KKBlankComments(NSString *src) {
  NSMutableString *out = [src mutableCopy];
  NSUInteger n = out.length;
  BOOL line = NO, block = NO;
  for (NSUInteger i = 0; i < n; i++) {
    unichar c = [out characterAtIndex:i];
    unichar d = (i + 1 < n) ? [out characterAtIndex:i + 1] : 0;
    if (line) {
      if (c == '\n') { line = NO; continue; }
    } else if (block) {
      if (c == '*' && d == '/') {
        [out replaceCharactersInRange:NSMakeRange(i, 2) withString:@"  "];
        i++;
        block = NO;
        continue;
      }
    } else if (c == '/' && d == '/') {
      line = YES;
    } else if (c == '/' && d == '*') {
      block = YES;
    } else {
      continue;
    }
    if (c != '\n')
      [out replaceCharactersInRange:NSMakeRange(i, 1) withString:@" "];
  }
  return out;
}

// Which iChannels the USER's source references (before wrapping widens it).
//
// Comments are blanked first. A shader that only NAMES a channel in prose
// ("never samples iChannel0") does not use it, and counting that as a use
// turned off the alpha-composite path - the shader's own alpha was then
// discarded by the opaque image convention and the whole frame rendered as its
// flat colour. It also left the sampler declared but unreferenced, which the
// compiler strips, which used to corrupt GPU memory at bind time.
static NSUInteger KKChannelMask(NSString *src) {
  NSString *code = KKBlankComments(src);
  NSUInteger mask = 0;
  for (NSUInteger ch = 0; ch < 4; ch++) {
    NSString *tok = [NSString stringWithFormat:@"iChannel%lu", (unsigned long)ch];
    if ([code rangeOfString:tok].location != NSNotFound)
      mask |= (1u << ch);
  }
  return mask;
}

static KKGLSLTranspileResult *KKTranspileUncached(NSString *userGLSL,
                                                  KKGLSLPassKind pass);

// An editing session churns many one-off shader variants; past this many
// distinct sources the least-recently-used transpile is dropped.
#define KK_TRANSPILE_CACHE_CAP 64

// Memoise by full source: the MSL, entry names and channel bindings are
// device-independent, so both the main render and the mini-viewer share one
// cache and a given shader is transpiled once. The key is the source string
// itself (not its hash - lookups compare contents, so a collision can't
// return another shader's MSL), bounded LRU.
static KKGLSLTranspileResult *KKTranspileMemoized(NSString *userGLSL,
                                                  KKGLSLPassKind pass) {
  static NSMutableDictionary<NSString *, KKGLSLTranspileResult *> *cache;
  static NSMutableOrderedSet<NSString *> *recency;
  static NSLock *cacheLock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cache = [NSMutableDictionary dictionary];
    recency = [NSMutableOrderedSet orderedSet];
    cacheLock = [NSLock new];
  });
  NSString *key = [(pass == KKGLSLPassBuffer ? @"b|" : @"i|")
      stringByAppendingString:userGLSL];
  [cacheLock lock];
  KKGLSLTranspileResult *hit = cache[key];
  if (hit) {
    [recency removeObject:key];
    [recency addObject:key];
  }
  [cacheLock unlock];
  if (hit)
    return hit;
  KKGLSLTranspileResult *r = KKTranspileUncached(userGLSL, pass);
  [cacheLock lock];
  cache[key] = r;
  [recency removeObject:key];
  [recency addObject:key];
  while (recency.count > KK_TRANSPILE_CACHE_CAP) {
    [cache removeObjectForKey:recency.firstObject];
    [recency removeObjectAtIndex:0];
  }
  [cacheLock unlock];
  return r;
}

KKGLSLTranspileResult *KKTranspileGLSL(NSString *userGLSL) {
  return KKTranspileMemoized(userGLSL, KKGLSLPassImage);
}

KKGLSLTranspileResult *KKTranspileGLSLBuffer(NSString *userGLSL) {
  return KKTranspileMemoized(userGLSL, KKGLSLPassBuffer);
}


// Run the dialect shims, then wrap. Fills in the result's shim/channel/line
// metadata and returns the core-450 GLSL glslang parses.
static NSString *KKPrepareGLSL(NSString *userGLSL, KKGLSLPassKind pass,
                               KKGLSLTranspileResult *result) {
  BOOL hadMainImage =
      [userGLSL rangeOfString:@"mainImage"].location != NSNotFound;
  // Before the raw-GL shim: this one SUPPLIES mainImage, which is exactly the
  // condition KKShimRawGLSL bails on, so it then correctly leaves us alone.
  BOOL glTransition = KKLooksLikeGLTransition(userGLSL);
  NSString *shimmed = KKShimGLTransition(userGLSL); // gl-transitions -> image
  shimmed = KKShimRawGLSL(shimmed);                 // raw-GL -> image
  result.shimmedFromRawGL =
      !hadMainImage && !glTransition &&
      [shimmed rangeOfString:@"mainImage"].location != NSNotFound;

  NSUInteger channelMask = KKChannelMask(shimmed);
  // A GL transition names its sources getFromColor/getToColor and never writes
  // `iChannel` anywhere, so the scan returns 0 and BOTH clips would go unbound.
  // Force the two it always samples.
  if (glTransition)
    channelMask |= 0x3u;
  result.declaredChannelMask = KKDeclaredChannelMask(channelMask, pass);
  // `// #frames`: the wrapper declares one neighbour sampler per offset, on the
  // Image pass only. Recorded from the DIRECTIVE, not from reflection, so the
  // render knows how many frames to schedule even when the shader never samples
  // one (and SPIRV-Cross therefore strips its binding).
  result.neighborCount = (pass == KKGLSLPassImage)
                             ? MirageFrameOffsetCountForSource(shimmed)
                             : 0;

  NSInteger lineOffset = 0;
  NSString *glsl = KKWrapGLSL(shimmed, channelMask, &lineOffset, pass);
  result.userLineOffset = lineOffset;
  return glsl;
}

// Reflect the fragment entry name and each channel's MSL texture/sampler index.
static void KKReflectBindings(spvc_compiler compiler,
                              KKGLSLTranspileResult *result) {
  const char *cleansed = spvc_compiler_get_cleansed_entry_point_name(
      compiler, "main", SpvExecutionModelFragment);
  if (cleansed)
    result.fragmentName = @(cleansed);

  spvc_resources resources = nullptr;
  if (spvc_compiler_create_shader_resources(compiler, &resources) != SPVC_SUCCESS)
    return;
  const spvc_reflected_resource *list = nullptr;
  size_t count = 0;
  spvc_resources_get_resource_list_for_type(
      resources, SPVC_RESOURCE_TYPE_SAMPLED_IMAGE, &list, &count);
  for (size_t i = 0; i < count; i++) {
    NSString *name = @(list[i].name);
    NSInteger channel = -1, neighbor = -1;
    for (NSUInteger ch = 0; ch < 4; ch++)
      if ([name isEqualToString:[NSString stringWithFormat:@"iChannel%lu",
                                                           (unsigned long)ch]])
        channel = (NSInteger)ch;
    for (NSUInteger n = 0; channel < 0 && n < KK_SHADER_MAX_FRAME_OFFSETS; n++)
      if ([name isEqualToString:[NSString stringWithFormat:@"iNeighbor%lu",
                                                           (unsigned long)n]])
        neighbor = (NSInteger)n;
    if (channel < 0 && neighbor < 0)
      continue;

    unsigned t =
        spvc_compiler_msl_get_automatic_resource_binding(compiler, list[i].id);
    unsigned sm = spvc_compiler_msl_get_automatic_resource_binding_secondary(
        compiler, list[i].id);
    // SPIRV-Cross returns uint32_t(-1) when a resource got NO automatic
    // binding - it was declared but never referenced, so the compiler
    // dropped it. Recording that verbatim made it a real-looking index
    // (4294967295) that passed every NSNotFound guard downstream and
    // reached setFragmentTexture:atIndex:, which writes far outside the
    // argument table and corrupts GPU memory. The fault then surfaces at
    // some LATER, unrelated Metal call, which is what makes it so hard to
    // place. A stripped channel is simply unused - record it as such.
    static const unsigned kNoBinding = 0xFFFFFFFFu;
    if (t == kNoBinding && sm == kNoBinding)
      continue;
    NSInteger texIdx = (t == kNoBinding ? NSNotFound : (NSInteger)t);
    NSInteger sampIdx = (sm == kNoBinding ? NSNotFound : (NSInteger)sm);
    if (channel >= 0)
      [result setTexture:texIdx sampler:sampIdx forChannel:(NSUInteger)channel];
    else
      [result setTexture:texIdx
                 sampler:sampIdx
             forNeighbor:(NSUInteger)neighbor];
  }
}

// GLSL -> SPIR-V. Returns NO with result.errorLog set on a parse/link failure.
static BOOL KKCompileToSPIRV(const std::string &glslStr,
                             std::vector<unsigned int> &spirv,
                             KKGLSLTranspileResult *result) {
  glslang_input_t input = {};
  input.language = GLSLANG_SOURCE_GLSL;
  input.stage = GLSLANG_STAGE_FRAGMENT;
  input.client = GLSLANG_CLIENT_VULKAN;
  input.client_version = GLSLANG_TARGET_VULKAN_1_0;
  input.target_language = GLSLANG_TARGET_SPV;
  input.target_language_version = GLSLANG_TARGET_SPV_1_0;
  input.code = glslStr.c_str();
  input.default_version = 450;
  input.default_profile = GLSLANG_CORE_PROFILE;
  input.force_default_version_and_profile = 1;
  input.forward_compatible = 0;
  input.messages =
      (glslang_messages_t)(GLSLANG_MSG_SPV_RULES_BIT | GLSLANG_MSG_VULKAN_RULES_BIT);
  input.resource = glslang_default_resource();

  glslang_shader_t *shader = glslang_shader_create(&input);
  if (!glslang_shader_preprocess(shader, &input) ||
      !glslang_shader_parse(shader, &input)) {
    result.errorLog =
        [NSString stringWithFormat:@"%s\n%s",
                                   glslang_shader_get_info_log(shader),
                                   glslang_shader_get_info_debug_log(shader)];
    glslang_shader_delete(shader);
    return NO;
  }
  glslang_program_t *program = glslang_program_create();
  glslang_program_add_shader(program, shader);
  if (!glslang_program_link(program, GLSLANG_MSG_SPV_RULES_BIT |
                                         GLSLANG_MSG_VULKAN_RULES_BIT)) {
    result.errorLog = @(glslang_program_get_info_log(program));
    glslang_program_delete(program);
    glslang_shader_delete(shader);
    return NO;
  }
  glslang_program_SPIRV_generate(program, GLSLANG_STAGE_FRAGMENT);
  size_t words = glslang_program_SPIRV_get_size(program);
  spirv.resize(words);
  glslang_program_SPIRV_get(program, spirv.data());
  glslang_program_delete(program);
  glslang_shader_delete(shader);
  return YES;
}

// SPIR-V -> MSL. Fills result.msl + the reflected bindings, or result.errorLog.
static void KKCompileToMSL(const std::vector<unsigned int> &spirv,
                           KKGLSLTranspileResult *result) {
  spvc_context ctx = nullptr;
  spvc_context_create(&ctx);
  spvc_parsed_ir ir = nullptr;
  if (spvc_context_parse_spirv(ctx, spirv.data(), spirv.size(), &ir) !=
      SPVC_SUCCESS) {
    result.errorLog = @(spvc_context_get_last_error_string(ctx));
    spvc_context_destroy(ctx);
    return;
  }
  spvc_compiler compiler = nullptr;
  spvc_context_create_compiler(ctx, SPVC_BACKEND_MSL, ir,
                               SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &compiler);
  spvc_compiler_options options = nullptr;
  spvc_compiler_create_compiler_options(compiler, &options);
  spvc_compiler_options_set_uint(options, SPVC_COMPILER_OPTION_MSL_VERSION, 20300);
  spvc_compiler_options_set_uint(options, SPVC_COMPILER_OPTION_MSL_PLATFORM, 1);
  // Zero-initialise all locals, matching Chrome/ANGLE (WebGL).
  // A lot of golfed shaders rely on `float i;` starting at 0 (`for(O*=i; i<n;
  // i++)`); without this those read garbage and render differently per compile.
  spvc_compiler_options_set_uint(
      options, SPVC_COMPILER_OPTION_FORCE_ZERO_INITIALIZED_VARIABLES, 1);
  spvc_compiler_install_compiler_options(compiler, options);

  const char *msl = nullptr;
  if (spvc_compiler_compile(compiler, &msl) != SPVC_SUCCESS || !msl) {
    result.errorLog = @(spvc_context_get_last_error_string(ctx));
    spvc_context_destroy(ctx);
    return;
  }
  KKReflectBindings(compiler, result);
  result.msl = [KKZeroInitLocals(@(msl)) stringByAppendingString:kKKVertexMSL];
  spvc_context_destroy(ctx);
}

static KKGLSLTranspileResult *KKTranspileUncached(NSString *userGLSL,
                                                  KKGLSLPassKind pass) {
  static NSLock *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    glslang_initialize_process();
    lock = [NSLock new];
  });

  KKGLSLTranspileResult *result = [KKGLSLTranspileResult new];
  NSString *glsl = KKPrepareGLSL(userGLSL, pass, result);
  std::string glslStr = glsl.UTF8String;

  // glslang is process-global state, so the whole pipeline is serialised.
  [lock lock];
  std::vector<unsigned int> spirv;
  if (KKCompileToSPIRV(glslStr, spirv, result))
    KKCompileToMSL(spirv, result);
  [lock unlock];
  if (result.msl) {
    NSData *mslData = [result.msl dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char sha[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(mslData.bytes, (CC_LONG)mslData.length, sha);
    NSMutableString *hex = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; i++)
      [hex appendFormat:@"%02x", sha[i]];
    result.mslDigest = hex;
  }
  return result;
}
