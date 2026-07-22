/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKGLSLFormatter.h"

#import <KeyframelessKit/KKLog.h>

#include <cstdlib>
#include <cstring>

// astyle's library entry point (declared in astyle_main.h behind ASTYLE_LIB).
// The C ABI is stable, so we declare it here rather than put astyle's headers
// on the search path - the symbol lives in libkktranspiler.a. STDCALL is empty
// on macOS/clang.
extern "C" {
typedef void (*KKAStyleError)(int errorNumber, const char *errorMessage);
typedef char *(*KKAStyleAlloc)(unsigned long memoryNeeded);
char *AStyleMain(const char *pSourceIn, const char *pOptions,
                 KKAStyleError fpErrorHandler, KKAStyleAlloc fpMemoryAlloc);
}

// The SPIRV-Cross .clang-format, translated to astyle option names:
//   style=allman   -> BreakBeforeBraces: Allman (brace on its own line)
//   indent=tab=4   -> UseTab: ForIndentation, IndentWidth/TabWidth 4
//   pad-header     -> SpaceBeforeParens: ControlStatements ("if (")
//   pad-oper       -> spaces around binary operators (unary signs untouched)
//   unpad-paren    -> SpacesInParentheses: false ("(out vec4 O)")
//   squeeze-lines=1-> MaxEmptyLinesToKeep: 1
//   mode=c         -> C/C++ family (covers GLSL)
static const char *const kKKGLSLAStyleOptions =
    "style=allman\n"
    "indent=tab=4\n"
    "pad-header\n"
    "pad-oper\n"
    "unpad-paren\n"
    "squeeze-lines=1\n"
    "mode=c\n";

static void KKAStyleOnError(int errorNumber, const char *errorMessage) {
  KKLogWarn(@"GLSL format: astyle error %d: %s", errorNumber,
            errorMessage ? errorMessage : "(null)");
}

static char *KKAStyleOnAlloc(unsigned long memoryNeeded) {
  return static_cast<char *>(malloc(memoryNeeded));
}

static NSString *KKGLSLApplyPass(NSString *code, NSString *pattern,
                                 NSString *tmpl) {
  NSRegularExpression *re =
      [NSRegularExpression regularExpressionWithPattern:pattern
                                                options:0
                                                  error:nil];
  if (!re)
    return code;
  return [re stringByReplacingMatchesInString:code
                                      options:0
                                        range:NSMakeRange(0, code.length)
                                 withTemplate:tmpl];
}

// Redundant intra-line whitespace clean-up that astyle has no option for (its
// console-only squeeze-ws is compiled out of the library, and even it only
// collapses runs to a single space, never to zero before punctuation). Each
// regex is chosen to be safe against GLSL's ambiguous cases - line-leading
// indentation and the decimal point. Runs on CODE only; comments are passed
// through verbatim by the caller.
static NSString *KKGLSLNormalizeCode(NSString *code) {
  // Collapse a run of 2+ spaces/tabs after a token to a single space. The
  // leading `\S` means a token must precede the run, so line-leading
  // indentation (preceded by a newline) is never touched.
  code = KKGLSLApplyPass(code, @"(\\S)[ \\t]{2,}", @"$1 ");
  // Zero space before ';' or ',' (same `\S` guard).
  code = KKGLSLApplyPass(code, @"(\\S)[ \\t]+([;,])", @"$1$2");
  // Zero space around a member/swizzle dot (`iResolution.  y`, `a . b` ->
  // `iResolution.y`, `a.b`). A dot is member access only when a letter/
  // underscore follows it, so decimal points (`0.5`, `.25`, `2.`, `1. + 2.`)
  // are left untouched. The before-dot pass uses a lookahead so it never
  // consumes the dot, keeping chained access (`a . b . c`) correct.
  code = KKGLSLApplyPass(code, @"\\.[ \\t]+([A-Za-z_])", @".$1");
  code = KKGLSLApplyPass(code, @"([A-Za-z0-9_)\\]])[ \\t]+\\.(?=[A-Za-z_])",
                         @"$1.");
  // Zero space just inside subscript brackets (`w[ 1 ]` -> `w[1]`) - astyle's
  // pad-brackets options are console-only, like squeeze-ws. '[' and ']' are
  // unambiguous in GLSL (array subscript / size), so no guard is needed beyond
  // requiring a token on the inner side.
  code = KKGLSLApplyPass(code, @"\\[[ \\t]+(\\S)", @"[$1");
  code = KKGLSLApplyPass(code, @"(\\S)[ \\t]+\\]", @"$1]");
  return code;
}

// Split the source into alternating code / comment spans and normalize only the
// code, so a comment's internal spacing (and any `;` / `.` inside it) survives
// untouched. GLSL has no string literals, so `//` and `/* */` are the only
// spans to protect.
static NSString *KKGLSLTidyWhitespace(NSString *src) {
  NSUInteger n = src.length;
  if (n == 0)
    return src;
  unichar *buf = (unichar *)malloc(n * sizeof(unichar));
  [src getCharacters:buf range:NSMakeRange(0, n)];
  NSMutableString *out = [NSMutableString stringWithCapacity:n];
  NSUInteger seg = 0, i = 0; // seg = start of the current code span
  while (i < n) {
    unichar c = buf[i];
    unichar d = (i + 1 < n) ? buf[i + 1] : 0;
    if (c == '/' && d == '/') {
      [out appendString:KKGLSLNormalizeCode(
                            [src substringWithRange:NSMakeRange(seg, i - seg)])];
      NSUInteger cs = i;
      while (i < n && buf[i] != '\n')
        i++;
      [out appendString:[src substringWithRange:NSMakeRange(cs, i - cs)]];
      seg = i; // the newline belongs to the next code span
    } else if (c == '/' && d == '*') {
      [out appendString:KKGLSLNormalizeCode(
                            [src substringWithRange:NSMakeRange(seg, i - seg)])];
      NSUInteger cs = i;
      i += 2;
      while (i < n && !(buf[i - 1] == '*' && buf[i] == '/'))
        i++;
      if (i < n)
        i++; // include the closing '/'
      [out appendString:[src substringWithRange:NSMakeRange(cs, i - cs)]];
      seg = i;
    } else {
      i++;
    }
  }
  if (seg < n)
    [out appendString:KKGLSLNormalizeCode(
                          [src substringWithRange:NSMakeRange(seg, n - seg)])];
  free(buf);
  return out;
}

NSString *KKFormatGLSL(NSString *source) {
  if (source.length == 0)
    return source;
  const char *in = source.UTF8String;
  if (!in)
    return source;
  char *out =
      AStyleMain(in, kKKGLSLAStyleOptions, KKAStyleOnError, KKAStyleOnAlloc);
  if (!out) // astyle failed (it already logged via the error handler)
    return source;
  NSString *formatted = [NSString stringWithUTF8String:out];
  free(out);
  if (!formatted)
    return source;
  return KKGLSLTidyWhitespace(formatted);
}
