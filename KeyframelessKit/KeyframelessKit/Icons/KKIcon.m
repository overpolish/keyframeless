/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKIcon.h"
#import "../Style/NSColor+KKColors.h"

static const CGFloat KKIconViewBoxSize = 24.0;

@implementation KKIcon

- (instancetype)initWithPath:(NSBezierPath *)path
                 strokeColor:(NSColor *)strokeColor {
  self = [super initWithFrame:NSMakeRect(0, 0, 16.0, 16.0)];
  if (self) {
    _path = path;
    _strokeColor = strokeColor;
    _strokeWidth = 1.5;
    self.wantsLayer = NO;
  }
  return self;
}

- (instancetype)initWithPath:(NSBezierPath *)path {
  return [self initWithPath:path strokeColor:[NSColor accent]];
}

- (void)drawRect:(NSRect)dirtyRect {
  [super drawRect:dirtyRect];

  if (!_path || !_strokeColor)
    return;

  CGFloat scale = MIN(NSWidth(self.bounds) / KKIconViewBoxSize,
                      NSHeight(self.bounds) / KKIconViewBoxSize);
  CGFloat offsetX = (NSWidth(self.bounds) - KKIconViewBoxSize * scale) / 2.0;
  CGFloat offsetY = (NSHeight(self.bounds) - KKIconViewBoxSize * scale) / 2.0;

  NSGraphicsContext *ctx = [NSGraphicsContext currentContext];
  [ctx saveGraphicsState];

  // Translate origin to top-left, then flip Y so SVG coordinates (Y-down)
  // map correctly onto the AppKit coordinate system (Y-up).
  NSAffineTransform *transform = [NSAffineTransform transform];
  [transform translateXBy:offsetX yBy:NSHeight(self.bounds) - offsetY];
  [transform scaleXBy:scale yBy:-scale];
  [transform concat];

  // Undo the context scale for strokeWidth so it stays in screen points.
  _path.lineWidth = _strokeWidth / scale;
  [_strokeColor setStroke];
  [_path stroke];

  [ctx restoreGraphicsState];
}

@end
