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
          E(@"#gradient", @"#gradient",
            @"A colour ramp you sample by position, from 0 to 1.",
            @"#gradient "),
          E(@"#multi", @"#multi",
            @"2-4 numbers in one control, like a size or offset.", @"#multi "),
          E(@"#random", @"#random", @"A random-seed field with a dice button.",
            @"#random "),
          E(@"#point", @"#point",
            @"A draggable point in the frame, delivering its "
            @"position.",
            @"#point "),
          E(@"#audio", @"#audio",
            @"Reacts to sound, binding a clip's frequency spectrum and "
            @"optional waveform.",
            @"#audio "),
          E(@"#progress", @"#progress",
            @"Optional: hands the user a reshapeable 0-100% sweep lane. A "
            @"transition already gets the sweep from the built-in iProgress.",
            @"#progress "),
          E(@"#color-surface", @"#color-surface",
            @"Adds the Grading panel: scopes for this effect, plus handles for "
            @"any control it gives a colour role to. Declare it twice - "
            @"ring=hue and ring=light - to stack both circles.",
            @"#color-surface "),
          E(@"#template", @"#template",
            @"Required template type: generator, filter, layout, transition, "
            @"or color-transform.",
            @"#template "),
          E(@"#motionblur", @"#motionblur",
            @"Who renders motion blur: accumulate, native, or off.",
            @"#motionblur "),
          E(@"#frames", @"#frames",
            @"Also deliver the clip at other frames, for trails and other "
            @"effects that read across time.",
            @"#frames offsets=\""),
          E(@"#easing", @"#easing",
            @"Which curve a transition's Easing menu starts on: linear, "
            @"ease-in, ease-out, ease-in-out, elastic, or bounce.",
            @"#easing default=\""),
          E(@"#speed", @"#speed",
            @"Adds a Speed control that scales the shader's time.", @"#speed"),
          E(@"#seed", @"#seed",
            @"Adds a Seed control that offsets where the shader's time "
            @"starts.",
            @"#seed"),
          E(@"#grain", @"#grain",
            @"Adds Grain and Grain Size controls, overlaid on the result.",
            @"#grain"),
          E(@"#alpha", @"#alpha",
            @"Take control of transparency, to mask part of "
            @"the frame so a lower clip shows through.",
            @"#alpha"),
          E(@"#slots", @"#slots",
            @"Start a group of controls the user can add and remove copies "
            @"of, like a list of colours. Name it, cap it with max=, and "
            @"write {n} wherever a control inside says which copy it is.",
            @"#slots name=\""),
          E(@"#slots-end", @"#slots-end",
            @"End the repeatable group opened by #slots.", @"#slots-end"),
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
          E(@"maxby", @"maxby=",
            @"Make this control's upper bound follow another control.",
            @"maxby="),
          E(@"maxvalues", @"maxvalues={}",
            @"Upper bounds indexed by the control named in maxby=.",
            @"maxvalues={"),
          E(@"visibleby", @"visibleby=",
            @"Show this control only for selected values of another control.",
            @"visibleby="),
          E(@"visiblevalues", @"visiblevalues={}",
            @"Controller values for which this control is visible.",
            @"visiblevalues={"),
          E(@"optionsby", @"optionsby=",
            @"Map a colour array to a multiple-choice control's options.",
            @"optionsby="),
          E(@"default", @"default=", @"Starting value.", @"default="),
          E(@"name", @"name=\"\"",
            @"#slots: what one copy of the group is called, e.g. "
            @"name=\"Colour\". It heads every instance and keys its lanes, so "
            @"two groups can't share one.",
            @"name=\""),
          E(@"space", @"space=",
            @"The colour space this shader's maths works in, so the Grading "
            @"panel measures it correctly.",
            @"space="),
          E(@"surface", @"surface=\"\"",
            @"Bind this control to the Color panel's puck. Cartesian: "
            @"\"y:+30\", \"x:-4 y:+12\". Polar, for a wheel: \"r:+35\" follows "
            @"the puck's distance from the centre, \"a:+180\" follows its "
            @"bearing. The number is the move at full deflection, in this "
            @"control's own units, and the rim reaches its min / max. With two "
            @"rings declared, start the value with the ring this control "
            @"belongs to: \"hue x:+31 y:+17\", \"light y:+1.5\".",
            @"surface=\""),
          E(@"puck", @"puck={\"\", \"\"}",
            @"Which handle in the Color panel drives this control, e.g. "
            @"puck={\"Shadows\", \"moon\"}. Controls sharing a name share a "
            @"handle, so one circle can carry a whole three-way. Omit it and "
            @"every mapping drives the single puck.",
            @"puck={\""),
          E(@"track", @"track=",
            @"Pin this control's puck to a circle at that fraction of the "
            @"radius, e.g. track=0.75, so it can only be rotated. For a handle "
            @"whose controls are all angular - picking a hue - distance means "
            @"nothing, and a track says so instead of leaving it to be "
            @"discovered.",
            @"track="),
          E(@"pick", @"pick=",
            @"Feed this control from the Color panel's eyedropper: pick=hue, "
            @"pick=saturation, pick=luma, pick=luma-linear or pick=color. "
            @"Sampling the picture writes that property of the sampled colour "
            @"here - the hue in this control's own convention, saturation and "
            @"luma as 0..1 or as percent when the declared max says so, and "
            @"the "
            @"colour itself into a #color swatch. pick=luma is the brightness "
            @"the scope shows, display-coded. pick=luma-linear is the same "
            @"weights on linear light, for a value the shader consumes as "
            @"light "
            @"such as a contrast pivot. Independent of surface=: a control can "
            @"take the eyedropper without being on the puck.",
            @"pick="),
          E(@"preview", @"preview=",
            @"Hand this control to the inspector as SESSION STATE: no "
            @"inspector row, no keyframes, nothing saved. preview=selection "
            @"marks a #bool as the switch that shows this shader's selection "
            @"(the matte) instead of the graded result - it appears on the "
            @"preview, beside Before and Split. preview=active-key marks a "
            @"#choice that "
            @"says WHICH key the matte is about (option 0 = all, n = the nth "
            @"instance); the panel feeds it the handle you last touched, so "
            @"you never set it. Everywhere the panel is not driving them, "
            @"including Final Cut's viewer, they read your default= - so "
            @"declare them off. First one declared wins.",
            @"preview="),
          E(@"ring", @"ring=",
            @"#color-surface: what the circle's outline paints - plain, light "
            @"or hue. It doubles as the scope, so pick the one your axes are "
            @"about. A shader may declare one hue surface and one light "
            @"surface, and no more.",
            @"ring="),
          E(@"xaxis", @"xaxis=\"\"",
            @"#color-surface: the two ends of the puck's horizontal axis, e.g. "
            @"xaxis=\"Cool,Warm\". Drawn either side of the circle.",
            @"xaxis=\""),
          E(@"yaxis", @"yaxis=\"\"",
            @"#color-surface: the two ends of the puck's vertical axis, e.g. "
            @"yaxis=\"Darker,Brighter\". Negative end first, as with xaxis.",
            @"yaxis=\""),
          E(@"osc", @"osc=",
            @"Add an on-screen control: point, position, ring, box or rotate.",
            @"osc="),
          E(@"fields", @"fields={}",
            @"Names for each number of a #multi control.", @"fields={"),
          E(@"units", @"units={}",
            @"How the value reads. % and px also change the value: % divides "
            @"by 100, px scales with the media. Any other word (stops, °, "
            @"dB/oct) just labels the field. One per field on a #multi, or "
            @"units=\"px\" on a single control.",
            @"units={"),
          E(@"center", @"center=",
            @"Where a ring or box sits in the frame, 0 to 1.", @"center="),
          E(@"anchor", @"anchor=",
            @"Box OSC: grow FROM this #point instead of symmetrically about "
            @"the centre - a corner anchor keeps that corner put and grows "
            @"the opposite one.",
            @"anchor="),
          E(@"link", @"link=",
            @"Pin a ring / box centre to a #point control (`link=uCenter`), or "
            @"to a computed centre with the quoted form "
            @"(`link=\"uPosition + uAnchor - vec2(0.5)\"`).",
            @"link="),
          E(@"axis", @"axis=", @"Which axes a rotate control spins: x, y, z.",
            @"axis="),
          E(@"group", @"group=",
            @"Which inspector group the control goes in. Either "
            @"group=\"Name\" or group={\"Name\", \"sf.symbol\"} to pick the "
            @"group's icon too.",
            @"group=\""),
          E(@"size", @"size=", @"#grain: the grain's cell size, in pixels.",
            @"size="),
          E(@"offsets", @"offsets=\"\"",
            @"#frames: which frames to deliver, signed and relative to this "
            @"one, like \"-2,-1,+1\".",
            @"offsets=\""),
          E(@"waveform", @"waveform=",
            @"#audio: expose this many signed time-domain samples.",
            @"waveform="),
          E(@"wavewindow", @"wavewindow=",
            @"#audio: seconds covered by the generated waveform samples.",
            @"wavewindow="),
        ],
        kKEY);
    // Bare flags / values - coral (keyword value) so the popup swatch matches
    // the code. `#motionblur` takes its mode as a bare word too, so its three
    // modes live here beside skipsnapping rather than needing a `key=` form.
    v = [v
        arrayByAddingObjectsFromArray:
            Colored(
                @[
                  E(@"skipsnapping", @"skipsnapping",
                    @"Opt a point/position handle out of the default "
                    @"Cmd-held snap.",
                    @"skipsnapping"),
                  E(@"multiple", @"multiple",
                    @"Make a dropdown #choice a multi-select checklist that "
                    @"delivers a bitmask.",
                    @"multiple"),
                  // The glyph words, bare beside `osc=` - the sugar form of an
                  // authored block's `style =`, so the wording matches the
                  // enum offered for that key.
                  E(@"dot", @"dot", @"osc= glyph: a filled dot. The default.",
                    @"dot"),
                  E(@"square", @"square", @"osc= glyph: a filled square.",
                    @"square"),
                  E(@"hollow", @"hollow", @"osc= glyph: a small hollow ring.",
                    @"hollow"),
                  E(@"arc", @"arc",
                    @"osc= glyph: an arc handle, like a position control.",
                    @"arc"),
                  E(@"accumulate", @"accumulate",
                    @"#motionblur: the default. The plugin re-renders your "
                    @"shader across the shutter and averages it. Exact for any "
                    @"motion, including rotation. Single-pass only.",
                    @"accumulate"),
                  E(@"native", @"native",
                    @"#motionblur: your shader blurs itself - a feedback trail "
                    @"or its own loop. Required for multi-pass. You get "
                    @"iMotionBlur (0-1 shutter) + iMotionBlurSamples.",
                    @"native"),
                  E(@"off", @"off",
                    @"#motionblur: no blur, and the Motion Blur control is "
                    @"cleared.",
                    @"off"),
                  E(@"on", @"on",
                    @"#motionblur: start ENABLED when this shader is applied "
                    @"(the user can still turn it off).",
                    @"on"),
                ],
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
      @"true",
      @"false",
      @"yes",
      @"no",
      @"none", // booleans / off
      @"point",
      @"position",
      @"ring",
      @"box",
      @"rotate", // primitives / kinds
      @"dot",
      @"square",
      @"hollow",
      @"arc", // point styles
      @"skipsnapping",
      @"lockaspect",
      @"dropdown",
      @"multiple", // bare flags
      @"percent",
      @"int",
      @"px", // #multi units/modifiers
      @"accumulate",
      @"native",
      @"off",
      @"on", // #motionblur modes
      @"generator",
      @"filter",
      @"layout",
      @"transition",
      @"color-transform", // templates
      @"linear-rec709",   // #color-surface space=
      @"plain",           // #color-surface ring=
      @"light",
      @"hue",
      @"saturation",
      @"luma",
      @"luma-linear", // pick=
      @"selection",   // preview=
      @"active-key",
      @"linear",
      @"ease-in",
      @"ease-out",
      @"ease-in-out",
      @"elastic",
      @"bounce" // #easing default=
    ]];
  });
  return v;
}

