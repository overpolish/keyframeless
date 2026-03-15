/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKIcons.h"

@implementation KKIcons

/// Returns a path with Lucide's default line style applied.
static NSBezierPath *KKIconPath(void) {
  NSBezierPath *path = [NSBezierPath bezierPath];
  path.lineCapStyle = NSLineCapStyleRound;
  path.lineJoinStyle = NSLineJoinStyleRound;
  return path;
}

/// Source - https://lucide.dev/icons/info
+ (NSBezierPath *)info {
  static NSBezierPath *path = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    path = KKIconPath();

    [path appendBezierPathWithOvalInRect:NSMakeRect(2, 2, 20, 20)];

    [path moveToPoint:NSMakePoint(12, 16)];
    [path lineToPoint:NSMakePoint(12, 12)];

    [path moveToPoint:NSMakePoint(12, 8)];
    [path lineToPoint:NSMakePoint(12.01, 8)];
  });
  return path;
}

@end
