/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKResizeCursor.h"
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKOnScreenControl.h>

// FCP's canvas resize handles use custom cursor art from LunaKit, not AppKit's
// own resize cursors. Those renditions were extracted from LunaKit's Assets.car
// into this framework's Resources: ResizeLeftRightCursor (horizontal),
// MoveCurve (vertical), and ResizeTopLeft / ResizeTopRightCursor (the two
// diagonals). The hotspot is FCP's own, from LunaKit's SRCursor.plist (top-left
// origin, matching NSCursor): the resize arrows aim at (15,14), MoveCurve at
// (16,16). The white glyph sits up-left of the 32x32 frame centre because the
// drop-shadow fills the lower-right, so a naive (16,16) would read as
// off-centre. Cache per asset.
static NSCursor *bundledResizeCursor(NSString *assetName, NSPoint hotSpot) {
  static NSMutableDictionary<NSString *, NSCursor *> *cache = nil;
  if (!cache)
    cache = [NSMutableDictionary dictionary];
  NSCursor *cached = cache[assetName];
  if (cached)
    return cached;
  NSBundle *bundle = [NSBundle bundleForClass:[KKOnScreenControl class]];
  // imageForResource: resolves the bundled image by base name regardless of
  // extension and coalesces @2x. Xcode combines the loose Name.png +
  // Name@2x.png pair into a single multi-rep Name.tiff at build time, so a
  // hardcoded "png" type would miss it.
  NSImage *image = [bundle imageForResource:assetName];
  if (!image.isValid)
    return nil;
  NSCursor *cursor = [[NSCursor alloc] initWithImage:image hotSpot:hotSpot];
  cache[assetName] = cursor;
  return cursor;
}

// Private AppKit window-resize cursor (plain double-arrow, no centre bar) as a
// middle fallback if the bundled FCP art is missing.
static NSCursor *privateCursor(NSString *name) {
  SEL sel = NSSelectorFromString(name);
  if ([NSCursor respondsToSelector:sel]) {
    NSCursor *c = [NSCursor performSelector:sel];
    if (c)
      return c;
  }
  return nil;
}

// FCP cursor art first, then the private window-resize cursor, then a public
// cursor as a last resort.
static NSCursor *resizeCursor(NSString *asset, NSPoint hot, NSString *priv,
                              NSCursor *pub) {
  return bundledResizeCursor(asset, hot) ?: privateCursor(priv) ?: pub;
}

NSCursor *KKResizeCursorOfKind(KKResizeCursorKind kind) {
  switch (kind) {
  case KKResizeCursorHorizontal:
    return resizeCursor(@"ResizeLeftRightCursor", NSMakePoint(15, 14),
                        @"_windowResizeEastWestCursor",
                        [NSCursor resizeLeftRightCursor]);
  case KKResizeCursorVertical:
    return resizeCursor(@"MoveCurve", NSMakePoint(16, 16),
                        @"_windowResizeNorthSouthCursor",
                        [NSCursor resizeUpDownCursor]);
  case KKResizeCursorDiagonalNESW:
    return resizeCursor(@"ResizeTopRightCursor", NSMakePoint(15, 14),
                        @"_windowResizeNorthEastSouthWestCursor",
                        [NSCursor resizeLeftRightCursor]);
  case KKResizeCursorDiagonalNWSE:
    return resizeCursor(@"ResizeTopLeftCursor", NSMakePoint(15, 14),
                        @"_windowResizeNorthWestSouthEastCursor",
                        [NSCursor resizeUpDownCursor]);
  }
  return [NSCursor arrowCursor];
}

NSCursor *KKResizeCursorForAngle(double radians) {
  double deg = radians * 180.0 / M_PI;
  if (deg < 0)
    deg += 360.0;
  int sector = ((int)round(deg / 45.0)) % 8;
  switch (sector) {
  case 0: // Right (E)
  case 4: // Left  (W)
    return KKResizeCursorOfKind(KKResizeCursorHorizontal);
  case 2: // Up   (N)
  case 6: // Down (S)
    return KKResizeCursorOfKind(KKResizeCursorVertical);
  case 1: // Top-right   (NE) - "/" diagonal
  case 5: // Bottom-left (SW)
    return KKResizeCursorOfKind(KKResizeCursorDiagonalNESW);
  case 3: // Top-left     (NW) - "\" diagonal
  case 7: // Bottom-right (SE)
    return KKResizeCursorOfKind(KKResizeCursorDiagonalNWSE);
  default:
    return [NSCursor arrowCursor];
  }
}

NSCursor *KKPointMoveCursor(void) {
  // MoveCurveSegment hotspot from SRCursor.plist is (17,15).
  return bundledResizeCursor(@"MoveCurveSegment", NSMakePoint(17, 15))
             ?: [NSCursor openHandCursor];
}

