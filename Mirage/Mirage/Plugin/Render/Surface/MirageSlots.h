/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// `// #slots name="Colour" max=8` ... `// #slots-end`: a group of controls the
// author declares ONCE and the user adds and removes instances of at runtime.
//
//     // #slots name="Colour" max=8 default=1 min=0
//     // #color label="New Colour {n}" puck={"Colour {n}", "{n}.circle"}
//     pick=hue uniform vec4 uNewColour;
//     // #slots-end
//
// The block is the unit. Everything between the two lines repeats together, so
// a slot is "another one of these", not "another one of that control" - which
// is what lets a slot carry a swatch, its strength and its own puck as one
// thing the user thinks of as one thing.
//
// `{n}` is the instance number, and inside a block it is REQUIRED wherever a
// control is named: two instances whose rows both read "New Colour" are two
// rows the user cannot tell apart, and two pucks with one name are one puck.
// Outside a block it means nothing, so it is rejected rather than left to
// render literally in the inspector.
//
// This is the grammar half only: parse, validate, and expose what was
// declared. The transpiler turns each declared uniform into an array and
// injects the count (see the uniform contract in directives.md), the panel adds
// and removes instances, and the lane catalog stamps a lane set per instance -
// none of which this header knows about.
#pragma once

#ifndef __METAL_VERSION__

#import <Foundation/Foundation.h>
#import <limits.h>

#import "MirageDirectiveCommon.h" // MirageAttrString, MirageParseNamedPairAttr
#import "MirageScalarKinds.h"     // the scalar directive keywords

/// Ceiling on `max=`. Every instance is a live lane set and a slice of the
/// finite render pool, so this is a budget rather than a syntax limit: a shader
/// asking for 32 colours would compile and then quietly lose the last of them.
#define KK_SHADER_MAX_SLOT_INSTANCES 16

/// Longest `name=`. It is a display name AND part of every lane key the group
/// stamps, so it stays short enough to read in a row header.
#define KK_SHADER_MAX_SLOT_NAME 40

typedef NS_ENUM(NSInteger, MirageSlotsDirectiveError) {
  MirageSlotsDirectiveErrorNone = 0,
  /// A `#slots` with no `#slots-end` after it.
  MirageSlotsDirectiveErrorUnclosed,
  /// A `#slots-end` with no open block.
  MirageSlotsDirectiveErrorUnopened,
  /// A `#slots` inside a block. Nesting would make an instance count a product
  /// of two counts, and there is no lane key that reads sensibly for it.
  MirageSlotsDirectiveErrorNested,
  /// Missing `name=`, or one outside the letters/digits/spaces the lane keys
  /// can carry.
  MirageSlotsDirectiveErrorName,
  /// Two groups sharing a name. The name IS how an instance is addressed, so
  /// two of them is two groups the user cannot tell apart.
  MirageSlotsDirectiveErrorDuplicateName,
  /// Missing `max=`, or one outside 1..KK_SHADER_MAX_SLOT_INSTANCES.
  MirageSlotsDirectiveErrorMax,
  /// `default=` or `min=` outside 0..max, or a `default=` below `min=`.
  MirageSlotsDirectiveErrorCount,
  /// A control inside a block whose `label=` (or `puck=` name) has no `{n}`.
  MirageSlotsDirectiveErrorPlaceholder,
  /// A control inside a block that writes `puck=` but whose name comes out
  /// empty. An unnamed puck passes the `{n}` check by being empty rather than
  /// by being distinct, so every instance would share one handle - the exact
  /// silent collapse the placeholder rule exists to stop.
  MirageSlotsDirectiveErrorPuckName,
  /// A `{n}` on a directive outside every block, where there is no instance
  /// number to put there.
  MirageSlotsDirectiveErrorStrayPlaceholder,
};

/// One declared group. `bodyRange` is exactly what repeats: everything between
/// the two directive lines, which is how a caller asks whether a control it
/// already parsed belongs to this group without a second control model.
typedef struct MirageSlotsGroup {
  char name[KK_SHADER_MAX_SLOT_NAME + 8];
  /// Hard ceiling on instances, 1..KK_SHADER_MAX_SLOT_INSTANCES.
  int maxCount;
  /// Instances a fresh apply starts with, 0..max (1 when `default=` is absent).
  int defaultCount;
  /// Instances the panel refuses to delete below, 0..max (0 by default).
  int minCount;
  /// The whole block, both directive lines included.
  NSRange range;
  /// Just the controls, between the two directive lines.
  NSRange bodyRange;
} MirageSlotsGroup;

