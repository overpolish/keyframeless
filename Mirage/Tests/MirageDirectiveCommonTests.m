/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <Foundation/Foundation.h>

#import "MirageColorProps.h"
#import "MirageColorSurfaceProps.h"
#import "MirageDirectiveCommon.h"
#import "MirageFrameOffsets.h"
#import "MirageScalarParse.h"
#import "MirageSlotBudget.h"
#import "MirageSurfaceResponse.h"
#import "MirageTemplateType.h"

static void KKRequire(BOOL condition, NSString *message) {
  if (condition)
    return;
  NSLog(@"FAIL: %@", message);
  exit(1);
}

/// One named-pair parse, reported as "name|symbol" with the caller's untouched
/// defaults spelled out. Absent and empty are different answers here, which is
/// the whole point of the attribute.
static NSString *KKPair(NSString *attrs, NSString *key) {
  char name[64] = {0}, symbol[64] = {0};
  strncpy(name, "-", sizeof(name) - 1);
  strncpy(symbol, "-", sizeof(symbol) - 1);
  MirageParseNamedPairAttr(attrs, key, name, sizeof(name), symbol,
                           sizeof(symbol));
  return [NSString stringWithFormat:@"%s|%s", name, symbol];
}

int main(void) {
  @autoreleasepool {
    KKRequire(MirageAttrHasBareFlag(@" dropdown multiple", @"dropdown"),
              @"recognises a bare dropdown flag");
    KKRequire(MirageAttrHasBareFlag(@" dropdown multiple", @"multiple"),
              @"recognises a bare multiple flag");
    KKRequire(!MirageAttrHasBareFlag(@" label=\"multiple\"", @"multiple"),
              @"ignores flags in quoted labels");
    KKRequire(!MirageAttrHasBareFlag(@" options=\"Flow,No flow\" flowgate=-30",
                                     @"flow"),
              @"ignores quoted and prefixed flow words");
    KKRequire(MirageAttrHasBareFlag(@" flow flowgate=-30", @"flow"),
              @"recognises flow alongside prefixed attributes");

    // The braced pair, whose body used to be read as "up to the first `}`".
    // A `{n}` placeholder lives INSIDE the quotes, so that scan ended at the
    // placeholder's own brace and returned nothing at all - no error, just a
    // control that had lost its puck.
    KKRequire([KKPair(@" puck={\"Colour {n}\", \"{n}.circle\"}", @"puck")
                  isEqualToString:@"Colour {n}|{n}.circle"],
              @"a placeholder in both slots of a braced pair survives");
    KKRequire([KKPair(@" puck={\"Colour {N}\", \"circle\"}", @"puck")
                  isEqualToString:@"Colour {N}|circle"],
              @"and the shouted spelling reads the same way");
    KKRequire([KKPair(@" label=\"New Colour {n}\" "
                      @"puck={\"Colour {n}\", \"{n}.circle\"} pick=hue",
                      @"puck") isEqualToString:@"Colour {n}|{n}.circle"],
              @"the documented #slots line parses as documented");
    KKRequire([KKPair(@" group={\"Set {n}\", \"{n}.square\"}", @"group")
                  isEqualToString:@"Set {n}|{n}.square"],
              @"group= shares the parse, so it shares the fix");

    // Every shape that already worked, pinned byte for byte.
    KKRequire([KKPair(@" puck=\"Hue\"", @"puck") isEqualToString:@"Hue|-"],
              @"the bare quoted form names no symbol");
    KKRequire([KKPair(@" puck={\"Hue\"}", @"puck") isEqualToString:@"Hue|-"],
              @"the braced single form is the same answer");
    KKRequire([KKPair(@" puck={\"Hue\", \"moon\"}", @"puck")
                  isEqualToString:@"Hue|moon"] &&
                  [KKPair(@" puck={ \"Hue\" , \"moon\" }", @"puck")
                      isEqualToString:@"Hue|moon"] &&
                  [KKPair(@" puck  =  {\"Hue\", \"moon\"} extra=1", @"puck")
                      isEqualToString:@"Hue|moon"],
              @"the plain braced pair is unchanged, whitespace and all");
    KKRequire([KKPair(@" group={\"Options\", \"gear\"}", @"group")
                  isEqualToString:@"Options|gear"],
              @"and so is a plain group pair");
    KKRequire([KKPair(@" puck={\"a, b\", \"moon\"}", @"puck")
                  isEqualToString:@"a, b|moon"],
              @"a comma inside the name is part of the name");
    KKRequire(
        [KKPair(@" puck={\"a\",\"b\",\"c\"}", @"puck") isEqualToString:@"a|b"],
        @"a third string is ignored rather than fatal");
    KKRequire([KKPair(@" nopuck={\"Hue\"}", @"puck") isEqualToString:@"-|-"],
              @"a longer key ending in the one asked for is not it");
    KKRequire([KKPair(@" label=\"puck={x}\"", @"puck") isEqualToString:@"-|-"],
              @"an attribute named inside a quoted label is not written");
    KKRequire(
        [KKPair(@" puck={}", @"puck") isEqualToString:@"-|-"] &&
            [KKPair(@" puck={\"\"}", @"puck") isEqualToString:@"-|-"] &&
            [KKPair(@" puck=\"\"", @"puck") isEqualToString:@"-|-"] &&
            [KKPair(@" puck={Options}", @"puck") isEqualToString:@"-|-"] &&
            [KKPair(@" puck={\"a\"", @"puck") isEqualToString:@"-|-"] &&
            [KKPair(@" puck={\"unterminated}", @"puck") isEqualToString:@"-|-"],
        @"an empty or malformed value leaves the caller's default alone");
    KKRequire(
        [KKPair(@" puck={\"\", \"moon\"}", @"puck") isEqualToString:@"-|moon"],
        @"an empty name with a symbol keeps the symbol");

    KKRequire(MirageAttrHasKey(@" puck={\"a\", \"b\"}", @"puck") &&
                  MirageAttrHasKey(@" puck  = \"\"", @"puck") &&
                  MirageAttrHasKey(@" puck={n}", @"puck"),
              @"a key is written whether or not its value can be read");
    KKRequire(!MirageAttrHasKey(@" label=\"puck=x\"", @"puck") &&
                  !MirageAttrHasKey(@" nopuck=\"a\"", @"puck") &&
                  !MirageAttrHasKey(@" pick=hue", @"puck"),
              @"and not written by a quoted label or a longer key");

    MirageTemplateDirectiveError templateError =
        MirageTemplateDirectiveErrorNone;
    KKRequire(MirageTemplateTypeForSource(
                  @"// #template color-transform\nvoid mainImage() {}",
                  &templateError) == MirageTemplateTypeColorTransform &&
                  templateError == MirageTemplateDirectiveErrorNone,
              @"recognises the color-transform template");

    NSMutableArray<NSString *> *longLabels = [NSMutableArray array];
    for (NSInteger i = 0; i < 40; i++)
      [longLabels addObject:[NSString stringWithFormat:@"Camera Profile %02ld",
                                                       (long)i]];
    NSString *longChoice = [NSString
        stringWithFormat:@"// #choice dropdown options=\"%@\" default=39\n"
                         @"uniform int uInput;\n",
                         [longLabels componentsJoinedByString:@","]];
    MirageScalarProp prop = {0};
    int used = 0, truncated = 0;
    KKRequire(
        MirageParseScalarProps(longChoice, &prop, 1, 0, &used, &truncated) == 1,
        @"parses a long searchable choice");
    KKRequire(prop.choiceCount == 40 && prop.cdefault == 39,
              @"preserves every long-choice label and its default");

    // A directive name ends at a hyphen. These patterns used to end in `\b`,
    // which IS a boundary between a letter and a hyphen, so a future
    // `#color-surface` parsed as `#color` and handed `-surface ...` over as its
    // attribute body. Silently, which is the bad part.
    MirageScalarProp hyphenated = {0};
    used = 0;
    truncated = 0;
    KKRequire(
        MirageParseScalarProps(@"// #choice-surface options=\"A,B\" default=1\n"
                               @"uniform int uThing;\n",
                               &hyphenated, 1, 0, &used, &truncated) == 0,
        @"does not read #choice-surface as #choice");
    KKRequire(MirageParseScalarProps(@"// #choice options=\"A,B\" default=1\n"
                                     @"uniform int uThing;\n",
                                     &hyphenated, 1, 0, &used, &truncated) == 1,
              @"still reads a plain #choice");

    templateError = MirageTemplateDirectiveErrorNone;
    KKRequire(MirageTemplateTypeForSource(
                  @"// #template-of-mine filter\nvoid mainImage() {}",
                  &templateError) == MirageTemplateTypeInvalid,
              @"does not read #template-of-mine as #template");

    MirageColorSurfaceSpace space = MirageColorSurfaceSpaceInvalid;
    MirageColorSurfaceError surfaceError = MirageColorSurfaceErrorNone;
    KKRequire(!MirageColorSurfaceForSource(@"// #template filter\n", &space,
                                           &surfaceError) &&
                  surfaceError == MirageColorSurfaceErrorNone,
              @"no surface without the directive, and that is not an error");
    KKRequire(MirageColorSurfaceForSource(@"// #template filter\n"
                                          @"// #color-surface\n",
                                          &space, &surfaceError) &&
                  space == MirageColorSurfaceSpaceLinearRec709 &&
                  surfaceError == MirageColorSurfaceErrorNone,
              @"opts in with a bare directive, defaulting the space");
    KKRequire(
        MirageColorSurfaceForSource(@"// #color-surface space=linear-rec709\n",
                                    &space, &surfaceError) &&
            space == MirageColorSurfaceSpaceLinearRec709 &&
            surfaceError == MirageColorSurfaceErrorNone,
        @"reads the hyphenated space value whole");
    KKRequire(MirageColorSurfaceForSource(@"// #color-surface space=acescg\n",
                                          &space, &surfaceError) &&
                  space == MirageColorSurfaceSpaceInvalid &&
                  surfaceError == MirageColorSurfaceErrorValue,
              @"rejects a space the surface cannot measure");
    KKRequire(MirageColorSurfaceForSource(@"// #color-surface\n"
                                          @"// #color-surface\n",
                                          &space, &surfaceError) &&
                  surfaceError == MirageColorSurfaceErrorMultiple,
              @"reports a duplicated directive instead of picking one");

    // Two surfaces, one per ring kind: the grade that needs a wheel AND a tonal
    // circle declares both and gets them stacked.
    NSString *dualSurface = @"// #color-surface ring=hue\n"
                            @"// #color-surface ring=light\n";
    KKRequire(MirageColorSurfaceForSource(dualSurface, &space, &surfaceError) &&
                  space == MirageColorSurfaceSpaceLinearRec709 &&
                  surfaceError == MirageColorSurfaceErrorNone,
              @"a hue ring and a light ring are legal together");
    KKRequire(MirageColorSurfaceForSource(@"// #color-surface ring=light\n"
                                          @"// #color-surface ring=hue\n",
                                          &space, &surfaceError) &&
                  surfaceError == MirageColorSurfaceErrorNone,
              @"the pair is legal in either declaration order");
    NSArray<NSNumber *> *dualRings =
        MirageColorSurfaceRingsForSource(dualSurface);
    KKRequire(dualRings.count == 2 &&
                  dualRings[0].integerValue == MirageColorSurfaceRingHue &&
                  dualRings[1].integerValue == MirageColorSurfaceRingLight,
              @"the rings come back in declaration order, which is stacking "
              @"order");
    KKRequire(MirageColorSurfaceRingForSource(dualSurface) ==
                  MirageColorSurfaceRingHue,
              @"the single-ring accessor still answers with the first");
    KKRequire(
        MirageColorSurfaceDeclaresRing(dualSurface,
                                       MirageColorSurfaceRingLight) &&
            !MirageColorSurfaceDeclaresRing(@"// #color-surface ring=hue\n",
                                            MirageColorSurfaceRingLight),
        @"asks whether a ring is declared, not which one came first");
    KKRequire(MirageColorSurfaceForSource(@"// #color-surface ring=hue\n"
                                          @"// #color-surface ring=hue\n",
                                          &space, &surfaceError) &&
                  surfaceError == MirageColorSurfaceErrorMultiple,
              @"two of the SAME ring is still a duplicate");
    KKRequire(MirageColorSurfaceForSource(@"// #color-surface ring=hue\n"
                                          @"// #color-surface\n",
                                          &space, &surfaceError) &&
                  surfaceError == MirageColorSurfaceErrorMultiple,
              @"a plain outline has no keyword to aim at, so it cannot pair");
    KKRequire(MirageColorSurfaceForSource(@"// #color-surface ring=hue\n"
                                          @"// #color-surface ring=light\n"
                                          @"// #color-surface ring=light\n",
                                          &space, &surfaceError) &&
                  surfaceError == MirageColorSurfaceErrorMultiple,
              @"two is the ceiling");
    KKRequire(MirageColorSurfaceForSource(@"// #color-surface ring=hue\n"
                                          @"// #color-surface ring=light "
                                          @"space=acescg\n",
                                          &space, &surfaceError) &&
                  surfaceError == MirageColorSurfaceErrorValue,
              @"a bad space on the SECOND line is not silently ignored");

    // Axis labels are per surface, so the light ring's names cannot leak onto
    // the wheel above it.
    NSString *dualLabelled =
        @"// #color-surface ring=hue\n"
        @"// #color-surface ring=light xaxis=\"Flat,Punchy\" "
        @"yaxis=\"Darker,Brighter\"\n";
    KKRequire(
        !MirageColorSurfaceAxisLabelsAtIndex(dualLabelled, 0, @"xaxis") &&
            [MirageColorSurfaceAxisLabelsAtIndex(dualLabelled, 1, @"xaxis")[1]
                isEqualToString:@"Punchy"] &&
            [MirageColorSurfaceAxisLabelsAtIndex(dualLabelled, 1, @"yaxis")[0]
                isEqualToString:@"Darker"],
        @"each surface carries its own axis labels");

    // Attaching a control to a ring. The marker is a bare word at the front of
    // the value, so the term scanner never sees it and an unmarked control
    // parses exactly as it always did.
    MirageSurfaceResponse marked =
        MirageParseSurfaceResponse(@" default=0 surface=\"light y:+1.5\"");
    KKRequire(marked.present && marked.hasRing &&
                  marked.ring == MirageColorSurfaceRingLight &&
                  marked.y == 1.5 && marked.x == 0.0,
              @"reads the ring marker without disturbing the terms");
    MirageSurfaceResponse markedHue =
        MirageParseSurfaceResponse(@" default=0 surface=\"hue x:+31 y:+17\"");
    KKRequire(markedHue.hasRing &&
                  markedHue.ring == MirageColorSurfaceRingHue &&
                  markedHue.x == 31.0 && markedHue.y == 17.0,
              @"the marker may sit in front of a two-term response");
    MirageSurfaceResponse unmarked =
        MirageParseSurfaceResponse(@" default=0 surface=\"x:+31 y:+17\"");
    KKRequire(!unmarked.hasRing && unmarked.x == 31.0 && unmarked.y == 17.0,
              @"an unmarked response names no ring and parses unchanged");
    KKRequire(
        MirageSurfaceResponseOnRing(unmarked, MirageColorSurfaceRingHue, NO) &&
            MirageSurfaceResponseOnRing(unmarked, MirageColorSurfaceRingLight,
                                        NO),
        @"with one surface declared, every mapping belongs to it");
    KKRequire(
        !MirageSurfaceResponseOnRing(unmarked, MirageColorSurfaceRingHue, YES),
        @"with two declared, an unmarked mapping belongs to neither");
    KKRequire(
        MirageSurfaceResponseOnRing(marked, MirageColorSurfaceRingLight, YES) &&
            !MirageSurfaceResponseOnRing(marked, MirageColorSurfaceRingHue,
                                         YES),
        @"a marked mapping belongs to the ring it names and no other");

    NSString *dualControls =
        @"// #color-surface ring=hue\n"
        @"// #color-surface ring=light\n"
        @"// #float label=\"Red / Cyan\" min=-100 max=100 default=0 "
        @"surface=\"hue x:+31 y:+17\"\n"
        @"uniform float uRedCyan;\n"
        @"// #float label=\"Exposure\" min=-5 max=5 default=0 "
        @"surface=\"light y:+1.5\"\n"
        @"uniform float uExposure;\n"
        @"// #percent label=\"Contrast\" min=0 max=200 default=100 "
        @"surface=\"light x:+70\"\n"
        @"uniform float uContrast;\n";
    NSDictionary<NSString *, NSValue *> *hueRing =
        MirageSurfaceResponsesForRing(dualControls, MirageColorSurfaceRingHue);
    NSDictionary<NSString *, NSValue *> *lightRing =
        MirageSurfaceResponsesForRing(dualControls,
                                      MirageColorSurfaceRingLight);
    KKRequire(hueRing.count == 1 && hueRing[@"uRedCyan"],
              @"the wheel gets only the controls aimed at it");
    KKRequire(lightRing.count == 2 && lightRing[@"uExposure"] &&
                  lightRing[@"uContrast"],
              @"the tonal circle gets only the controls aimed at it");
    KKRequire(MirageSurfaceResponsesForSource(dualControls).count == 3,
              @"the unfiltered scan still sees every mapping");
    KKRequire(
        MirageSurfacePucksForRing(dualControls, MirageColorSurfaceRingHue)
                    .count == 1 &&
            MirageSurfacePucksForRing(dualControls, MirageColorSurfaceRingLight)
                    .count == 1,
        @"each ring gets its own single unnamed puck");

    // A single-surface shader is untouched by all of it: no marker needed, and
    // the ring filter still hands over everything.
    NSString *singleControls =
        @"// #color-surface ring=hue\n"
        @"// #float label=\"Red / Cyan\" min=-100 max=100 default=0 "
        @"surface=\"x:+31 y:+17\"\n"
        @"uniform float uRedCyan;\n";
    KKRequire(
        MirageSurfaceResponsesForRing(singleControls, MirageColorSurfaceRingHue)
                    .count == 1 &&
            MirageSurfaceResponsesForRing(singleControls,
                                          MirageColorSurfaceRingLight)
                    .count == 1,
        @"one surface means one ring, and every mapping is on it");

    // Misattachment is an editor error, never a silent no-op.
    MirageSurfaceRingBindingError binding = MirageSurfaceRingBindingErrorNone;
    KKRequire(!MirageFirstBadSurfaceRingBinding(singleControls, &binding) &&
                  binding == MirageSurfaceRingBindingErrorNone,
              @"an unmarked mapping under one surface is not an error");
    KKRequire(!MirageFirstBadSurfaceRingBinding(dualControls, &binding) &&
                  binding == MirageSurfaceRingBindingErrorNone,
              @"every marked mapping under two surfaces resolves");
    NSString *unnamedUnderTwo =
        @"// #color-surface ring=hue\n"
        @"// #color-surface ring=light\n"
        @"// #float label=\"Exposure\" min=-5 max=5 default=0 "
        @"surface=\"y:+1.5\"\n"
        @"uniform float uExposure;\n";
    KKRequire(
        [MirageFirstBadSurfaceRingBinding(unnamedUnderTwo, &binding)
            isEqualToString:@"Exposure"] &&
            binding == MirageSurfaceRingBindingErrorUnnamed,
        @"with two rings, an unmarked mapping names the control at fault");
    NSString *aimedAtNothing =
        @"// #color-surface ring=hue\n"
        @"// #float label=\"Exposure\" min=-5 max=5 default=0 "
        @"surface=\"light y:+1.5\"\n"
        @"uniform float uExposure;\n";
    KKRequire([MirageFirstBadSurfaceRingBinding(aimedAtNothing, &binding)
                  isEqualToString:@"Exposure"] &&
                  binding == MirageSurfaceRingBindingErrorUnknown,
              @"a marker naming an undeclared ring is reported, not dropped");
    KKRequire([MirageFirstBadSurfaceRingBinding(
                  @"// #color-surface ring=hue\n"
                  @"// #float min=-5 max=5 default=0 "
                  @"surface=\"light y:+1.5\"\n"
                  @"uniform float uExposure;\n",
                  &binding) isEqualToString:@"uExposure"],
              @"an unlabelled control is named by its uniform");

    // The reason the boundary fix above had to land first: #color-surface and
    // #color are a live collision, not a hypothetical one.
    MirageColorProp colorProp = {0};
    KKRequire(MirageParseColorProps(@"// #color-surface\nuniform vec4 uTint;\n",
                                    &colorProp, 1, NULL) == 0,
              @"#color-surface is not a #color control");
    KKRequire(!MirageColorSurfaceForSource(@"// #color label=\"Tint\"\n",
                                           &space, &surfaceError),
              @"#color is not a #color-surface opt-in");

    MirageSurfaceResponse r = MirageParseSurfaceResponse(@" surface=\"y:+30\"");
    KKRequire(r.present && r.x == 0.0 && r.y == 30.0,
              @"parses a single-axis response");
    r = MirageParseSurfaceResponse(@" surface=\"x:-4 y:+12\"");
    KKRequire(r.present && r.x == -4.0 && r.y == 12.0,
              @"parses both axes with signs");
    r = MirageParseSurfaceResponse(@" surface=\"y:12,x:-3\"");
    KKRequire(r.present && r.x == -3.0 && r.y == 12.0,
              @"parses either order, comma separated");
    r = MirageParseSurfaceResponse(@" label=\"Bloom\" default=45");
    KKRequire(!r.present, @"a control with no surface= does not respond");

    NSDictionary<NSString *, NSValue *> *responses =
        MirageSurfaceResponsesForSource(
            @"// #percent label=\"Threshold\" default=58 surface=\"y:-14\"\n"
            @"uniform float uThreshold;\n"
            @"// #percent label=\"Bloom\" default=45 surface=\"y:+30\"\n"
            @"uniform float uBloom;\n"
            @"// #percent label=\"Mix\" default=100\n"
            @"uniform float uMix;\n");
    KKRequire(responses.count == 2, @"maps only the controls that responded");
    KKRequire(responses[@"uThreshold"] && responses[@"uBloom"] &&
                  !responses[@"uMix"],
              @"keys responses by uniform name");

    // Round trip: a known puck produces control deltas, and deriving from those
    // deltas must land back on the same puck.
    MirageSurfaceSample trip[2] = {{0.0, -14.0, 0.0}, {0.0, 30.0, 0.0}};
    const double puckY = 0.4;
    trip[0].delta = trip[0].ry * puckY;
    trip[1].delta = trip[1].ry * puckY;
    double dx = 0.0, dy = 0.0;
    KKRequire(MirageSurfaceDerivePuck(trip, 2, &dx, &dy),
              @"derives from single-axis responses");
    KKRequire(fabs(dy - puckY) < 1e-9 && fabs(dx) < 1e-9,
              @"round trips the puck, leaving the unmapped axis at zero");

    // Normalisation: a wide-ranged control must not outvote a narrow one. Both
    // agree the puck is at 0.5, and a raw fit would still be pulled by the
    // pixel control's much larger absolute delta.
    MirageSurfaceSample scaled[2] = {{0.0, 4.0, 2.0}, {0.0, 120.0, 60.0}};
    KKRequire(MirageSurfaceDerivePuck(scaled, 2, &dx, &dy) &&
                  fabs(dy - 0.5) < 1e-9,
              @"weights each control by its own response magnitude");

    // A hand-edit that does not lie on the mapping fits between, rather than
    // being rejected or snapping to one control.
    MirageSurfaceSample partial[2] = {{0.0, -14.0, 14.0}, {0.0, 30.0, 0.0}};
    KKRequire(MirageSurfaceDerivePuck(partial, 2, &dx, &dy) && dy < 0.0 &&
                  dy > -1.0,
              @"best-fits an inconsistent hand edit");

    MirageSurfaceSample both[2] = {{10.0, 0.0, 5.0}, {0.0, 20.0, -10.0}};
    KKRequire(MirageSurfaceDerivePuck(both, 2, &dx, &dy) &&
                  fabs(dx - 0.5) < 1e-9 && fabs(dy + 0.5) < 1e-9,
              @"derives both axes independently");

    // The response curve: author magnitude sets the centre slope, the rim
    // reaches the control's declared limit, and it inverts.
    MirageSurfaceResponse curve = MirageParseSurfaceResponse(
        @" min=0 max=150 default=45 surface=\"y:+30\"");
    KKRequire(curve.hasLimits && curve.minValue == 0.0 &&
                  curve.maxValue == 150.0,
              @"parses the control's limits for the response curve");
    double atRim = MirageSurfaceCurveDelta(curve, 45.0, 1.0, 30.0);
    KKRequire(
        fabs(atRim - 105.0) < 1e-9,
        @"full deflection reaches the control's max, not just the magnitude");
    double atRimDown = MirageSurfaceCurveDelta(curve, 45.0, -1.0, 30.0);
    KKRequire(fabs(atRimDown + 45.0) < 1e-9,
              @"full deflection downward reaches the control's min");
    double small = MirageSurfaceCurveDelta(curve, 45.0, 0.01, 30.0);
    KKRequire(fabs(small - 0.30) < 0.01,
              @"near the centre the slope is the author's magnitude");
    for (double u = -0.95; u <= 0.95; u += 0.15) {
      double d = MirageSurfaceCurveDelta(curve, 45.0, u, 30.0);
      double back = MirageSurfaceCurveDeflection(curve, 45.0, d, 30.0);
      KKRequire(fabs(back - u) < 1e-3, @"the response curve round trips");
    }
    // An inverted mapping: the puck going up drives the control DOWN, so the
    // rims are its min and max the other way round. Both must land exactly on a
    // limit, or the control pins short of the rim in one direction and
    // overshoots in the other.
    MirageSurfaceResponse inverted = MirageParseSurfaceResponse(
        @" min=0 max=100 default=58 surface=\"y:-12\"");
    KKRequire(fabs(MirageSurfaceCurveDelta(inverted, 58.0, 1.0, -12.0) + 58.0) <
                  1e-9,
              @"an inverted control reaches its min at the top of the circle");
    KKRequire(
        fabs(MirageSurfaceCurveDelta(inverted, 58.0, -1.0, -12.0) - 42.0) <
            1e-9,
        @"an inverted control reaches its max at the bottom, not past it");
    for (double u = -0.95; u <= 0.95; u += 0.15) {
      double d = MirageSurfaceCurveDelta(inverted, 58.0, u, -12.0);
      double back = MirageSurfaceCurveDeflection(inverted, 58.0, d, -12.0);
      KKRequire(fabs(back - u) < 1e-3,
                @"an inverted response curve round trips");
    }

    MirageSurfaceResponse noLimits =
        MirageParseSurfaceResponse(@" default=0 surface=\"x:+60\"");
    KKRequire(!noLimits.hasLimits &&
                  fabs(MirageSurfaceCurveDelta(noLimits, 0.0, 0.5, 60.0) -
                       30.0) < 1e-9,
              @"no declared range stays linear");

    // Polar axes: distance drives `r:`, bearing drives `a:`.
    MirageSurfaceResponse radial = MirageParseSurfaceResponse(
        @" min=0 max=200 default=100 surface=\"r:+40\"");
    KKRequire(radial.present && fabs(radial.r - 40.0) < 1e-9 && radial.x == 0.0,
              @"parses a radial response");
    KKRequire(fabs(MirageSurfaceCurveDelta(radial, 100.0, 1.0, radial.r) -
                   100.0) < 1e-9,
              @"the rim reaches a radial control's max");
    KKRequire(fabs(MirageSurfaceCurveDelta(radial, 100.0, 0.0, radial.r)) <
                  1e-9,
              @"the centre is a radial control's default");

    MirageSurfaceResponse angular = MirageParseSurfaceResponse(
        @" min=-180 max=180 default=0 surface=\"a:+180\"");
    KKRequire(angular.present && fabs(angular.a - 180.0) < 1e-9,
              @"parses an angular response");
    KKRequire(fabs(MirageSurfaceAngleDelta(angular, 90.0) - 90.0) < 1e-9,
              @"a:180 maps the bearing one-for-one in degrees");
    KKRequire(fabs(MirageSurfaceAngleForDelta(angular, 90.0) - 90.0) < 1e-9,
              @"an angular response inverts");
    KKRequire(fabs(MirageSurfaceAngleForDelta(angular, 270.0) + 90.0) < 1e-9,
              @"a bearing wraps rather than accumulating past half a turn");

    MirageSurfacePolarFit fit = {0.0, 0, 0.0, 0.0, 0};
    MirageSurfacePolarAddRadius(&fit, 0.5);
    MirageSurfacePolarAddAngle(&fit, 90.0);
    double polarX = 0.0, polarY = 0.0;
    KKRequire(MirageSurfacePolarResolve(fit, &polarX, &polarY) &&
                  fabs(polarX) < 1e-9 && fabs(polarY - 0.5) < 1e-9,
              @"radius plus bearing recombine into a puck position");
    // A mean of 170 and -170 is 180, not 0: the two are ten degrees apart.
    MirageSurfacePolarFit wrapped = {0.0, 0, 0.0, 0.0, 0};
    MirageSurfacePolarAddRadius(&wrapped, 1.0);
    MirageSurfacePolarAddAngle(&wrapped, 170.0);
    MirageSurfacePolarAddAngle(&wrapped, -170.0);
    MirageSurfacePolarResolve(wrapped, &polarX, &polarY);
    KKRequire(polarX < -0.98 && fabs(polarY) < 1e-9,
              @"bearings average circularly, not arithmetically");
    MirageSurfacePolarFit empty = {0.0, 0, 0.0, 0.0, 0};
    KKRequire(!MirageSurfacePolarResolve(empty, &polarX, &polarY),
              @"nothing observed derives nothing");

    KKRequire(
        MirageSurfaceResponsesArePolar(@{
          @"uSat" : [NSValue valueWithBytes:&radial
                                   objCType:@encode(MirageSurfaceResponse)]
        }),
        @"one polar control makes the surface polar");
    KKRequire(!MirageSurfaceResponsesArePolar(@{
      @"uBloom" : [NSValue valueWithBytes:&curve
                                 objCType:@encode(MirageSurfaceResponse)]
    }),
              @"a cartesian-only surface stays cartesian");

    // Named pucks: several independent handles sharing one circle.
    MirageSurfaceResponse named = MirageParseSurfaceResponse(
        @" min=-100 max=100 default=0 surface=\"x:+40\" "
        @"puck={\"Shadows\", \"moon\"}");
    KKRequire(strcmp(named.puck, "Shadows") == 0 &&
                  strcmp(named.puckSymbol, "moon") == 0,
              @"parses a puck name and its icon");
    MirageSurfaceResponse bare = MirageParseSurfaceResponse(
        @" default=0 surface=\"x:+40\" puck=\"Highlights\"");
    KKRequire(strcmp(bare.puck, "Highlights") == 0 && bare.puckSymbol[0] == 0,
              @"a puck may be named without an icon");
    MirageSurfaceResponse unnamed =
        MirageParseSurfaceResponse(@" default=0 surface=\"x:+40\"");
    KKRequire(unnamed.puck[0] == 0,
              @"no puck= leaves the response on the single unnamed puck");

    NSString *twoPucks = @"// #float label=\"A\" default=0 surface=\"x:+40\" "
                         @"puck={\"Shadows\", \"moon\"}\n"
                         @"uniform float uA;\n"
                         @"// #float label=\"B\" default=0 surface=\"y:+40\" "
                         @"puck={\"Shadows\", \"moon\"}\n"
                         @"uniform float uB;\n"
                         @"// #float label=\"C\" default=0 surface=\"x:+40\" "
                         @"puck={\"Highlights\", \"sun.max\"}\n"
                         @"uniform float uC;\n";
    NSArray<NSDictionary<NSString *, NSString *> *> *pucks =
        MirageSurfacePucksForSource(twoPucks);
    KKRequire(pucks.count == 2,
              @"one entry per distinct puck, not per control");
    KKRequire([pucks[0][@"name"] isEqualToString:@"Shadows"] &&
                  [pucks[0][@"symbol"] isEqualToString:@"moon"] &&
                  [pucks[1][@"name"] isEqualToString:@"Highlights"],
              @"pucks keep the order the author declared them in");
    KKRequire(
        MirageSurfacePucksForSource(@"// #float label=\"A\" default=0 "
                                    @"surface=\"x:+40\"\nuniform float uA;")
                    .count == 1 &&
            [MirageSurfacePucksForSource(@"")[0][@"name"] isEqualToString:@""],
        @"a shader with no puck= still reports one unnamed puck");

    // A tracked puck: pinned to a circle so the gesture is a rotation only.
    MirageSurfaceResponse tracked = MirageParseSurfaceResponse(
        @" min=-180 max=180 default=0 surface=\"a:+180\" track=0.75");
    KKRequire(fabs(tracked.track - 0.75) < 1e-9, @"parses a track radius");
    KKRequire(
        MirageParseSurfaceResponse(@" default=0 surface=\"a:+180\"").track ==
            0.0,
        @"no track= leaves the puck free");
    KKRequire(
        MirageParseSurfaceResponse(@" default=0 surface=\"a:+180\" track=4")
                    .track == 1.0 &&
            MirageParseSurfaceResponse(
                @" default=0 surface=\"a:+180\" track=0.01")
                    .track == 0.1,
        @"a track outside the disc is clamped, not rejected");

    // The track may be declared on any of the puck's controls, not just the
    // first.
    NSString *lateTrack = @"// #float label=\"A\" default=0 surface=\"a:+180\" "
                          @"puck={\"Target\", \"eyedropper\"}\n"
                          @"uniform float uA;\n"
                          @"// #float label=\"B\" default=0 surface=\"a:+90\" "
                          @"puck={\"Target\", \"eyedropper\"} track=0.8\n"
                          @"uniform float uB;\n";
    NSArray<NSDictionary<NSString *, NSString *> *> *late =
        MirageSurfacePucksForSource(lateTrack);
    KKRequire(late.count == 1 && [late[0][@"track"] doubleValue] == 0.8,
              @"a track on a later control still reaches its puck");

    // `pick=`: the eyedropper's subscribers, parsed independently of surface=.
    NSString *pickSource =
        @"// #float label=\"Target Hue\" min=-180 max=180 default=0 pick=hue\n"
        @"uniform float uHue;\n"
        @"// #percent label=\"Sat\" min=0 max=100 default=50 pick=saturation\n"
        @"uniform float uSat;\n"
        @"// #float label=\"Luma\" min=0 max=1 default=0.5 pick=luma\n"
        @"uniform float uLuma;\n"
        @"// #percent label=\"Pivot\" min=1 max=99 default=18 "
        @"pick=luma-linear\n"
        @"uniform float uPivot;\n"
        @"// #color label=\"Key\" default=#ff0000 pick=color\n"
        @"uniform vec4 uKey;\n"
        @"// #float label=\"Nope\" default=0 pick=chroma\n"
        @"uniform float uNope;\n"
        @"// #float label=\"Plain\" default=0\n"
        @"uniform float uPlain;\n"
        @"// #float label=\"Orphan\" default=0 pick=hue\n";
    NSDictionary<NSString *, NSNumber *> *picks =
        MirageSurfacePicksForSource(pickSource);
    KKRequire(picks.count == 5, @"maps only the controls that subscribed");
    KKRequire(picks[@"uHue"].integerValue == MirageSurfacePickKindHue &&
                  picks[@"uSat"].integerValue ==
                      MirageSurfacePickKindSaturation &&
                  picks[@"uLuma"].integerValue == MirageSurfacePickKindLuma &&
                  picks[@"uKey"].integerValue == MirageSurfacePickKindColor,
              @"keys each kind by its uniform name");
    // The hyphen has to survive the value parser, or `luma-linear` arrives as
    // `luma` and the control quietly gets the display number it was moved off.
    KKRequire(picks[@"uPivot"].integerValue == MirageSurfacePickKindLumaLinear,
              @"luma-linear parses whole rather than truncating at the hyphen");
    KKRequire(MirageParseSurfacePick(@"pick=luma") ==
                      MirageSurfacePickKindLuma &&
                  MirageParseSurfacePick(@"pick=luma-linear") ==
                      MirageSurfacePickKindLumaLinear,
              @"the two luma kinds stay distinct");
    KKRequire(
        MirageParseSurfacePick(@"pick=luma-lin") == MirageSurfacePickKindNone &&
            MirageParseSurfacePick(@"pick=linear") == MirageSurfacePickKindNone,
        @"a near-miss spelling subscribes to nothing rather than to luma");
    KKRequire(!picks[@"uNope"],
              @"an unrecognised pick= value subscribes to nothing");
    KKRequire(!picks[@"uPlain"],
              @"a control with no pick= subscribes to nothing");
    KKRequire(!picks[@"uOrphan"] && picks.count == 5,
              @"a pick= directive with no uniform after it is ignored");

    // The two attributes are independent: declaring both must leave each parse
    // reading exactly what it would have read alone.
    NSString *bothSource =
        @"// #float label=\"Hue\" min=-180 max=180 default=0 "
        @"surface=\"a:+180\" "
        @"pick=hue puck={\"Target\", \"eyedropper\"}\n"
        @"uniform float uBoth;\n"
        @"// #float label=\"Only Pick\" min=0 max=1 default=0 pick=luma\n"
        @"uniform float uOnlyPick;\n";
    KKRequire(MirageSurfacePicksForSource(bothSource).count == 2,
              @"pick= is read whether or not the control also has a surface=");
    NSDictionary<NSString *, NSValue *> *bothResponses =
        MirageSurfaceResponsesForSource(bothSource);
    KKRequire(bothResponses.count == 1 && bothResponses[@"uBoth"],
              @"pick= adds nothing to the surface responses");
    MirageSurfaceResponse both709;
    [bothResponses[@"uBoth"] getValue:&both709];
    KKRequire(fabs(both709.a - 180.0) < 1e-9 && both709.hasBase &&
                  strcmp(both709.puck, "Target") == 0,
              @"a pick= alongside surface= does not perturb the response");
    NSArray<NSDictionary<NSString *, NSString *> *> *bothPucks =
        MirageSurfacePucksForSource(bothSource);
    KKRequire(bothPucks.count == 1 &&
                  [bothPucks[0][@"name"] isEqualToString:@"Target"],
              @"a pick-only control does not invent a puck");

    // Hue and saturation come out of one pass over the same max/min pair.
    double sat = -1.0;
    double hue = MirageSurfaceHueDegreesWithSaturation(0.5, 0.25, 0.25, &sat);
    KKRequire(fabs(hue) < 1e-9 && fabs(sat - 0.5) < 1e-9,
              @"reports a hue and its saturation together");
    KKRequire(MirageSurfaceHueDegreesWithSaturation(0.4, 0.4, 0.4, &sat) <
                      0.0 &&
                  fabs(sat) < 1e-9,
              @"a neutral patch has no hue and no saturation");

    // Oklab: the space the grading wheel paints in, and now the only space any
    // colour on the surface is measured or written in.
    const double lchTrip[][3] = {{0.78, 0.58, 0.47},
                                 {0.20, 0.55, 0.30},
                                 {0.90, 0.90, 0.10},
                                 {0.35, 0.35, 0.80},
                                 {0.50, 0.50, 0.50}};
    for (size_t i = 0; i < sizeof(lchTrip) / sizeof(*lchTrip); i++) {
      double L = 0.0, C = 0.0, h = -1.0;
      MirageSurfaceOklabLCh(lchTrip[i][0], lchTrip[i][1], lchTrip[i][2], &L, &C,
                            &h);
      double br = 0.0, bg = 0.0, bb = 0.0;
      MirageSurfaceEncodedForOklabLCh(L, C, h < 0.0 ? 0.0 : h, &br, &bg, &bb);
      KKRequire(fabs(br - lchTrip[i][0]) < 1e-4 &&
                    fabs(bg - lchTrip[i][1]) < 1e-4 &&
                    fabs(bb - lchTrip[i][2]) < 1e-4,
                @"an in-gamut colour survives the LCh round trip");
    }
    KKRequire(({
                double L = 0.0, C = 0.0, h = 0.0;
                MirageSurfaceOklabLCh(0.5, 0.5, 0.5, &L, &C, &h);
                h < 0.0 && C < 1e-4;
              }),
              @"a grey has no Oklab hue to report");

    // Write a bearing, read it back: this is the exactness the whole space
    // change exists to deliver, so it has to hold on the out-of-gamut request
    // too. A plain clamp instead of the chroma descent swings the landed hue by
    // 6 to 11 degrees there, which is the bug rewritten in a new space.
    const double bearings[] = {0.0, 50.0, 120.0, 200.0, 300.0};
    for (size_t i = 0; i < sizeof(bearings) / sizeof(*bearings); i++) {
      double wr = 0.0, wg = 0.0, wb = 0.0;
      MirageSurfaceEncodedForOklabLCh(0.62, 0.12, bearings[i], &wr, &wg, &wb);
      double back = -1.0;
      MirageSurfaceOklabLCh(wr, wg, wb, NULL, NULL, &back);
      KKRequire(fabs(MirageSurfaceHueDelta(bearings[i], back)) < 0.5,
                @"a written bearing reads back as the same hue");
    }
    double tr = 0.0, tg = 0.0, tb = 0.0;
    MirageSurfaceEncodedForOklabLCh(0.62, 0.30, 200.0, &tr, &tg, &tb);
    double tightC = 0.0, tightH = -1.0;
    MirageSurfaceOklabLCh(tr, tg, tb, NULL, &tightC, &tightH);
    KKRequire(fabs(MirageSurfaceHueDelta(200.0, tightH)) < 0.5 && tightC < 0.30,
              @"an unreachable chroma is halved away, not clamped off-hue");

    // The number that proves the space actually changed: a skin tone measures
    // ~50 degrees in Oklab where HSV called it ~21.
    double skinH = -1.0;
    MirageSurfaceOklabLCh(0.78, 0.58, 0.47, NULL, NULL, &skinH);
    KKRequire(skinH > 46.0 && skinH < 54.0,
              @"skin measures its Oklab hue, not its HSV one");
    KKRequire(MirageSurfaceHueDegrees(0.78, 0.58, 0.47) < 30.0,
              @"and HSV is the number it is no longer using");

    // A `#color` control's hex default is that same Oklab measurement, because
    // apply, derive and recentre are all angles against it.
    MirageSurfaceResponse hexBase = MirageParseSurfaceResponse(
        @" label=\"Key\" default=\"#FF8C5A\" surface=\"a:+180\"");
    // Through the same float components the hex parser hands back, so the only
    // difference under test is the space and not the width of the round trip.
    float hexRGB[3] = {1.0f, (float)(0x8C / 255.0), (float)(0x5A / 255.0)};
    double hexH = -1.0;
    MirageSurfaceOklabLCh(hexRGB[0], hexRGB[1], hexRGB[2], NULL, NULL, &hexH);
    KKRequire(hexBase.hasBase && hexBase.baseIsHue &&
                  fabs(hexBase.base - hexH) < 1e-9,
              @"a hex default's origin is its Oklab hue");
    KKRequire(fabs(MirageSurfaceHueDelta(
                  MirageSurfaceHueDegrees(hexRGB[0], hexRGB[1], hexRGB[2]),
                  hexBase.base)) > 5.0,
              @"which is a different angle from the HSV one it used to be");

    // Disc <-> the controls' axes. The screen-aligned cases below are the
    // regression guard: the generalised stretch has to reduce exactly to the
    // old
    // `|p| / max(|px|, |py|)` when the axes are at 0 and 90 degrees.
    MirageSurfaceAxisSet screenAxes;
    memset(&screenAxes, 0, sizeof(screenAxes));
    MirageSurfaceAxisSetAdd(&screenAxes, 40.0, 0.0);
    MirageSurfaceAxisSetAdd(&screenAxes, 0.0, -30.0);
    KKRequire(screenAxes.count == 2, @"two directions make two axes");
    MirageSurfaceAxisSetAdd(&screenAxes, -12.0, 0.0);
    MirageSurfaceAxisSetAdd(&screenAxes, 0.0, 0.0);
    KKRequire(screenAxes.count == 2,
              @"a parallel control and a dead one add no axis");

    // The round trip has to be exact, or a puck would creep every time the
    // derive fed a position back into the display.
    const double roundTrip[][2] = {{1.0, 0.0},   {0.0, -1.0},  {0.7, 0.7},
                                   {-0.5, 0.25}, {0.31, -0.9}, {0.0, 0.0}};
    for (size_t i = 0; i < sizeof(roundTrip) / sizeof(*roundTrip); i++) {
      double rx = roundTrip[i][0], ry = roundTrip[i][1];
      MirageSurfaceDiscToAxes(&rx, &ry, screenAxes);
      MirageSurfaceAxesToDisc(&rx, &ry, screenAxes);
      KKRequire(fabs(rx - roundTrip[i][0]) < 1e-9 &&
                    fabs(ry - roundTrip[i][1]) < 1e-9,
                @"disc to the control basis and back is the identity");
    }
    double ax = 0.6, ay = 0.0;
    MirageSurfaceDiscToAxes(&ax, &ay, screenAxes);
    KKRequire(fabs(ax - 0.6) < 1e-9 && fabs(ay) < 1e-9,
              @"a point on an axis is left where it is");
    // The whole point: the rim at 45 degrees has to land on the corner, so a
    // pair of perpendicular controls can both reach their limits from one
    // gesture.
    const double diagonal[][2] = {{M_SQRT1_2, M_SQRT1_2},
                                  {-M_SQRT1_2, M_SQRT1_2},
                                  {M_SQRT1_2, -M_SQRT1_2},
                                  {-M_SQRT1_2, -M_SQRT1_2}};
    for (size_t i = 0; i < sizeof(diagonal) / sizeof(*diagonal); i++) {
      double cx = diagonal[i][0], cy = diagonal[i][1];
      MirageSurfaceDiscToAxes(&cx, &cy, screenAxes);
      KKRequire(fabs(fabs(cx) - 1.0) < 1e-9 && fabs(fabs(cy) - 1.0) < 1e-9,
                @"the diagonal rim reaches the corner");
    }
    double previous = -1.0;
    for (int step = 0; step <= 20; step++) {
      double t = (double)step / 20.0;
      double mx = t * M_SQRT1_2, my = t * M_SQRT1_2;
      MirageSurfaceDiscToAxes(&mx, &my, screenAxes);
      KKRequire(mx > previous, @"the stretch is monotonic along a diagonal");
      previous = mx;
    }

    // Rotated axes: the Grade and Ranges templates point Red/Cyan at 29 degrees
    // and Green/Magenta at 142, and the screen-basis stretch projected 1.36
    // onto the 29-degree axis from a drag to the screen diagonal - 36 percent
    // past full deflection. The write clamped, the derive read the clamp back
    // as a full deflection, and the puck sprang inward on release.
    MirageSurfaceAxisSet hueAxes;
    memset(&hueAxes, 0, sizeof(hueAxes));
    MirageSurfaceAxisSetAdd(&hueAxes, 35.0, 19.0);  // 28.5 degrees
    MirageSurfaceAxisSetAdd(&hueAxes, -32.0, 25.0); // 142.0 degrees
    MirageSurfaceAxisSet singleAxis;
    memset(&singleAxis, 0, sizeof(singleAxis));
    MirageSurfaceAxisSetAdd(&singleAxis, 35.0, 19.0);
    MirageSurfaceAxisSet noAxes;
    memset(&noAxes, 0, sizeof(noAxes));
    const MirageSurfaceAxisSet sets[] = {screenAxes, hueAxes, singleAxis,
                                         noAxes};
    for (size_t s = 0; s < sizeof(sets) / sizeof(*sets); s++) {
      MirageSurfaceAxisSet axes = sets[s];
      double worstProjection = 0.0;
      for (int deg = 0; deg < 360; deg++) {
        double t = deg * M_PI / 180.0;
        double px = cos(t), py = sin(t);
        double qx = px, qy = py;
        MirageSurfaceDiscToAxes(&qx, &qy, axes);
        double strongest = 0.0;
        for (int i = 0; i < axes.count; i++)
          strongest = fmax(strongest, fabs(qx * axes.x[i] + qy * axes.y[i]));
        worstProjection = fmax(worstProjection, strongest);
        // At the rim the STRONGEST-affected control has to sit at exactly full
        // deflection: any less and the corner is unreachable, any more and the
        // write clamps where the derive cannot follow it.
        KKRequire(!axes.count || fabs(strongest - 1.0) < 1e-9,
                  @"the rim is exactly full deflection at every bearing");
        for (int step = 0; step <= 10; step++) {
          double f = (double)step / 10.0;
          double ix = px * f, iy = py * f;
          double bx = ix, by = iy;
          MirageSurfaceDiscToAxes(&bx, &by, axes);
          MirageSurfaceAxesToDisc(&bx, &by, axes);
          KKRequire(fabs(bx - ix) < 1e-9 && fabs(by - iy) < 1e-9,
                    @"the stretch inverts exactly for any axis set");
        }
      }
      KKRequire(worstProjection <= 1.0 + 1e-9,
                @"no control overshoots its range in any direction");
    }

    MirageSurfaceSample dead[1] = {{0.0, 0.0, 5.0}};
    KKRequire(!MirageSurfaceDerivePuck(dead, 1, &dx, &dy),
              @"a control that cannot respond derives nothing");

    // `// #frames`. The offset list IS the binding order of the iNeighbor
    // samplers, so declaration order has to survive the parse untouched and
    // anything ambiguous has to be rejected rather than repaired.
    MirageFramesDirectiveError framesError = MirageFramesDirectiveErrorNone;
    MirageFrameOffsets frames = MirageFrameOffsetsForSource(
        @"// #template filter\n// #frames offsets=\"-1, +3,-2\"\n"
        @"void mainImage(out vec4 O, in vec2 fc) { O = vec4(0.0); }\n",
        &framesError);
    KKRequire(framesError == MirageFramesDirectiveErrorNone &&
                  frames.count == 3 && frames.offsets[0] == -1 &&
                  frames.offsets[1] == 3 && frames.offsets[2] == -2,
              @"parses #frames offsets in declaration order");

    framesError = MirageFramesDirectiveErrorMultiple;
    frames = MirageFrameOffsetsForSource(
        @"// #template filter\nvoid mainImage() {}\n", &framesError);
    KKRequire(frames.count == 0 &&
                  framesError == MirageFramesDirectiveErrorNone,
              @"a shader with no #frames requests no frames and is not an "
              @"error");

    NSMutableArray<NSString *> *manyOffsets = [NSMutableArray array];
    for (int i = 1; i <= KK_SHADER_MAX_FRAME_OFFSETS; i++)
      [manyOffsets addObject:[NSString stringWithFormat:@"-%d", i]];
    frames = MirageFrameOffsetsForSource(
        [NSString stringWithFormat:@"// #frames offsets=\"%@\"\n",
                                   [manyOffsets componentsJoinedByString:@","]],
        &framesError);
    KKRequire(frames.count == KK_SHADER_MAX_FRAME_OFFSETS &&
                  framesError == MirageFramesDirectiveErrorNone,
              @"accepts exactly the offset cap");
    [manyOffsets addObject:@"-99"];
    frames = MirageFrameOffsetsForSource(
        [NSString stringWithFormat:@"// #frames offsets=\"%@\"\n",
                                   [manyOffsets componentsJoinedByString:@","]],
        &framesError);
    KKRequire(frames.count == 0 &&
                  framesError == MirageFramesDirectiveErrorTooMany,
              @"rejects one offset past the cap");

    frames = MirageFrameOffsetsForSource(@"// #frames offsets=\"-1,0,+1\"\n",
                                         &framesError);
    KKRequire(frames.count == 0 &&
                  framesError == MirageFramesDirectiveErrorZero,
              @"rejects offset 0, which is already iChannel0");

    frames = MirageFrameOffsetsForSource(@"// #frames offsets=\"-1,-2,-1\"\n",
                                         &framesError);
    KKRequire(frames.count == 0 &&
                  framesError == MirageFramesDirectiveErrorDuplicate,
              @"rejects a duplicate offset rather than folding it");

    frames = MirageFrameOffsetsForSource(
        @"// #frames offsets=\"-1\"\n// #frames offsets=\"+1\"\n",
        &framesError);
    KKRequire(frames.count == 0 &&
                  framesError == MirageFramesDirectiveErrorMultiple,
              @"rejects a second #frames directive");

    frames = MirageFrameOffsetsForSource(@"// #frames\n", &framesError);
    KKRequire(frames.count == 0 &&
                  framesError == MirageFramesDirectiveErrorMissing,
              @"rejects #frames with no offsets list");
    frames = MirageFrameOffsetsForSource(@"// #frames offsets=\"-1,half\"\n",
                                         &framesError);
    KKRequire(frames.count == 0 &&
                  framesError == MirageFramesDirectiveErrorValue,
              @"rejects an offset that is not a whole number");

    // #frames and #motionblur are independent whole-shader directives that a
    // shader may declare together; neither parse may swallow the other's line.
    frames = MirageFrameOffsetsForSource(
        @"// #template filter\n// #motionblur native on\n"
        @"// #frames offsets=\"-1,-2\"\n"
        @"void mainImage(out vec4 O, in vec2 fc) { O = vec4(0.0); }\n",
        &framesError);
    KKRequire(framesError == MirageFramesDirectiveErrorNone &&
                  frames.count == 2 && frames.offsets[0] == -1 &&
                  frames.offsets[1] == -2,
              @"#frames parses alongside #motionblur");
    frames = MirageFrameOffsetsForSource(
        @"// #motionblur accumulate\nvoid mainImage() {}\n", &framesError);
    KKRequire(frames.count == 0 &&
                  framesError == MirageFramesDirectiveErrorNone,
              @"#motionblur alone declares no frames");

    frames = MirageFrameOffsetsForSource(
        @"// #frames-per-second offsets=\"-1\"\n", &framesError);
    KKRequire(frames.count == 0 &&
                  framesError == MirageFramesDirectiveErrorNone,
              @"does not read #frames-per-second as #frames");

    // `// #slots`: a group of controls declared once and instanced at runtime.
    MirageSlotsDirectiveError slotsError = MirageSlotsDirectiveErrorNone;
    NSString *slotsDetail = nil;
    NSString *oneGroup =
        @"// #template generator\n"
        @"// #slots name=\"Colour\" max=8 default=2 min=1\n"
        @"// #color label=\"New Colour {n}\" puck={\"Colour {n}\", "
        @"\"{n}.circle\"} pick=hue\n"
        @"uniform vec4 uNewColour;\n"
        @"// #float label=\"Strength {n}\" min=0 max=1 default=0.5\n"
        @"uniform float uNewStrength;\n"
        @"// #slots-end\n"
        @"void mainImage(out vec4 O, in vec2 fc) { O = vec4(0.0); }\n";
    NSArray<NSValue *> *groups =
        MirageSlotGroupsForSource(oneGroup, &slotsError, &slotsDetail);
    KKRequire(groups.count == 1 && slotsError == MirageSlotsDirectiveErrorNone,
              @"parses one #slots block");
    MirageSlotsGroup g0 = MirageSlotsGroupValue(groups[0]);
    KKRequire([@(g0.name) isEqualToString:@"Colour"] && g0.maxCount == 8 &&
                  g0.defaultCount == 2 && g0.minCount == 1,
              @"reads name, max, default and min");
    KKRequire(g0.bodyRange.length > 0 &&
                  NSMaxRange(g0.bodyRange) < NSMaxRange(g0.range),
              @"the body is the controls, inside the block's own range");
    NSDictionary<NSString *, NSNumber *> *byUniform =
        MirageSlotGroupIndexByUniform(oneGroup);
    KKRequire(byUniform.count == 2 &&
                  byUniform[@"uNewColour"].integerValue == 0 &&
                  byUniform[@"uNewStrength"].integerValue == 0,
              @"both controls resolve to the group that repeats them");
    KKRequire(MirageSlotGroupIndexForLocation(
                  groups, [oneGroup rangeOfString:@"#float"].location) == 0 &&
                  MirageSlotGroupIndexForLocation(
                      groups, [oneGroup rangeOfString:@"#template"].location) ==
                      -1,
              @"membership answers by source location too");

    // Defaults: `default=` absent starts at one instance, `min=` at none.
    groups = MirageSlotGroupsForSource(@"// #slots name=\"Layer\" max=4\n"
                                       @"// #float label=\"Size {n}\"\n"
                                       @"uniform float uSize;\n"
                                       @"// #slots-end\n",
                                       &slotsError, &slotsDetail);
    g0 = MirageSlotsGroupValue(groups.firstObject);
    KKRequire(groups.count == 1 && g0.defaultCount == 1 && g0.minCount == 0,
              @"an unstated default is one instance and an unstated min none");

    // Two groups are legal: a shader may repeat more than one thing.
    NSString *twoGroups = @"// #slots name=\"Colour\" max=4\n"
                          @"// #color label=\"Colour {n}\"\n"
                          @"uniform vec4 uColour;\n"
                          @"// #slots-end\n"
                          @"// #slots name=\"Light\" max=3 default=0\n"
                          @"// #point label=\"Light {n}\" osc=point\n"
                          @"uniform vec2 uLight;\n"
                          @"// #slots-end\n";
    groups = MirageSlotGroupsForSource(twoGroups, &slotsError, &slotsDetail);
    KKRequire(groups.count == 2 && slotsError == MirageSlotsDirectiveErrorNone,
              @"two groups are two groups, not a nesting error");
    KKRequire(
        [@(MirageSlotsGroupValue(groups[1]).name) isEqualToString:@"Light"] &&
            MirageSlotsGroupValue(groups[1]).defaultCount == 0,
        @"the second group keeps its own name and counts");
    byUniform = MirageSlotGroupIndexByUniform(twoGroups);
    KKRequire(byUniform[@"uColour"].integerValue == 0 &&
                  byUniform[@"uLight"].integerValue == 1,
              @"each control belongs to the block it sits in");

    groups = MirageSlotGroupsForSource(@"// #slots name=\"Colour\" max=4\n"
                                       @"// #color label=\"Colour {n}\"\n"
                                       @"uniform vec4 uColour;\n",
                                       &slotsError, &slotsDetail);
    KKRequire(groups.count == 0 &&
                  slotsError == MirageSlotsDirectiveErrorUnclosed,
              @"an unclosed block is an error, not an open-ended group");

    groups = MirageSlotGroupsForSource(@"// #slots-end\n", &slotsError,
                                       &slotsDetail);
    KKRequire(groups.count == 0 &&
                  slotsError == MirageSlotsDirectiveErrorUnopened,
              @"#slots-end with nothing open is an error");

    groups = MirageSlotGroupsForSource(@"// #slots name=\"A\" max=4\n"
                                       @"// #slots name=\"B\" max=2\n"
                                       @"// #slots-end\n"
                                       @"// #slots-end\n",
                                       &slotsError, &slotsDetail);
    KKRequire(groups.count == 0 &&
                  slotsError == MirageSlotsDirectiveErrorNested &&
                  [slotsDetail isEqualToString:@"B"],
              @"nesting is rejected and names the inner group");

    groups = MirageSlotGroupsForSource(@"// #slots max=4\n"
                                       @"// #slots-end\n",
                                       &slotsError, &slotsDetail);
    KKRequire(groups.count == 0 && slotsError == MirageSlotsDirectiveErrorName,
              @"a group with no name has nothing to key its lanes on");
    groups = MirageSlotGroupsForSource(@"// #slots name=\"Colour!\" max=4\n"
                                       @"// #slots-end\n",
                                       &slotsError, &slotsDetail);
    KKRequire(groups.count == 0 && slotsError == MirageSlotsDirectiveErrorName,
              @"a name outside the lane-key charset is rejected");

    groups = MirageSlotGroupsForSource(@"// #slots name=\"Colour\"\n"
                                       @"// #slots-end\n",
                                       &slotsError, &slotsDetail);
    KKRequire(groups.count == 0 && slotsError == MirageSlotsDirectiveErrorMax,
              @"max is required - the pool budget is finite");
    groups = MirageSlotGroupsForSource(
        [NSString stringWithFormat:@"// #slots name=\"Colour\" max=%d\n"
                                   @"// #slots-end\n",
                                   KK_SHADER_MAX_SLOT_INSTANCES + 1],
        &slotsError, &slotsDetail);
    KKRequire(groups.count == 0 && slotsError == MirageSlotsDirectiveErrorMax,
              @"one instance past the cap is rejected");
    groups = MirageSlotGroupsForSource(
        [NSString stringWithFormat:@"// #slots name=\"Colour\" max=%d\n"
                                   @"// #slots-end\n",
                                   KK_SHADER_MAX_SLOT_INSTANCES],
        &slotsError, &slotsDetail);
    KKRequire(groups.count == 1 && slotsError == MirageSlotsDirectiveErrorNone,
              @"accepts exactly the cap");
    groups = MirageSlotGroupsForSource(@"// #slots name=\"Colour\" max=0\n"
                                       @"// #slots-end\n",
                                       &slotsError, &slotsDetail);
    KKRequire(groups.count == 0 && slotsError == MirageSlotsDirectiveErrorMax,
              @"a group that can never have an instance is not a group");

    groups = MirageSlotGroupsForSource(
        @"// #slots name=\"Colour\" max=4 default=5\n// #slots-end\n",
        &slotsError, &slotsDetail);
    KKRequire(groups.count == 0 && slotsError == MirageSlotsDirectiveErrorCount,
              @"a default above max is rejected");
    groups = MirageSlotGroupsForSource(
        @"// #slots name=\"Colour\" max=4 min=5\n// #slots-end\n", &slotsError,
        &slotsDetail);
    KKRequire(groups.count == 0 && slotsError == MirageSlotsDirectiveErrorCount,
              @"a min above max is rejected");
    groups = MirageSlotGroupsForSource(
        @"// #slots name=\"Colour\" max=4 min=3 default=1\n// #slots-end\n",
        &slotsError, &slotsDetail);
    KKRequire(
        groups.count == 0 && slotsError == MirageSlotsDirectiveErrorCount,
        @"a default the panel would refuse to delete down to is rejected");

    groups = MirageSlotGroupsForSource(@"// #slots name=\"Colour\" max=4\n"
                                       @"// #slots-end\n"
                                       @"// #slots name=\"colour\" max=2\n"
                                       @"// #slots-end\n",
                                       &slotsError, &slotsDetail);
    KKRequire(groups.count == 0 &&
                  slotsError == MirageSlotsDirectiveErrorDuplicateName,
              @"two groups may not share a name, whatever its case");

    groups = MirageSlotGroupsForSource(@"// #slots name=\"Colour\" max=4\n"
                                       @"// #color label=\"Colour\"\n"
                                       @"uniform vec4 uColour;\n"
                                       @"// #slots-end\n",
                                       &slotsError, &slotsDetail);
    KKRequire(groups.count == 0 &&
                  slotsError == MirageSlotsDirectiveErrorPlaceholder &&
                  [slotsDetail isEqualToString:@"Colour"],
              @"a label with no {n} would collide across instances");
    groups = MirageSlotGroupsForSource(@"// #slots name=\"Colour\" max=4\n"
                                       @"// #color\n"
                                       @"uniform vec4 uColour;\n"
                                       @"// #slots-end\n",
                                       &slotsError, &slotsDetail);
    KKRequire(groups.count == 0 &&
                  slotsError == MirageSlotsDirectiveErrorPlaceholder &&
                  [slotsDetail isEqualToString:@"uColour"],
              @"a control with no label at all is named by its uniform");
    groups = MirageSlotGroupsForSource(
        @"// #slots name=\"Colour\" max=4\n"
        @"// #color label=\"Colour {n}\" puck={\"Colour\", \"moon\"}\n"
        @"uniform vec4 uColour;\n"
        @"// #slots-end\n",
        &slotsError, &slotsDetail);
    KKRequire(groups.count == 0 &&
                  slotsError == MirageSlotsDirectiveErrorPlaceholder,
              @"a shared puck name would make every instance one handle");
    groups = MirageSlotGroupsForSource(
        @"// #slots name=\"Colour\" max=4\n"
        @"// #color label=\"New Colour {n}\" "
        @"puck={\"Colour {n}\", \"{n}.circle\"} pick=hue\n"
        @"uniform vec4 uColour;\n"
        @"// #slots-end\n",
        &slotsError, &slotsDetail);
    KKRequire(groups.count == 1 && slotsError == MirageSlotsDirectiveErrorNone,
              @"a per-instance puck, named and drawn by its number, is legal");
    // An unnamed puck used to pass the placeholder rule by being EMPTY rather
    // than by being distinct - which is the collapse the rule exists to stop,
    // arrived at through the front door.
    groups = MirageSlotGroupsForSource(@"// #slots name=\"Colour\" max=4\n"
                                       @"// #color label=\"Colour {n}\" "
                                       @"puck={\"\", \"{n}.circle\"}\n"
                                       @"uniform vec4 uColour;\n"
                                       @"// #slots-end\n",
                                       &slotsError, &slotsDetail);
    KKRequire(groups.count == 0 &&
                  slotsError == MirageSlotsDirectiveErrorPuckName &&
                  [slotsDetail isEqualToString:@"Colour {n}"],
              @"a puck written with no name is every instance's one handle");
    groups = MirageSlotGroupsForSource(@"// #slots name=\"Colour\" max=4\n"
                                       @"// #color label=\"Colour {n}\" "
                                       @"puck={Colour}\n"
                                       @"uniform vec4 uColour;\n"
                                       @"// #slots-end\n",
                                       &slotsError, &slotsDetail);
    KKRequire(groups.count == 0 &&
                  slotsError == MirageSlotsDirectiveErrorPuckName,
              @"and so is one written in a shape the parse cannot read");
    // Outside a block the same line is fine: there is one handle by design, so
    // an unnamed puck is the shader's single unnamed puck, not a collision.
    groups = MirageSlotGroupsForSource(@"// #color label=\"Colour\" "
                                       @"puck={\"\", \"moon\"}\n"
                                       @"uniform vec4 uColour;\n",
                                       &slotsError, &slotsDetail);
    KKRequire(groups.count == 0 &&
                  slotsError == MirageSlotsDirectiveErrorNone &&
                  slotsDetail == nil,
              @"an unnamed puck outside every block is the unnamed puck");
    groups = MirageSlotGroupsForSource(@"// #slots name=\"Colour\" max=4\n"
                                       @"// #speed\n"
                                       @"// #color label=\"Colour {n}\"\n"
                                       @"uniform vec4 uColour;\n"
                                       @"// #slots-end\n",
                                       &slotsError, &slotsDetail);
    KKRequire(
        groups.count == 1 && slotsError == MirageSlotsDirectiveErrorNone,
        @"a standalone directive declares no control, so it needs no {n}");

    groups = MirageSlotGroupsForSource(@"// #float label=\"Size {n}\"\n"
                                       @"uniform float uSize;\n",
                                       &slotsError, &slotsDetail);
    KKRequire(groups.count == 0 &&
                  slotsError == MirageSlotsDirectiveErrorStrayPlaceholder &&
                  [slotsDetail isEqualToString:@"#float"],
              @"{n} outside every block has no instance number to carry");

    KKRequire(
        [MirageSlotsSubstitute(@"New Colour {n}", 3)
            isEqualToString:@"New Colour 3"] &&
            [MirageSlotsSubstitute(@"{n}.circle", 2)
                isEqualToString:@"2.circle"] &&
            [MirageSlotsSubstitute(@"{N} of {n}", 1) isEqualToString:@"1 of 1"],
        @"substitutes the instance number, in either spelling");
    KKRequire(MirageSlotsHasPlaceholder(@"Colour {n}") &&
                  !MirageSlotsHasPlaceholder(@"Colour n"),
              @"the placeholder is the braced form only");
    KKRequire([MirageSlotsCountUniformName("Colour")
                  isEqualToString:@"uColourCount"] &&
                  [MirageSlotsCountUniformName("new colour")
                      isEqualToString:@"uNewColourCount"],
              @"the injected count uniform is named from the group");

    // The shape of every shader written before `#slots` existed: no block, no
    // groups, no error, and nothing else about it read differently.
    NSString *legacy = @"// #template filter\n"
                       @"// #color-surface ring=light\n"
                       @"// #float label=\"Amount\" min=0 max=2 default=0.5 "
                       @"surface=\"y:+30\"\n"
                       @"uniform float uAmount;\n";
    groups = MirageSlotGroupsForSource(legacy, &slotsError, &slotsDetail);
    KKRequire(groups.count == 0 &&
                  slotsError == MirageSlotsDirectiveErrorNone &&
                  slotsDetail == nil,
              @"a shader with no #slots declares no groups and no error");
    KKRequire(MirageSlotGroupIndexByUniform(legacy).count == 0 &&
                  MirageSlotGroupIndexForLocation(@[], 0) == -1,
              @"and nothing belongs to a group that isn't there");
    KKRequire(
        MirageParseSurfaceResponse(@" default=0.5 surface=\"y:+30\"").present,
        @"the surface grammar around it is unchanged");

    // Kinds the pool cannot repeat. Each one would otherwise be a single value
    // wearing an instance's row.
    MirageSlotRepeatKind repeatKind = MirageSlotRepeatKindNone;
    NSString *unrepeatable =
        MirageFirstUnrepeatableSlotControl(@"// #slots name=\"Colour\" max=4\n"
                                           @"// #gradient label=\"Ramp {n}\"\n"
                                           @"uniform vec4 uRamp;\n"
                                           @"// #slots-end\n",
                                           &repeatKind);
    KKRequire([unrepeatable isEqualToString:@"Ramp {n}"] &&
                  repeatKind == MirageSlotRepeatKindGradient,
              @"a #gradient inside a block is one ramp, not one per instance");
    unrepeatable =
        MirageFirstUnrepeatableSlotControl(@"// #slots name=\"Band\" max=4\n"
                                           @"// #audio label=\"Band {n}\"\n"
                                           @"uniform float uBand[8];\n"
                                           @"// #slots-end\n",
                                           &repeatKind);
    KKRequire([unrepeatable isEqualToString:@"Band {n}"] &&
                  repeatKind == MirageSlotRepeatKindAudio,
              @"and an #audio binding is one binding");
    unrepeatable = MirageFirstUnrepeatableSlotControl(
        @"// #slots name=\"Colour\" max=4\n"
        @"// #color label=\"Palette {n}\" min=1 max=8 default=4\n"
        @"uniform vec4 uPalette[8];\n"
        @"// #slots-end\n",
        &repeatKind);
    KKRequire([unrepeatable isEqualToString:@"Palette {n}"] &&
                  repeatKind == MirageSlotRepeatKindColorArray,
              @"a colour that is already an array cannot be arrayed again");
    unrepeatable = MirageFirstUnrepeatableSlotControl(oneGroup, &repeatKind);
    KKRequire(unrepeatable == nil && repeatKind == MirageSlotRepeatKindNone,
              @"a plain #color and a #float repeat perfectly well");
    unrepeatable =
        MirageFirstUnrepeatableSlotControl(@"// #gradient label=\"Ramp\"\n"
                                           @"uniform vec4 uRamp;\n"
                                           @"// #audio label=\"Music\"\n"
                                           @"uniform float uMusic[8];\n",
                                           &repeatKind);
    KKRequire(unrepeatable == nil,
              @"and outside every block they are ordinary controls");

    // The pool budget: a group is counted at its CEILING, because that is what
    // the user can reach with the plus button.
    int budgetScalars = 0, budgetColors = 0;
    KKRequire(MirageSlotsControlBudget(legacy, &budgetScalars, &budgetColors) ==
                      MirageSlotBudgetKindNone &&
                  budgetScalars == 0 && budgetColors == 0,
              @"a shader with no group is left to the plain control count");
    KKRequire(
        MirageSlotsControlBudget(oneGroup, &budgetScalars, &budgetColors) ==
                MirageSlotBudgetKindNone &&
            budgetScalars == 8 && budgetColors == 8,
        @"one control of each kind, times the group's max of eight");
    NSString *fatGroup = @"// #slots name=\"Layer\" max=16\n"
                         @"// #float label=\"A {n}\"\n"
                         @"uniform float uA;\n"
                         @"// #float label=\"B {n}\"\n"
                         @"uniform float uB;\n"
                         @"// #float label=\"C {n}\"\n"
                         @"uniform float uC;\n"
                         @"// #float label=\"D {n}\"\n"
                         @"uniform float uD;\n"
                         @"// #float label=\"E {n}\"\n"
                         @"uniform float uE;\n"
                         @"// #slots-end\n";
    KKRequire(
        MirageSlotsControlBudget(fatGroup, &budgetScalars, &budgetColors) ==
                MirageSlotBudgetKindScalar &&
            budgetScalars == 80,
        @"five controls at sixteen instances overflows the scalar pool");
    NSString *fatColors = @"// #slots name=\"Colour\" max=16\n"
                          @"// #color label=\"Colour {n}\"\n"
                          @"uniform vec4 uColour;\n"
                          @"// #slots-end\n";
    KKRequire(
        MirageSlotsControlBudget(fatColors, &budgetScalars, &budgetColors) ==
                MirageSlotBudgetKindColor &&
            budgetColors == 16,
        @"and sixteen colours overflows the colour pool");
    // The count is a CEILING, not a reading of any one project: nothing here
    // has a timeline, and the answer is the same either way.
    KKRequire(
        MirageSlotsControlBudget(twoGroups, &budgetScalars, &budgetColors) ==
                MirageSlotBudgetKindNone &&
            budgetColors == 4 && budgetScalars == 3,
        @"two groups each count at their own max");

    // `preview=selection`: which switch the Color panel puts beside Before and
    // Split.
    KKRequire(MirageParseSurfacePreview(@" label=\"Show Selection\" "
                                        @"preview=selection") ==
                  MirageSurfacePreviewKindSelection,
              @"the selection marker parses");
    KKRequire(MirageParseSurfacePreview(@" preview=matte") ==
                  MirageSurfacePreviewKindNone,
              @"an unrecognised preview value claims nothing");
    KKRequire(MirageParseSurfacePreview(@" label=\"Show Selection\"") ==
                  MirageSurfacePreviewKindNone,
              @"and no marker at all claims nothing");

    NSString *markedSource = @"// #float label=\"Amount\" default=1\n"
                             @"uniform float uAmount;\n"
                             @"// #bool label=\"Show Selection\" default=false "
                             @"preview=selection\n"
                             @"uniform bool uShowSelection;\n";
    KKRequire([MirageSurfaceSelectionToggleForSource(markedSource)
                  isEqualToString:@"uShowSelection"],
              @"the lookup finds the marked switch's uniform");

    // The whole reason the marker exists: the panel must never guess from the
    // wording, which is one of many and is translated in the templates' prose.
    NSString *labelledOnly =
        @"// #bool label=\"Show Selection\" default=false\n"
        @"uniform bool uShowSelection;\n";
    KKRequire(!MirageSurfaceSelectionToggleForSource(labelledOnly),
              @"a label that says so is not a declaration");
    KKRequire(!MirageSurfaceSelectionToggleForSource(@""),
              @"and an empty source declares nothing");

    // Pinned: the marker on anything but a boolean is IGNORED, the way a
    // mistyped `pick=` is. The panel's button is two-state, so there is no
    // reading of it on a float that says what pressing it would write.
    NSString *onAFloat = @"// #float label=\"Amount\" min=0 max=1 default=1 "
                         @"preview=selection\n"
                         @"uniform float uAmount;\n";
    KKRequire(!MirageSurfaceSelectionToggleForSource(onAFloat),
              @"the marker on a non-bool control is ignored");
    NSString *disagreeing = @"// #bool label=\"Show Selection\" "
                            @"preview=selection\n"
                            @"uniform float uShowSelection;\n";
    KKRequire(!MirageSurfaceSelectionToggleForSource(disagreeing),
              @"and a bool directive over a float uniform is ignored too");

    // One panel, one button: the first marked switch in the source wins rather
    // than the last one parsed.
    NSString *twice = @"// #bool label=\"Key\" preview=selection\n"
                      @"uniform bool uKey;\n"
                      @"// #bool label=\"Matte\" preview=selection\n"
                      @"uniform bool uMatte;\n";
    KKRequire(
        [MirageSurfaceSelectionToggleForSource(twice) isEqualToString:@"uKey"],
        @"the first marked switch is the one the panel drives");

    // A directive with no uniform after it resolves to nothing, matching every
    // other attribute in this grammar.
    NSString *dangling = @"// #bool label=\"Show Selection\" "
                         @"preview=selection\n";
    KKRequire(!MirageSurfaceSelectionToggleForSource(dangling),
              @"a marker with no uniform under it resolves to nothing");

    // `preview=active-key`: which key of a slotted qualifier the matte shows.
    // The same nine questions, because it is the same grammar with a different
    // word and a different kind - and the wrong-kind rule is the one worth
    // pinning twice.
    KKRequire(MirageParseSurfacePreview(@" label=\"Preview Key\" "
                                        @"preview=active-key") ==
                  MirageSurfacePreviewKindActiveKey,
              @"the active-key marker parses");
    KKRequire(MirageParseSurfacePreview(@" preview=activekey") ==
                  MirageSurfacePreviewKindNone,
              @"and the hyphen is part of the word");

    NSString *keyedSource =
        @"// #float label=\"Amount\" default=1\n"
        @"uniform float uAmount;\n"
        @"// #choice label=\"Preview Key\" "
        @"options=\"All,1,2\" default=0 preview=active-key\n"
        @"uniform int uPreviewKey;\n";
    KKRequire([MirageSurfaceActiveKeyControlForSource(keyedSource)
                  isEqualToString:@"uPreviewKey"],
              @"the lookup finds the marked choice's uniform");
    KKRequire(!MirageSurfaceSelectionToggleForSource(keyedSource),
              @"and the two markers do not answer for each other");

    NSString *keyLabelledOnly = @"// #choice label=\"Preview Key\" "
                                @"options=\"All,1,2\" default=0\n"
                                @"uniform int uPreviewKey;\n";
    KKRequire(!MirageSurfaceActiveKeyControlForSource(keyLabelledOnly),
              @"a label that says so is not a declaration");
    KKRequire(!MirageSurfaceActiveKeyControlForSource(@""),
              @"and an empty source declares nothing");

    // A CHOICE and nothing else. "Which key" is a set, not a quantity: the
    // panel drives a pill whose options the catalog trims to the live instance
    // count, and there is no reading of the marker on a slider that says how
    // many pills to draw. So an #int now costs exactly what a mistyped `pick=`
    // costs - the feature quietly does not appear.
    NSString *keyOnAnInt = @"// #int label=\"Preview Key\" min=0 max=6 "
                           @"preview=active-key\n"
                           @"uniform int uPreviewKey;\n";
    KKRequire(!MirageSurfaceActiveKeyControlForSource(keyOnAnInt),
              @"the marker on an #int is ignored - the pill is the shape");
    NSString *keyOnABool = @"// #bool label=\"Preview Key\" "
                           @"preview=active-key\n"
                           @"uniform bool uPreviewKey;\n";
    KKRequire(!MirageSurfaceActiveKeyControlForSource(keyOnABool),
              @"and so is the marker on a switch");
    // The pair still has to agree, and for a choice the pair is `#choice` over
    // a `uniform int` - a choice IS delivered to the shader as an integer.
    NSString *keyDisagreeing = @"// #choice label=\"Preview Key\" "
                               @"options=\"All,1\" preview=active-key\n"
                               @"uniform float uPreviewKey;\n";
    KKRequire(!MirageSurfaceActiveKeyControlForSource(keyDisagreeing),
              @"a choice directive over a float uniform is ignored too");

    // One panel, one active handle: the first marked control wins.
    NSString *keyTwice = @"// #choice label=\"Key\" options=\"All,1\" "
                         @"preview=active-key\n"
                         @"uniform int uKey;\n"
                         @"// #choice label=\"Other\" options=\"All,1\" "
                         @"preview=active-key\n"
                         @"uniform int uOther;\n";
    KKRequire([MirageSurfaceActiveKeyControlForSource(keyTwice)
                  isEqualToString:@"uKey"],
              @"the first marked choice is the one the panel drives");

    NSString *keyDangling = @"// #choice label=\"Preview Key\" "
                            @"options=\"All,1\" preview=active-key\n";
    KKRequire(!MirageSurfaceActiveKeyControlForSource(keyDangling),
              @"a marker with no uniform under it resolves to nothing");

    // Both markers together are what the catalog leaves out of the lane set and
    // the render ignores any stored value for. The union, so one lookup answers
    // "is this control the panel's".
    NSString *markedPair =
        @"// #bool label=\"Show Selection\" preview=selection\n"
        @"uniform bool uShowSelection;\n"
        @"// #choice label=\"Preview Key\" options=\"All,1\" "
        @"preview=active-key\n"
        @"uniform int uPreviewKey;\n"
        @"// #float label=\"Amount\" default=1\n"
        @"uniform float uAmount;\n";
    NSSet<NSString *> *owned = MirageSurfacePreviewOwnedKeys(markedPair);
    KKRequire(owned.count == 2 && [owned containsObject:@"uShowSelection"] &&
                  [owned containsObject:@"uPreviewKey"],
              @"markedPair marked uniforms are panel-owned");
    KKRequire(![owned containsObject:@"uAmount"],
              @"and an ordinary control is not");

    // A shader declaring neither owns nothing, which is what makes every
    // template written before this feature behave exactly as it did: no lane is
    // dropped and no stored value is ignored.
    KKRequire(MirageSurfacePreviewOwnedKeys(
                  @"// #float label=\"Amount\"\nuniform float uAmount;\n")
                      .count == 0,
              @"a shader with no markers owns nothing");
    KKRequire(MirageSurfacePreviewOwnedKeys(@"").count == 0,
              @"and neither does an empty source");

    // A marker on the wrong kind is ignored here too, so a typo cannot silently
    // delete a real control's row.
    KKRequire(MirageSurfacePreviewOwnedKeys(onAFloat).count == 0,
              @"a mistyped marker claims no control");
  }
  return 0;
}
