/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The parameter-link EXPRESSION vocabulary - the single source of truth for
// the insert menu AND the AI-knowledge reference (KKExprCatalogMarkdown), so
// they can never drift. Pure data; the tokenizer/word-colour grammar is in
// KKGLSLSyntax.m.

#import "KKGLSLSyntax.h"

#import "KKLocalized.h" // KKLoc - catalog descriptions are user-facing

static NSDictionary<NSString *, NSString *> *
KKExprEntry(NSString *name, NSString *cat, NSString *sig, NSString *desc,
            NSString *insert) {
  // `name`/`category`/`insert` are stable keys (matching + inserted syntax) and
  // `signature` is literal code - never localized. Only `desc` is prose the
  // menu shows, so it is looked up in the catalog (runtime key; the table is
  // hand- authored so a variable key resolves). The category's DISPLAY is
  // localized at the menu site, keeping the English string here as the grouping
  // key.
  return @{
    @"name" : name,
    @"category" : cat,
    @"signature" : sig,
    @"desc" : KKLoc(desc, @"Expression reference: a function or variable "
                          @"description shown in the insert menu."),
    @"insert" : insert
  };
}

NSArray<NSString *> *KKExprCatalogCategories(void) {
  return @[ @"Variables", @"Math", @"Easing", @"Phase", @"Vector" ];
}

NSString *KKExprCatalogMarkdown(void) {
  NSMutableString *md = [NSMutableString string];
  [md appendString:
          @"# Expression reference: every function and variable\n\n"
          @"The complete vocabulary the expression editor accepts - the same "
          @"list its insert menu shows. These are the ONLY names valid in an "
          @"expression; anything else is an error. See the `expressions` topic "
          @"for how expressions work and worked examples.\n\n"];
  NSArray<NSDictionary<NSString *, NSString *> *> *catalog = KKExprCatalog();
  for (NSString *category in KKExprCatalogCategories()) {
    [md appendFormat:@"## %@\n\n", category];
    for (NSDictionary<NSString *, NSString *> *e in catalog) {
      if (![e[@"category"] isEqualToString:category])
        continue;
      [md appendFormat:@"- `%@` - %@\n", e[@"signature"], e[@"desc"]];
    }
    [md appendString:@"\n"];
  }
  return md;
}