/// Unbox a group from the array below.
static inline MirageSlotsGroup MirageSlotsGroupValue(NSValue *boxed) {
  MirageSlotsGroup g;
  memset(&g, 0, sizeof(g));
  if (boxed)
    [boxed getValue:&g];
  return g;
}

/// YES when `text` carries the instance placeholder. `{N}` is accepted beside
/// `{n}`: it is one placeholder with two spellings, and rejecting the shouted
/// one would be a validation error about capitalisation.
static inline BOOL MirageSlotsHasPlaceholder(NSString *text) {
  if (!text.length)
    return NO;
  return [text rangeOfString:@"{n}"].location != NSNotFound ||
         [text rangeOfString:@"{N}"].location != NSNotFound;
}

/// `text` with `{n}` replaced by `oneBased`. The number the user sees is
/// 1-based, because "Colour 0" is not a thing anybody says.
static inline NSString *MirageSlotsSubstitute(NSString *text, int oneBased) {
  if (!text.length)
    return text;
  NSString *number = [NSString stringWithFormat:@"%d", oneBased];
  NSString *out = [text stringByReplacingOccurrencesOfString:@"{n}"
                                                  withString:number];
  return [out stringByReplacingOccurrencesOfString:@"{N}" withString:number];
}

/// The `int` the transpiler injects for a group: how many instances are live
/// this frame. Derived from the group's name rather than from any one uniform,
/// because the count belongs to the BLOCK - every control in it appears and
/// disappears together - and a per-uniform count would let a shader read two
/// disagreeing answers to one question.
static inline NSString *MirageSlotsCountUniformName(const char *groupName) {
  NSString *name = groupName ? @(groupName) : @"";
  NSMutableString *out = [NSMutableString stringWithString:@"u"];
  BOOL upper = YES;
  for (NSUInteger i = 0; i < name.length; i++) {
    unichar c = [name characterAtIndex:i];
    BOOL alnum = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                 (c >= '0' && c <= '9');
    if (!alnum) {
      upper = YES;
      continue;
    }
    if (upper && c >= 'a' && c <= 'z')
      c = (unichar)(c - 'a' + 'A');
    [out appendFormat:@"%C", c];
    upper = NO;
  }
  [out appendString:@"Count"];
  return out;
}

/// Every `// #` directive in `source`, as `@[kind, attrs]` ranges. The one
/// scan the checks below share, so "what is a directive line" is answered once.
static inline NSArray<NSTextCheckingResult *> *
MirageSlotsDirectiveMatches(NSString *source) {
  static NSRegularExpression *dirRe;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dirRe = [NSRegularExpression
        regularExpressionWithPattern:@"(?m)^[ \\t]*//[ \\t]*#([A-Za-z_][\\w-]*)"
                                     @"([^\\n]*)$"
                             options:0
                               error:nil];
  });
  return [dirRe matchesInString:source
                        options:0
                          range:NSMakeRange(0, source.length)];
}

/// YES when `keyword` is a directive that declares a CONTROL (as opposed to the
/// whole-shader directives, which annotate nothing and repeat nothing). The
/// scalar kinds come from their own registry so a new one is covered here the
/// day it is added.
static inline BOOL MirageSlotsIsControlKeyword(NSString *keyword) {
  for (int i = 0; i < KK_MIRAGE_SCALAR_KIND_COUNT; i++)
    if ([keyword isEqualToString:@(kMirageScalarKinds[i].keyword)])
      return YES;
  return [keyword isEqualToString:@"color"] ||
         [keyword isEqualToString:@"gradient"] ||
         [keyword isEqualToString:@"audio"];
}

/// How a control inside a block is named in an error, best first: its label,
/// then the uniform under it, then its kind.
static inline NSString *
MirageSlotsControlName(NSString *source, NSString *keyword, NSString *attrs,
                       NSUInteger after, NSUInteger limit) {
  NSString *label = MirageAttrString(attrs, @"label");
  if (label.length)
    return label;
  NSRegularExpression *uniRe = [NSRegularExpression
      regularExpressionWithPattern:
          @"\\buniform\\s+(?:float|int|vec2|vec3|vec4|bool)\\s+(\\w+)"
                           options:0
                             error:nil];
  NSTextCheckingResult *um =
      [uniRe firstMatchInString:source
                        options:0
                          range:NSMakeRange(after, limit - after)];
  if (um)
    return [source substringWithRange:[um rangeAtIndex:1]];
  return [@"#" stringByAppendingString:keyword];
}

