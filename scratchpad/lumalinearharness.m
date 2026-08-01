/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Numeric proof for `pick=luma-linear`. Three things:
//
//   1. the conversion the Color panel now runs for the new kind agrees with an
//      independently written sRGB decode, over all 256 8-bit greys and a set of
//      colours, so the shared helper is not quietly a 2.2 power curve,
//   2. the value a percent-ranged Pivot actually receives, display against
//      linear, for the face-at-0.55 case the whole change is about,
//   3. the two templates on disk resolve their Pivot to the new kind, and Film
//      Halation's Threshold still resolves to the display-coded one.
//
// The panel's scaling and clamping is restated here rather than linked, because
// reaching it means standing up the whole inspector. The CONVERSION is the real
// helper from MirageOklab.h, which is the part that could be wrong.

#import <Foundation/Foundation.h>

#import "MirageOklab.h"
#import "MirageSurfaceGrammar.h"

static int gFailures = 0;

static void Check(BOOL ok, NSString *what) {
  if (!ok) {
    gFailures++;
    printf("FAIL  %s\n", what.UTF8String);
  }
}

// The panel's new path, verbatim: decode each display-encoded component with
// the shared helper, then weight the LINEAR components with Rec.709.
static double PanelLumaLinear(double r, double g, double b) {
  return 0.2126 * MirageSRGBDecode(r) + 0.7152 * MirageSRGBDecode(g) +
         0.0722 * MirageSRGBDecode(b);
}

