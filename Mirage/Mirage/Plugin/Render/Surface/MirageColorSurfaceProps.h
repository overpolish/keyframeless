/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// `// #color-surface`: opt a shader into the Grading surface - the measurement
// and direct-manipulation panel for colour work.
#pragma once

#ifndef __METAL_VERSION__

#import <Foundation/Foundation.h>

#import "MirageDirectiveCommon.h"

NS_ASSUME_NONNULL_BEGIN

// --- Colour surface (`// #color-surface`) --------------------------------
// One whole-shader declaration, like #template or #motionblur, rather than a
// per-uniform control:
//     // #color-surface
//     // #color-surface space=linear-rec709
//
// The surface is OPT-IN. Without the directive a shader gets no scopes and no
// grading handles, so no inspector grows a panel it never asked for.
//
// A shader may declare the surface TWICE, once per ring kind:
//     // #color-surface ring=hue
//     // #color-surface ring=light
//
// which stacks the two circles in the panel, in declaration order. A grade
// needs both - the cast is a hue problem and the exposure is a light one - and
// they are two readings of the same frame, not one control with a mode. Two of
// the SAME ring is still rejected: there is nothing a second copy of a wheel
// could measure that the first does not. Two is the ceiling for the same
// reason.
//
// `space=` names the colour space the shader's maths works in, which the
// surface needs because chroma and density are primaries-dependent: the same
// drag in linear Rec.709 and in ACEScg produces different colour. It is NOT a
// conversion request. Nothing here transforms the image - FCP does not tell a
// plugin what space its input is in, so a conversion would be a guess. Users
// normalise upstream with the Color Transform effect, which is also why the
// space list here is the transform's OUTPUT list rather than its input list.
//
// Only linear-rec709 is accepted for now: it is what Color Transform hands
// downstream by default, and one implemented space beats five declared ones.
// The others stay rejected until a real case turns up, so a shader can never
// declare a space the surface is silently ignoring.

typedef NS_ENUM(NSInteger, MirageColorSurfaceSpace) {
  MirageColorSurfaceSpaceInvalid = -1,
  MirageColorSurfaceSpaceLinearRec709 = 0,
};

/// What the circle's outline paints. It is the legend AND the scope: the ring
/// tells you what the two axes mean, and carries the frame's own distribution,
/// so the measurement lives inside the control instead of in a separate readout
/// nobody relates back to it.
typedef NS_ENUM(NSInteger, MirageColorSurfaceRing) {
  /// No ring painting: a plain outline. The default, since a shader whose axes
  /// are not about light or hue would be mislabelled by either.
  MirageColorSurfaceRingPlain = 0,
  /// A dark-to-bright ramp, with the frame's luminance distribution around it.
  MirageColorSurfaceRingLight,
  /// A hue wheel, with the frame's chroma as a polar cloud - a vectorscope you
  /// can pull against.
  MirageColorSurfaceRingHue,
};

/// Absence is legal (it means "no surface"), so there is no Missing case.
typedef NS_ENUM(NSInteger, MirageColorSurfaceError) {
  MirageColorSurfaceErrorNone = 0,
  MirageColorSurfaceErrorMultiple,
  MirageColorSurfaceErrorValue,
};

/// The most surfaces one shader may declare: the hue ring and the light ring.
enum { kMirageColorSurfaceMaxCount = 2 };

static inline NSString *_Nullable MirageColorSurfaceSpaceID(
    MirageColorSurfaceSpace s) {
  return s == MirageColorSurfaceSpaceLinearRec709 ? @"linear-rec709" : nil;
}

/// The attribute text of every `#color-surface` line, in declaration order.
///
/// One scanner, because the ring, the axis labels and the opt-in all read the
/// same lines: a second regular expression would be a second place for them to
/// disagree about which line is which.
static inline NSArray<NSString *> *
MirageColorSurfaceAttrLines(NSString *source) {
  NSMutableArray<NSString *> *out = [NSMutableArray array];
  if (!source.length)
    return out;
  // Literal reject before the pattern. The directive spelling is mandatory, so
  // a source that doesn't contain it cannot match, and a plain substring search
  // is orders of magnitude cheaper than compiling a fresh NSRegularExpression
  // and running it over the whole shader - which the browser gallery was doing
  // once per catalogue entry, on the main thread, on every rebuild.
  if ([source rangeOfString:@"#color-surface"].location == NSNotFound)
    return out;
  NSRegularExpression *dirRe = [NSRegularExpression
      regularExpressionWithPattern:
          @"(?m)^[ \\t]*//[ \\t]*#color-surface(?![-\\w])([^\\n]*)$"
                           options:0
                             error:nil];
  for (NSTextCheckingResult *m in
       [dirRe matchesInString:source
                      options:0
                        range:NSMakeRange(0, source.length)])
    [out addObject:[source substringWithRange:[m rangeAtIndex:1]]];
  return out;
}

/// `ring=` on one `#color-surface` line, defaulting to a plain outline.
static inline MirageColorSurfaceRing
MirageColorSurfaceRingForAttrs(NSString *attrs) {
  NSString *ring = [MirageAttrWord(attrs, @"ring") lowercaseString];
  if ([ring isEqualToString:@"light"])
    return MirageColorSurfaceRingLight;
  if ([ring isEqualToString:@"hue"])
    return MirageColorSurfaceRingHue;
  return MirageColorSurfaceRingPlain;
}