NSCursor *KKRotateCursorForAngle(double radians) {
  // The four Rotate*Cursor assets aren't keyed in SRCursor.plist, so the
  // hotspot is the measured white-glyph centre (the curved arrow's visual
  // centre). Map the hover angle to the quadrant whose corner cursor curves
  // that way; same canvas convention as KKResizeCursorForAngle (NE =
  // top-right).
  double deg = radians * 180.0 / M_PI;
  if (deg < 0)
    deg += 360.0;
  NSCursor *c = nil;
  if (deg < 90.0) // NE
    c = bundledResizeCursor(@"RotateTopRightCursor", NSMakePoint(14, 16));
  else if (deg < 180.0) // NW
    c = bundledResizeCursor(@"RotateTopLeftCursor", NSMakePoint(17, 16));
  else if (deg < 270.0) // SW
    c = bundledResizeCursor(@"RotateBottomLeftCursor", NSMakePoint(17, 13));
  else // SE
    c = bundledResizeCursor(@"RotateBottomRightCursor", NSMakePoint(14, 13));
  return c ?: [NSCursor arrowCursor];
}

NSCursor *KKRotationAxisCursor(NSInteger axis, double hoverRadians) {
  switch (axis) {
  case 0: // X: tilt forward/back -> drag is vertical
    return KKResizeCursorOfKind(KKResizeCursorVertical);
  case 1: // Y: turn left/right -> drag is horizontal
    return KKResizeCursorOfKind(KKResizeCursorHorizontal);
  default: // Z: in-plane spin -> rotate
    return KKRotateCursorForAngle(hoverRadians);
  }
}

// Re-color an SF Symbol (a template image) by filling its alpha with `color`.
static NSImage *tintedSymbol(NSImage *symbol, NSColor *color) {
  NSImage *img = [symbol copy];
  img.template = NO;
  [img lockFocus];
  [color set];
  NSRectFillUsingOperation((NSRect){NSZeroPoint, img.size},
                           NSCompositingOperationSourceAtop);
  [img unlockFocus];
  return img;
}

// Render an SF Symbol into a cursor: a white glyph with a 1px dark outline
// (stamp a black copy at the 8 surrounding offsets, then the white glyph on
// top) so it stays legible over any canvas - the same white-glyph-with-edge
// look as FCP's bundled cursor art. macOS ships no visibility cursor, so the
// OSC Opt-hover hide/show affordance uses eye.slash / eye. Cached per symbol.
static NSCursor *symbolCursor(NSString *symbolName) {
  static NSMutableDictionary<NSString *, NSCursor *> *cache = nil;
  if (!cache)
    cache = [NSMutableDictionary dictionary];
  NSCursor *cached = cache[symbolName];
  if (cached)
    return cached;

  NSImage *base = [NSImage imageWithSystemSymbolName:symbolName
                            accessibilityDescription:nil];
  if (!base)
    return nil;
  NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration
      configurationWithPointSize:13.0
                          weight:NSFontWeightSemibold
                           scale:NSImageSymbolScaleMedium];
  NSImage *symbol = [base imageWithSymbolConfiguration:cfg] ?: base;

  NSSize gs = symbol.size;
  const CGFloat outline = 1.0;
  const CGFloat pad = outline + 1.0;
  NSSize canvasSize =
      NSMakeSize(ceil(gs.width + pad * 2), ceil(gs.height + pad * 2));
  NSImage *black = tintedSymbol(symbol, [NSColor blackColor]);
  NSImage *white = tintedSymbol(symbol, [NSColor whiteColor]);
  NSRect glyph = NSMakeRect(pad, pad, gs.width, gs.height);

  NSImage *out = [[NSImage alloc] initWithSize:canvasSize];
  [out lockFocus];
  for (int dx = -1; dx <= 1; dx++)
    for (int dy = -1; dy <= 1; dy++) {
      if (dx == 0 && dy == 0)
        continue;
      [black drawInRect:NSOffsetRect(glyph, dx * outline, dy * outline)
               fromRect:NSZeroRect
              operation:NSCompositingOperationSourceOver
               fraction:0.9];
    }
  [white drawInRect:glyph
           fromRect:NSZeroRect
          operation:NSCompositingOperationSourceOver
           fraction:1.0];
  [out unlockFocus];

  NSCursor *cursor =
      [[NSCursor alloc] initWithImage:out
                              hotSpot:NSMakePoint(canvasSize.width / 2.0,
                                                  canvasSize.height / 2.0)];
  cache[symbolName] = cursor;
  return cursor;
}

NSCursor *KKVisibilityHideCursor(void) {
  return symbolCursor(@"eye.slash") ?: [NSCursor arrowCursor];
}

NSCursor *KKVisibilityShowCursor(void) {
  return symbolCursor(@"eye") ?: [NSCursor arrowCursor];
}

NSCursor *KKResizeCursorForBoxHandle(NSInteger handleIndex) {
  // KKBoxOSC order: 0-3 corners BL, BR, TR, TL; 4-7 edges bottom, right, top,
  // left. The "/" and "\" diagonal arrows are symmetric, so a corner maps to a
  // diagonal kind independent of the canvas Y direction.
  switch (handleIndex) {
  case 0: // bottom-left
  case 2: // top-right
    return KKResizeCursorOfKind(KKResizeCursorDiagonalNESW);
  case 1: // bottom-right
  case 3: // top-left
    return KKResizeCursorOfKind(KKResizeCursorDiagonalNWSE);
  case 4: // bottom-mid
  case 6: // top-mid
    return KKResizeCursorOfKind(KKResizeCursorVertical);
  case 5: // right-mid
  case 7: // left-mid
    return KKResizeCursorOfKind(KKResizeCursorHorizontal);
  default:
    return nil;
  }
}
