/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// KKExprNode tree -> value. The evaluator core: the KKLinkExpr instance holds
// the compiled root (built by KKLinkExpr+Parse.m) plus the per-evaluation
// context, and walks the tree per component. Parsing lives in +Parse.m, the
// pretty-printer in +Format.m.

#import "KKLinkExpr_Private.h"

#import "KKEasing.h" // easeIn/easeOut/... share the timeline's KKApplyEasing
#import "KKScaleGizmo.h" // ringExtent/ringNorm share the radius-ring OSC curve
#import <math.h>

@implementation KKExprNode
@end

static double KKExprComp(KKExprVal x, int i) {
  return x.v[x.n == 1 ? 0 : (i < x.n ? i : x.n - 1)];
}

static KKExprVal KKExprBroadcast2(KKExprVal a, KKExprVal b,
                                  double (^f)(double, double)) {
  KKExprVal r;
  r.n = a.n > b.n ? a.n : b.n;
  if (r.n < 1)
    r.n = 1;
  if (r.n > 4)
    r.n = 4;
  for (int i = 0; i < r.n; i++)
    r.v[i] = f(KKExprComp(a, i), KKExprComp(b, i));
  return r;
}

static KKExprVal KKExprMap1(KKExprVal a, double (^f)(double)) {
  KKExprVal r;
  r.n = a.n;
  for (int i = 0; i < a.n; i++)
    r.v[i] = f(a.v[i]);
  return r;
}

static double KKClampD(double x, double lo, double hi) {
  return x < lo ? lo : (x > hi ? hi : x);
}

// Deterministic pseudo-random in [0, 1) from a seed - the classic hash, but
// stable per input so an expression re-evaluates identically every frame (no
// flicker; scrub/undo reproducible). `random(3)` is a fixed roll;
// `random(floor(t))` a new roll each second.
static double KKExprHash01(double x) {
  // +1.0 so seed 0 isn't degenerate (sin(0)=0 -> a always-0 first roll).
  double s = sin((x + 1.0) * 12.9898) * 43758.5453;
  return s - floor(s); // fract
}

// Smooth value noise in [0, 1] over `x`: interpolate two neighbouring hashes
// with a smoothstep, so it wanders organically instead of jumping. `noise(t)`
// drifts once per unit of x; `noise(t * 0.5)` half as fast.
static double KKExprValueNoise(double x) {
  double i = floor(x), f = x - i;
  double u = f * f * (3.0 - 2.0 * f); // smoothstep ease
  double a = KKExprHash01(i), b = KKExprHash01(i + 1.0);
  return a + (b - a) * u;
}

@implementation KKLinkExpr {
  // Per-evaluation context, constant across one -evalWithValue... pass (nested
  // `${ref}` resolution evaluates a DIFFERENT KKLinkExpr instance, so these are
  // never re-entered on the same instance). Held as ivars so the recursive node
  // walk stays a plain `-eval:` without threading every scalar through it.
  KKExprVal _cValue;
  double _cT, _cProgress, _cClipTime;
  KKExprVal (^_cResolveRef)(NSString *);
  KKExprVal (^_cVars)(NSString *); // OSC bare-variable resolver
}

- (NSArray<NSString *> *)references {
  return _refs;
}

