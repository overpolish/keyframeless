/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKHostInfo.h"
#import "NSColor+KKColors.h"
#include <AppKit/AppKit.h>

@implementation NSColor (KKColors)

+ (NSColor *)inspectorLabel {
  return [NSColor colorWithWhite:179.0 / 255.0 alpha:1.0];
}

+ (NSColor *)inspectorBackground {
  if ([KKHostInfo isRunningInFinalCut]) {
    return [NSColor colorWithWhite:22.0 / 255.0 alpha:1.0];
  }
  return [NSColor colorWithWhite:45.0 / 255.0 alpha:1.0];
}

+ (NSColor *)primary {
  return [NSColor colorWithRed:0.7f green:0.7f blue:0.7f alpha:0.65f];
}

+ (NSColor *)outline {
  return [NSColor colorWithRed:0.0f green:0.0f blue:0.0f alpha:0.8f];
}

+ (NSColor *)hover {
  return [NSColor colorWithRed:0.7f green:0.7f blue:0.7f alpha:0.8f];
}

+ (NSColor *)active {
  return [NSColor colorWithRed:0.7f green:0.7f blue:0.7f alpha:0.95f];
}

+ (NSColor *)transparent {
  return [NSColor colorWithRed:0.0f green:0.0f blue:0.0f alpha:0.0f];
}

+ (NSColor *)error {
  return [NSColor colorWithRed:0xFE / 255.0
                         green:0x4C / 255.0
                          blue:0x4C / 255.0
                         alpha:1.0];
}

// TODO standardize to floats or hex
+ (NSColor *)sliderTrackBackground {
  return [NSColor colorWithRed:0x17 / 255.0
                         green:0x17 / 255.0
                          blue:0x17 / 255.0
                         alpha:1.0];
}

+ (NSColor *)sliderTrackFill {
  return [NSColor colorWithRed:0x61 / 255.0
                         green:0x68 / 255.0
                          blue:0xF5 / 255.0
                         alpha:1.0];
}

+ (NSColor *)sliderKnobFill {
  return [NSColor colorWithWhite:0x80 / 255.0 alpha:1.0];
}

+ (NSColor *)sliderKnobOutline {
  return [NSColor colorWithRed:0x17 / 255.0
                         green:0x17 / 255.0
                          blue:0x17 / 255.0
                         alpha:1.0];
}

+ (NSColor *)expandChevron {
  return [NSColor colorWithWhite:0x91 / 255.0 alpha:1.0];
}

+ (NSColor *)activeExpandChevron {
  return [NSColor colorWithWhite:0x6e / 255.0 alpha:1.0];
}

+ (NSColor *)keyboardFocusIndicator {
  if ([KKHostInfo isRunningInFinalCut]) {
    return [NSColor colorWithRed:0x1B / 255.0
                           green:0x3B / 255.0
                            blue:0x6A / 255.0
                           alpha:1.0];
  } else {
    return [NSColor colorWithRed:0x28 / 255.0
                           green:0x47 / 255.0
                            blue:0x77 / 255.0
                           alpha:1.0];
  }
}

+ (NSColor *)selection {
  if ([KKHostInfo isRunningInFinalCut]) {
    return [NSColor colorWithRed:0x57 / 255.0
                           green:0x57 / 255.0
                            blue:0xDF / 255.0
                           alpha:1.0];
  } else {
    return [NSColor colorWithRed:0x59 / 255.0
                           green:0x59 / 255.0
                            blue:0xE1 / 255.0
                           alpha:1.0];
  }
}

+ (NSColor *)selectionForeground {
  return [NSColor colorWithRed:0xF7 / 255.0
                         green:0xF7 / 255.0
                          blue:0xFE / 255.0
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
