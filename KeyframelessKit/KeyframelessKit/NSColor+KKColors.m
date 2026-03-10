/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "NSColor+KKColors.h"
#import <KeyframelessKit/KKHostInfo.h>

@implementation NSColor (KKColors)

+ (NSColor *)inspectorLabelColor {
  return [NSColor colorWithWhite:179.0 / 255.0 alpha:1.0];
}

+ (NSColor *)inspectorBackground {
  if ([KKHostInfo isRunningInFinalCut]) {
    return [NSColor colorWithWhite:22.0 / 255.0 alpha:1.0];
  }
  return [NSColor colorWithWhite:45.0 / 255.0 alpha:1.0];
}

+ (NSColor *)primaryColor {
  return [NSColor colorWithRed:0.7f green:0.7f blue:0.7f alpha:0.65f];
}

+ (NSColor *)outlineColor {
  return [NSColor colorWithRed:0.0f green:0.0f blue:0.0f alpha:0.8f];
}

+ (NSColor *)hoverColor {
  return [NSColor colorWithRed:0.7f green:0.7f blue:0.7f alpha:0.8f];
}

+ (NSColor *)activeColor {
  return [NSColor colorWithRed:0.7f green:0.7f blue:0.7f alpha:0.95f];
}

+ (NSColor *)transparentColor {
  return [NSColor colorWithRed:0.0f green:0.0f blue:0.0f alpha:0.0f];
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
