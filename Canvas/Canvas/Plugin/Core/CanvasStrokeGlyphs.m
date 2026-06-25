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

static NSImage *CanvasGlyphImage(CGFloat contentScale,
                                 void (^draw)(CGFloat k)) {
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
    CanvasGlyphImage(1.0f,
                     ^(CGFloat k) {
                       CanvasDrawCapGlyph(k, 0);
                     }),
    CanvasGlyphImage(1.0f,
                     ^(CGFloat k) {
                       CanvasDrawCapGlyph(k, 1);
                     }),
    CanvasGlyphImage(1.0f,
                     ^(CGFloat k) {
                       CanvasDrawCapGlyph(k, 2);
                     }),
  ];
}

NSArray<NSImage *> *CanvasLineJoinGlyphs(void) {
  return @[
    CanvasGlyphImage(kJoinContentScale,
                     ^(CGFloat k) {
                       CanvasDrawJoinGlyph(k, 0);
                     }),
    CanvasGlyphImage(kJoinContentScale,
                     ^(CGFloat k) {
                       CanvasDrawJoinGlyph(k, 1);
                     }),
    CanvasGlyphImage(kJoinContentScale,
                     ^(CGFloat k) {
                       CanvasDrawJoinGlyph(k, 2);
                     }),
  ];
}

// Marker glyphs: a baseline stroke (y = 12 on the 24-grid) with the decoration
// at the matching end (right for End, mirrored left for Start). Ported from
// _Attic/UI/MarkerStyleView.m, retuned to the cap/join glyph weight + bounds.
static const CGFloat kMarkerLineW = 2.0f; // 24-grid units, scaled by k

static void CanvasMarkerBaseline(CGFloat k, CGFloat x0, CGFloat x1) {
  NSBezierPath *p = [NSBezierPath bezierPath];
  [p moveToPoint:NSMakePoint(x0 * k, 12 * k)];
  [p lineToPoint:NSMakePoint(x1 * k, 12 * k)];
  p.lineWidth = kMarkerLineW * k;
  p.lineCapStyle = NSLineCapStyleRound;
  [p stroke];
}

static void CanvasDrawMarkerNone(CGFloat k, BOOL isStart) {
  (void)isStart;
  CanvasMarkerBaseline(k, 3, 21);
}

static void CanvasDrawMarkerArrow(CGFloat k, BOOL isStart) {
  CanvasMarkerBaseline(k, 3, 21);
  NSBezierPath *tri = [NSBezierPath bezierPath];
  if (isStart) {
    [tri moveToPoint:NSMakePoint(10 * k, 6 * k)];
    [tri lineToPoint:NSMakePoint(3 * k, 12 * k)];
    [tri lineToPoint:NSMakePoint(10 * k, 18 * k)];
  } else {
    [tri moveToPoint:NSMakePoint(14 * k, 6 * k)];
    [tri lineToPoint:NSMakePoint(21 * k, 12 * k)];
    [tri lineToPoint:NSMakePoint(14 * k, 18 * k)];
  }
  [tri closePath];
  [tri fill];
}

static void CanvasDrawMarkerCircle(CGFloat k, BOOL isStart) {
  CGFloat r = 4.5f;
  CGFloat cx = isStart ? 7.5f : 16.5f;
  if (isStart)
    CanvasMarkerBaseline(k, cx + r, 21);
  else
    CanvasMarkerBaseline(k, 3, cx - r);
  NSRect rr = NSMakeRect((cx - r) * k, (12 - r) * k, 2 * r * k, 2 * r * k);
  [[NSBezierPath bezierPathWithOvalInRect:rr] fill];
}

static void CanvasDrawMarkerSquare(CGFloat k, BOOL isStart) {
  CGFloat h = 4.5f;
  CGFloat cx = isStart ? 7.5f : 16.5f;
  if (isStart)
    CanvasMarkerBaseline(k, cx + h, 21);
  else
    CanvasMarkerBaseline(k, 3, cx - h);
  NSRect rr = NSMakeRect((cx - h) * k, (12 - h) * k, 2 * h * k, 2 * h * k);
  [[NSBezierPath bezierPathWithRect:rr] fill];
}

static void CanvasDrawMarkerArrowhead(CGFloat k, BOOL isStart) {
  CanvasMarkerBaseline(k, 3, 21);
  NSBezierPath *chev = [NSBezierPath bezierPath];
  chev.lineWidth = kMarkerLineW * k;
  chev.lineCapStyle = NSLineCapStyleRound;
  chev.lineJoinStyle = NSLineJoinStyleRound;
  if (isStart) {
    [chev moveToPoint:NSMakePoint(10 * k, 6 * k)];
    [chev lineToPoint:NSMakePoint(4 * k, 12 * k)];
    [chev lineToPoint:NSMakePoint(10 * k, 18 * k)];
  } else {
    [chev moveToPoint:NSMakePoint(14 * k, 6 * k)];
    [chev lineToPoint:NSMakePoint(20 * k, 12 * k)];
    [chev lineToPoint:NSMakePoint(14 * k, 18 * k)];
  }
  [chev stroke];
}

static void CanvasDrawMarkerLine(CGFloat k, BOOL isStart) {
  CanvasMarkerBaseline(k, 3, 21);
  NSBezierPath *bar = [NSBezierPath bezierPath];
  bar.lineWidth = kMarkerLineW * k;
  bar.lineCapStyle = NSLineCapStyleRound;
  CGFloat bx = isStart ? 4 : 20;
  [bar moveToPoint:NSMakePoint(bx * k, 6 * k)];
  [bar lineToPoint:NSMakePoint(bx * k, 18 * k)];
  [bar stroke];
}

