/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
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

#pragma mark - OSC

+ (NSColor *)arcFill {
  return [NSColor colorWithRed:0xC1 / 255.0
                         green:0xC1 / 255.0
                          blue:0xC1 / 255.0
                         alpha:1.0f];
}

+ (NSColor *)arcStroke {
  return [NSColor colorWithRed:0x00 / 255.0
                         green:0x00 / 255.0
                          blue:0x00 / 255.0
                         alpha:0.8f];
}

+ (NSColor *)pointFill {
  return [NSColor colorWithRed:0xB3 / 255.0
                         green:0xB3 / 255.0
                          blue:0xB3 / 255.0
                         alpha:0.65f];
}

+ (NSColor *)pointStroke {
  return [NSColor colorWithRed:0x00 / 255.0
                         green:0x00 / 255.0
                          blue:0x00 / 255.0
                         alpha:0.8f];
}

+ (NSColor *)pointFillHover {
  return [NSColor colorWithRed:0xB3 / 255.0
                         green:0xB3 / 255.0
                          blue:0xB3 / 255.0
                         alpha:0.8f];
}

+ (NSColor *)pointFillActive {
  return [NSColor colorWithRed:0xB3 / 255.0
                         green:0xB3 / 255.0
                          blue:0xB3 / 255.0
                         alpha:0.95f];
}

+ (NSColor *)ringIdleFill {
  return [NSColor colorWithRed:0xCE / 255.0
                         green:0xCB / 255.0
                          blue:0xCE / 255.0
                         alpha:0xB1 / 255.0];
}

+ (NSColor *)ringIdleStroke {
  return [NSColor colorWithRed:0x1B / 255.0
                         green:0x18 / 255.0
                          blue:0x1D / 255.0
                         alpha:0x9F / 255.0];
}

+ (NSColor *)ringHoverFill {
  return [NSColor colorWithRed:0xD0 / 255.0
                         green:0xCA / 255.0
                          blue:0xCD / 255.0
                         alpha:0xB2 / 255.0];
}

+ (NSColor *)ringHoverStroke {
  return [NSColor colorWithRed:0x09 / 255.0
                         green:0x07 / 255.0
                          blue:0x0A / 255.0
                         alpha:0xAD / 255.0];
}

+ (NSColor *)ringActiveFill {
  return [NSColor colorWithRed:0xFF / 255.0
                         green:0xFF / 255.0
                          blue:0xFF / 255.0
                         alpha:1.0];
}

+ (NSColor *)ringActiveStroke {
  return [NSColor colorWithRed:0x00 / 255.0
                         green:0x00 / 255.0
                          blue:0x00 / 255.0
                         alpha:1.0];
}

+ (NSColor *)labelFill {
  return [self arcFill];
}

+ (NSColor *)labelStroke {
  return [self arcStroke];
}

+ (NSColor *)iconButtonFill {
  return [self arcFill];
}

+ (NSColor *)iconButtonStroke {
  return [[self arcStroke] colorWithAlphaComponent:0.5];
}

+ (NSColor *)donutFill {
  return [NSColor colorWithRed:0x00 / 255.0
                         green:0x00 / 255.0
                          blue:0x00 / 255.0
                         alpha:0.13f];
}

+ (NSColor *)donutStroke {
  return [NSColor colorWithRed:0xFF / 255.0
                         green:0xFF / 255.0
                          blue:0xFF / 255.0
                         alpha:0.2f];
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
