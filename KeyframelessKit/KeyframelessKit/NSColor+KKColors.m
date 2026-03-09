//
//  NSColor+KKColors.m
//  KeyframelessKit
//
//  Created by Dom on 04/03/2026.
//

#import "KKHostInfo.h"
#import "NSColor+KKColors.h"
#import <AppKit/NSColor.h>

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
