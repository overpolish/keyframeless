/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasStrokeGlyphs.h"

// The _Attic glyphs were authored on a 24-unit grid; this is the cubic-bezier
// circle constant they use for the rounded connectors / caps.
static const CGFloat kKappa = 0.5522847498f;
static const CGFloat kGlyphSize = 18.0f;

// Cap glyph: two stacked bars joined by a small rounded connector, the right
// edge closing per cap style. 0 = Butt (flat), 1 = Round (semicircle bulge),
// 2 = Square (extends past the end). Ported from _Attic/UI/CapStyleView.m.
static void CanvasDrawCapGlyph(CGFloat k, NSInteger cap) {
  NSBezierPath *p = [NSBezierPath bezierPath];
  [p moveToPoint:NSMakePoint(2 * k, 4 * k)];
  [p lineToPoint:NSMakePoint(2 * k, 11 * k)];
  [p lineToPoint:NSMakePoint(12.874 * k, 11 * k)];
  [p curveToPoint:NSMakePoint(13.786 * k, 12.004 * k)
      controlPoint1:NSMakePoint((12.874 + 0.911 * kKappa) * k, 11 * k)
      controlPoint2:NSMakePoint(13.786 * k, (12.004 - 1.004 * kKappa) * k)];
  [p curveToPoint:NSMakePoint(12.874 * k, 13.008 * k)
      controlPoint1:NSMakePoint(13.786 * k, (12.004 + 1.004 * kKappa) * k)
      controlPoint2:NSMakePoint((12.874 + 0.911 * kKappa) * k, 13.008 * k)];
  [p lineToPoint:NSMakePoint(2 * k, 13.008 * k)];
  [p lineToPoint:NSMakePoint(2 * k, 20 * k)];
  switch (cap) {
  case 0: // Butt
    [p lineToPoint:NSMakePoint(14 * k, 20 * k)];
    [p lineToPoint:NSMakePoint(14 * k, 4 * k)];
    break;
  case 1: { // Round
    CGFloat cx = 13.805, ry = 8.0, rx = 8.195;
    [p lineToPoint:NSMakePoint(cx * k, 20 * k)];
    [p curveToPoint:NSMakePoint((cx + rx) * k, 12 * k)
        controlPoint1:NSMakePoint((cx + rx * kKappa) * k, 20 * k)
        controlPoint2:NSMakePoint((cx + rx) * k, (12 + ry * kKappa) * k)];
    [p curveToPoint:NSMakePoint(cx * k, 4 * k)
        controlPoint1:NSMakePoint((cx + rx) * k, (12 - ry * kKappa) * k)
        controlPoint2:NSMakePoint((cx + rx * kKappa) * k, 4 * k)];
    break;
  }
  default: // Square
    [p lineToPoint:NSMakePoint(22 * k, 20 * k)];
    [p lineToPoint:NSMakePoint(22 * k, 4 * k)];
    break;
  }
  [p closePath];
  [p fill];
}

// Join glyph: an outer L whose corner varies per join style (0 = Miter sharp,
// 1 = Round quarter-circle, 2 = Bevel diagonal), with a fixed inner L cut out.
// Ported from _Attic/UI/JoinStyleView.m.
static void CanvasDrawJoinGlyph(CGFloat k, NSInteger join) {
  NSBezierPath *p = [NSBezierPath bezierPath];
  [p moveToPoint:NSMakePoint(2 * k, 22 * k)];
  switch (join) {
  case 0: // Miter
    [p lineToPoint:NSMakePoint(2 * k, 2 * k)];
    [p lineToPoint:NSMakePoint(22 * k, 2 * k)];
    break;
  case 1: { // Round
    [p lineToPoint:NSMakePoint(2 * k, 8 * k)];
    CGFloat r = 6.0;
    [p curveToPoint:NSMakePoint(8 * k, 2 * k)
        controlPoint1:NSMakePoint(2 * k, (8 - r * kKappa) * k)
        controlPoint2:NSMakePoint((8 - r * kKappa) * k, 2 * k)];
    [p lineToPoint:NSMakePoint(22 * k, 2 * k)];
    break;
  }
  default: // Bevel
    [p lineToPoint:NSMakePoint(2 * k, 8 * k)];
    [p lineToPoint:NSMakePoint(8 * k, 2 * k)];
    [p lineToPoint:NSMakePoint(22 * k, 2 * k)];
    break;
  }
  [p lineToPoint:NSMakePoint(22 * k, 7.055 * k)];
  [p lineToPoint:NSMakePoint(8 * k, 7.055 * k)];
  [p curveToPoint:NSMakePoint(7.055 * k, 8 * k)
      controlPoint1:NSMakePoint((8 - 0.945 * kKappa) * k, 7.055 * k)
      controlPoint2:NSMakePoint(7.055 * k, (8 - 0.945 * kKappa) * k)];
  [p lineToPoint:NSMakePoint(7.055 * k, 22 * k)];
  [p closePath];
  [p moveToPoint:NSMakePoint(8.945 * k, 8.945 * k)];
  [p lineToPoint:NSMakePoint(8.945 * k, 22 * k)];
  [p lineToPoint:NSMakePoint(14 * k, 22 * k)];
  [p lineToPoint:NSMakePoint(14 * k, 14 * k)];
  [p lineToPoint:NSMakePoint(22 * k, 14 * k)];
  [p lineToPoint:NSMakePoint(22 * k, 8.945 * k)];
  [p closePath];
  [p setWindingRule:NSWindingRuleEvenOdd];
  [p fill];
}

// The join glyph fills the 24-grid more than the cap glyph (its content runs
// y 2..22 vs the cap's 4..20), so at the same scale it reads larger. Shrink the
// join's content a touch, centred, so the two pills look the same size.
static const CGFloat kJoinContentScale = 0.84f;

static NSImage *CanvasGlyphImage(CGFloat contentScale, void (^draw)(CGFloat k)) {
  NSImage *img = [NSImage
        imageWithSize:NSMakeSize(kGlyphSize, kGlyphSize)
              flipped:NO
       drawingHandler:^BOOL(NSRect dstRect) {
         [[NSColor blackColor] set]; // template image: tinted by the control
         if (contentScale != 1.0f) {
           CGFloat c = kGlyphSize * 0.5f;
           NSAffineTransform *tx = [NSAffineTransform transform];
           [tx translateXBy:c yBy:c];
           [tx scaleBy:contentScale];
           [tx translateXBy:-c yBy:-c];
           [tx concat];
         }
         draw(kGlyphSize / 24.0f);
         return YES;
       }];
  img.template = YES; // adopts the pill's foreground colour
  return img;
}

NSArray<NSImage *> *CanvasLineCapGlyphs(void) {
  return @[
    CanvasGlyphImage(1.0f, ^(CGFloat k) { CanvasDrawCapGlyph(k, 0); }),
    CanvasGlyphImage(1.0f, ^(CGFloat k) { CanvasDrawCapGlyph(k, 1); }),
    CanvasGlyphImage(1.0f, ^(CGFloat k) { CanvasDrawCapGlyph(k, 2); }),
  ];
}

NSArray<NSImage *> *CanvasLineJoinGlyphs(void) {
  return @[
    CanvasGlyphImage(kJoinContentScale, ^(CGFloat k) { CanvasDrawJoinGlyph(k, 0); }),
    CanvasGlyphImage(kJoinContentScale, ^(CGFloat k) { CanvasDrawJoinGlyph(k, 1); }),
    CanvasGlyphImage(kJoinContentScale, ^(CGFloat k) { CanvasDrawJoinGlyph(k, 2); }),
  ];
}
