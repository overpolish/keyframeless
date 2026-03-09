/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "NSColor+KKColors.h"
#import <KeyframelessKit/KKHostInfo.h>

@implementation NSColor (KKColors)

+ (NSColor *)inspectorLabelColor {
  static NSColor *color = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    color = [NSColor colorWithWhite:179.0 / 255.0 alpha:1.0];
  });
  return color;
}

+ (NSColor *)inspectorBackground {
  static NSColor *color = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    if ([KKHostInfo isRunningInFinalCut]) {
      color = [NSColor colorWithWhite:22.0 / 255.0 alpha:1.0];
    } else {
      color = [NSColor colorWithWhite:45.0 / 255.0 alpha:1.0];
    }
  });
  return color;
}

@end
