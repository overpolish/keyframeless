/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKHostInfo.h"
#import "NSColor+KKColors.h"
#import <AppKit/AppKit.h>

@implementation NSColor (KKColors)

#pragma mark - FxPlug

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

#pragma mark - Workflow Extension

+ (NSColor *)windowBackground {
  return [NSColor colorWithRed:0x27 / 255.0
                         green:0x27 / 255.0
                          blue:0x27 / 255.0
                         alpha:1.0];
}

+ (NSColor *)timelineLabel {
  return [NSColor colorWithRed:0x70 / 255.0
                         green:0x70 / 255.0
                          blue:0x70 / 255.0
                         alpha:1.0];
}

+ (NSColor *)timelineTick {
  return [NSColor colorWithRed:0x79 / 255.0
                         green:0x79 / 255.0
                          blue:0x79 / 255.0
                         alpha:1.0];
}

#pragma mark - Shared

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

+ (NSColor *)accentMatchingHost {
  return [NSColor colorWithRed:0x5B / 255.0
                         green:0x5C / 255.0
                          blue:0xE9 / 255.0
                         alpha:1.0];
}

+ (NSColor *)warning {
  return [NSColor colorWithRed:0xFF / 255.0
                         green:0xCC / 255.0
                          blue:0x02 / 255.0
                         alpha:1.0];
}

+ (NSColor *)error {
  return [NSColor colorWithRed:0xFB / 255.0
                         green:0x2C / 255.0
                          blue:0x36 / 255.0
                         alpha:1.0];
}

+ (NSColor *)success {
  return [NSColor colorWithRed:0x2D / 255.0
                         green:0xB6 / 255.0
                          blue:0x55 / 255.0
                         alpha:1.0];
}

- (NSColor *)shiftedHueBy:(CGFloat)amount {
  NSColor *hsb = [self colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
  if (!hsb)
    return self;
  CGFloat h, s, b, a;
  [hsb getHue:&h saturation:&s brightness:&b alpha:&a];
  return [NSColor colorWithHue:fmod(h + amount + 1.0, 1.0)
                    saturation:s
                    brightness:b
                         alpha:a];
}

- (NSColor *)compound {
  NSColor *hsb = [self colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
  if (!hsb)
    return self;
  CGFloat h, s, b, a;
  [hsb getHue:&h saturation:&s brightness:&b alpha:&a];
  return [NSColor colorWithHue:fmod(h + 0.333 + 1.0, 1.0)
                    saturation:s * 0.45
                    brightness:b * 0.75
                         alpha:a];
}

- (simd_float4)simdFloat4 {
  NSColor *rgb = [self colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
  return (simd_float4){
      (float)rgb.redComponent,
      (float)rgb.greenComponent,
      (float)rgb.blueComponent,
      (float)rgb.alphaComponent,
  };
}

@end
