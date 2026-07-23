/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageDirectiveVocab.h"

// Popup name-colour hints (hex), matching the editor's own highlighting so a
// row reads the same colour it will once inserted. `kVAR` (white) is in the
// header, shared with the engine.
static NSString *const kDIR = @"7ee787"; // directive kind (green)
static NSString *const kKEY = @"ffa657"; // attribute / field key (orange)
static NSString *const kKW = @"ff7b72";  // GLSL type / keyword (coral)
static NSString *const kFN = @"d2a8ff";  // function (purple)

// A function entry: shows `name(args)`, inserts `name(`.
static NSDictionary<NSString *, NSString *> *Fn(NSString *name, NSString *sig,
                                                NSString *desc) {
  return E(name, sig, desc, [name stringByAppendingString:@"("]);
}

NSArray<NSDictionary<NSString *, NSString *> *> *MirageDirectiveKinds(void) {
  static NSArray *v;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    v = Colored(
        @[
          E(@"#float", @"#float",
            @"A number slider. min= and max= set the range.", @"#float "),
          E(@"#percent", @"#percent", @"A 0-100% slider, delivered as 0..1.",
            @"#percent "),
          E(@"#int", @"#int", @"A whole-number slider.", @"#int "),
          E(@"#bool", @"#bool", @"An on/off checkbox.", @"#bool "),
          E(@"#choice", @"#choice",
            @"A pick-one menu, delivering the chosen index.", @"#choice "),
          E(@"#angle", @"#angle",
            @"A rotation dial in degrees, delivered as radians.", @"#angle "),
          E(@"#color", @"#color",
            @"A colour picker or palette, delivered as rgba.", @"#color "),
          E(@"#multi", @"#multi",
            @"2-4 numbers in one control, like a size or offset.", @"#multi "),
          E(@"#seed", @"#seed", @"A random-seed field with a dice button.",
            @"#seed "),
          E(@"#point", @"#point",
            @"A draggable point in the frame, delivering its "
            @"position.",
            @"#point "),
          E(@"#audio", @"#audio",
            @"Reacts to sound, binding a clip's frequency "
            @"spectrum.",
            @"#audio "),
          E(@"#progress", @"#progress",
            @"A 0-100% sweep that auto-runs across a "
            @"transition.",
            @"#progress "),
          E(@"#alpha", @"#alpha",
            @"Take control of transparency, to mask part of "
            @"the frame so a lower clip shows through.",
            @"#alpha"),
          E(@"@osc", @"@osc", @"A draggable on-screen handle for a value.",
            @"@osc "),
        ],
        kDIR);
  });
  return v;
}

NSArray<NSDictionary<NSString *, NSString *> *> *
MirageDirectiveAttributeKeys(void) {
  static NSArray *v;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    v = Colored(
        @[
          E(@"label", @"label=", @"The name shown in the inspector.",
            @"label="),
          E(@"min", @"min=", @"Lowest allowed value.", @"min="),
          E(@"max", @"max=", @"Highest allowed value.", @"max="),
          E(@"default", @"default=", @"Starting value.", @"default="),
          E(@"osc", @"osc=",
            @"Add an on-screen control: point, position, ring, box or rotate.",
            @"osc="),
          E(@"fields", @"fields={}",
            @"Names for each number of a #multi control.", @"fields={"),
          E(@"units", @"units={}", @"Per-field units for #multi: % or px.",
            @"units={"),
          E(@"center", @"center=",
            @"Where a ring or box sits in the frame, 0 to 1.", @"center="),
          E(@"link", @"link=", @"Pin a ring centre to a #point control.",
            @"link="),
          E(@"axis", @"axis=", @"Which axes a rotate control spins: x, y, z.",
            @"axis="),
        ],
        kKEY);
    // A bare flag - coral (keyword value) so its popup swatch matches the code.
    v = [v arrayByAddingObjectsFromArray:
               Colored(@[ E(@"skipsnapping", @"skipsnapping",
                            @"Opt a point/position handle out of the default "
                            @"Cmd-held snap.",
                            @"skipsnapping") ],
                       kKW)];
  });
  return v;
}