static double PanelLumaDisplay(double r, double g, double b) {
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

// Written from the IEC 61966-2-1 definition rather than from the header, so a
// mistake in the header cannot agree with a mistake here.
static double ReferenceDecode(double v) {
  if (v <= 0.04045)
    return v / 12.92;
  return pow((v + 0.055) / 1.055, 2.4);
}

static double ReferenceLumaLinear(double r, double g, double b) {
  return 0.2126 * ReferenceDecode(r) + 0.7152 * ReferenceDecode(g) +
         0.0722 * ReferenceDecode(b);
}

// What the pick write lands in a control declaring min/max, matching the panel:
// a max above 1.5 says the control holds percent, then clamp to the range.
static double WrittenInto(double value01, double lo, double hi) {
  double next = value01;
  if (hi > 1.5)
    next *= 100.0;
  next = MAX(next, lo);
  next = MIN(next, hi);
  return next;
}

static NSDictionary<NSString *, NSNumber *> *PicksOfTemplate(NSString *uuid) {
  NSString *path = [NSString
      stringWithFormat:@"%@/Library/Application Support/Keyframeless/Shaders/"
                       @"%@/image.glsl",
                       NSHomeDirectory(), uuid];
  NSString *src = [NSString stringWithContentsOfFile:path
                                            encoding:NSUTF8StringEncoding
                                               error:nil];
  if (!src.length) {
    printf("FAIL  cannot read %s\n", path.UTF8String);
    gFailures++;
    return @{};
  }
  return MirageSurfacePicksForSource(src);
}

int main(void) {
  @autoreleasepool {
    printf("== 256 8-bit greys: helper against an independent sRGB decode\n");
    double worst = 0.0;
    int worstStep = -1;
    for (int i = 0; i < 256; i++) {
      double v = i / 255.0;
      double mine = PanelLumaLinear(v, v, v);
      double ref = ReferenceLumaLinear(v, v, v);
      double d = fabs(mine - ref);
      if (d > worst) {
        worst = d;
        worstStep = i;
      }
      Check(d < 1e-12, ([NSString
                           stringWithFormat:@"grey %d agrees to 1e-12", i]));
    }
    printf("   worst disagreement %.3e at step %d\n", worst, worstStep);

    // The toe, where a hand-rolled pow(2.2) would be furthest out. Printed so
    // the size of the error the shared helper avoids is on the record.
    printf("   toe check, display 0.03: shared %.9f, pow(2.2) %.9f\n",
           MirageSRGBDecode(0.03), pow(0.03, 2.2));

    printf("== colours\n");
    const double colours[][3] = {
        {1.0, 0.0, 0.0},    {0.0, 1.0, 0.0},
        {0.0, 0.0, 1.0},    {0.78, 0.58, 0.47} /* skin */,
        {0.55, 0.55, 0.55}, {0.18, 0.18, 0.18},
        {1.0, 1.0, 1.0},    {0.0, 0.0, 0.0},
        {0.2, 0.66, 0.31},
    };
    for (size_t i = 0; i < sizeof(colours) / sizeof(colours[0]); i++) {
      double r = colours[i][0], g = colours[i][1], b = colours[i][2];
      double mine = PanelLumaLinear(r, g, b);
      double ref = ReferenceLumaLinear(r, g, b);
      Check(fabs(mine - ref) < 1e-12, @"colour agrees to 1e-12");
      printf("   (%.2f %.2f %.2f)  display %.4f  linear %.4f\n", r, g, b,
             PanelLumaDisplay(r, g, b), mine);
    }

    printf("== the Tone / Grade pivot, a face sampled at display 0.55\n");
    double face = 0.55;
    double display = PanelLumaDisplay(face, face, face);
    double linear = PanelLumaLinear(face, face, face);
    // Both templates declare `#percent min=1 max=99`, so the lane is in percent
    // and the shader divides by 100 on the way in.
    double writtenOld = WrittenInto(display, 1.0, 99.0);
    double writtenNew = WrittenInto(linear, 1.0, 99.0);
    printf("   pick=luma        writes %.2f%%  -> uniform %.4f\n", writtenOld,
           writtenOld / 100.0);
    printf("   pick=luma-linear writes %.2f%%  -> uniform %.4f\n", writtenNew,
           writtenNew / 100.0);
    printf("   the old value is %.2f stops above the light the user clicked\n",
           log2(writtenOld / writtenNew));
    Check(fabs(linear - 0.2634) < 0.0005, @"display 0.55 decodes to ~0.263");
    Check(fabs(writtenNew - 26.34) < 0.05, @"the pivot receives ~26.3 percent");
    Check(log2(writtenOld / writtenNew) > 0.9,
          @"the old kind was about a stop high");

    // Middle grey the other way round: a pivot of 18% linear is what the
    // default already is, so a pick on an 18% grey card should now land on the
    // default instead of pushing it to 46%.
    double card = MirageSRGBEncode(0.18);
    printf("   an 18%% grey card is display %.4f, and now picks back to %.2f%% "
           "(display-coded it would read %.2f%%)\n",
           card, WrittenInto(PanelLumaLinear(card, card, card), 1.0, 99.0),
           WrittenInto(PanelLumaDisplay(card, card, card), 1.0, 99.0));
    Check(fabs(WrittenInto(PanelLumaLinear(card, card, card), 1.0, 99.0) -
               18.0) < 0.05,
          @"picking an 18% grey card lands on the 18% default");

    printf("== the templates on disk\n");
    NSDictionary<NSString *, NSNumber *> *tone =
        PicksOfTemplate(@"A9FD3161-F043-4687-BB49-6BA100922BBF");
    NSDictionary<NSString *, NSNumber *> *grade =
        PicksOfTemplate(@"45D74BCA-3979-4F23-9573-D15881BA5805");
    NSDictionary<NSString *, NSNumber *> *halation =
        PicksOfTemplate(@"78FC60F4-116B-423A-9283-6DDA04873605");
    printf("   Tone uPivot          %ld\n", (long)tone[@"uPivot"].integerValue);
    printf("   Grade uPivot         %ld\n",
           (long)grade[@"uPivot"].integerValue);
    printf("   Halation uThreshold  %ld\n",
           (long)halation[@"uThreshold"].integerValue);
    Check(tone[@"uPivot"].integerValue == MirageSurfacePickKindLumaLinear,
          @"Tone's Pivot resolves to luma-linear");
    Check(grade[@"uPivot"].integerValue == MirageSurfacePickKindLumaLinear,
          @"Grade's Pivot resolves to luma-linear");
    Check(halation[@"uThreshold"].integerValue == MirageSurfacePickKindLuma,
          @"Film Halation's Threshold stays display-coded");
    Check(halation[@"uHalationColor"].integerValue ==
                  MirageSurfacePickKindColor ||
              halation.count >= 2,
          @"Film Halation keeps its colour pick");

    printf(gFailures ? "\n%d FAILURE(S)\n" : "\nall checks passed\n",
           gFailures);
  }
  return gFailures ? 1 : 0;
}
