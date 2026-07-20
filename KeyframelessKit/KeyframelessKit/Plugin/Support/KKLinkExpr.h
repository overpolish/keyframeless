/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A value flowing through a link expression: 1-4 components, so one evaluator
/// serves scalar / point / colour lanes. Binary ops broadcast a scalar (n==1)
/// against a vector component-wise; functions apply per component.
typedef struct {
  double v[4];
  int n;
} KKExprVal;

static inline KKExprVal KKExprScalar(double x) {
  KKExprVal r = {{x, 0, 0, 0}, 1};
  return r;
}

/// A compiled parameter-link expression (see KKLinkBus). Grammar is
/// JS/spreadsheet flavoured but NOT JavaScript - a tiny numeric language parsed
/// here:
///   numbers, + - * / %, unary - !, comparisons < > <= >= == !=, && ||,
///   ternary `c ? a : b`, calls f(a,b,...), parentheses.
/// Variables: `value` (the lane's own value), `t` (absolute project seconds),
/// `progress` (0..1 across the clip), `ct` (seconds since the clip started),
/// `pi`, `tau`, `e`.
/// References: `${name}` resolves a subscribed source via the resolveRef block
/// (recursively, in the caller). The default source `value` is a passthrough.
/// Functions: sin cos tan abs sign floor ceil round sqrt exp log
///            min max mod pow atan2 hypot step  (2-arg)
///            clamp lerp mix smoothstep  (3-arg)
///            easeIn easeOut easeInOut elastic bounce  (a 0..1 factor -> eased
///            0..1, identical to the timeline's keypose easing; optional 2nd
///            arg intensity 0..1, 3rd arg frequency for elastic/bounce).
///            repeat(t, period) pingpong(t, period)  (turn unbounded time into
///            a repeating 0..1 phase to feed the easing fns: repeat = 0->1
///            sawtooth, pingpong = 0->1->0 triangle; period seconds, default 1)
///            vec2/vec3/vec4(...)  (build a vector, GLSL-style).
/// Multi-component lanes: `value` is the whole vector (Crop Size = vec2 W,H).
/// Ops broadcast per component; `.xyzw`/`.rgba` swizzle reads components and
/// `vec2(value.x, value.y + …)` rebuilds one for independent per-axis control.
@interface KKLinkExpr : NSObject

/// Compile `source`, or nil with `*error` set on a parse error. An empty / all-
/// whitespace source compiles to a bare `value` passthrough (never nil).
+ (nullable instancetype)compile:(NSString *)source
                           error:(NSString *_Nullable *_Nullable)error;

/// The CHARACTER range in `source` of the first parse error (the offending
/// token expanded to its whole identifier, else the single bad character), for
/// an editor to underline, plus a short human-readable message in `*outMessage`
/// (for a hover tooltip). `{NSNotFound, 0}` and `*outMessage == nil` when
/// `source` is valid (or empty). Indices are into `source` as given (leading
/// whitespace included).
+ (NSRange)errorCharRangeForSource:(NSString *)source
                           message:(NSString *_Nullable *_Nullable)outMessage;

/// Evaluate. `value` is the lane's own value; `t` absolute project seconds;
/// `progress` the clip's 0..1 position; `clipTime` seconds since the clip
/// started; each `${name}` is resolved through `resolveRef` (nil resolves refs
/// to 0).
- (KKExprVal)evalWithValue:(KKExprVal)value
                         t:(double)t
                  progress:(double)progress
                  clipTime:(double)clipTime
                resolveRef:(nullable KKExprVal (^)(NSString *name))resolveRef;

/// The distinct `${name}` references in this expression, so the resolver knows
/// which sources to load (and the UI which are in use).
@property(nonatomic, readonly) NSArray<NSString *> *references;

/// A normalized re-rendering of the compiled expression: single spaces around
/// binary operators, `f(a, b)` calls, minimal parentheses (only where
/// precedence or left-associativity needs them). Semantically identical to the
/// source; the editor's "Format" action replaces the text with this.
/// `pi`/`tau`/`e` fold to their names when a constant matches.
- (NSString *)formattedSource;

@end

NS_ASSUME_NONNULL_END
