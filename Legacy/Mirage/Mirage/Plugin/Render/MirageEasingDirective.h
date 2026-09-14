/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// `// #easing default="ease-in-out"` - the whole-shader directive a TRANSITION
// template uses to say which curve its Easing lane should start on. It stands
// alone like `#motionblur` / `#frames` and binds no uniform: the curve is
// applied HOST-SIDE, to the clip fraction, before it ever becomes iProgress.
// A template that declares nothing starts on Linear, which is the identity -
// so the directive only ever moves a template's STARTING POINT, never what the
// user can choose.
//
// The curve set is the timing engine's (KKEasingCurve), not a set of our own:
// the indices below ARE that enum's values and the lane's choice labels come
// from KKEasingCurveDisplayName. The indices are restated here rather than
// imported because this header is parsed by the directive harness, which
// compiles against Foundation alone; MirageLaneCatalog.h holds the static
// assertions that keep the two in step.

#ifndef __METAL_VERSION__

#import <Foundation/Foundation.h>

#import "MirageDirectiveCommon.h" // MirageAttrString

typedef NS_ENUM(NSInteger, MirageEasingDirectiveError) {
  MirageEasingDirectiveErrorNone = 0,
  /// More than one `#easing` line: which default wins would be positional, and
  /// a template's default is meant to be a single stated fact.
  MirageEasingDirectiveErrorMultiple,
  /// No `default=` attribute, or an empty one.
  MirageEasingDirectiveErrorMissing,
  /// A curve name the engine doesn't have.
  MirageEasingDirectiveErrorValue,
};

/// KKEasingCurve's values, restated (see the header note).
typedef NS_ENUM(NSInteger, MirageEasingCurve) {
  MirageEasingCurveLinear = 0,
  MirageEasingCurveEaseIn = 1,
  MirageEasingCurveEaseOut = 2,
  MirageEasingCurveEaseInOut = 3,
  MirageEasingCurveElastic = 4,
  MirageEasingCurveBounce = 5,
};

#define KK_SHADER_EASING_CURVE_COUNT 6

/// The canonical source spelling of a curve, for docs and error messages. The
/// parse accepts more than this (see MirageEasingCurveForToken); this is what
/// we write.
static inline NSString *MirageEasingCurveToken(NSInteger curve) {
  switch (curve) {
  case MirageEasingCurveLinear:
    return @"linear";
  case MirageEasingCurveEaseIn:
    return @"ease-in";
  case MirageEasingCurveEaseOut:
    return @"ease-out";
  case MirageEasingCurveEaseInOut:
    return @"ease-in-out";
  case MirageEasingCurveElastic:
    return @"elastic";
  case MirageEasingCurveBounce:
    return @"bounce";
  }
  return nil;
}

/// The curve a written name asks for, or -1 for a name the engine doesn't have.
/// Separators and case are ignored, so `ease-in-out`, `Ease In Out` and the
/// inspector's own "Ease In/Out" all name the same curve - an author reading
/// the menu and typing what they see gets the curve they read.
static inline NSInteger MirageEasingCurveForToken(NSString *token) {
  if (!token.length)
    return -1;
  NSMutableString *normalized =
      [[token lowercaseString] mutableCopy]; // separators are noise
  for (NSString *drop in @[ @" ", @"-", @"_", @"/", @"\t" ])
    [normalized replaceOccurrencesOfString:drop
                                withString:@""
                                   options:0
                                     range:NSMakeRange(0, normalized.length)];
  if ([normalized isEqualToString:@"linear"])
    return MirageEasingCurveLinear;
  if ([normalized isEqualToString:@"easein"])
    return MirageEasingCurveEaseIn;
  if ([normalized isEqualToString:@"easeout"])
    return MirageEasingCurveEaseOut;
  if ([normalized isEqualToString:@"easeinout"])
    return MirageEasingCurveEaseInOut;
  if ([normalized isEqualToString:@"elastic"])
    return MirageEasingCurveElastic;
  if ([normalized isEqualToString:@"bounce"])
    return MirageEasingCurveBounce;
  return -1;
}

/// The curve `source` wants its Easing lane to START on. Linear (the identity)
/// for a source that declares nothing AND for one whose directive is malformed
/// - a shader that fails validation still has to render, and rendering it on a
/// guessed curve would be worse than rendering it on the one that changes
/// nothing. `outError` tells the validator which message to show.
static inline NSInteger
MirageEasingDefaultCurveForSource(NSString *source,
                                  MirageEasingDirectiveError *outError) {
  if (outError)
    *outError = MirageEasingDirectiveErrorNone;
  if (!source.length)
    return MirageEasingCurveLinear;
  // Substring fast-reject before the regex, like every other whole-shader
  // directive: the lane catalog asks this per entry on every rebuild, and the
  // answer for almost every shader is "no such line".
  if ([source rangeOfString:@"#easing"].location == NSNotFound)
    return MirageEasingCurveLinear;

  static NSRegularExpression *expression;
  static dispatch_once_t onceEasing;
  dispatch_once(&onceEasing, ^{
    expression = [[NSRegularExpression alloc]
        initWithPattern:@"(?m)^[ \\t]*//[ \\t]*#easing(?![-\\w:])(.*)$"
                options:0
                  error:nil];
  });
  NSArray<NSTextCheckingResult *> *matches =
      [expression matchesInString:source
                          options:0
                            range:NSMakeRange(0, source.length)];
  if (matches.count == 0)
    return MirageEasingCurveLinear;
  if (matches.count != 1) {
    if (outError)
      *outError = MirageEasingDirectiveErrorMultiple;
    return MirageEasingCurveLinear;
  }

  NSString *attrs =
      [source substringWithRange:[matches.firstObject rangeAtIndex:1]];
  NSString *name = MirageAttrString(attrs, @"default");
  name = [name
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  if (!name.length) {
    if (outError)
      *outError = MirageEasingDirectiveErrorMissing;
    return MirageEasingCurveLinear;
  }
  NSInteger curve = MirageEasingCurveForToken(name);
  if (curve < 0) {
    if (outError)
      *outError = MirageEasingDirectiveErrorValue;
    return MirageEasingCurveLinear;
  }
  return curve;
}

#endif // __METAL_VERSION__