// The directive/`@osc` VALUE words the editor highlights as keywords (coral),
// so `osc=position`, `body = none`, `linked = true`, `skipsnapping` etc. read
// as vocabulary rather than flat text. Kinds/keys are coloured elsewhere; this
// is the enum values, booleans, and bare flags.
NSSet<NSString *> *MirageDirectiveKindTokens(void) {
  static NSSet *v;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableSet<NSString *> *s = [NSMutableSet set];
    for (NSDictionary<NSString *, NSString *> *e in MirageDirectiveKinds())
      if (e[@"name"].length)
        [s addObject:e[@"name"]];
    v = [s copy];
  });
  return v;
}

NSSet<NSString *> *MirageDirectiveValueKeywords(void) {
  static NSSet *v;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    v = [NSSet setWithArray:@[
      @"true",         @"false",      @"yes",      @"no",
      @"none", // booleans / off
      @"point",        @"position",   @"ring",     @"box",
      @"rotate",                                           // primitives / kinds
      @"dot",          @"square",     @"hollow",   @"arc", // point styles
      @"skipsnapping", @"lockaspect", @"dropdown",         // bare flags
      @"percent",      @"int",        @"px" // #multi units/modifiers
    ]];
  });
  return v;
}

NSArray<NSDictionary<NSString *, NSString *> *> *MirageOSCFieldKeys(void) {
  static NSArray *v;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    v = Colored(
        @[
          E(@"primitive", @"primitive =",
            @"The control kind: point, position, ring, box or rotate.",
            @"primitive = "),
          E(@"binds", @"binds =", @"The value this control edits.",
            @"binds = "),
          E(@"style", @"style =", @"Point look: hollow, square, dot or arc.",
            @"style = "),
          E(@"cursor", @"cursor =", @"The cursor shown over the control.",
            @"cursor = "),
          E(@"toPos", @"toPos =",
            @"Where the handle sits, worked out from the value.", @"toPos = "),
          E(@"fromPos", @"fromPos =",
            @"Turns a drag back into a value. Optional, "
            @"guessed if omitted.",
            @"fromPos = "),
          E(@"toR",
            @"toR =", @"A ring's radius from the value, in min-side fractions.",
            @"toR = "),
          E(@"fromR", @"fromR =",
            @"Turns a dragged radius r back into a value.", @"fromR = "),
          E(@"toRect", @"toRect =", @"A box's rectangle from the value.",
            @"toRect = "),
          E(@"fromRect", @"fromRect =",
            @"Turns the dragged rect back into a value.", @"fromRect = "),
          E(@"center", @"center =",
            @"Where a ring or rotate sits. A point value follows it live.",
            @"center = "),
          E(@"axes", @"axes =", @"The axes a rotate control spins: x, y, z.",
            @"axes = "),
          E(@"linked", @"linked =",
            @"true keeps a two-field ring or box in proportion. Shift "
            @"inverts it.",
            @"linked = "),
          E(@"body", @"body =",
            @"none makes a box's interior inert (no body-move).", @"body = "),
        ],
        kKEY);
    // A bare flag - highlighted coral (a keyword value), so its popup swatch
    // matches how it renders in the code.
    v = [v
        arrayByAddingObjectsFromArray:Colored(
                                          @[ E(@"skipsnapping", @"skipsnapping",
                                               @"Opt a point/position handle "
                                               @"out of the default "
                                               @"Cmd-held snap.",
                                               @"skipsnapping") ],
                                          kKW)];
  });
  return v;
}