- (KKExprVal)eval:(KKExprNode *)node {
  switch (node->kind) {
  case KKNodeNum:
    return KKExprScalar(node->num);
  case KKNodeValue:
    return _cValue;
  case KKNodeTime:
    return KKExprScalar(_cT);
  case KKNodeProgress:
    return KKExprScalar(_cProgress);
  case KKNodeClipTime:
    return KKExprScalar(_cClipTime);
  case KKNodeRef:
    return _cResolveRef ? _cResolveRef(node->name) : KKExprScalar(0.0);
  case KKNodeVar:
    return _cVars ? _cVars(node->name) : KKExprScalar(0.0);
  case KKNodeSwizzle: {
    KKExprVal cv = [self eval:node->a];
    const char *s = node->name.UTF8String;
    int len = (int)node->name.length;
    KKExprVal r;
    r.n = len < 1 ? 1 : (len > 4 ? 4 : len);
    for (int i = 0; i < r.n; i++) {
      int idx = KKExprSwizzleIndex(s[i]);
      r.v[i] = KKExprComp(cv, idx < 0 ? 0 : idx);
    }
    return r;
  }
  case KKNodeMember: {
    // Child is a rect vec4 (minX, minY, maxX, maxY).
    KKExprVal cv = [self eval:node->a];
    if ([node->name isEqualToString:@"min"])
      return (KKExprVal){{KKExprComp(cv, 0), KKExprComp(cv, 1), 0, 0}, 2};
    if ([node->name isEqualToString:@"max"])
      return (KKExprVal){{KKExprComp(cv, 2), KKExprComp(cv, 3), 0, 0}, 2};
    if ([node->name isEqualToString:@"width"])
      return KKExprScalar(KKExprComp(cv, 2) - KKExprComp(cv, 0));
    return KKExprScalar(KKExprComp(cv, 3) - KKExprComp(cv, 1)); // height
  }
  case KKNodeUnary: {
    KKExprVal x = [self eval:node->a];
    if (node->op == '-')
      return KKExprMap1(x, ^(double v) {
        return -v;
      });
    return KKExprMap1(x, ^(double v) {
      return v == 0.0 ? 1.0 : 0.0;
    }); // '!'
  }
  case KKNodeTernary: {
    KKExprVal cond = [self eval:node->a];
    return cond.v[0] != 0.0 ? [self eval:node->b] : [self eval:node->c];
  }
  case KKNodeBinary: {
    KKExprVal a = [self eval:node->a];
    KKExprVal b = [self eval:node->b];
    switch (node->op) {
    case '+':
      return KKExprBroadcast2(a, b, ^(double x, double y) {
        return x + y;
      });
    case '-':
      return KKExprBroadcast2(a, b, ^(double x, double y) {
        return x - y;
      });
    case '*':
      return KKExprBroadcast2(a, b, ^(double x, double y) {
        return x * y;
      });
    case '/':
      return KKExprBroadcast2(a, b, ^(double x, double y) {
        return y == 0.0 ? 0.0 : x / y;
      });
    case '%':
      return KKExprBroadcast2(a, b, ^(double x, double y) {
        return y == 0.0 ? 0.0 : fmod(x, y);
      });
    case '<':
      return KKExprBroadcast2(a, b, ^(double x, double y) {
        return x < y ? 1.0 : 0.0;
      });
    case '>':
      return KKExprBroadcast2(a, b, ^(double x, double y) {
        return x > y ? 1.0 : 0.0;
      });
    case KKOpLE:
      return KKExprBroadcast2(a, b, ^(double x, double y) {
        return x <= y ? 1.0 : 0.0;
      });
    case KKOpGE:
      return KKExprBroadcast2(a, b, ^(double x, double y) {
        return x >= y ? 1.0 : 0.0;
      });
    case KKOpEQ:
      return KKExprBroadcast2(a, b, ^(double x, double y) {
        return x == y ? 1.0 : 0.0;
      });
    case KKOpNE:
      return KKExprBroadcast2(a, b, ^(double x, double y) {
        return x != y ? 1.0 : 0.0;
      });
    case KKOpAND:
      return KKExprBroadcast2(a, b, ^(double x, double y) {
        return (x != 0.0 && y != 0.0) ? 1.0 : 0.0;
      });
    case KKOpOR:
      return KKExprBroadcast2(a, b, ^(double x, double y) {
        return (x != 0.0 || y != 0.0) ? 1.0 : 0.0;
      });
    }
    return a;
  }
  case KKNodeCall: {
    NSArray<KKExprNode *> *an = node->args;
    NSUInteger nc = an.count;
    NSString *fn = node->name;
    // Vector constructors: flatten every arg's components in order and take N
    // (GLSL: vec2(x,y), vec4(v2, a, b), vec3(x) -> broadcast). Handled before
    // the 3-arg shortcut below because vec4 takes four args. `rect(min, max)`
    // is the vec4 constructor spelt as a rectangle (two vec2 corners ->
    // minX, minY, maxX, maxY), read back via `.min .max .width .height`.
    if ((fn.length == 4 && [fn hasPrefix:@"vec"]) ||
        [fn isEqualToString:@"rect"]) {
      int N = [fn hasPrefix:@"vec"] ? (int)[fn characterAtIndex:3] - '0' : 4;
      if (N >= 2 && N <= 4) {
        double comps[4];
        int k = 0;
        for (KKExprNode *arg in an) {
          KKExprVal av = [self eval:arg];
          for (int i = 0; i < av.n && k < 4; i++)
            comps[k++] = av.v[i];
        }
        KKExprVal r;
        r.n = N;
        for (int i = 0; i < N; i++)
          r.v[i] = (k == 1) ? comps[0] : (i < k ? comps[i] : 0.0);
        return r;
      }
    }
    KKExprVal a0 = nc > 0 ? [self eval:an[0]] : KKExprScalar(0);
    KKExprVal a1 = nc > 1 ? [self eval:an[1]] : KKExprScalar(0);
    KKExprVal a2 = nc > 2 ? [self eval:an[2]] : KKExprScalar(0);
    // Vector reducers (GLSL): length(v), distance(a,b), dot(a,b) -> scalar;
    // normalize(v) -> unit vector. Handle before the per-component maps.
    if ([fn isEqualToString:@"length"] || [fn isEqualToString:@"normalize"]) {
      double s = 0;
      for (int i = 0; i < a0.n; i++)
        s += a0.v[i] * a0.v[i];
      double len = sqrt(s);
      if ([fn isEqualToString:@"length"])
        return KKExprScalar(len);
      KKExprVal r = a0;
      if (len > 1e-12)
        for (int i = 0; i < r.n; i++)
          r.v[i] /= len;
      return r;
    }
    if ([fn isEqualToString:@"distance"]) {
      double s = 0;
      int m = MAX(a0.n, a1.n);
      for (int i = 0; i < m; i++) {
        double d = (i < a0.n ? a0.v[i] : 0) - (i < a1.n ? a1.v[i] : 0);
        s += d * d;
      }
      return KKExprScalar(sqrt(s));
    }
    if ([fn isEqualToString:@"dot"]) {
      double s = 0;
      int m = MIN(a0.n, a1.n);
      for (int i = 0; i < m; i++)
        s += a0.v[i] * a1.v[i];
      return KKExprScalar(s);
    }
    // 1-arg per-component
    if ([fn isEqualToString:@"sin"])
      return KKExprMap1(a0, ^(double x) {
        return sin(x);
      });
    if ([fn isEqualToString:@"cos"])
      return KKExprMap1(a0, ^(double x) {
        return cos(x);
      });
    if ([fn isEqualToString:@"tan"])
      return KKExprMap1(a0, ^(double x) {
        return tan(x);
      });
    if ([fn isEqualToString:@"abs"])
      return KKExprMap1(a0, ^(double x) {
        return fabs(x);
      });
    if ([fn isEqualToString:@"sign"])
      return KKExprMap1(a0, ^(double x) {
        return (double)((x > 0) - (x < 0));
      });
    if ([fn isEqualToString:@"floor"])
      return KKExprMap1(a0, ^(double x) {
        return floor(x);
      });
    if ([fn isEqualToString:@"ceil"])
      return KKExprMap1(a0, ^(double x) {
        return ceil(x);
      });
    if ([fn isEqualToString:@"round"])
      return KKExprMap1(a0, ^(double x) {
        return round(x);
      });
    if ([fn isEqualToString:@"sqrt"])
      return KKExprMap1(a0, ^(double x) {
        return x < 0 ? 0 : sqrt(x);
      });
    if ([fn isEqualToString:@"exp"])
      return KKExprMap1(a0, ^(double x) {
        return exp(x);
      });
    if ([fn isEqualToString:@"log"])
      return KKExprMap1(a0, ^(double x) {
        return x <= 0 ? 0 : log(x);
      });
    // Radius-ring OSC curve, in MIN-DIMENSION FRACTIONS (multiply by the
    // surface's min dimension for pixels): ringExtent maps a normalized 0..1
    // value to the ring's radius, ringNorm inverts it. Shared with every
    // radius-ring OSC so an expression-driven ring sits at the identical size.
    if ([fn isEqualToString:@"ringExtent"])
      return KKExprMap1(a0, ^(double x) {
        return KKRingOSCExtentForNorm(x, 1.0);
      });
    if ([fn isEqualToString:@"ringNorm"])
      return KKExprMap1(a0, ^(double x) {
        return KKRingOSCNormForExtent(x, 1.0);
      });
    if ([fn isEqualToString:@"rad"])
      return KKExprMap1(a0, ^(double x) {
        return x * M_PI / 180.0;
      });
    if ([fn isEqualToString:@"deg"])
      return KKExprMap1(a0, ^(double x) {
        return x * 180.0 / M_PI;
      });
    // 2-arg broadcast
    if ([fn isEqualToString:@"min"])
      return KKExprBroadcast2(a0, a1, ^(double x, double y) {
        return x < y ? x : y;
      });
    if ([fn isEqualToString:@"max"])
      return KKExprBroadcast2(a0, a1, ^(double x, double y) {
        return x > y ? x : y;
      });
    if ([fn isEqualToString:@"mod"])
      return KKExprBroadcast2(a0, a1, ^(double x, double y) {
        return y == 0 ? 0 : fmod(x, y);
      });
    if ([fn isEqualToString:@"pow"])
      return KKExprBroadcast2(a0, a1, ^(double x, double y) {
        return pow(x, y);
      });
    if ([fn isEqualToString:@"atan2"])
      return KKExprBroadcast2(a0, a1, ^(double x, double y) {
        return atan2(x, y);
      });
    if ([fn isEqualToString:@"hypot"])
      return KKExprBroadcast2(a0, a1, ^(double x, double y) {
        return hypot(x, y);
      });
    if ([fn isEqualToString:@"step"])
      return KKExprBroadcast2(a0, a1, ^(double edge, double x) {
        return x < edge ? 0.0 : 1.0;
      });
    // 3-arg broadcast
    if ([fn isEqualToString:@"clamp"]) {
      KKExprVal r;
      r.n = a0.n;
      for (int i = 0; i < a0.n; i++)
        r.v[i] = KKClampD(a0.v[i], KKExprComp(a1, i), KKExprComp(a2, i));
      return r;
    }
    if ([fn isEqualToString:@"lerp"] || [fn isEqualToString:@"mix"]) {
      KKExprVal r;
      r.n = a0.n > a1.n ? a0.n : a1.n;
      for (int i = 0; i < r.n; i++) {
        double x = KKExprComp(a0, i), y = KKExprComp(a1, i),
               u = KKExprComp(a2, i);
        r.v[i] = x + (y - x) * u;
      }
      return r;
    }
    if ([fn isEqualToString:@"smoothstep"]) {
      KKExprVal r;
      r.n = a2.n;
      for (int i = 0; i < a2.n; i++) {
        double e0 = KKExprComp(a0, i), e1 = KKExprComp(a1, i), x = a2.v[i];
        double u = e1 == e0 ? 0.0 : KKClampD((x - e0) / (e1 - e0), 0.0, 1.0);
        r.v[i] = u * u * (3.0 - 2.0 * u);
      }
      return r;
    }
    // Time -> repeating 0..1 PHASE helpers, so unbounded `t` can drive the
    // easing/curve functions (which expect a 0..1 progress). `period` seconds
    // (default 1). repeat = sawtooth 0->1 (jumps back); pingpong = triangle
    // 0->1->0 (there and back), one full cycle per period.
    if ([fn isEqualToString:@"repeat"]) {
      double period = nc > 1 ? KKExprComp(a1, 0) : 1.0;
      return KKExprMap1(a0, ^(double x) {
        return period == 0.0 ? 0.0
                             : fmod(fmod(x, period) + period, period) / period;
      });
    }
    if ([fn isEqualToString:@"pingpong"]) {
      double period = nc > 1 ? KKExprComp(a1, 0) : 1.0;
      return KKExprMap1(a0, ^(double x) {
        if (period == 0.0)
          return 0.0;
        double p = fmod(fmod(x, period) + period, period) / period; // 0..1
        return 1.0 - fabs(2.0 * p - 1.0);
      });
    }
    // Deterministic randomness (Motion's linking can't do this). Seeded by the
    // ARGUMENT, so it is stable per frame: `random` a hard 0..1 roll, `noise`
    // its smooth cousin. Centre a swing with `noise(t)*2-1`, like `sin`.
    if ([fn isEqualToString:@"random"])
      return KKExprMap1(a0, ^(double x) {
        return KKExprHash01(x);
      });
    if ([fn isEqualToString:@"noise"])
      return KKExprMap1(a0, ^(double x) {
        return KKExprValueNoise(x);
      });
    // Keypose easing curves, identical to the timeline sampler (shared
    // KKApplyEasing): a 0..1 factor in -> eased 0..1 out, per component.
    // Optional 2nd arg = intensity (0..1, default 0.5); 3rd = frequency
    // (elastic/bounce only, default 0.5).
    NSInteger ecurve = -1;
    if ([fn isEqualToString:@"easeIn"])
      ecurve = KKEasingCurveEaseIn;
    else if ([fn isEqualToString:@"easeOut"])
      ecurve = KKEasingCurveEaseOut;
    else if ([fn isEqualToString:@"easeInOut"])
      ecurve = KKEasingCurveEaseInOut;
    else if ([fn isEqualToString:@"elastic"])
      ecurve = KKEasingCurveElastic;
    else if ([fn isEqualToString:@"bounce"])
      ecurve = KKEasingCurveBounce;
    if (ecurve >= 0) {
      double intensity = nc > 1 ? KKExprComp(a1, 0) : 0.5;
      double frequency = nc > 2 ? KKExprComp(a2, 0) : 0.5;
      KKEasingCurve c = (KKEasingCurve)ecurve;
      return KKExprMap1(a0, ^(double x) {
        return KKApplyEasing(x, c, intensity, frequency);
      });
    }
    return a0; // unknown function: passthrough first arg
  }
  }
  return KKExprScalar(0.0);
}

- (KKExprVal)evalWithValue:(KKExprVal)value
                         t:(double)t
                  progress:(double)progress
                  clipTime:(double)clipTime
                resolveRef:(KKExprVal (^)(NSString *))resolveRef {
  _cValue = value;
  _cT = t;
  _cProgress = progress;
  _cClipTime = clipTime;
  _cResolveRef = resolveRef;
  _cVars = nil;
  return [self eval:_root];
}

- (KKExprVal)evalWithValue:(KKExprVal)value
                      vars:(KKExprVal (^)(NSString *))vars {
  _cValue = value;
  _cT = 0.0;
  _cProgress = 0.0;
  _cClipTime = 0.0;
  _cResolveRef = nil;
  _cVars = vars;
  return [self eval:_root];
}

@end
