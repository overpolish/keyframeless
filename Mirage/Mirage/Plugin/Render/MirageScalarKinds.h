/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The scalar directive KIND registry. One row here declares a directive
// keyword and the flag template it stamps onto the parsed prop; the parse
// regex alternation is generated from the table. Every per-kind behaviour
// chain (defaults, lane build, #define emission, pool fill, OSC eligibility)
// dispatches on MirageScalarKind with a full `switch` and NO default case, so
// -Wswitch turns "I added a kind but missed a chain" into a compile warning
// at every site that still needs a branch.
#pragma once

#ifndef __METAL_VERSION__

#import <Foundation/Foundation.h>
#import <string.h>

typedef enum MirageScalarKind {
  MirageScalarKindFloat = 0,
  MirageScalarKindPercent,
  MirageScalarKindProgress,
  MirageScalarKindRandom,
  MirageScalarKindPoint,
  MirageScalarKindInt,
  MirageScalarKindAngle,
  MirageScalarKindBool,
  MirageScalarKindChoice,
  MirageScalarKindMulti,
} MirageScalarKind;

typedef struct MirageScalarKindSpec {
  MirageScalarKind kind;
  const char *keyword; // the token after "// #" in a directive comment
  // Flag template stamped onto the parsed prop. Composition (a #progress is a
  // percent field with a ramp default) is DATA here, not keyword checks in
  // the parser. A `#multi` may still upgrade isPercent/isInt from its own
  // attributes after stamping.
  int isChoice, isProgress, isPercent, isSeed, isPoint, isBool, isInt, isAngle,
      isMulti;
} MirageScalarKindSpec;

//                             kind                       keyword     cho prg
//                             pct sed pnt bool int ang mlt
static const MirageScalarKindSpec kMirageScalarKinds[] = {
    {MirageScalarKindFloat, "float", 0, 0, 0, 0, 0, 0, 0, 0, 0},
    {MirageScalarKindPercent, "percent", 0, 0, 1, 0, 0, 0, 0, 0, 0},
    {MirageScalarKindProgress, "progress", 0, 1, 1, 0, 0, 0, 0, 0, 0},
    {MirageScalarKindRandom, "random", 0, 0, 0, 1, 0, 0, 0, 0, 0},
    {MirageScalarKindPoint, "point", 0, 0, 0, 0, 1, 0, 0, 0, 0},
    {MirageScalarKindInt, "int", 0, 0, 0, 0, 0, 0, 1, 0, 0},
    {MirageScalarKindAngle, "angle", 0, 0, 0, 0, 0, 0, 0, 1, 0},
    {MirageScalarKindBool, "bool", 0, 0, 0, 0, 0, 1, 0, 0, 0},
    {MirageScalarKindChoice, "choice", 1, 0, 0, 0, 0, 0, 0, 0, 0},
    {MirageScalarKindMulti, "multi", 0, 0, 0, 0, 0, 0, 0, 0, 1},
};
#define KK_MIRAGE_SCALAR_KIND_COUNT                                            \
  ((int)(sizeof(kMirageScalarKinds) / sizeof(kMirageScalarKinds[0])))

/// The regex alternation ("float|percent|...") for the directive-comment
/// scanner, generated from the table so the parser can't miss a registered
/// kind. Longer keywords first is NOT needed: the pattern is bounded by \b.
static inline NSString *MirageScalarKindAlternation(void) {
  static NSString *alt;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableArray<NSString *> *kws = [NSMutableArray array];
    for (int i = 0; i < KK_MIRAGE_SCALAR_KIND_COUNT; i++)
      [kws addObject:@(kMirageScalarKinds[i].keyword)];
    alt = [kws componentsJoinedByString:@"|"];
  });
  return alt;
}

/// The registered spec for a matched keyword, or NULL when it isn't one
/// (cannot happen for a keyword the generated alternation matched).
static inline const MirageScalarKindSpec *
MirageScalarKindForKeyword(NSString *keyword) {
  const char *kw = keyword.UTF8String ?: "";
  for (int i = 0; i < KK_MIRAGE_SCALAR_KIND_COUNT; i++)
    if (strcmp(kMirageScalarKinds[i].keyword, kw) == 0)
      return &kMirageScalarKinds[i];
  return NULL;
}

#endif // __METAL_VERSION__
