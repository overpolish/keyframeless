/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// `// #frames offsets="-1,+1"` - the whole-shader directive that gives a shader
// TEMPORAL reach: the source clip at other frames, alongside the current one on
// iChannel0. It stands alone like `#motionblur` / `#template` and binds no
// uniform of its own; the offsets it lists become the `iNeighbor0..N-1`
// samplers the wrapper declares, in the order they are written.
//
// Offsets are signed WHOLE FRAMES relative to the render time, resolved against
// the clip's frame duration at schedule time. Everything here is a pure parse -
// the scheduling lives in `-scheduleInputs:` and the binding in the wrapper -
// so the render, the validator and the tests all read one implementation.

#ifndef __METAL_VERSION__

#import <Foundation/Foundation.h>

#import "MirageDirectiveCommon.h" // MirageAttrString

/// Ceiling on declared offsets. Each one is a full-resolution texture held for
/// the frame AND an extra upstream render, so this is a memory/throughput
/// budget rather than a binding limit: eight 4K RGBA16F frames is already
/// ~250MB of live texture on top of the render itself.
#define KK_SHADER_MAX_FRAME_OFFSETS 8

typedef NS_ENUM(NSInteger, MirageFramesDirectiveError) {
  MirageFramesDirectiveErrorNone = 0,
  /// More than one `#frames` line. Binding order is positional, so a second
  /// list would silently renumber the first one's samplers.
  MirageFramesDirectiveErrorMultiple,
  /// No `offsets=` attribute, or an empty list.
  MirageFramesDirectiveErrorMissing,
  /// A token that isn't a signed whole number.
  MirageFramesDirectiveErrorValue,
  /// Offset 0 - that frame is already iChannel0, and accepting it would burn a
  /// sampler and an upstream render on a duplicate.
  MirageFramesDirectiveErrorZero,
  /// The same offset twice. REJECTED rather than folded: folding shifts every
  /// later sampler index down, so a shader written against `iNeighbor2` would
  /// quietly start reading a different frame.
  MirageFramesDirectiveErrorDuplicate,
  /// More than KK_SHADER_MAX_FRAME_OFFSETS offsets.
  MirageFramesDirectiveErrorTooMany,
};

/// The parsed offset list, in DECLARATION ORDER - that order is the binding
/// order (`offsets[i]` is the sampler `iNeighbor` i), so it is never sorted.
typedef struct MirageFrameOffsets {
  int count;
  int offsets[KK_SHADER_MAX_FRAME_OFFSETS];
} MirageFrameOffsets;

/// The offsets a source declares. `count` is 0 for a source with no `#frames`
/// line AND for one whose directive is malformed - a shader that fails
/// validation still has to render, and rendering it with a partial temporal set
/// would be worse than rendering it with none. `outError` tells the validator
/// which message to show.
static inline MirageFrameOffsets
MirageFrameOffsetsForSource(NSString *source,
                            MirageFramesDirectiveError *outError) {
  MirageFrameOffsets out;
  memset(&out, 0, sizeof(out));
  if (outError)
    *outError = MirageFramesDirectiveErrorNone;
  if (!source.length)
    return out;
  // Substring fast-reject before the regex. A rack asks this once per ENTRY per
  // scheduled frame (and again per entry per mini redraw), and compiling an
  // NSRegularExpression costs far more than the scan that proves there is
  // nothing to match - which is the answer for every shader that doesn't
  // declare the directive, i.e. almost all of them.
  if ([source rangeOfString:@"#frames"].location == NSNotFound)
    return out;

  // Built once per process, not once per call: the pattern is constant and
  // compiling it was the dominant cost of asking this question on a chain.
  // -initWithPattern: (not the autoreleased convenience form) so the static
  // holds a retained object under MRR as well as ARC.
  static NSRegularExpression *expression;
  static dispatch_once_t onceFrames;
  dispatch_once(&onceFrames, ^{
    expression = [[NSRegularExpression alloc]
        initWithPattern:@"(?m)^[ \\t]*//[ \\t]*#frames(?![-\\w])(.*)$"
                options:0
                  error:nil];
  });
  NSArray<NSTextCheckingResult *> *matches =
      [expression matchesInString:source
                          options:0
                            range:NSMakeRange(0, source.length)];
  if (matches.count == 0)
    return out;
  if (matches.count != 1) {
    if (outError)
      *outError = MirageFramesDirectiveErrorMultiple;
    return out;
  }

  NSString *attrs =
      [source substringWithRange:[matches.firstObject rangeAtIndex:1]];
  NSString *list = MirageAttrString(attrs, @"offsets");
  list = [list
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  if (!list.length) {
    if (outError)
      *outError = MirageFramesDirectiveErrorMissing;
    return out;
  }

  static NSRegularExpression *intRe;
  static dispatch_once_t onceInt;
  dispatch_once(&onceInt, ^{
    intRe = [[NSRegularExpression alloc] initWithPattern:@"^[+-]?[0-9]+$"
                                                 options:0
                                                   error:nil];
  });
  int parsed[KK_SHADER_MAX_FRAME_OFFSETS];
  int n = 0;
  for (NSString *raw in [list componentsSeparatedByString:@","]) {
    NSString *token = [raw
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!token.length) {
      if (outError)
        *outError = MirageFramesDirectiveErrorValue;
      return out;
    }
    if (![intRe firstMatchInString:token
                           options:0
                             range:NSMakeRange(0, token.length)]) {
      if (outError)
        *outError = MirageFramesDirectiveErrorValue;
      return out;
    }
    int value = token.intValue;
    if (value == 0) {
      if (outError)
        *outError = MirageFramesDirectiveErrorZero;
      return out;
    }
    for (int i = 0; i < n; i++) {
      if (parsed[i] == value) {
        if (outError)
          *outError = MirageFramesDirectiveErrorDuplicate;
        return out;
      }
    }
    if (n >= KK_SHADER_MAX_FRAME_OFFSETS) {
      if (outError)
        *outError = MirageFramesDirectiveErrorTooMany;
      return out;
    }
    parsed[n++] = value;
  }

  out.count = n;
  for (int i = 0; i < n; i++)
    out.offsets[i] = parsed[i];
  return out;
}

/// How many neighbour frames a source asks for (0 when it declares none or the
/// directive is malformed). The scheduling and binding sides only ever need the
/// count and the values, never the error.
static inline int MirageFrameOffsetCountForSource(NSString *source) {
  return MirageFrameOffsetsForSource(source, NULL).count;
}

#endif // __METAL_VERSION__