NSArray<NSImage *> *CanvasMarkerGlyphs(BOOL isStart) {
  return @[
    CanvasGlyphImage(1.0f,
                     ^(CGFloat k) {
                       CanvasDrawMarkerNone(k, isStart);
                     }),
    CanvasGlyphImage(1.0f,
                     ^(CGFloat k) {
                       CanvasDrawMarkerArrow(k, isStart);
                     }),
    CanvasGlyphImage(1.0f,
                     ^(CGFloat k) {
                       CanvasDrawMarkerCircle(k, isStart);
                     }),
    CanvasGlyphImage(1.0f,
                     ^(CGFloat k) {
                       CanvasDrawMarkerSquare(k, isStart);
                     }),
    CanvasGlyphImage(1.0f,
                     ^(CGFloat k) {
                       CanvasDrawMarkerArrowhead(k, isStart);
                     }),
    CanvasGlyphImage(1.0f,
                     ^(CGFloat k) {
                       CanvasDrawMarkerLine(k, isStart);
                     }),
  ];
}

// Fill style glyph on the 24-grid (the helper sets the template colour +
// origin). 0 = Solid (filled rounded rect), 1 = Hachure (diagonals clipped to
// the box), 2 = Cross-hatch (two diagonal sets), 3 = Zigzag, 4 = Dots (3x3).
// Ported from _Attic/UI/FillStyleView.m.
static void CanvasDrawFillStyleGlyph(CGFloat k, NSInteger style) {
  CGFloat inset = 5.0 * k, size = 14.0 * k;
  NSRect box = NSMakeRect(inset, inset, size, size);
  switch (style) {
  case 0: {
    [[NSBezierPath bezierPathWithRoundedRect:box xRadius:2 * k
                                     yRadius:2 * k] fill];
    break;
  }
  case 1: {
    [NSGraphicsContext saveGraphicsState];
    [[NSBezierPath bezierPathWithRoundedRect:box xRadius:2 * k
                                     yRadius:2 * k] addClip];
    for (CGFloat o = -size; o <= size * 2; o += 4.5 * k) {
      NSBezierPath *l = [NSBezierPath bezierPath];
      [l moveToPoint:NSMakePoint(inset + o, inset + size)];
      [l lineToPoint:NSMakePoint(inset + o + size, inset)];
      [l setLineWidth:1.0 * k];
      [l stroke];
    }
    [NSGraphicsContext restoreGraphicsState];
    break;
  }
  case 2: {
    [NSGraphicsContext saveGraphicsState];
    [[NSBezierPath bezierPathWithRoundedRect:box xRadius:2 * k
                                     yRadius:2 * k] addClip];
    for (CGFloat o = -size; o <= size * 2; o += 5.0 * k) {
      NSBezierPath *l = [NSBezierPath bezierPath];
      [l moveToPoint:NSMakePoint(inset + o, inset + size)];
      [l lineToPoint:NSMakePoint(inset + o + size, inset)];
      [l setLineWidth:1.0 * k];
      [l stroke];
      NSBezierPath *l2 = [NSBezierPath bezierPath];
      [l2 moveToPoint:NSMakePoint(inset + o, inset)];
      [l2 lineToPoint:NSMakePoint(inset + o + size, inset + size)];
      [l2 setLineWidth:1.0 * k];
      [l2 stroke];
    }
    [NSGraphicsContext restoreGraphicsState];
    break;
  }
  case 3: {
    [NSGraphicsContext saveGraphicsState];
    [[NSBezierPath bezierPathWithRoundedRect:box xRadius:2 * k
                                     yRadius:2 * k] addClip];
    CGFloat zigH = 3.0 * k, zigW = 2.5 * k, midY = inset + (size - zigH) / 2.0;
    NSBezierPath *zig = [NSBezierPath bezierPath];
    [zig moveToPoint:NSMakePoint(inset, midY)];
    for (CGFloat x = 0; x < size; x += zigW * 2) {
      [zig lineToPoint:NSMakePoint(inset + x + zigW, midY + zigH)];
      [zig lineToPoint:NSMakePoint(inset + x + zigW * 2, midY)];
    }
    [zig setLineWidth:1.2 * k];
    [zig stroke];
    [NSGraphicsContext restoreGraphicsState];
    break;
  }
  default: {
    CGFloat dotR = 1.0 * k, step = size / 4.0;
    for (NSInteger row = 0; row < 3; row++)
      for (NSInteger col = 0; col < 3; col++) {
        CGFloat cx = inset + step * (col + 1), cy = inset + step * (row + 1);
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx - dotR, cy - dotR,
                                                           dotR * 2, dotR * 2)]
            fill];
      }
    break;
  }
  }
}

NSArray<NSImage *> *CanvasFillStyleGlyphs(void) {
  return @[
    CanvasGlyphImage(1.0f,
                     ^(CGFloat k) {
                       CanvasDrawFillStyleGlyph(k, 0);
                     }),
    CanvasGlyphImage(1.0f,
                     ^(CGFloat k) {
                       CanvasDrawFillStyleGlyph(k, 1);
                     }),
    CanvasGlyphImage(1.0f,
                     ^(CGFloat k) {
                       CanvasDrawFillStyleGlyph(k, 2);
                     }),
    CanvasGlyphImage(1.0f,
                     ^(CGFloat k) {
                       CanvasDrawFillStyleGlyph(k, 3);
                     }),
    CanvasGlyphImage(1.0f,
                     ^(CGFloat k) {
                       CanvasDrawFillStyleGlyph(k, 4);
                     }),
  ];
}