/// The rings the shader declares, in declaration order - which is the order
/// they are stacked in the panel, so the author decides what sits on top.
static inline NSArray<NSNumber *> *
MirageColorSurfaceRingsForSource(NSString *source) {
  NSMutableArray<NSNumber *> *out = [NSMutableArray array];
  for (NSString *attrs in MirageColorSurfaceAttrLines(source))
    [out addObject:@(MirageColorSurfaceRingForAttrs(attrs))];
  return out;
}

/// The first declared ring, for the callers that only ever have one.
static inline MirageColorSurfaceRing
MirageColorSurfaceRingForSource(NSString *source) {
  NSArray<NSNumber *> *rings = MirageColorSurfaceRingsForSource(source);
  return rings.count ? (MirageColorSurfaceRing)rings.firstObject.integerValue
                     : MirageColorSurfaceRingPlain;
}

/// YES when `ring` is one of the rings `source` declares.
static inline BOOL MirageColorSurfaceDeclaresRing(NSString *source,
                                                  MirageColorSurfaceRing ring) {
  for (NSNumber *boxed in MirageColorSurfaceRingsForSource(source))
    if ((MirageColorSurfaceRing)boxed.integerValue == ring)
      return YES;
  return NO;
}

/// The two labels of an axis, from `xaxis="Cool,Warm"` /
/// `yaxis="Deeper,Brighter"` on the `index`th `#color-surface` line. Returns
/// nil when the axis is undeclared, which the surface draws as an unlabelled
/// direction rather than inventing a name. `axis` is @"xaxis" or @"yaxis".
static inline NSArray<NSString *>
    *_Nullable MirageColorSurfaceAxisLabelsAtIndex(NSString *source,
                                                   NSUInteger index,
                                                   NSString *axis) {
  NSArray<NSString *> *lines = MirageColorSurfaceAttrLines(source);
  if (index >= lines.count)
    return nil;
  NSString *value = MirageAttrString(lines[index], axis);
  if (!value.length)
    return nil;
  NSMutableArray<NSString *> *out = [NSMutableArray array];
  for (NSString *part in [value componentsSeparatedByString:@","]) {
    NSString *trimmed = [part
        stringByTrimmingCharactersInSet:NSCharacterSet
                                            .whitespaceAndNewlineCharacterSet];
    if (trimmed.length)
      [out addObject:trimmed];
  }
  return out.count == 2 ? out : nil;
}

/// The single-surface spelling, kept for the callers that never ask for a ring.
static inline NSArray<NSString *> *_Nullable MirageColorSurfaceAxisLabels(
    NSString *source, NSString *axis) {
  return MirageColorSurfaceAxisLabelsAtIndex(source, 0, axis);
}

/// YES when `source` opts into the surface. `outSpace` gets the declared space
/// (defaulting to linear-rec709 when `space=` is omitted, since typing the only
/// legal value should not be busywork) and `outError` why a present directive
/// was rejected.
static inline BOOL
MirageColorSurfaceForSource(NSString *source,
                            MirageColorSurfaceSpace *_Nullable outSpace,
                            MirageColorSurfaceError *_Nullable outError) {
  if (outSpace)
    *outSpace = MirageColorSurfaceSpaceInvalid;
  if (outError)
    *outError = MirageColorSurfaceErrorNone;
  if (!source.length)
    return NO;

  NSArray<NSString *> *lines = MirageColorSurfaceAttrLines(source);
  if (lines.count == 0)
    return NO;
  if (lines.count > kMirageColorSurfaceMaxCount) {
    if (outError)
      *outError = MirageColorSurfaceErrorMultiple;
    return YES; // present but unusable: the caller reports, not silently drops
  }
  if (lines.count == kMirageColorSurfaceMaxCount) {
    // The pair has to be the hue ring and the light ring. A second copy of the
    // same ring would measure the frame twice and give the author two names for
    // one gesture, and a plain outline has no keyword a control could aim at,
    // so neither can be the partner.
    MirageColorSurfaceRing a = MirageColorSurfaceRingForAttrs(lines[0]);
    MirageColorSurfaceRing b = MirageColorSurfaceRingForAttrs(lines[1]);
    if (!((a == MirageColorSurfaceRingHue &&
           b == MirageColorSurfaceRingLight) ||
          (a == MirageColorSurfaceRingLight &&
           b == MirageColorSurfaceRingHue))) {
      if (outError)
        *outError = MirageColorSurfaceErrorMultiple;
      return YES;
    }
  }

  // Checked on every line, since each carries its own attributes and a space
  // the surface silently ignored on the second one would be the worse failure.
  for (NSString *attrs in lines) {
    NSString *space = MirageAttrWord(attrs, @"space");
    space = [[space
        stringByTrimmingCharactersInSet:NSCharacterSet
                                            .whitespaceAndNewlineCharacterSet]
        lowercaseString];
    if (space.length &&
        ![space isEqualToString:MirageColorSurfaceSpaceID(
                                    MirageColorSurfaceSpaceLinearRec709)]) {
      if (outError)
        *outError = MirageColorSurfaceErrorValue;
      return YES;
    }
  }
  if (outSpace)
    *outSpace = MirageColorSurfaceSpaceLinearRec709;
  return YES;
}

NS_ASSUME_NONNULL_END

#endif
