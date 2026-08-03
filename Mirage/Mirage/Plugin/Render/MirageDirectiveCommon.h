/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Shared plumbing for the `// #` directive parsers: attribute scraping, the
// uniform-name prettifier, and the always-present shared params (timing +
// grain). Every per-kind header below builds on this one.
#pragma once

#ifndef __METAL_VERSION__

#import <Foundation/Foundation.h>
#import <ctype.h>
#import <math.h>
#import <string.h>

#import "MirageTypes.h"

/// Every directive scan spells its name lookahead `(?![-\w:])` rather than
/// `(?![-\w])`: no directive's grammar puts a colon after its own name, and
/// prose does it constantly. A comment opening "// #gradient: nAt() returns the
/// colour at t" used to parse as a real `#gradient` and bind the next uniform
/// it found, so a line ABOUT a directive quietly became one. Rejecting the
/// colon costs nothing a real directive can spell and takes the whole class of
/// mistake off the table.
///
/// Shared timing defaults.
#define KK_SHADER_GRAD_DEFAULT_SPEED 1.0f // time multiplier (1 = source rate)
#define KK_SHADER_GRAD_DEFAULT_SEED 0.0f

/// Film-grain overlay (MirageCommonUniforms). These are the values the LANES
/// start at once a shader opts in with `// #grain`: a subtle nonzero amount
/// that reads as tasteful and also breaks up 8-bit banding. A shader that never
/// asks for grain renders with none at all (see MirageCommonDefault), so this
/// is a starting point rather than a baseline.
#define KK_CORE_GRAIN_DEFAULT 0.06f    // amount (0..1)
#define KK_CORE_GRAINSIZE_DEFAULT 2.0f // grain cell size in whole pixels

static inline int MirageAttrInt(NSString *s, NSString *pattern, int fallback) {
  NSTextCheckingResult *m =
      [[NSRegularExpression regularExpressionWithPattern:pattern
                                                 options:0
                                                   error:nil]
          firstMatchInString:s
                     options:0
                       range:NSMakeRange(0, s.length)];
  if (!m || [m rangeAtIndex:1].location == NSNotFound)
    return fallback;
  return [s substringWithRange:[m rangeAtIndex:1]].intValue;
}

static inline double MirageAttrDouble(NSString *s, NSString *pattern,
                                      double fallback) {
  NSTextCheckingResult *m =
      [[NSRegularExpression regularExpressionWithPattern:pattern
                                                 options:0
                                                   error:nil]
          firstMatchInString:s
                     options:0
                       range:NSMakeRange(0, s.length)];
  if (!m || [m rangeAtIndex:1].location == NSNotFound)
    return fallback;
  return [s substringWithRange:[m rangeAtIndex:1]].doubleValue;
}

/// A quoted string attribute (`key="value"`), or nil when absent.
static inline NSString *MirageAttrString(NSString *s, NSString *key) {
  if (!s.length)
    return nil;
  NSString *pat =
      [NSString stringWithFormat:@"\\b%@\\s*=\\s*\"([^\"]*)\"", key];
  NSTextCheckingResult *m =
      [[NSRegularExpression regularExpressionWithPattern:pat
                                                 options:0
                                                   error:nil]
          firstMatchInString:s
                     options:0
                       range:NSMakeRange(0, s.length)];
  if (!m || [m rangeAtIndex:1].location == NSNotFound)
    return nil;
  return [s substringWithRange:[m rangeAtIndex:1]];
}