/// The groups `source` declares, in declaration order, each boxed as a
/// MirageSlotsGroup.
///
/// EMPTY on any error, the way `#frames` reports a malformed offset list: a
/// shader that fails validation still renders, and rendering half a repeatable
/// group - the first instance of one and none of the next - would be a worse
/// answer than rendering none of it. `outDetail` names whatever the error is
/// about (the group, or the control inside it), for the editor's message.
static inline NSArray<NSValue *> *
MirageSlotGroupsForSource(NSString *source, MirageSlotsDirectiveError *outError,
                          NSString **outDetail) {
  if (outError)
    *outError = MirageSlotsDirectiveErrorNone;
  if (outDetail)
    *outDetail = nil;
  NSMutableArray<NSValue *> *out = [NSMutableArray array];
  if (!source.length)
    return out;

  static NSRegularExpression *openRe;
  static NSRegularExpression *closeRe;
  static NSRegularExpression *nameRe;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    openRe = [NSRegularExpression
        regularExpressionWithPattern:@"(?m)^[ \\t]*//[ \\t]*#slots(?![-\\w])"
                                     @"([^\\n]*)$"
                             options:0
                               error:nil];
    closeRe =
        [NSRegularExpression regularExpressionWithPattern:
                                 @"(?m)^[ \\t]*//[ \\t]*#slots-end(?![-\\w])"
                                 @"[^\\n]*$"
                                                  options:0
                                                    error:nil];
    nameRe = [NSRegularExpression
        regularExpressionWithPattern:@"^[A-Za-z0-9][A-Za-z0-9 ._-]*$"
                             options:0
                               error:nil];
  });
  NSRange whole = NSMakeRange(0, source.length);
  NSArray<NSTextCheckingResult *> *opens = [openRe matchesInString:source
                                                           options:0
                                                             range:whole];
  NSArray<NSTextCheckingResult *> *closes = [closeRe matchesInString:source
                                                             options:0
                                                               range:whole];
  // The shape of every shader written before this existed: no block and no
  // placeholder to misplace, answered by a literal scan rather than by walking
  // its directives, since this runs on sources that will never declare either.
  if (!opens.count && !closes.count && !MirageSlotsHasPlaceholder(source))
    return out;

  // One walk over both lists in source order, so an unbalanced pair is caught
  // where it happens rather than by comparing two counts and guessing which
  // side is wrong.
  NSUInteger oi = 0, ci = 0;
  NSTextCheckingResult *pendingOpen = nil;
  NSMutableArray<NSValue *> *blocks = [NSMutableArray array];
  while (oi < opens.count || ci < closes.count) {
    BOOL takeOpen = ci >= closes.count ||
                    (oi < opens.count &&
                     opens[oi].range.location < closes[ci].range.location);
    if (takeOpen) {
      NSTextCheckingResult *m = opens[oi++];
      if (pendingOpen) {
        if (outError)
          *outError = MirageSlotsDirectiveErrorNested;
        if (outDetail)
          *outDetail = MirageAttrString(
              [source substringWithRange:[m rangeAtIndex:1]], @"name");
        return @[];
      }
      pendingOpen = m;
      continue;
    }
    NSTextCheckingResult *m = closes[ci++];
    if (!pendingOpen) {
      if (outError)
        *outError = MirageSlotsDirectiveErrorUnopened;
      return @[];
    }
    MirageSlotsGroup g;
    memset(&g, 0, sizeof(g));
    g.range = NSMakeRange(pendingOpen.range.location,
                          NSMaxRange(m.range) - pendingOpen.range.location);
    g.bodyRange = NSMakeRange(NSMaxRange(pendingOpen.range),
                              m.range.location - NSMaxRange(pendingOpen.range));
    NSString *attrs = [source substringWithRange:[pendingOpen rangeAtIndex:1]];
    NSString *name = [MirageAttrString(attrs, @"name")
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!name.length || name.length > KK_SHADER_MAX_SLOT_NAME ||
        ![nameRe firstMatchInString:name
                            options:0
                              range:NSMakeRange(0, name.length)]) {
      if (outError)
        *outError = MirageSlotsDirectiveErrorName;
      if (outDetail)
        *outDetail = name;
      return @[];
    }
    strncpy(g.name, name.UTF8String ?: "", sizeof(g.name) - 1);
    const int kAbsent = INT_MIN;
    int maxCount = MirageAttrInt(attrs, @"\\bmax\\s*=\\s*([-+]?\\d+)", kAbsent);
    if (maxCount == kAbsent || maxCount < 1 ||
        maxCount > KK_SHADER_MAX_SLOT_INSTANCES) {
      if (outError)
        *outError = MirageSlotsDirectiveErrorMax;
      if (outDetail)
        *outDetail = name;
      return @[];
    }
    g.maxCount = maxCount;
    int minCount = MirageAttrInt(attrs, @"\\bmin\\s*=\\s*([-+]?\\d+)", 0);
    int defaultCount =
        MirageAttrInt(attrs, @"\\bdefault\\s*=\\s*([-+]?\\d+)", 1);
    if (minCount < 0 || minCount > maxCount || defaultCount < 0 ||
        defaultCount > maxCount || defaultCount < minCount) {
      if (outError)
        *outError = MirageSlotsDirectiveErrorCount;
      if (outDetail)
        *outDetail = name;
      return @[];
    }
    g.minCount = minCount;
    g.defaultCount = defaultCount;
    for (NSValue *boxed in blocks) {
      MirageSlotsGroup other = MirageSlotsGroupValue(boxed);
      if ([@(other.name) caseInsensitiveCompare:name] == NSOrderedSame) {
        if (outError)
          *outError = MirageSlotsDirectiveErrorDuplicateName;
        if (outDetail)
          *outDetail = name;
        return @[];
      }
    }
    [blocks addObject:[NSValue valueWithBytes:&g
                                     objCType:@encode(MirageSlotsGroup)]];
    pendingOpen = nil;
  }
  if (pendingOpen) {
    if (outError)
      *outError = MirageSlotsDirectiveErrorUnclosed;
    if (outDetail)
      *outDetail = MirageAttrString(
          [source substringWithRange:[pendingOpen rangeAtIndex:1]], @"name");
    return @[];
  }

  // `{n}`, both ways round: required on every control INSIDE a block, and
  // meaningless outside every block.
  NSArray<NSTextCheckingResult *> *dirs = MirageSlotsDirectiveMatches(source);
  for (NSUInteger i = 0; i < dirs.count; i++) {
    NSTextCheckingResult *dm = dirs[i];
    NSString *keyword = [source substringWithRange:[dm rangeAtIndex:1]];
    NSString *attrs = [source substringWithRange:[dm rangeAtIndex:2]];
    if ([keyword isEqualToString:@"slots"] ||
        [keyword isEqualToString:@"slots-end"])
      continue;
    NSInteger inside = -1;
    for (NSUInteger b = 0; b < blocks.count; b++) {
      MirageSlotsGroup g = MirageSlotsGroupValue(blocks[b]);
      if (NSLocationInRange(dm.range.location, g.bodyRange))
        inside = (NSInteger)b;
    }
    if (inside < 0) {
      if (MirageSlotsHasPlaceholder(attrs)) {
        if (outError)
          *outError = MirageSlotsDirectiveErrorStrayPlaceholder;
        if (outDetail)
          *outDetail = [@"#" stringByAppendingString:keyword];
        return @[];
      }
      continue;
    }
    if (!MirageSlotsIsControlKeyword(keyword))
      continue;
    char puck[48] = {0}, puckSymbol[48] = {0};
    MirageParseNamedPairAttr(attrs, @"puck", puck, sizeof(puck), puckSymbol,
                             sizeof(puckSymbol));
    NSString *label = MirageAttrString(attrs, @"label");
    BOOL labelOK = MirageSlotsHasPlaceholder(label);
    BOOL puckWritten = MirageAttrHasKey(attrs, @"puck");
    BOOL puckNamed = puck[0] != 0;
    BOOL puckOK =
        !puckWritten || (puckNamed && MirageSlotsHasPlaceholder(@(puck)));
    if (labelOK && puckOK)
      continue;
    if (outError)
      *outError = (labelOK && puckWritten && !puckNamed)
                      ? MirageSlotsDirectiveErrorPuckName
                      : MirageSlotsDirectiveErrorPlaceholder;
    if (outDetail) {
      NSUInteger after = NSMaxRange(dm.range);
      NSUInteger limit =
          (i + 1 < dirs.count) ? dirs[i + 1].range.location : source.length;
      *outDetail = MirageSlotsControlName(source, keyword, attrs, after, limit);
    }
    return @[];
  }

  [out addObjectsFromArray:blocks];
  return out;
}

