/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKHostInfo.h"
#import "NSColor+KKColors.h"
#include <AppKit/AppKit.h>

@implementation NSColor (KKColors)

+ (NSColor *)inspectorLabel {
  return [NSColor colorWithRed:0xB3 / 255.0
                         green:0xB3 / 255.0
                          blue:0xB3 / 255.0
                         alpha:1.0];
}

+ (NSColor *)inspectorBackground {
  if ([KKHostInfo isRunningInFinalCut]) {
    return [NSColor colorWithRed:0x16 / 255.0
                           green:0x16 / 255.0
                            blue:0x16 / 255.0
                           alpha:1.0];
  }

  return [NSColor colorWithRed:0x2D / 255.0
                         green:0x2D / 255.0
                          blue:0x2D / 255.0
                         alpha:1.0];
}

+ (NSColor *)primary {
  return [NSColor colorWithRed:0xB3 / 255.0
                         green:0xB3 / 255.0
                          blue:0xB3 / 255.0
                         alpha:0.65f];
}

+ (NSColor *)outline {
  return [NSColor colorWithRed:0x00 / 255.0
                         green:0x00 / 255.0
                          blue:0x00 / 255.0
                         alpha:0.8f];
}

+ (NSColor *)hover {
  return [NSColor colorWithRed:0xB3 / 255.0
                         green:0xB3 / 255.0
                          blue:0xB3 / 255.0
                         alpha:0.8f];
}

+ (NSColor *)active {
  return [NSColor colorWithRed:0xB3 / 255.0
                         green:0xB3 / 255.0
                          blue:0xB3 / 255.0
                         alpha:0.95f];
}

+ (NSColor *)transparent {
  return [NSColor colorWithRed:0x00 / 255.0
                         green:0x00 / 255.0
                          blue:0x00 / 255.0
                         alpha:0.0f];
}

+ (NSColor *)accent {
  // Lighter than the shade as used in Motion/FCP for better accessibility
  return [NSColor colorWithRed:0x8B / 255.0
                         green:0x8B / 255.0
                          blue:0xF0 / 255.0
                         alpha:1.0];
}

+ (NSColor *)warning {
  return [NSColor colorWithRed:0xFF / 255.0
                         green:0xCC / 255.0
                          blue:0x02 / 255.0
                         alpha:1.0];
}

- (simd_float4)simdFloat4 {
  NSColor *rgb = [self colorUsingColorSpace:NSColorSpace.genericRGBColorSpace];
  return (simd_float4){
      (float)rgb.redComponent,
      (float)rgb.greenComponent,
      (float)rgb.blueComponent,
      (float)rgb.alphaComponent,
  };
}

@end
