/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineInspectorButtons.h"
#import "KKLocalized.h"

#import "KKTokens.h"
#import "NSColor+KKColors.h"

static const CGFloat kLoopIconSize = 11.0;
static const CGFloat kConstantsIconSize = 10.0;
static const CGFloat kDetachIconSize = 12.0;
static const CGFloat kPlayIconSize = 11.0;
static const CGFloat kResetIconSize = 11.0;
static const CGFloat kClearIconSize = 11.0;
static const CGFloat kOnionSkinIconSize = 11.0;
static const CGFloat kDynamicIconSize = 11.0;
static const CGFloat kMaintainTimingIconSize = 11.0;

NSButton *KKResetToDefaultButton(id target, SEL action) {
  NSImage *resetImg =
      [[NSImage imageWithSystemSymbolName:@"arrow.counterclockwise"
                 accessibilityDescription:KKLoc(@"Reset to default",
                                                @"Reset control to default.")]
          imageWithSymbolConfiguration:
              [NSImageSymbolConfiguration
                  configurationWithPointSize:10.5
                                      weight:NSFontWeightRegular]];
  NSButton *reset = [NSButton buttonWithImage:resetImg
                                       target:target
                                       action:action];
  reset.bordered = NO;
  reset.imagePosition = NSImageOnly;
  reset.contentTintColor =
      [[NSColor inspectorLabel] colorWithAlphaComponent:0.5];
  reset.toolTip = KKLoc(@"Reset to default", @"Reset control to default.");
  reset.translatesAutoresizingMaskIntoConstraints = NO;
  reset.hidden = YES;
  return reset;
}

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
static NSImage *KKOnionSkinImage(void) {
  return KKSymbolImage(@"film", kOnionSkinIconSize);
}
static NSImage *KKDynamicImage(void) {
  return KKSymbolImage(@"arrow.left.and.right", kDynamicIconSize);
}
static NSImage *KKMaintainTimingImage(void) {
  NSImage *img = KKSymbolImage(@"lock.badge.clock", kMaintainTimingIconSize);
  if (!img) // older OS without this symbol
    img = KKSymbolImage(@"lock", kMaintainTimingIconSize);
  return img;
}

