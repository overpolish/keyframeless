/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Does a `#slots` shader still fit the render pool once its groups are FULL?
//
// The plain control count answers the question for a shader whose controls are
// all written out: one directive, one pool slot. A slot group breaks that -
// each of its controls is a prototype that becomes `max=` real controls the
// moment the user presses "+", and the pool is a fixed array the render fills
// from lane keys.
//
// So the budget is conservative on purpose: a group is counted at its CEILING,
// not at whatever the current project happens to have stamped. The alternative
// is a shader that validates clean, works for three instances, and silently
// drops the fourth - which is the exact failure the control-count check exists
// to prevent, arriving later and looking like a bug in the plus button.
//
// The other half of the same question is WHICH KINDS the pool can repeat at
// all, which is the check below the budget: a control the pool cannot array is
// one shared value however many instances there are, and that failure is
// silent too.
#pragma once

#ifndef __METAL_VERSION__

#import <Foundation/Foundation.h>

#import "MirageColorProps.h"  // KK_SHADER_MAX_COLOR_PROPS
#import "MirageScalarKinds.h" // the scalar directive keywords
#import "MirageScalarProps.h" // KK_SHADER_MAX_SCALAR_PROPS
#import "MirageSlots.h"       // the declared groups and their ceilings

/// Which pool a source overflows, so the caller can name it.
typedef NS_ENUM(NSInteger, MirageSlotBudgetKind) {
  MirageSlotBudgetKindNone = 0,
  /// `#float`, `#choice`, `#point` and friends: the scalar pool.
  MirageSlotBudgetKindScalar,
  /// `#color`: the colour-property pool, which is counted separately because
  /// the render fills it from its own array.
  MirageSlotBudgetKindColor,
};

/// The scalar and colour controls `source` asks for with every group full.
/// Returns the pool it overflows, or None when it fits.
///
/// Counted from the DIRECTIVES rather than from the parsed model: the model
/// stops at the pool ceiling by construction (that is what its truncation flag
/// reports), so asking it how far past the ceiling a source went is asking a
/// question it has already thrown the answer away for.
static inline MirageSlotBudgetKind
MirageSlotsControlBudget(NSString *source, int *outScalars, int *outColors) {
  int scalars = 0, colors = 0;
  if (outScalars)
    *outScalars = 0;
  if (outColors)
    *outColors = 0;
  if (!source.length)
    return MirageSlotBudgetKindNone;
  NSArray<NSValue *> *groups = MirageSlotGroupsForSource(source, NULL, NULL);
  // A shader with no group asks for exactly what it writes, which the parsed
  // model already reports by truncating. Leaving it to that check keeps every
  // template written before `#slots` existed answering to the same rule, and
  // to the same wording.
  if (!groups.count)
    return MirageSlotBudgetKindNone;
  for (NSTextCheckingResult *dm in MirageSlotsDirectiveMatches(source)) {
    NSString *keyword = [source substringWithRange:[dm rangeAtIndex:1]];
    // A control inside a group is worth its group's ceiling, one outside is
    // worth itself.
    int weight = 1;
    NSInteger gi = MirageSlotGroupIndexForLocation(groups, dm.range.location);
    if (gi >= 0)
      weight = MirageSlotsGroupValue(groups[(NSUInteger)gi]).maxCount;
    if ([keyword isEqualToString:@"color"]) {
      colors += weight;
      continue;
    }
    if (MirageSlotsIsControlKeyword(keyword) &&
        ![keyword isEqualToString:@"gradient"] &&
        ![keyword isEqualToString:@"audio"])
      scalars += weight;
  }
  if (outScalars)
    *outScalars = scalars;
  if (outColors)
    *outColors = colors;
  if (scalars > KK_SHADER_MAX_SCALAR_PROPS)
    return MirageSlotBudgetKindScalar;
  if (colors > KK_SHADER_MAX_COLOR_PROPS)
    return MirageSlotBudgetKindColor;
  return MirageSlotBudgetKindNone;
}

/// A control kind that cannot be repeated, for the message.
typedef NS_ENUM(NSInteger, MirageSlotRepeatKind) {
  MirageSlotRepeatKindNone = 0,
  MirageSlotRepeatKindGradient,
  MirageSlotRepeatKindAudio,
  /// A `#color` that is already an array (`uniform vec4 uPalette[8]`, or the
  /// `count=` / `optionsby=` forms that imply one).
  MirageSlotRepeatKindColorArray,
};

/// The first control inside a `#slots` block whose kind the pool cannot repeat,
/// named the way the other slot errors name one, or nil when every control in
/// every block can be instanced.
///
/// A ramp, an audio binding and an already-arrayed colour each occupy the pool
/// as ONE thing with an internal shape of their own, so a second instance of
/// one has nowhere to go: the render would read a single shared ramp while the
/// inspector showed a row per instance, each editing the same value. Silent,
/// and exactly the kind of wrongness that only shows up once someone has
/// keyframed against it - so it is a hard error at the point of writing
/// instead.
static inline NSString *
MirageFirstUnrepeatableSlotControl(NSString *source,
                                   MirageSlotRepeatKind *outKind) {
  if (outKind)
    *outKind = MirageSlotRepeatKindNone;
  if (!source.length)
    return nil;
  NSArray<NSValue *> *groups = MirageSlotGroupsForSource(source, NULL, NULL);
  if (!groups.count)
    return nil;
  static NSRegularExpression *arrayRe;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // A colour ARRAY is one declared with a length. The bracket is the whole
    // test: it is how every other reader of `#color` decides the same thing.
    arrayRe = [NSRegularExpression
        regularExpressionWithPattern:@"\\buniform\\s+vec4\\s+\\w+\\s*\\["
                             options:0
                               error:nil];
  });
  NSArray<NSTextCheckingResult *> *dirs = MirageSlotsDirectiveMatches(source);
  for (NSUInteger i = 0; i < dirs.count; i++) {
    NSTextCheckingResult *dm = dirs[i];
    if (MirageSlotGroupIndexForLocation(groups, dm.range.location) < 0)
      continue;
    NSString *keyword = [source substringWithRange:[dm rangeAtIndex:1]];
    NSString *attrs = [source substringWithRange:[dm rangeAtIndex:2]];
    NSUInteger after = NSMaxRange(dm.range);
    NSUInteger limit =
        (i + 1 < dirs.count) ? dirs[i + 1].range.location : source.length;
    MirageSlotRepeatKind kind = MirageSlotRepeatKindNone;
    if ([keyword isEqualToString:@"gradient"]) {
      kind = MirageSlotRepeatKindGradient;
    } else if ([keyword isEqualToString:@"audio"]) {
      kind = MirageSlotRepeatKindAudio;
    } else if ([keyword isEqualToString:@"color"]) {
      BOOL arrayed =
          [arrayRe firstMatchInString:source
                              options:0
                                range:NSMakeRange(after, limit - after)] != nil;
      // `count=` and `optionsby=` only mean anything on an array, so either one
      // is the author saying the same thing in the directive.
      if (!arrayed &&
          (MirageAttrString(attrs, @"optionsby").length ||
           MirageAttrInt(attrs, @"\\bcount\\s*=\\s*(\\d+)", -1) >= 0))
        arrayed = YES;
      if (arrayed)
        kind = MirageSlotRepeatKindColorArray;
    }
    if (kind == MirageSlotRepeatKindNone)
      continue;
    if (outKind)
      *outKind = kind;
    return MirageSlotsControlName(source, keyword, attrs, after, limit);
  }
  return nil;
}

#endif // __METAL_VERSION__