/// Which group a source location sits in, or -1 for one outside every block.
/// The membership question, asked the way an existing scanner already knows
/// where it is: by the range it matched.
static inline NSInteger
MirageSlotGroupIndexForLocation(NSArray<NSValue *> *groups,
                                NSUInteger location) {
  for (NSUInteger i = 0; i < groups.count; i++) {
    MirageSlotsGroup g = MirageSlotsGroupValue(groups[i]);
    if (NSLocationInRange(location, g.bodyRange))
      return (NSInteger)i;
  }
  return -1;
}

/// Each uniform declared inside a block, mapped to its group's index. The other
/// way to ask the membership question, for a caller holding a uniform name
/// rather than a range - which is most of them, since the uniform name is the
/// control's identity everywhere else.
static inline NSDictionary<NSString *, NSNumber *> *
MirageSlotGroupIndexByUniform(NSString *source) {
  NSMutableDictionary<NSString *, NSNumber *> *out =
      [NSMutableDictionary dictionary];
  NSArray<NSValue *> *groups = MirageSlotGroupsForSource(source, NULL, NULL);
  if (!groups.count)
    return out;
  NSRegularExpression *uniRe = [NSRegularExpression
      regularExpressionWithPattern:
          @"\\buniform\\s+(?:float|int|vec2|vec3|vec4|bool)\\s+(\\w+)"
                           options:0
                             error:nil];
  for (NSUInteger i = 0; i < groups.count; i++) {
    MirageSlotsGroup g = MirageSlotsGroupValue(groups[i]);
    for (NSTextCheckingResult *m in [uniRe matchesInString:source
                                                   options:0
                                                     range:g.bodyRange])
      out[[source substringWithRange:[m rangeAtIndex:1]]] = @(i);
  }
  return out;
}