/// An UNQUOTED word attribute (`key=value`), or nil when absent. Hyphens count
/// as part of the value, so an enum like `space=linear-rec709` arrives whole
/// rather than truncated at the hyphen the way `\w+` would leave it.
static inline NSString *MirageAttrWord(NSString *s, NSString *key) {
  if (!s.length)
    return nil;
  NSString *pat =
      [NSString stringWithFormat:@"\\b%@\\s*=\\s*([A-Za-z0-9_][\\w-]*)", key];
  NSTextCheckingResult *m =
      [[NSRegularExpression regularExpressionWithPattern:pat
                                                 options:0
                                                   error:nil]
          firstMatchInString:s
                     options:0
                       range:NSMakeRange(0, s.length)];
  if (!m || [m rangeAtIndex:1].location == NSNotFound)
    return nil;
  return [s substringWithRange:[m rangeAtIndex:1]];
}

/// Whether `word` appears as a bare directive flag. Quoted attribute values are
/// ignored, so labels and option names cannot accidentally enable behaviour.
static inline BOOL MirageAttrHasBareFlag(NSString *attrs, NSString *word) {
  if (!attrs.length || !word.length)
    return NO;
  NSString *bare =
      [[NSRegularExpression regularExpressionWithPattern:@"\"[^\"]*\""
                                                 options:0
                                                   error:nil]
          stringByReplacingMatchesInString:attrs
                                   options:0
                                     range:NSMakeRange(0, attrs.length)
                              withTemplate:@""];
  NSString *pattern = [NSString
      stringWithFormat:@"\\b%@\\b",
                       [NSRegularExpression escapedPatternForString:word]];
  return [[NSRegularExpression regularExpressionWithPattern:pattern
                                                    options:0
                                                      error:nil]
             firstMatchInString:bare
                        options:0
                          range:NSMakeRange(0, bare.length)] != nil;
}