// The icon slot of a `group={"Name", "symbol"}`. Descriptions are empty on
// purpose: an SF Symbol's name IS its description, and a line of prose per
// icon would be 84 strings saying nothing. The insert closes the quote the
// caret is already inside.
NSArray<NSDictionary<NSString *, NSString *> *> *MirageGroupSymbols(void) {
  static NSArray *v;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    v = Colored(
        @[
          E(@"wind", @"wind", @"", @"wind\""),
          E(@"tornado", @"tornado", @"", @"tornado\""),
          E(@"hare", @"hare", @"", @"hare\""),
          E(@"tortoise", @"tortoise", @"", @"tortoise\""),
          E(@"timer", @"timer", @"", @"timer\""),
          E(@"clock", @"clock", @"", @"clock\""),
          E(@"metronome", @"metronome", @"", @"metronome\""),
          E(@"speedometer", @"speedometer", @"", @"speedometer\""),
          E(@"arrow.clockwise", @"arrow.clockwise", @"", @"arrow.clockwise\""),
          E(@"arrow.triangle.2.circlepath", @"arrow.triangle.2.circlepath", @"",
            @"arrow.triangle.2.circlepath\""),
          E(@"figure.walk.motion", @"figure.walk.motion", @"",
            @"figure.walk.motion\""),
          E(@"gauge", @"gauge", @"", @"gauge\""),
          E(@"sparkles", @"sparkles", @"", @"sparkles\""),
          E(@"sun.max", @"sun.max", @"", @"sun.max\""),
          E(@"bolt", @"bolt", @"", @"bolt\""),
          E(@"flame", @"flame", @"", @"flame\""),
          E(@"lightbulb", @"lightbulb", @"", @"lightbulb\""),
          E(@"moon", @"moon", @"", @"moon\""),
          E(@"star", @"star", @"", @"star\""),
          E(@"rays", @"rays", @"", @"rays\""),
          E(@"light.max", @"light.max", @"", @"light.max\""),
          E(@"sun.dust", @"sun.dust", @"", @"sun.dust\""),
          E(@"circle", @"circle", @"", @"circle\""),
          E(@"square", @"square", @"", @"square\""),
          E(@"triangle", @"triangle", @"", @"triangle\""),
          E(@"hexagon", @"hexagon", @"", @"hexagon\""),
          E(@"diamond", @"diamond", @"", @"diamond\""),
          E(@"capsule", @"capsule", @"", @"capsule\""),
          E(@"oval", @"oval", @"", @"oval\""),
          E(@"rectangle", @"rectangle", @"", @"rectangle\""),
          E(@"seal", @"seal", @"", @"seal\""),
          E(@"pentagon", @"pentagon", @"", @"pentagon\""),
          E(@"octagon", @"octagon", @"", @"octagon\""),
          E(@"circle.grid.3x3", @"circle.grid.3x3", @"", @"circle.grid.3x3\""),
          E(@"square.grid.3x3", @"square.grid.3x3", @"", @"square.grid.3x3\""),
          E(@"circle.hexagongrid", @"circle.hexagongrid", @"",
            @"circle.hexagongrid\""),
          E(@"point.3.connected.trianglepath.dotted",
            @"point.3.connected.trianglepath.dotted", @"",
            @"point.3.connected.trianglepath.dotted\""),
          E(@"grid", @"grid", @"", @"grid\""),
          E(@"squareshape", @"squareshape", @"", @"squareshape\""),
          E(@"paintpalette", @"paintpalette", @"", @"paintpalette\""),
          E(@"paintbrush", @"paintbrush", @"", @"paintbrush\""),
          E(@"eyedropper", @"eyedropper", @"", @"eyedropper\""),
          E(@"drop", @"drop", @"", @"drop\""),
          E(@"drop.fill", @"drop.fill", @"", @"drop.fill\""),
          E(@"camera.filters", @"camera.filters", @"", @"camera.filters\""),
          E(@"swatchpalette", @"swatchpalette", @"", @"swatchpalette\""),
          E(@"circle.lefthalf.filled", @"circle.lefthalf.filled", @"",
            @"circle.lefthalf.filled\""),
          E(@"waveform", @"waveform", @"", @"waveform\""),
          E(@"waveform.path", @"waveform.path", @"", @"waveform.path\""),
          E(@"speaker.wave.2", @"speaker.wave.2", @"", @"speaker.wave.2\""),
          E(@"music.note", @"music.note", @"", @"music.note\""),
          E(@"dial.low", @"dial.low", @"", @"dial.low\""),
          E(@"dial.high", @"dial.high", @"", @"dial.high\""),
          E(@"water.waves", @"water.waves", @"", @"water.waves\""),
          E(@"cloud.fog", @"cloud.fog", @"", @"cloud.fog\""),
          E(@"snowflake", @"snowflake", @"", @"snowflake\""),
          E(@"leaf", @"leaf", @"", @"leaf\""),
          E(@"mountain.2", @"mountain.2", @"", @"mountain.2\""),
          E(@"globe", @"globe", @"", @"globe\""),
          E(@"aqi.medium", @"aqi.medium", @"", @"aqi.medium\""),
          E(@"sparkle", @"sparkle", @"", @"sparkle\""),
          E(@"move.3d", @"move.3d", @"", @"move.3d\""),
          E(@"rotate.3d", @"rotate.3d", @"", @"rotate.3d\""),
          E(@"scale.3d", @"scale.3d", @"", @"scale.3d\""),
          E(@"crop", @"crop", @"", @"crop\""),
          E(@"aspectratio", @"aspectratio", @"", @"aspectratio\""),
          E(@"arrow.up.left.and.arrow.down.right",
            @"arrow.up.left.and.arrow.down.right", @"",
            @"arrow.up.left.and.arrow.down.right\""),
          E(@"perspective", @"perspective", @"", @"perspective\""),
          E(@"skew", @"skew", @"", @"skew\""),
          E(@"camera.aperture", @"camera.aperture", @"", @"camera.aperture\""),
          E(@"circle.dashed", @"circle.dashed", @"", @"circle.dashed\""),
          E(@"camera.metering.spot", @"camera.metering.spot", @"",
            @"camera.metering.spot\""),
          E(@"scribble", @"scribble", @"", @"scribble\""),
          E(@"textformat", @"textformat", @"", @"textformat\""),
          E(@"number", @"number", @"", @"number\""),
          E(@"gearshape", @"gearshape", @"", @"gearshape\""),
          E(@"wand.and.stars", @"wand.and.stars", @"", @"wand.and.stars\""),
          E(@"wand.and.rays", @"wand.and.rays", @"", @"wand.and.rays\""),
          E(@"slider.horizontal.3", @"slider.horizontal.3", @"",
            @"slider.horizontal.3\""),
          E(@"switch.2", @"switch.2", @"", @"switch.2\""),
          E(@"function", @"function", @"", @"function\""),
          E(@"chevron.left.forwardslash.chevron.right",
            @"chevron.left.forwardslash.chevron.right", @"",
            @"chevron.left.forwardslash.chevron.right\""),
          E(@"cube", @"cube", @"", @"cube\""),
          E(@"square.stack.3d.up", @"square.stack.3d.up", @"",
            @"square.stack.3d.up\""),
        ],
        kVAR);
  });
  return v;
}

