/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */
#import "InspectorTokens.h"

@implementation ICInspectorTokens
+ (NSFont *)labelFont { return [NSFont systemFontOfSize:11 weight:NSFontWeightLight]; }
+ (NSFont *)decorationFont { return [NSFont systemFontOfSize:11 weight:NSFontWeightLight]; }
+ (NSFont *)valueFont { return [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular]; }
+ (NSColor *)labelColor { return [NSColor colorWithWhite:0.701 alpha:1]; }
+ (NSColor *)decorationColor {
  return [NSColor colorWithSRGBRed:179.0/255 green:179.0/255 blue:179.0/255 alpha:1];
}
+ (NSColor *)valueColor { return [NSColor colorWithWhite:0.839 alpha:1]; }
+ (NSColor *)accentMatchingHost {
  // Ported from NSColor+KKColors: Motion and FCP use the same accent.
  return [NSColor colorWithSRGBRed:0x5B/255.0 green:0x5C/255.0 blue:0xE9/255.0 alpha:1];
}
+ (NSColor *)inactiveControlColor { return [self.labelColor colorWithAlphaComponent:0.55]; }
+ (NSColor *)selectionColor { return [self.accentMatchingHost colorWithAlphaComponent:0.3]; }
@end
