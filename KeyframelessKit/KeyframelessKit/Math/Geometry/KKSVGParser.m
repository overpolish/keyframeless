/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKSVGParser.h"
#import "KKBezierPath.h"
#import <simd/simd.h>

#define NANOSVG_IMPLEMENTATION
#include "nanosvg.h"

static float sRGBToLinear(float c) {
  return (c <= 0.04045f) ? (c / 12.92f) : powf((c + 0.055f) / 1.055f, 2.4f);
}

// Endpoint-marker name -> KKBezierPath marker index. Matches the canonical
// marker set (None, Arrow, Circle, Square, Arrowhead, Line). Unknown / "none"
// -> 0 (no marker).
static uint8_t KKMarkerIndexForName(NSString *name) {
  static NSDictionary<NSString *, NSNumber *> *map;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    map = @{
      @"arrow" : @1,
      @"circle" : @2,
      @"dot" : @2,
      @"square" : @3,
      @"arrowhead" : @4,
      @"line" : @5,
      @"bar" : @5,
    };
  });
  NSNumber *idx = map[name.lowercaseString];
  return idx ? (uint8_t)idx.unsignedCharValue : 0;
}

// Parse endpoint-marker hints from an SVG element `id`, so an author (or the AI)
// can request the plugin's NATIVE stroke markers instead of drawing arrowhead
// geometry. Tokens (space/comma separated): a LEADING tilde = START end, a
// TRAILING tilde = END end, e.g. "~arrow" (arrow at start), "arrow~" (arrow at
// end), "~arrow~" (both), "~circle arrow~" (circle start, arrow end). The marker
// renders at the stroke's default size (% of stroke width).
static void KKApplyMarkerHintsFromID(KKBezierPath *path, const char *cid) {
  if (!cid || cid[0] == '\0')
    return;
  NSString *raw = [NSString stringWithUTF8String:cid];
  NSCharacterSet *seps = [NSCharacterSet characterSetWithCharactersInString:@" ,;"];
  for (NSString *tokenRaw in [raw componentsSeparatedByCharactersInSet:seps]) {
    NSString *token = [tokenRaw stringByTrimmingCharactersInSet:
                                    [NSCharacterSet whitespaceCharacterSet]];
    if (token.length < 2)
      continue;
    BOOL atStart = [token hasPrefix:@"~"];
    BOOL atEnd = [token hasSuffix:@"~"];
    if (!atStart && !atEnd)
      continue;
    NSString *name = [token
        stringByTrimmingCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@"~"]];
    uint8_t idx = KKMarkerIndexForName(name);
    if (idx == 0)
      continue;
    if (atStart) {
      path.startMarker = idx;
      if (path.startMarkerSize <= 0.0f)
        path.startMarkerSize = 300.0f; // 3x stroke width (lane default)
    }
    if (atEnd) {
      path.endMarker = idx;
      if (path.endMarkerSize <= 0.0f)
        path.endMarkerSize = 300.0f;
    }
  }
}

@implementation KKSVGParser