NSArray<NSDictionary<NSString *, NSString *> *> *MirageMotionBlurModes(void) {
  static NSArray *v;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    v = Colored(
        @[
          E(@"accumulate", @"accumulate",
            @"The default. The plugin re-renders your shader across the "
            @"shutter and averages it. Exact for any motion, including "
            @"rotation. Single-pass shaders only.",
            @"accumulate"),
          E(@"native", @"native",
            @"Your shader blurs itself - a feedback trail, or its own sampling "
            @"loop. Required for multi-pass shaders. You get iMotionBlur "
            @"(0-1 shutter) and iMotionBlurSamples.",
            @"native"),
          E(@"off", @"off", @"No motion blur, and the control is cleared.",
            @"off"),
        ],
        kKW);
  });
  return v;
}

NSArray<NSDictionary<NSString *, NSString *> *> *MirageTemplateTypes(void) {
  static NSArray *v;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    v = Colored(
        @[
          E(@"generator", @"generator",
            @"Draws its own image. Audio-reactive generators still use this "
            @"type.",
            @"generator"),
          E(@"filter", @"filter", @"Processes the source clip on iChannel0.",
            @"filter"),
          E(@"layout", @"layout",
            @"Places or masks its source, normally with #alpha.", @"layout"),
          E(@"transition", @"transition",
            @"Receives outgoing and incoming clips and adds Transition / In / "
            @"Out coverage.",
            @"transition"),
          E(@"color-transform", @"color-transform",
            @"Converts a camera or display encoding into a practical output "
            @"space.",
            @"color-transform"),
        ],
        kKW);
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
          E(@"angleOffset", @"angleOffset =",
            @"Degrees added to a rotate control's drawn angle only, so rings "
            @"sit in phase with a preset the shader adds.",
            @"angleOffset = "),
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
          Fn(@"decodeToLinear", @"decodeToLinear(c)",
             @"sRGB colour to linear light. What iChannel0 needs before "
             @"any grading maths."),
          Fn(@"encodeFromLinear", @"encodeFromLinear(c)",
             @"Linear light back to sRGB colour, for the output."),
          Fn(@"linearToOklab", @"linearToOklab(c)",
             @"Linear colour to Oklab, where lightness, chroma and hue "
             @"move independently."),
          Fn(@"oklabToLinear", @"oklabToLinear(lab)",
             @"Oklab back to linear colour, pulling chroma in when the "
             @"colour is outside the gamut."),
          Fn(@"oklabToLinearRaw", @"oklabToLinearRaw(lab)",
             @"Oklab back to linear colour with no gamut fit. Prefer "
             @"oklabToLinear."),
          Fn(@"balanceGain", @"balanceGain(redCyan, greenMagenta)",
             @"Colour balance as linear channel gains, red against cyan "
             @"and green against magenta."),
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
          E(@"iNeighborAt", @"iNeighborAt(i, uv)",
            @"The source clip at the i-th frame offset declared by #frames, "
            @"sampled at uv.",
            @"iNeighborAt("),
          E(@"iNeighborCount", @"iNeighborCount",
            @"How many frames #frames declared.", @"iNeighborCount"),
          E(@"iNeighborOffset", @"iNeighborOffset(i)",
            @"The i-th #frames offset, in whole frames.", @"iNeighborOffset("),
          E(@"iNeighbor0", @"iNeighbor0",
            @"The clip at the first #frames offset. Prefer iNeighborAt.",
            @"iNeighbor0"),
          E(@"iNeighbor1", @"iNeighbor1",
            @"The clip at the second #frames offset. Prefer iNeighborAt.",
            @"iNeighbor1"),
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
  if ([k isEqualToString:@"space"])
    return Colored(
        @[
          E(@"linear-rec709", @"linear-rec709",
            @"Linear Rec.709, what Color Transform outputs by default.",
            @"linear-rec709"),
        ],
        kVAR);
  if ([k isEqualToString:@"ring"])
    return Colored(
        @[
          E(@"plain", @"plain",
            @"A plain outline. The default, for axes that are about neither "
            @"light nor hue.",
            @"plain"),
          E(@"light", @"light",
            @"A dark-to-bright ramp, with the frame's tones plotted inside it.",
            @"light"),
          E(@"hue", @"hue",
            @"A hue wheel, with the frame's colour as a vectorscope cloud "
            @"inside it.",
            @"hue"),
        ],
        kVAR);
  if ([k isEqualToString:@"pick"])
    return Colored(
        @[
          E(@"hue", @"hue",
            @"The sampled hue in degrees, in this control's own convention.",
            @"hue"),
          E(@"saturation", @"saturation",
            @"How colourful the sample is, as a fraction of the most colourful "
            @"thing Rec.709 shows.",
            @"saturation"),
          E(@"luma", @"luma",
            @"The sample's brightness as the scope shows it, display-coded. "
            @"For "
            @"a control compared against the picture's own pixel values, like "
            @"a "
            @"highlight threshold.",
            @"luma"),
          E(@"luma-linear", @"luma-linear",
            @"The same brightness measured in linear light. For a control the "
            @"shader consumes as light, like a contrast pivot: a face sampled "
            @"at 0.55 is 0.26 of the light, and feeding the display number to "
            @"a "
            @"pivot puts it about a stop high.",
            @"luma-linear"),
          E(@"color", @"color",
            @"The sampled colour itself, into a #color swatch.", @"color"),
        ],
        kVAR);
  if ([k isEqualToString:@"preview"])
    return Colored(
        @[
          E(@"selection", @"selection",
            @"This #bool shows the selection - the matte - instead of the "
            @"graded result. Session state: no row, no keyframes, nothing "
            @"saved. It appears on the preview, beside Before and Split.",
            @"selection"),
          E(@"active-key", @"active-key",
            @"This #choice says WHICH key the selection shows: option 0 for "
            @"all of them, option n for the nth instance of the repeatable "
            @"group. Panel session state with no row - the Color panel feeds "
            @"it the handle you last touched, so the matte follows the puck.",
            @"active-key"),
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