NSArray<NSDictionary<NSString *, NSString *> *> *MirageOSCExprBuiltins(void) {
  static NSArray *v;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSArray *vars = Colored(
        @[
          E(@"mouse", @"mouse", @"The drag position, 0 to 1 across the frame.",
            @"mouse"),
          E(@"pos", @"pos", @"The drag position, same as mouse.", @"pos"),
          E(@"tr", @"tr", @"The top-right corner.", @"tr"),
          E(@"tl", @"tl", @"The top-left corner.", @"tl"),
          E(@"bl", @"bl", @"The bottom-left corner.", @"bl"),
          E(@"br", @"br", @"The bottom-right corner.", @"br"),
          E(@"center", @"center", @"The centre of the frame.", @"center"),
          E(@"aspect", @"aspect",
            @"Frame width over height. Multiply x by this to "
            @"correct for shape.",
            @"aspect"),
          E(@"size", @"size", @"The frame size.", @"size"),
          E(@"part", @"part", @"The sub-part being dragged.", @"part"),
          E(@"r", @"r", @"The dragged radius in fromR, in min-side fractions.",
            @"r"),
          E(@"rect", @"rect",
            @"The dragged rectangle in fromRect. Read .min, .max, .width, "
            @".height.",
            @"rect"),
          E(@"pi", @"pi", @"3.14159, half a turn in radians.", @"pi"),
        ],
        kVAR);
    NSArray *fns = Colored(
        @[
          E(@"vec2", @"vec2(x, y)", @"Make a point from an x and a y.",
            @"vec2("),
          E(@"rect", @"rect(min, max)",
            @"Make a rectangle from two corner points.", @"rect("),
          E(@"ringExtent", @"ringExtent(norm)",
            @"The ring size for a 0 to 1 value, on the shared curve.",
            @"ringExtent("),
          E(@"ringNorm", @"ringNorm(r)",
            @"Turns a ring size back into a 0 to 1 value.", @"ringNorm("),
          E(@"length", @"length(v)", @"The length of a vector.", @"length("),
          E(@"normalize", @"normalize(v)", @"A vector scaled to length 1.",
            @"normalize("),
          E(@"distance", @"distance(a, b)", @"The distance between two points.",
            @"distance("),
          E(@"dot", @"dot(a, b)", @"The dot product of two vectors.", @"dot("),
          E(@"mix", @"mix(a, b, t)", @"Blend from a to b as t runs 0 to 1.",
            @"mix("),
          E(@"clamp", @"clamp(x, lo, hi)",
            @"Keep a value within a low and high bound.", @"clamp("),
          E(@"min", @"min(a, b)", @"The smaller of two values.", @"min("),
          E(@"max", @"max(a, b)", @"The larger of two values.", @"max("),
          E(@"pow", @"pow(a, b)", @"a to the power b.", @"pow("),
          E(@"sqrt", @"sqrt(x)", @"Square root.", @"sqrt("),
          E(@"sin", @"sin(x)", @"Sine, angle in radians.", @"sin("),
          E(@"cos", @"cos(x)", @"Cosine, angle in radians.", @"cos("),
        ],
        kFN);
    v = [vars arrayByAddingObjectsFromArray:fns];
  });
  return v;
}

