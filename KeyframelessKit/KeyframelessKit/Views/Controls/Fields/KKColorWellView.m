/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKColorWellView.h"
#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>

extern void KKDrawCheckerboard(NSRect rect);

static const CGFloat kSwatchSize = 14.0;

@implementation KKColorWellView

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    _color = [NSColor whiteColor];
  }
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (!self.window) {
    NSColorPanel *panel = [NSColorPanel sharedColorPanel];
    [panel setTarget:nil];
    [panel setAction:nil];
  }
}

- (NSSize)intrinsicContentSize {
  return NSMakeSize(kSwatchSize, kSwatchSize);
}

- (void)drawRect:(NSRect)dirtyRect {
  NSRect swatch = NSMakeRect(round((NSWidth(self.bounds) - kSwatchSize) * 0.5),
                             round((NSHeight(self.bounds) - kSwatchSize) * 0.5),
                             kSwatchSize, kSwatchSize);

  // Checkerboard for transparency
  NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:swatch
                                                       xRadius:KKRadiusSM
                                                       yRadius:KKRadiusSM];
  [NSGraphicsContext saveGraphicsState];
  [clip addClip];
  KKDrawCheckerboard(swatch);
  [NSGraphicsContext restoreGraphicsState];

  // Color fill
  [_color setFill];
  [clip fill];

  // Border
  [[NSColor.inspectorLabel colorWithAlphaComponent:0.3] setStroke];
  NSBezierPath *border =
      [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(swatch, 0.5, 0.5)
                                      xRadius:KKRadiusSM
                                      yRadius:KKRadiusSM];
  border.lineWidth = KKBorderWidthXS;
  [border stroke];
}

- (void)mouseDown:(NSEvent *)event {
  NSColorPanel *panel = [NSColorPanel sharedColorPanel];
  panel.color = _color;
  panel.target = self;
  panel.action = @selector(_colorPanelChanged:);
  panel.continuous = YES;

  NSWindow *hostWindow = self.window;
  if (hostWindow && panel.parentWindow != hostWindow) {
    [panel.parentWindow removeChildWindow:panel];
    [hostWindow addChildWindow:panel ordered:NSWindowAbove];
  }

  [panel orderFront:nil];
}

- (void)_colorPanelChanged:(NSColorPanel *)panel {
  self.color = panel.color;
  if (_onColorChanged)
    _onColorChanged(_color);
}

- (void)setColor:(NSColor *)color {
  _color = color;
  [self setNeedsDisplay:YES];
}

@end
