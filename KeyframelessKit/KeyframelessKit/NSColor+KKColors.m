//
//  NSColor+KKColors.m
//  KeyframelessKit
//
//  Created by Dom on 04/03/2026.
//

#import "NSColor+KKColors.h"
#include <AppKit/NSColor.h>

@implementation NSColor (KKColors)

+ (NSColor *)inspectorLabelColor {
  static NSColor *color = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    color = [NSColor colorWithWhite:179.0 / 255.0 alpha:1.0];
  });
  return color;
}

@end