/// What one uniform inherits from the block it sits in. The directive parsers
/// hold a uniform name and need three things at once - which group, how wide
/// its array is, and the group name their lane keys are built from - so they
/// ask once rather than cross-referencing two dictionaries.
typedef struct MirageSlotBinding {
  /// Index into the group array, and into the injected count members.
  int groupIndex;
  int maxCount;
  char groupName[KK_SHADER_MAX_SLOT_NAME + 8];
} MirageSlotBinding;

/// Every uniform declared inside a block, mapped to its binding. Empty for the
/// shape of every shader written before `#slots` existed, which is the case the
/// group scan short-circuits, so a legacy parse pays one literal search.
static inline NSDictionary<NSString *, NSValue *> *
MirageSlotBindingsByUniform(NSString *source) {
  NSMutableDictionary<NSString *, NSValue *> *out =
      [NSMutableDictionary dictionary];
  NSArray<NSValue *> *groups = MirageSlotGroupsForSource(source, NULL, NULL);
  if (!groups.count)
    return out;
  NSRegularExpression *uniRe = [NSRegularExpression
      regularExpressionWithPattern:
          @"\\buniform\\s+(?:float|int|vec2|vec3|vec4|bool)\\s+(\\w+)"
                           options:0
                             error:nil];
  for (NSUInteger i = 0; i < groups.count; i++) {
    MirageSlotsGroup g = MirageSlotsGroupValue(groups[i]);
    MirageSlotBinding b;
    memset(&b, 0, sizeof(b));
    b.groupIndex = (int)i;
    b.maxCount = g.maxCount;
    strncpy(b.groupName, g.name, sizeof(b.groupName) - 1);
    for (NSTextCheckingResult *m in [uniRe matchesInString:source
                                                   options:0
                                                     range:g.bodyRange])
      out[[source substringWithRange:[m rangeAtIndex:1]]] =
          [NSValue valueWithBytes:&b objCType:@encode(MirageSlotBinding)];
  }
  return out;
}

/// Unbox a binding, zeroed (groupIndex -1, maxCount 0) when the uniform is not
/// in any block - the answer most uniforms get.
static inline MirageSlotBinding MirageSlotBindingValue(NSValue *boxed) {
  MirageSlotBinding b;
  memset(&b, 0, sizeof(b));
  b.groupIndex = -1;
  if (boxed)
    [boxed getValue:&b];
  return b;
}

#endif // __METAL_VERSION__