+ (NSArray<KKBezierPath *> *)pathsFromSVGString:(NSString *)svgString
                                    canvasWidth:(float)canvasWidth
                                   canvasHeight:(float)canvasHeight {
  if (!svgString || svgString.length == 0)
    return @[];
  if (canvasWidth < 1)
    canvasWidth = 1;
  if (canvasHeight < 1)
    canvasHeight = 1;

  // `currentColor` means "inherit the CSS `color` property", which has no value
  // outside a document - nanosvg can't resolve the keyword and falls back to a
  // bogus mid-grey (the unknown-colour-name default). Resolve it to its spec
  // default (black) up front so a currentColor stroke/fill imports as black
  // rather than grey, and keeps its stroke-width.
  svgString = [svgString stringByReplacingOccurrencesOfString:@"currentColor"
                                                   withString:@"black"
                                                      options:NSCaseInsensitiveSearch
                                                        range:NSMakeRange(0, svgString.length)];

  // nsvgParse modifies the input string, so we need a mutable C copy.
  const char *utf8 = [svgString UTF8String];
  char *buf = strdup(utf8);
  NSVGimage *image = nsvgParse(buf, "px", 96);
  free(buf);
  if (!image)
    return @[];

  NSMutableArray<KKBezierPath *> *results = [NSMutableArray array];

  for (NSVGshape *shape = image->shapes; shape != NULL; shape = shape->next) {
    if (!(shape->flags & NSVG_FLAGS_VISIBLE))
      continue;

    KKBezierPath *path = [[KKBezierPath alloc] init];

    // --- Fill ---
    if (shape->fill.type == NSVG_PAINT_COLOR) {
      path.fillEnabled = YES;
      unsigned int fc = shape->fill.color;
      path.fillR = sRGBToLinear((fc & 0xFF) / 255.0f);
      path.fillG = sRGBToLinear(((fc >> 8) & 0xFF) / 255.0f);
      path.fillB = sRGBToLinear(((fc >> 16) & 0xFF) / 255.0f);
    } else {
      path.fillEnabled = NO;
    }

    // --- Stroke ---
    if (shape->stroke.type == NSVG_PAINT_COLOR) {
      path.strokeEnabled = YES;
      unsigned int sc = shape->stroke.color;
      path.strokeR = sRGBToLinear((sc & 0xFF) / 255.0f);
      path.strokeG = sRGBToLinear(((sc >> 8) & 0xFF) / 255.0f);
      path.strokeB = sRGBToLinear(((sc >> 16) & 0xFF) / 255.0f);
      path.strokeWidth = shape->strokeWidth;
    } else {
      path.strokeEnabled = NO;
    }

    // If neither fill nor stroke, default to a visible state.
    if (!path.fillEnabled && !path.strokeEnabled) {
      path.strokeEnabled = YES;
      path.strokeR = 0;
      path.strokeG = 0;
      path.strokeB = 0;
      path.strokeWidth = 1.0f;
    }

    path.opacity = shape->opacity;
    path.lineJoin = (uint8_t)shape->strokeLineJoin;
    path.lineCap = (uint8_t)shape->strokeLineCap;

    // Native endpoint markers requested via the element id (e.g. "arrow~"),
    // so an arrow uses the plugin's stroke marker instead of drawn geometry.
    KKApplyMarkerHintsFromID(path, shape->id);

    // --- Convert paths (contours) ---
    BOOL isFirstContour = YES;
    for (NSVGpath *npath = shape->paths; npath != NULL; npath = npath->next) {
      if (npath->npts < 2)
        continue;

      if (!isFirstContour)
        [path beginContour];
      isFirstContour = NO;

      // nanosvg stores cubic bezier points as:
      // pts[0],pts[1] = first anchor (x,y)
      // then groups of 3: cp1, cp2, anchor
      // Total: 1 + (npts-1)/3 anchors, with cubic segments between them.

      // First anchor point.
      float x0 = npath->pts[0];
      float y0 = npath->pts[1];
      [path insertAtIndex:path.count position:(simd_float2){x0, y0}];

      for (int i = 1; i < npath->npts - 2; i += 3) {
        float cp1x = npath->pts[i * 2 + 0];
        float cp1y = npath->pts[i * 2 + 1];
        float cp2x = npath->pts[(i + 1) * 2 + 0];
        float cp2y = npath->pts[(i + 1) * 2 + 1];
        float ax = npath->pts[(i + 2) * 2 + 0];
        float ay = npath->pts[(i + 2) * 2 + 1];

        // Set out-handle on previous point (relative to that point).
        NSUInteger prevIdx = path.count - 1;
        KKBezierPoint prev = [path pointAtIndex:prevIdx];
        [path setOutHandle:(simd_float2){cp1x - prev.x, cp1y - prev.y}
                   atIndex:prevIdx];
        [path setType:KKBezierPointBezier atIndex:prevIdx];

        // Insert new anchor with in-handle.
        [path insertAtIndex:path.count position:(simd_float2){ax, ay}];
        NSUInteger newIdx = path.count - 1;
        [path setInHandle:(simd_float2){cp2x - ax, cp2y - ay} atIndex:newIdx];
        [path setType:KKBezierPointBezier atIndex:newIdx];
      }

      if (npath->closed)
        path.closed = YES;
    }

    if (path.count >= 2)
      [results addObject:path];
  }

  float svgW = image->width;
  float svgH = image->height;
  nsvgDelete(image);

  if (results.count == 0 || svgW < 0.001f || svgH < 0.001f)
    return results;

  // Fit SVG into canvas pixel space with uniform scale (aspect-correct),
  // then convert to 0-1 object space by dividing by canvas dimensions.
  float pixScale = fminf(canvasWidth / svgW, canvasHeight / svgH);
  float fitW = svgW * pixScale;
  float fitH = svgH * pixScale;
  float pixOffX = (canvasWidth - fitW) * 0.5f;
  float pixOffY = (canvasHeight - fitH) * 0.5f;

  float scaleX = pixScale / canvasWidth;
  float scaleY = pixScale / canvasHeight;
  float offX = pixOffX / canvasWidth;
  float offY = pixOffY / canvasHeight;

  for (KKBezierPath *p in results) {
    for (NSUInteger i = 0; i < p.count; i++) {
      KKBezierPoint pt = [p pointAtIndex:i];
      float nx = pt.x * scaleX + offX;
      // Map nanosvg's coords straight through. An explicit `1 - y` flip here
      // came out vertically mirrored (upside down) in the consuming render, so
      // the SVG-native Y is what the render expects - don't flip.
      float ny = pt.y * scaleY + offY;
      [p moveAtIndex:i to:(simd_float2){nx, ny}];

      if (pt.type == KKBezierPointBezier) {
        [p setInHandle:(simd_float2){pt.inX * scaleX, pt.inY * scaleY}
               atIndex:i];
        [p setOutHandle:(simd_float2){pt.outX * scaleX, pt.outY * scaleY}
                atIndex:i];
      }
    }

    // Stroke width is authored in the same canonical pixel space as the rest of
    // the plugin (the canvasWidth/Height reference the caller passes), so scale
    // the SVG-unit width by the SVG->canvas-pixel fit factor (pixScale) - NOT by
    // pixScale/canvasDim, which is the 0..1 point scale and made strokes ~1000x
    // too thin (the reason a placeholder width used to overwrite this).
    if (p.strokeEnabled && p.strokeWidth > 0)
      p.strokeWidth = p.strokeWidth * pixScale;
  }

  return results;
}

@end