/// A readable display name for a GLSL uniform: drop a leading u/u_/i/i_ prefix,
/// split camelCase + underscores into words, capitalise. `uBackground` ->
/// "Background", `u_foreground_hue` -> "Foreground Hue".
static inline NSString *MiragePrettifyUniformName(NSString *name) {
  if (!name.length)
    return @"Color";
  NSString *base = name;
  if (name.length >= 2) {
    unichar c0 = [name characterAtIndex:0], c1 = [name characterAtIndex:1];
    BOOL upperNext = (c1 >= 'A' && c1 <= 'Z');
    if ((c0 == 'u' || c0 == 'i') && (upperNext || c1 == '_'))
      base = [name substringFromIndex:(c1 == '_' ? 2 : 1)];
  }
  base = [base stringByReplacingOccurrencesOfString:@"_" withString:@" "];
  NSMutableString *out = [NSMutableString string];
  for (NSUInteger i = 0; i < base.length; i++) {
    unichar c = [base characterAtIndex:i];
    if (i > 0 && c >= 'A' && c <= 'Z') {
      unichar p = [base characterAtIndex:i - 1];
      if (!(p >= 'A' && p <= 'Z') && p != ' ')
        [out appendString:@" "];
    }
    [out appendFormat:@"%C", c];
  }
  NSString *t = [out
      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if (!t.length)
    return @"Color";
  return [[[t substringToIndex:1] uppercaseString]
      stringByAppendingString:[t substringFromIndex:1]];
}

/// Where a control lands when its directive names no group. Free-form like
/// every other group name, so a shader writing `group={"Options"}` merges into
/// the same group rather than making a second one that looks identical.
static NSString *const kMirageDefaultGroup = @"Options";
static NSString *const kMirageDefaultGroupSymbol = @"slider.horizontal.3";

/// The groups that are not the shader's to name (the code editor and the
/// colour swatches; audio's lives in MirageAudioProps.h). These lead the
/// inspector in a fixed order, so editing directives never shuffles them.
static NSString *const kMirageShaderCategory = @"Shader";
static NSString *const kMirageColorCategory = @"Colors";

/// Parse a `name={"Display Name", "sf.symbol"}` attribute into its two parts.
/// Accepts the braced pair (the symbol is optional) and the bare
/// `name="Display Name"`. The quoted strings are pulled out in order rather
/// than split on commas, so a name may contain one. Absent attribute = both
/// buffers left as they were (the caller's default). `group=` and `puck=` share
/// this shape, so they share this parse.
///
/// The braced body is scanned as alternating plain text and WHOLE quoted
/// strings rather than as "everything up to the first `}`". A `{n}` slot
/// placeholder lives inside the quotes, so the naive scan stopped at the
/// placeholder's own brace and handed back an empty name and symbol - no
/// error, just a control that had quietly lost its puck.
static inline void MirageParseNamedPairAttr(NSString *attrs, NSString *key,
                                            char *outName, size_t nameSize,
                                            char *outSymbol,
                                            size_t symbolSize) {
  if (!attrs.length || !key.length)
    return;
  NSString *pattern = [NSString
      stringWithFormat:
          @"\\b%@\\s*=\\s*(\\{(?:[^{}\"]|\"[^\"]*\")*\\}|\"[^\"]*\")", key];
  NSTextCheckingResult *m =
      [[NSRegularExpression regularExpressionWithPattern:pattern
                                                 options:0
                                                   error:nil]
          firstMatchInString:attrs
                     options:0
                       range:NSMakeRange(0, attrs.length)];
  if (!m || [m rangeAtIndex:1].location == NSNotFound)
    return;
  NSString *body = [attrs substringWithRange:[m rangeAtIndex:1]];
  NSArray<NSTextCheckingResult *> *qs =
      [[NSRegularExpression regularExpressionWithPattern:@"\"([^\"]*)\""
                                                 options:0
                                                   error:nil]
          matchesInString:body
                  options:0
                    range:NSMakeRange(0, body.length)];
  for (int k = 0; k < 2 && k < (int)qs.count; k++) {
    NSString *t = [[body substringWithRange:[qs[k] rangeAtIndex:1]]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!t.length)
      continue;
    if (k == 0)
      strncpy(outName, t.UTF8String ?: "", nameSize - 1);
    else
      strncpy(outSymbol, t.UTF8String ?: "", symbolSize - 1);
  }
}

/// Whether `key=` is written at all, whatever shape its value takes. Quoted
/// values are stripped first, so a label mentioning another attribute does not
/// count as writing it. The question a validator asks that the parse above
/// cannot answer: a key present but unreadable and a key absent both leave the
/// caller's buffers alone, and only one of them is a mistake.
static inline BOOL MirageAttrHasKey(NSString *attrs, NSString *key) {
  if (!attrs.length || !key.length)
    return NO;
  NSString *bare =
      [[NSRegularExpression regularExpressionWithPattern:@"\"[^\"]*\""
                                                 options:0
                                                   error:nil]
          stringByReplacingMatchesInString:attrs
                                   options:0
                                     range:NSMakeRange(0, attrs.length)
                              withTemplate:@""];
  NSString *pattern = [NSString
      stringWithFormat:@"\\b%@\\s*=",
                       [NSRegularExpression escapedPatternForString:key]];
  return [[NSRegularExpression regularExpressionWithPattern:pattern
                                                    options:0
                                                      error:nil]
             firstMatchInString:bare
                        options:0
                          range:NSMakeRange(0, bare.length)] != nil;
}

/// The answers MirageAttrBool gives that are not a value: the key is not
/// written at all, or it is written with something that names neither state.
enum {
  kMirageAttrBoolAbsent = -1,
  kMirageAttrBoolInvalid = -2,
};

/// The literal text an attribute was written with, quoted or bare, or nil when
/// the key is absent. Sign-tolerant and hyphen-tolerant so the token arrives
/// whole - a validator has to see what the author actually typed to say why it
/// was rejected.
static inline NSString *MirageAttrRawValue(NSString *attrs, NSString *key) {
  if (!attrs.length || !key.length)
    return nil;
  NSString *quoted = MirageAttrString(attrs, key);
  if (quoted)
    return quoted;
  // The bare scan runs over the attributes with every quoted string removed,
  // so a label quoting `default=maybe` is text and not a value the way it is
  // for every other reader.
  NSString *bare =
      [[NSRegularExpression regularExpressionWithPattern:@"\"[^\"]*\""
                                                 options:0
                                                   error:nil]
          stringByReplacingMatchesInString:attrs
                                   options:0
                                     range:NSMakeRange(0, attrs.length)
                              withTemplate:@""];
  NSString *pat = [NSString
      stringWithFormat:@"\\b%@\\s*=\\s*([+-]?[A-Za-z0-9_][\\w.-]*)",
                       [NSRegularExpression escapedPatternForString:key]];
  NSTextCheckingResult *m =
      [[NSRegularExpression regularExpressionWithPattern:pat
                                                 options:0
                                                   error:nil]
          firstMatchInString:bare
                     options:0
                       range:NSMakeRange(0, bare.length)];
  if (!m || [m rangeAtIndex:1].location == NSNotFound)
    return nil;
  return [bare substringWithRange:[m rangeAtIndex:1]];
}

/// An on/off attribute as 1 or 0: `1`/`0`, `true`/`false`, `yes`/`no`,
/// `on`/`off`, in any case and quoted or bare. kMirageAttrBoolAbsent when the
/// key isn't written, kMirageAttrBoolInvalid when it is written with a word
/// that names neither state.
///
/// One reader for every on/off attribute, because the states have to agree
/// wherever they are read. A digits-only read of `default=true` matched
/// nothing, fell back to 0, and left a switch the author had written as ON
/// silently OFF with nothing to explain it.
static inline int MirageAttrBool(NSString *attrs, NSString *key) {
  NSString *raw = MirageAttrRawValue(attrs, key);
  if (!raw)
    return MirageAttrHasKey(attrs, key) ? kMirageAttrBoolInvalid
                                        : kMirageAttrBoolAbsent;
  NSString *v = [[raw
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
      lowercaseString];
  if ([v isEqualToString:@"1"] || [v isEqualToString:@"true"] ||
      [v isEqualToString:@"yes"] || [v isEqualToString:@"on"])
    return 1;
  if ([v isEqualToString:@"0"] || [v isEqualToString:@"false"] ||
      [v isEqualToString:@"no"] || [v isEqualToString:@"off"])
    return 0;
  // Any other whole number still reads as on/off the way it always did, so a
  // shader written against the numeric spelling keeps its answer.
  NSScanner *scanner = [NSScanner scannerWithString:v];
  int number = 0;
  if ([scanner scanInt:&number] && scanner.atEnd)
    return number != 0;
  return kMirageAttrBoolInvalid;
}

static inline void MirageParseGroupAttr(NSString *attrs, char *outGroup,
                                        size_t groupSize, char *outSymbol,
                                        size_t symbolSize) {
  MirageParseNamedPairAttr(attrs, @"group", outGroup, groupSize, outSymbol,
                           symbolSize);
}

/// Fallback shared-params block (timing + grain). `origin`/`scale`/`rotation`
/// are vestigial identity values (the legacy transform lanes are gone).
static inline MirageCommonUniforms MirageCommonDefault(void) {
  MirageCommonUniforms c;
  memset(&c, 0, sizeof(c));
  c.origin = (vector_float2){0.5f, 0.5f};
  c.scale = (vector_float2){1.0f, 1.0f};
  c.rotation = 0.0f;
  c.time = 0.0f;
  c.speed = KK_SHADER_GRAD_DEFAULT_SPEED;
  c.seed = 0.0f;
  // NEUTRAL, not the lane default: these are what a shader that declared no
  // `// #grain` renders with, and an opt-in control that still applied when
  // nobody opted in would not be one.
  c.grain = 0.0f;
  c.grainSize = KK_CORE_GRAINSIZE_DEFAULT;
  c.grainScale = 1.0f;
  c.resolution = (vector_float2){1920.0f, 1080.0f};
  return c;
}

#endif // __METAL_VERSION__
