/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKGLSLSyntax.h"
#import "KKLocalized.h" // KKLoc - expression catalog descriptions are user-facing

NSColor *KKHex(uint32_t rgb) {
  return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xff) / 255.0
                             green:((rgb >> 8) & 0xff) / 255.0
                              blue:(rgb & 0xff) / 255.0
                             alpha:1.0];
}
NSColor *KKCodeBG(void) { return KKHex(0x0d1117); }
NSColor *KKCodeBorder(void) { return KKHex(0x30363d); }
NSColor *KKCodeText(void) { return KKHex(0xe6edf3); }
NSColor *KKCodeComment(void) { return KKHex(0x8b949e); }
NSColor *KKCodeKeyword(void) { return KKHex(0xff7b72); }
NSColor *KKCodeUniform(void) { return KKHex(0xffa657); }
NSColor *KKCodeFunction(void) { return KKHex(0xd2a8ff); }
NSColor *KKCodeNumber(void) { return KKHex(0x79c0ff); }
NSColor *KKCodeCursor(void) { return KKHex(0x58a6ff); }
NSColor *KKCodeError(void) { return KKHex(0xf85149); }

NSColor *KKGLSLWordColor(NSString *w) {
  static NSSet *keywords, *uniforms;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    keywords = [NSSet setWithArray:@[
      // control + qualifiers
      @"if", @"else", @"for", @"while", @"do", @"return", @"break", @"continue",
      @"discard", @"const", @"in", @"out", @"inout", @"struct", @"true",
      @"false", @"uniform", @"varying", @"attribute", @"precision", @"highp",
      @"mediump", @"lowp", @"switch", @"case", @"default", @"layout",
      // types (GitHub colours storage types like keywords)
      @"void", @"float", @"int", @"uint", @"bool", @"double", @"vec2", @"vec3",
      @"vec4", @"ivec2", @"ivec3", @"ivec4", @"uvec2", @"uvec3", @"uvec4",
      @"bvec2", @"bvec3", @"bvec4", @"mat2", @"mat3", @"mat4", @"mat2x2",
      @"mat3x3", @"mat4x4", @"sampler2D", @"sampler3D", @"samplerCube",
      @"sampler2DArray"
    ]];
    uniforms = [NSSet setWithArray:@[
      @"iResolution", @"iTime", @"iTimeDelta", @"iFrame", @"iFrameRate",
      @"iChannelTime", @"iChannelResolution", @"iMouse", @"iDate",
      @"iSampleRate", @"iChannel0", @"iChannel1", @"iChannel2", @"iChannel3"
    ]];
  });
  if ([keywords containsObject:w])
    return KKCodeKeyword();
  if ([uniforms containsObject:w])
    return KKCodeUniform();
  return nil;
}

NSColor *KKExprWordColor(NSString *w) {
  static NSSet *fns, *vars;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    fns = [NSSet setWithArray:@[
      @"sin",      @"cos",       @"tan",     @"abs",        @"sign",
      @"floor",    @"ceil",      @"round",   @"sqrt",       @"exp",
      @"log",      @"rad",       @"deg",     @"min",        @"max",
      @"mod",      @"pow",       @"atan2",   @"hypot",      @"step",
      @"clamp",    @"lerp",      @"mix",     @"smoothstep", @"easeIn",
      @"easeOut",  @"easeInOut", @"elastic", @"bounce",     @"repeat",
      @"pingpong", @"vec2",      @"vec3",    @"vec4"
    ]];
    vars = [NSSet setWithArray:@[
      @"value", @"t", @"progress", @"ct", @"pi", @"tau", @"e"
    ]];
  });
  if ([fns containsObject:w])
    return KKCodeFunction();
  if ([vars containsObject:w])
    return KKCodeKeyword();
  return nil;
}

NSRegularExpression *KKExprTokenizer(void) {
  static NSRegularExpression *re;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    re = [NSRegularExpression
        regularExpressionWithPattern:
            @"(\\$\\{[^}]*\\})"                                  // 1 ${ref}
            @"|((?:\\d+\\.?\\d*(?:[eE][+-]?\\d+)?)|(?:\\.\\d+))" // 2 num
            @"|([A-Za-z_]\\w*)"                                  // 3 ident
                             options:0
                               error:nil];
  });
  return re;
}

NSRegularExpression *KKGLSLTokenizer(void) {
  static NSRegularExpression *re;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    re = [NSRegularExpression regularExpressionWithPattern:
                                  @"(/\\*[\\s\\S]*?\\*/|//[^\\n]*)" // 1 comment
                                  @"|(#[A-Za-z_]+)"                 // 2 pp
                                  @"|(\\b\\d+\\.?\\d*(?:[eE][+-]?\\d+)?[fFuU]?"
                                  @"\\b|\\.\\d+[fF]?)" // 3 num
                                  @"|([A-Za-z_]\\w*)"  // 4 ident
                                                   options:0
                                                     error:nil];
  });
  return re;
}

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
