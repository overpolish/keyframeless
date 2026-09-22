/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */
#import "InspectorTokens.h"

@implementation ICInspectorTokens
+ (NSFont *)labelFont { return [NSFont systemFontOfSize:11 weight:NSFontWeightLight]; }
+ (NSFont *)selectedLabelFont { return [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold]; }
+ (NSFont *)decorationFont { return [NSFont systemFontOfSize:11 weight:NSFontWeightLight]; }
+ (NSFont *)valueFont { return [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular]; }
+ (NSColor *)labelColor { return [NSColor colorWithWhite:0.701 alpha:1]; }
+ (NSColor *)decorationColor {
  return [NSColor colorWithSRGBRed:179.0/255 green:179.0/255 blue:179.0/255 alpha:1];
}
+ (NSColor *)disabledTextColor { return [NSColor colorWithSRGBRed:82.0/255 green:82.0/255 blue:82.0/255 alpha:1]; }
+ (NSColor *)valueColor { return [NSColor colorWithWhite:0.839 alpha:1]; }
+ (NSColor *)accentMatchingHost {
  // Ported from NSColor+KKColors: Motion and FCP use the same accent.
  return [NSColor colorWithSRGBRed:0x5B/255.0 green:0x5C/255.0 blue:0xE9/255.0 alpha:1];
}
// Kept beside the host accent so the two identity colours are read together.
+ (NSColor *)brandAmber {
  return [NSColor colorWithSRGBRed:1 green:0xC3/255.0 blue:0 alpha:1];
}
+ (NSColor *)inactiveControlColor { return [self.labelColor colorWithAlphaComponent:0.55]; }
+ (NSColor *)selectionColor { return [self.accentMatchingHost colorWithAlphaComponent:0.3]; }
+ (NSArray<NSColor *> *)curveColors {
  static NSArray<NSColor *> *colors;
  static dispatch_once_t once;
  dispatch_once(&once,^{
    colors=@[[NSColor colorWithSRGBRed:0.96 green:0.43 blue:0.40 alpha:1],
             [NSColor colorWithSRGBRed:0.35 green:0.82 blue:0.56 alpha:1],
             [NSColor colorWithSRGBRed:0.33 green:0.70 blue:0.98 alpha:1],
             [NSColor colorWithSRGBRed:0.76 green:0.57 blue:0.96 alpha:1],
             [NSColor colorWithSRGBRed:0.96 green:0.77 blue:0.32 alpha:1],
             [NSColor colorWithSRGBRed:1 green:0.58 blue:0.26 alpha:1],
             [NSColor colorWithSRGBRed:0.30 green:0.85 blue:0.82 alpha:1],
             [NSColor colorWithSRGBRed:0.97 green:0.47 blue:0.72 alpha:1],
             [NSColor colorWithSRGBRed:0.73 green:0.78 blue:0.88 alpha:1],
             [NSColor colorWithSRGBRed:0.69 green:0.85 blue:0.38 alpha:1],
             [NSColor colorWithSRGBRed:0.54 green:0.60 blue:1 alpha:1]];
  });
  return colors;
}
+ (NSArray<NSColor *> *)linkGroupColors { return self.curveColors; }
+ (NSColor *)sliderTrackColor { return [NSColor colorWithWhite:0x16/255.0 alpha:1]; }
+ (NSColor *)sliderKnobColor { return [NSColor colorWithWhite:0x80/255.0 alpha:1]; }
+ (NSColor *)sliderKnobOutlineColor { return [NSColor colorWithWhite:0x14/255.0 alpha:1]; }
@end