NSArray<NSDictionary<NSString *, NSString *> *> *KKExprCatalog(void) {
  static NSArray *cat;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cat = @[
      KKExprEntry(@"value", @"Variables", @"value",
                  @"This lane's own value (its keyframes or constant at this "
                  @"time). Most expressions build on it.",
                  @"value"),
      KKExprEntry(
          @"t", @"Variables", @"t",
          @"Absolute project time in seconds. Use for motion over time, "
          @"e.g. sin(t).",
          @"t"),
      KKExprEntry(@"progress", @"Variables", @"progress",
                  @"0 to 1 across the clip. Use for a whole-clip ramp.",
                  @"progress"),
      KKExprEntry(
          @"ct", @"Variables", @"ct",
          @"Seconds since this clip started (0 at its first frame). Use "
          @"for one-shots at the start.",
          @"ct"),
      KKExprEntry(@"pi", @"Variables", @"pi",
                  @"3.14159, half a turn in radians.", @"pi"),
      KKExprEntry(@"tau", @"Variables", @"tau",
                  @"Two times pi, one full turn in radians. sin(t*tau) repeats "
                  @"once per second.",
                  @"tau"),
      KKExprEntry(@"e", @"Variables", @"e", @"Euler's number, about 2.718.",
                  @"e"),

      KKExprEntry(@"sin", @"Math", @"sin(x)", @"Sine of x (x in radians).",
                  @"sin("),
      KKExprEntry(@"cos", @"Math", @"cos(x)", @"Cosine of x (x in radians).",
                  @"cos("),
      KKExprEntry(@"tan", @"Math", @"tan(x)", @"Tangent of x (x in radians).",
                  @"tan("),
      KKExprEntry(@"abs", @"Math", @"abs(x)",
                  @"Absolute value (drops the sign).", @"abs("),
      KKExprEntry(@"sign", @"Math", @"sign(x)",
                  @"Gives -1, 0 or 1 depending on the sign of x.", @"sign("),
      KKExprEntry(@"floor", @"Math", @"floor(x)",
                  @"Round down to a whole number.", @"floor("),
      KKExprEntry(@"ceil", @"Math", @"ceil(x)", @"Round up to a whole number.",
                  @"ceil("),
      KKExprEntry(@"round", @"Math", @"round(x)",
                  @"Round to the nearest whole "
                  @"number.",
                  @"round("),
      KKExprEntry(@"sqrt", @"Math", @"sqrt(x)", @"Square root.", @"sqrt("),
      KKExprEntry(@"exp", @"Math", @"exp(x)", @"e raised to the power x.",
                  @"exp("),
      KKExprEntry(@"log", @"Math", @"log(x)", @"Natural logarithm.", @"log("),
      KKExprEntry(@"rad", @"Math", @"rad(deg)", @"Convert degrees to radians.",
                  @"rad("),
      KKExprEntry(@"deg", @"Math", @"deg(rad)", @"Convert radians to degrees.",
                  @"deg("),
      KKExprEntry(@"min", @"Math", @"min(a, b)", @"The smaller of a and b.",
                  @"min("),
      KKExprEntry(@"max", @"Math", @"max(a, b)", @"The larger of a and b.",
                  @"max("),
      KKExprEntry(@"mod", @"Math", @"mod(a, b)",
                  @"Remainder of a divided by b (wraps a into 0 to b).",
                  @"mod("),
      KKExprEntry(@"pow", @"Math", @"pow(a, b)", @"a raised to the power b.",
                  @"pow("),
      KKExprEntry(@"atan2", @"Math", @"atan2(y, x)",
                  @"Angle of the point (x, y) in radians.", @"atan2("),
      KKExprEntry(@"hypot", @"Math", @"hypot(a, b)",
                  @"Diagonal length, the square root of a*a plus b*b.",
                  @"hypot("),
      KKExprEntry(@"step", @"Math", @"step(edge, x)",
                  @"Gives 0 if x is below edge, otherwise 1.", @"step("),
      KKExprEntry(@"clamp", @"Math", @"clamp(x, lo, hi)",
                  @"Keep x within the range lo to hi.", @"clamp("),
      KKExprEntry(@"lerp", @"Math", @"lerp(a, b, t)",
                  @"Linear blend from a to b as t goes 0 to 1.", @"lerp("),
      KKExprEntry(@"mix", @"Math", @"mix(a, b, t)", @"Same as lerp(a, b, t).",
                  @"mix("),
      KKExprEntry(@"smoothstep", @"Math", @"smoothstep(lo, hi, x)",
                  @"Smooth 0 to 1 ramp as x crosses lo to hi (eased ends).",
                  @"smoothstep("),
      KKExprEntry(@"random", @"Math", @"random(seed)",
                  @"A steady 0 to 1 value from a seed - the same seed always "
                  @"gives the same number. random(floor(t)) rolls once a "
                  @"second; multiply/offset to fit a range.",
                  @"random("),
      KKExprEntry(@"noise", @"Math", @"noise(x)",
                  @"Smooth 0 to 1 wander as x changes - random's flowing "
                  @"cousin. value + (noise(t)*2 - 1) * 20 drifts either way "
                  @"by 20.",
                  @"noise("),

      KKExprEntry(
          @"easeIn", @"Easing", @"easeIn(f, intensity?)",
          @"Ease in (slow start). Feed a 0 to 1 phase, get an eased 0 to "
          @"1, the same as the keypose easing.",
          @"easeIn("),
      KKExprEntry(@"easeOut", @"Easing", @"easeOut(f, intensity?)",
                  @"Ease out (slow end). Feed a 0 to 1 phase.", @"easeOut("),
      KKExprEntry(@"easeInOut", @"Easing", @"easeInOut(f, intensity?)",
                  @"Ease in and out (slow at both ends). Feed a 0 to 1 phase.",
                  @"easeInOut("),
      KKExprEntry(@"elastic", @"Easing", @"elastic(f, intensity?, freq?)",
                  @"Springy overshoot settling to 1. Feed a 0 to 1 phase.",
                  @"elastic("),
      KKExprEntry(@"bounce", @"Easing", @"bounce(f, intensity?, freq?)",
                  @"Bouncing settle to 1. Feed a 0 to 1 phase.", @"bounce("),

      KKExprEntry(@"repeat", @"Phase", @"repeat(t, period)",
                  @"Sawtooth from 0 to 1 every `period` seconds. Feed it to an "
                  @"easing function for a looping animation.",
                  @"repeat("),
      KKExprEntry(
          @"pingpong", @"Phase", @"pingpong(t, period)",
          @"Triangle from 0 up to 1 and back every `period` seconds. Feed "
          @"it to an easing function for a back and forth loop.",
          @"pingpong("),

      KKExprEntry(@"vec2", @"Vector", @"vec2(x, y)",
                  @"Build a 2 component value (e.g. a Size's W and H). Combine "
                  @"with value.x and value.y to drive axes independently.",
                  @"vec2("),
      KKExprEntry(@"vec3", @"Vector", @"vec3(x, y, z)",
                  @"Build a 3 component value.", @"vec3("),
      KKExprEntry(@"vec4", @"Vector", @"vec4(x, y, z, w)",
                  @"Build a 4 component value (e.g. W, H, X, Y).", @"vec4("),
    ];
  });
  return cat;
}