// Shared body for the centred icon-only buttons (Loop / Play / Reset /
// Detach). `tinted` is already coloured; just centre and blit.
static void KKDrawCentredIcon(NSImage *tinted, NSRect bounds) {
  CGFloat x = NSMidX(bounds) - tinted.size.width / 2.0;
  CGFloat y = NSMidY(bounds) - tinted.size.height / 2.0;
  // These buttons are isFlipped=YES; drawAtPoint: ignores that and renders the
  // image upside down (only visible on a vertically-asymmetric glyph like the
  // lock). respectFlipped:YES draws it upright.
  [tinted drawInRect:NSMakeRect(x, y, tinted.size.width, tinted.size.height)
            fromRect:NSZeroRect
           operation:NSCompositingOperationSourceOver
            fraction:1.0
      respectFlipped:YES
               hints:nil];
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

@implementation KKClearSelectionButton

- (BOOL)isFlipped {
  return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

- (void)setEnabled:(BOOL)enabled {
  if (_enabled == enabled)
    return;
  _enabled = enabled;
  [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
  NSColor *tint = _enabled
                      ? [NSColor accentMatchingHost]
                      : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
  NSImage *img = KKSymbolImage(@"xmark.circle", kClearIconSize);
  KKDrawCentredIcon(KKTintedImage(img, tint), self.bounds);
}

- (void)mouseDown:(NSEvent *)event {
  if (!_enabled)
    return;
  if (_onTapped)
    _onTapped();
}

- (NSSize)intrinsicContentSize {
  NSImage *img = KKSymbolImage(@"xmark.circle", kClearIconSize);
  return NSMakeSize(ceil(img.size.width) + 2.5, 18.0);
}

@end

@implementation KKConstantsButton

- (BOOL)isFlipped {
  return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

- (void)setActive:(BOOL)active {
  if (_active == active)
    return;
  _active = active;
  [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
  // Accent highlight background + tint while active (its popover is showing
  // constants). Full-radius pill to match the keypose pills, no outline - a
  // filled highlight plus the accent icon/text is the whole selection cue.
  if (_active) {
    NSColor *accent = [NSColor accentMatchingHost];
    CGFloat r = NSHeight(self.bounds) / 2.0;
    NSBezierPath *fill = [NSBezierPath bezierPathWithRoundedRect:self.bounds
                                                         xRadius:r
                                                         yRadius:r];
    [[accent colorWithAlphaComponent:0.18] setFill];
    [fill fill];
  }
  NSColor *tint = _active
                      ? [NSColor accentMatchingHost]
                      : [[NSColor inspectorLabel] colorWithAlphaComponent:0.45];
  NSImage *tinted = KKTintedImage(KKConstantsImage(), tint);

  // Horizontal padding so the full-radius highlight reads as a balanced pill,
  // matching the grouped tab pill's proportions.
  CGFloat kPadX = KKPaddingLG, kGap = KKSpacingSM;
  CGFloat iconY = NSMidY(self.bounds) - tinted.size.height / 2.0;
  [tinted drawAtPoint:NSMakePoint(kPadX, iconY)
             fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver
             fraction:1.0];

  NSFont *font = [NSFont systemFontOfSize:KKFontSizeSM
                                   weight:NSFontWeightMedium];
  NSDictionary *attrs =
      @{NSFontAttributeName : font, NSForegroundColorAttributeName : tint};
  NSSize textSz = [KKLoc(@"Constants", @"Constants editor tab/section header.")
      sizeWithAttributes:attrs];
  CGFloat textX = kPadX + tinted.size.width + kGap;
  CGFloat textY = NSMidY(self.bounds) - textSz.height / 2.0;
  [KKLoc(@"Constants", @"Constants editor tab/section header.")
         drawAtPoint:NSMakePoint(textX, textY)
      withAttributes:attrs];
}

- (void)mouseDown:(NSEvent *)event {
  if (_onTapped)
    _onTapped();
}

- (NSSize)intrinsicContentSize {
  NSImage *img = KKConstantsImage();
  NSFont *font = [NSFont systemFontOfSize:KKFontSizeSM
                                   weight:NSFontWeightMedium];
  CGFloat textW =
      ceil([KKLoc(@"Constants", @"Constants editor tab/section header.")
               sizeWithAttributes:@{NSFontAttributeName : font}]
               .width);
  CGFloat kPadX = KKPaddingLG, kGap = KKSpacingSM;
  // 18pt to match the Basic/Advanced tab pill it centres against, so the
  // highlight lines up with those pills.
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

@implementation KKOnionSkinButton

- (BOOL)isFlipped {
  return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
  NSColor *tint = _on ? [NSColor accentMatchingHost]
                      : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
  KKDrawCentredIcon(KKTintedImage(KKOnionSkinImage(), tint), self.bounds);
}

- (void)mouseDown:(NSEvent *)event {
  _on = !_on;
  [self setNeedsDisplay:YES];
  if (_onToggled)
    _onToggled(_on);
}

- (NSSize)intrinsicContentSize {
  return NSMakeSize(ceil(KKOnionSkinImage().size.width) + 2.5, 18.0);
}

@end

@implementation KKDynamicButton

- (BOOL)isFlipped {
  return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

// Custom setter so a programmatic `on =` (the guide forcing/restoring Dynamic)
// repaints the glyph - the synthesized setter wouldn't, leaving a stale icon
// while the model is already correct.
- (void)setOn:(BOOL)on {
  if (_on == on)
    return;
  _on = on;
  [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
  NSColor *tint = _on ? [NSColor accentMatchingHost]
                      : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
  KKDrawCentredIcon(KKTintedImage(KKDynamicImage(), tint), self.bounds);
}

- (void)mouseDown:(NSEvent *)event {
  self.on = !_on;
  if (_onToggled)
    _onToggled(_on);
}

- (NSSize)intrinsicContentSize {
  return NSMakeSize(ceil(KKDynamicImage().size.width) + 2.5, 18.0);
}

@end

@implementation KKMaintainTimingButton

- (BOOL)isFlipped {
  return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

- (void)setOn:(BOOL)on {
  if (_on == on)
    return;
  _on = on;
  [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
  NSColor *tint = _on ? [NSColor accentMatchingHost]
                      : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
  KKDrawCentredIcon(KKTintedImage(KKMaintainTimingImage(), tint), self.bounds);
}

- (void)mouseDown:(NSEvent *)event {
  self.on = !_on;
  if (_onToggled)
    _onToggled(_on);
}

- (NSSize)intrinsicContentSize {
  return NSMakeSize(ceil(KKMaintainTimingImage().size.width) + 2.5, 18.0);
}

@end
