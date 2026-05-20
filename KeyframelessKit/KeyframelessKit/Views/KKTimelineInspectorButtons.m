/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineInspectorButtons.h"

#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"

static const CGFloat kLoopIconSize = 11.0;
static const CGFloat kConstantsIconSize = 10.0;
static const CGFloat kDetachIconSize = 12.0;
static const CGFloat kPlayIconSize = 11.0;
static const CGFloat kResetIconSize = 11.0;

// Tint a copy of `src` with `tint` by source-atop fill. Used so each button
// shares one base symbol image and just paints it on/off-state coloured.
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

static NSImage *KKSymbolImage(NSString *name, CGFloat pointSize) {
  return [[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil]
      imageWithSymbolConfiguration:
          [NSImageSymbolConfiguration
              configurationWithPointSize:pointSize
                                  weight:NSFontWeightMedium]];
}

static NSImage *KKLoopImage(void) {
  return KKSymbolImage(@"repeat", kLoopIconSize);
}
static NSImage *KKPlayImage(void) {
  return KKSymbolImage(@"playpause.fill", kPlayIconSize);
}
static NSImage *KKResetImage(void) {
  return KKSymbolImage(@"arrow.down.right.and.arrow.up.left", kResetIconSize);
}
static NSImage *KKConstantsImage(void) {
  return KKSymbolImage(@"slider.horizontal.3", kConstantsIconSize);
}
static NSImage *KKDetachImage(void) {
  return KKSymbolImage(@"arrow.up.forward.app.fill", kDetachIconSize);
}

// Shared body for the centred icon-only buttons (Loop / Play / Reset /
// Detach). `tinted` is already coloured; just centre and blit.
static void KKDrawCentredIcon(NSImage *tinted, NSRect bounds) {
  CGFloat x = NSMidX(bounds) - tinted.size.width / 2.0;
  CGFloat y = NSMidY(bounds) - tinted.size.height / 2.0;
  [tinted drawAtPoint:NSMakePoint(x, y)
             fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver
             fraction:1.0];
}

@implementation KKLoopButton

- (BOOL)isFlipped {
  return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
  NSColor *tint = _on ? [NSColor accentMatchingHost]
                      : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
  KKDrawCentredIcon(KKTintedImage(KKLoopImage(), tint), self.bounds);
}

- (void)mouseDown:(NSEvent *)event {
  _on = !_on;
  [self setNeedsDisplay:YES];
  if (_onToggled)
    _onToggled(_on);
}

- (NSSize)intrinsicContentSize {
  return NSMakeSize(ceil(KKLoopImage().size.width) + 2.5, 18.0);
}

@end

@implementation KKPlayButton

- (BOOL)isFlipped {
  return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

- (void)setPlaying:(BOOL)playing {
  if (_playing == playing)
    return;
  _playing = playing;
  [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
  // Match the loop button exactly: accent while playing, the same gray
  // when paused (they sit side by side, so a different tone looks off).
  NSColor *tint = _playing
                      ? [NSColor accentMatchingHost]
                      : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
  KKDrawCentredIcon(KKTintedImage(KKPlayImage(), tint), self.bounds);
}

- (void)mouseDown:(NSEvent *)event {
  if (_onTapped)
    _onTapped();
}

- (NSSize)intrinsicContentSize {
  return NSMakeSize(ceil(KKPlayImage().size.width) + 2.5, 18.0);
}

@end

@implementation KKResetZoomButton

- (BOOL)isFlipped {
  return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

- (void)setZoomed:(BOOL)zoomed {
  if (_zoomed == zoomed)
    return;
  _zoomed = zoomed;
  [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
  // Accent while zoomed in, the loop button's gray at fit.
  NSColor *tint = _zoomed
                      ? [NSColor accentMatchingHost]
                      : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
  KKDrawCentredIcon(KKTintedImage(KKResetImage(), tint), self.bounds);
}

- (void)mouseDown:(NSEvent *)event {
  if (_onTapped)
    _onTapped();
}

- (NSSize)intrinsicContentSize {
  return NSMakeSize(ceil(KKResetImage().size.width) + 2.5, 18.0);
}

@end

@implementation KKConstantsButton

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

@implementation KKDetachButton

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
  return NSMakeSize(ceil(KKDetachImage().size.width) + 4.0, 18.0);
}

@end
