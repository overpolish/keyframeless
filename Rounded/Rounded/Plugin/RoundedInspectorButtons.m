/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "RoundedInspectorButtons.h"
#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>

static const CGFloat kLoopIconSize = 11.0;
static const CGFloat kConstantsIconSize = 10.0;
static const CGFloat kDetachIconSize = 12.0;

static NSImage *KKTintedImage(NSImage *src, NSColor *tint) {
  NSImage *result = [src copy];
  [result lockFocus];
  [tint set];
  NSRectFillUsingOperation(
      NSMakeRect(0, 0, result.size.width, result.size.height),
      NSCompositingOperationSourceAtop);
  [result unlockFocus];
  return result;
}

static NSImage *KKLoopImage(void) {
  return [[NSImage imageWithSystemSymbolName:@"repeat"
                    accessibilityDescription:nil]
      imageWithSymbolConfiguration:
          [NSImageSymbolConfiguration
              configurationWithPointSize:kLoopIconSize
                                  weight:NSFontWeightMedium]];
}

static NSImage *KKConstantsImage(void) {
  return [[NSImage imageWithSystemSymbolName:@"slider.horizontal.3"
                    accessibilityDescription:nil]
      imageWithSymbolConfiguration:
          [NSImageSymbolConfiguration
              configurationWithPointSize:kConstantsIconSize
                                  weight:NSFontWeightMedium]];
}

static NSImage *KKDetachImage(void) {
  return [[NSImage imageWithSystemSymbolName:@"arrow.up.forward.app.fill"
                    accessibilityDescription:nil]
      imageWithSymbolConfiguration:
          [NSImageSymbolConfiguration
              configurationWithPointSize:kDetachIconSize
                                  weight:NSFontWeightMedium]];
}

@implementation _RoundedLoopButton

- (BOOL)isFlipped {
  return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
  NSColor *tint = _on ? [NSColor accentMatchingHost]
                      : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
  NSImage *tinted = KKTintedImage(KKLoopImage(), tint);
  CGFloat x = NSMidX(self.bounds) - tinted.size.width / 2.0;
  CGFloat y = NSMidY(self.bounds) - tinted.size.height / 2.0;
  [tinted drawAtPoint:NSMakePoint(x, y)
             fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver
             fraction:1.0];
}

- (void)mouseDown:(NSEvent *)event {
  _on = !_on;
  [self setNeedsDisplay:YES];
  if (_onToggled)
    _onToggled(_on);
}

- (NSSize)intrinsicContentSize {
  NSImage *img = KKLoopImage();
  return NSMakeSize(ceil(img.size.width) + 2.5, 18.0);
}

@end

@implementation _RoundedConstantsButton

- (BOOL)isFlipped {
  return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
  NSColor *tint = [[NSColor inspectorLabel] colorWithAlphaComponent:0.45];
  NSImage *tinted = KKTintedImage(KKConstantsImage(), tint);

  static const CGFloat kPadX = 5.0, kGap = 3.0;
  CGFloat iconY = NSMidY(self.bounds) - tinted.size.height / 2.0;
  [tinted drawAtPoint:NSMakePoint(kPadX, iconY)
             fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver
             fraction:1.0];

  NSFont *font = [NSFont systemFontOfSize:KKFontSizeSM
                                   weight:NSFontWeightMedium];
  NSDictionary *attrs =
      @{NSFontAttributeName : font, NSForegroundColorAttributeName : tint};
  NSSize textSz = [@"Constants" sizeWithAttributes:attrs];
  CGFloat textX = kPadX + tinted.size.width + kGap;
  CGFloat textY = NSMidY(self.bounds) - textSz.height / 2.0;
  [@"Constants" drawAtPoint:NSMakePoint(textX, textY) withAttributes:attrs];
}

- (void)mouseDown:(NSEvent *)event {
  if (_onTapped)
    _onTapped();
}

- (NSSize)intrinsicContentSize {
  NSImage *img = KKConstantsImage();
  NSFont *font = [NSFont systemFontOfSize:KKFontSizeSM
                                   weight:NSFontWeightMedium];
  CGFloat textW = ceil(
      [@"Constants" sizeWithAttributes:@{NSFontAttributeName : font}].width);
  static const CGFloat kPadX = 5.0, kGap = 3.0;
  return NSMakeSize(kPadX + ceil(img.size.width) + kGap + textW + kPadX, 18.0);
}

@end

@implementation _RoundedDetachButton

- (BOOL)isFlipped {
  return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
  NSColor *tint = _on ? [NSColor accentMatchingHost]
                      : [[NSColor inspectorLabel] colorWithAlphaComponent:0.45];
  NSImage *tinted = KKTintedImage(KKDetachImage(), tint);
  CGFloat x = NSMidX(self.bounds) - tinted.size.width / 2.0;
  CGFloat y = NSMidY(self.bounds) - tinted.size.height / 2.0;
  [tinted drawInRect:NSMakeRect(x, y, tinted.size.width, tinted.size.height)
            fromRect:NSZeroRect
           operation:NSCompositingOperationSourceOver
            fraction:1.0
      respectFlipped:YES
               hints:nil];
}

- (void)mouseDown:(NSEvent *)event {
  if (_onTapped)
    _onTapped();
}

- (NSSize)intrinsicContentSize {
  NSImage *img = KKDetachImage();
  return NSMakeSize(ceil(img.size.width) + 4.0, 18.0);
}

@end