NSArray<NSDictionary<NSString *, NSString *> *> *MirageGLSLIdents(void) {
  static NSArray *v;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // Entry point + functions (purple, like a call in code).
    NSArray *calls = Colored(
        @[
          E(@"mainImage", @"mainImage(out fragColor, in fragCoord)",
            @"The entry point. Write the pixel colour to fragColor.",
            @"mainImage"),
          Fn(@"mix", @"mix(a, b, t)", @"Blend from a to b as t runs 0 to 1."),
          Fn(@"clamp", @"clamp(x, lo, hi)",
             @"Keep a value within a low and high bound."),
          Fn(@"smoothstep", @"smoothstep(edge0, edge1, x)",
             @"A smooth 0 to 1 ramp between two edges."),
          Fn(@"step", @"step(edge, x)", @"0 below the edge, 1 at or above it."),
          Fn(@"length", @"length(v)", @"The length of a vector."),
          Fn(@"distance", @"distance(a, b)",
             @"The distance between two points."),
          Fn(@"dot", @"dot(a, b)", @"The dot product of two vectors."),
          Fn(@"cross", @"cross(a, b)", @"The cross product, 3D."),
          Fn(@"normalize", @"normalize(v)", @"A vector scaled to length 1."),
          Fn(@"texture", @"texture(img, uv)",
             @"Read a pixel from an image at uv, 0 to 1."),
          Fn(@"textureLod", @"textureLod(img, uv, lod)",
             @"Read a pixel at a chosen blur level."),
          Fn(@"sin", @"sin(x)", @"Sine, angle in radians."),
          Fn(@"cos", @"cos(x)", @"Cosine, angle in radians."),
          Fn(@"tan", @"tan(x)", @"Tangent, angle in radians."),
          Fn(@"asin", @"asin(x)", @"Inverse sine, gives an angle."),
          Fn(@"acos", @"acos(x)", @"Inverse cosine, gives an angle."),
          Fn(@"atan", @"atan(y, x)", @"The angle of a direction, y and x."),
          Fn(@"pow", @"pow(a, b)", @"a to the power b."),
          Fn(@"exp", @"exp(x)", @"e to the power x."),
          Fn(@"log", @"log(x)", @"Natural logarithm."),
          Fn(@"exp2", @"exp2(x)", @"2 to the power x."),
          Fn(@"log2", @"log2(x)", @"Logarithm base 2."),
          Fn(@"sqrt", @"sqrt(x)", @"Square root."),
          Fn(@"inversesqrt", @"inversesqrt(x)", @"1 over square root, fast."),
          Fn(@"abs", @"abs(x)", @"Drop the sign, always positive."),
          Fn(@"sign", @"sign(x)", @"-1, 0 or 1 for the sign."),
          Fn(@"floor", @"floor(x)", @"Round down."),
          Fn(@"ceil", @"ceil(x)", @"Round up."),
          Fn(@"fract", @"fract(x)",
             @"The part after the decimal point, 0 to 1."),
          Fn(@"mod", @"mod(a, b)", @"The remainder, wrapping into 0 to b."),
          Fn(@"min", @"min(a, b)", @"The smaller of two values."),
          Fn(@"max", @"max(a, b)", @"The larger of two values."),
          Fn(@"radians", @"radians(deg)", @"Degrees to radians."),
          Fn(@"degrees", @"degrees(rad)", @"Radians to degrees."),
          Fn(@"reflect", @"reflect(dir, normal)",
             @"Bounce a direction off a surface."),
          Fn(@"refract", @"refract(dir, normal, eta)",
             @"Bend a direction through a surface."),
          Fn(@"fwidth", @"fwidth(x)",
             @"How fast a value changes between neighbouring "
             @"pixels, for anti-aliasing."),
          Fn(@"dFdx", @"dFdx(x)",
             @"How fast a value changes across the screen, left "
             @"to right."),
          Fn(@"dFdy", @"dFdy(x)",
             @"How fast a value changes across the screen, top "
             @"to bottom."),
        ],
        kFN);
    // The output value (white).
    NSArray *outs = Colored(
        @[
          E(@"fragColor", @"fragColor",
            @"The output colour for this pixel, rgba.", @"fragColor"),
          E(@"fragCoord", @"fragCoord", @"This pixel's position, in pixels.",
            @"fragCoord"),
        ],
        kVAR);
    // The inputs the plugin provides (orange, like a uniform).
    NSArray *inputs = Colored(
        @[
          E(@"iResolution", @"iResolution", @"The frame size in pixels, xy.",
            @"iResolution"),
          E(@"iChannel0", @"iChannel0",
            @"The source clip image. Sample it to read "
            @"the footage.",
            @"iChannel0"),
          E(@"iChannel1", @"iChannel1",
            @"A second input image, e.g. a transition's "
            @"incoming clip.",
            @"iChannel1"),
          E(@"iChannel2", @"iChannel2", @"An extra input image.", @"iChannel2"),
          E(@"iChannel3", @"iChannel3", @"An extra input image.", @"iChannel3"),
          E(@"iTime", @"iTime", @"Time in seconds since the clip started.",
            @"iTime"),
          E(@"iTimeDelta", @"iTimeDelta", @"Seconds since the previous frame.",
            @"iTimeDelta"),
          E(@"iFrame", @"iFrame", @"The current frame number.", @"iFrame"),
          E(@"iFrameRate", @"iFrameRate", @"Frames per second.", @"iFrameRate"),
          E(@"iMouse", @"iMouse",
            @"Pointer position and clicks, xy is the position.", @"iMouse"),
          E(@"iDate", @"iDate", @"The current date and time.", @"iDate"),
          E(@"iChannelResolution", @"iChannelResolution",
            @"The pixel size of each input image.", @"iChannelResolution"),
          E(@"iChannelTime", @"iChannelTime", @"Playback time of each input.",
            @"iChannelTime"),
          E(@"iSampleRate", @"iSampleRate", @"Audio sample rate.",
            @"iSampleRate"),
        ],
        kKEY);
    // Types + keywords (coral).
    NSArray *keywords = Colored(
        @[
          E(@"float", @"float", @"A single number.", @"float"),
          E(@"int", @"int", @"A whole number.", @"int"),
          E(@"bool", @"bool", @"True or false.", @"bool"),
          E(@"void", @"void", @"Nothing. A function that returns no value.",
            @"void"),
          E(@"vec2", @"vec2", @"A pair of numbers, x and y.", @"vec2"),
          E(@"vec3", @"vec3", @"Three numbers, xyz or rgb.", @"vec3"),
          E(@"vec4", @"vec4", @"Four numbers, xyzw or rgba.", @"vec4"),
          E(@"mat2", @"mat2", @"A 2x2 matrix.", @"mat2"),
          E(@"mat3", @"mat3", @"A 3x3 matrix.", @"mat3"),
          E(@"mat4", @"mat4", @"A 4x4 matrix.", @"mat4"),
          E(@"sampler2D", @"sampler2D",
            @"A handle to an image that can be sampled.", @"sampler2D"),
          E(@"uniform", @"uniform",
            @"Declares an input value, usually from a // # "
            @"directive.",
            @"uniform "),
          E(@"const", @"const", @"A value that never changes.", @"const "),
          E(@"return", @"return", @"Hand a result back from a function.",
            @"return "),
          E(@"if", @"if", @"Run a block only when a condition is true.",
            @"if ("),
          E(@"else", @"else", @"The block to run when the if was false.",
            @"else "),
          E(@"for", @"for", @"Repeat a block a set number of times.", @"for ("),
          E(@"while", @"while", @"Repeat a block while a condition holds.",
            @"while ("),
          E(@"struct", @"struct", @"Group values into a custom type.",
            @"struct "),
          E(@"discard", @"discard", @"Drop this pixel entirely.", @"discard"),
        ],
        kKW);
    NSMutableArray *a = [NSMutableArray array];
    [a addObjectsFromArray:calls];
    [a addObjectsFromArray:outs];
    [a addObjectsFromArray:inputs];
    [a addObjectsFromArray:keywords];
    v = a;
  });
  return v;
}

NSArray<NSDictionary<NSString *, NSString *> *> *
MirageValueEnumForKey(NSString *key) {
  NSString *k = key.lowercaseString;
  if ([k isEqualToString:@"osc"] || [k isEqualToString:@"primitive"])
    return Colored(
        @[
          E(@"point", @"point", @"A dot that gets dragged.", @"point"),
          E(@"position", @"position",
            @"The full position control with an editable motion path.",
            @"position"),
          E(@"ring", @"ring", @"A ring that gets resized.", @"ring"),
          E(@"box", @"box", @"A rectangle that gets resized.", @"box"),
          E(@"rotate", @"rotate", @"A dial that gets spun.", @"rotate"),
        ],
        kVAR);
  if ([k isEqualToString:@"style"])
    return Colored(
        @[
          E(@"hollow", @"hollow", @"A small hollow ring.", @"hollow"),
          E(@"square", @"square", @"A filled square.", @"square"),
          E(@"dot", @"dot", @"A filled dot.", @"dot"),
          E(@"arc", @"arc", @"An arc handle, like a position control.", @"arc"),
        ],
        kVAR);
  if ([k isEqualToString:@"linked"])
    return Colored(
        @[
          E(@"true", @"true", @"Keep the two fields in proportion.", @"true"),
          E(@"false", @"false", @"Each field resizes on its own.", @"false"),
        ],
        kVAR);
  if ([k isEqualToString:@"body"])
    return Colored(
        @[
          E(@"none", @"none", @"The box interior ignores drags.", @"none"),
        ],
        kVAR);
  if ([k isEqualToString:@"axes"])
    return Colored(
        @[
          E(@"x", @"x", @"Spin around the x axis.", @"x"),
          E(@"y", @"y", @"Spin around the y axis.", @"y"),
          E(@"z", @"z", @"Spin flat, like a dial.", @"z"),
        ],
        kVAR);
  if ([k isEqualToString:@"cursor"])
    return Colored(
        @[
          E(@"move", @"move", @"Open-hand move cursor.", @"move"),
          E(@"crosshair", @"crosshair", @"Crosshair cursor.", @"crosshair"),
          E(@"pointing", @"pointing", @"Pointing-hand cursor.", @"pointing"),
          E(@"resize-h", @"resize-h", @"Left-right resize.", @"resize-h"),
          E(@"resize-v", @"resize-v", @"Up-down resize.", @"resize-v"),
          E(@"resize-diag", @"resize-diag", @"Diagonal resize.",
            @"resize-diag"),
        ],
        kVAR);
  return nil;
}
