/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasCenterline.h"
#import "CanvasLocalized.h" // CLoc
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKShape.h> // KKRectShape min/max
#import <simd/simd.h>

#import "CanvasCenterlineInternal.h"

// Skeleton raster height (px). The width is derived from the canvas aspect so
// raster pixels are square in output space - a diagonal ribbon then thins to an
// equal-thickness centerline. 512 trades detail against thinning cost.
static const int kCenterlineRasterHeight = 512;

// Flatten a KKBezierPath (all contours, beziers sampled by CG) into a CGPath in
// object space (0-1, Y-up). Mirrors KKPathBoolean's private flattener.
static CGPathRef CenterlineCGPathFromPath(KKBezierPath *path) {
  CGMutablePathRef cg = CGPathCreateMutable();
  NSUInteger contours = path.contourCount;
  for (NSUInteger c = 0; c < contours; c++) {
    NSRange range = [path contourRangeAtIndex:c];
    if (range.length == 0)
      continue;
    KKBezierPoint first = [path pointAtIndex:range.location];
    CGPathMoveToPoint(cg, NULL, first.x, first.y);
    for (NSUInteger i = 1; i < range.length; i++) {
      NSUInteger idx = range.location + i;
      KKBezierPoint pt = [path pointAtIndex:idx];
      KKBezierPoint prev = [path pointAtIndex:idx - 1];
      if (prev.type == KKBezierPointBezier || pt.type == KKBezierPointBezier)
        CGPathAddCurveToPoint(cg, NULL, prev.x + prev.outX, prev.y + prev.outY,
                              pt.x + pt.inX, pt.y + pt.inY, pt.x, pt.y);
      else
        CGPathAddLineToPoint(cg, NULL, pt.x, pt.y);
    }
    if (range.length > 1) {
      KKBezierPoint last =
          [path pointAtIndex:range.location + range.length - 1];
      if (last.type == KKBezierPointBezier || first.type == KKBezierPointBezier)
        CGPathAddCurveToPoint(cg, NULL, last.x + last.outX, last.y + last.outY,
                              first.x + first.inX, first.y + first.inY, first.x,
                              first.y);
    }
    CGPathCloseSubpath(cg);
  }
  return cg;
}

// Rasterize the fill into a 1px-padded binary grid (0/1). contentW/H are the
// unpadded raster dims; the returned grid is (contentW+2)x(contentH+2) with a
// zero border so Zhang-Suen never reads out of bounds. *outFilled gets the
// inside-pixel count (for the stroke-width estimate). Caller frees the grid.
uint8_t *CenterlineRasterize(KKBezierPath *path, CGFloat aspect,
                             int *outContentW, int *outContentH, int *outGridW,
                             int *outGridH, long *outFilled) {
  int contentH = kCenterlineRasterHeight;
  int contentW = (int)lround((double)contentH * (aspect > 0.01 ? aspect : 1.0));
  if (contentW < 8)
    contentW = 8;
  size_t bytesPerRow = (size_t)contentW;
  uint8_t *gray = calloc((size_t)contentW * contentH, 1);
  if (!gray)
    return NULL;
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
  CGContextRef ctx =
      CGBitmapContextCreate(gray, contentW, contentH, 8, bytesPerRow, cs,
                            (CGBitmapInfo)kCGImageAlphaNone);
  CGColorSpaceRelease(cs);
  if (!ctx) {
    free(gray);
    return NULL;
  }
  // Object space (0-1, Y-up) maps directly onto the bottom-left-origin bitmap.
  CGContextScaleCTM(ctx, contentW, contentH);
  CGContextSetGrayFillColor(ctx, 1.0, 1.0);
  CGPathRef cg = CenterlineCGPathFromPath(path);
  CGContextAddPath(ctx, cg);
  CGPathRelease(cg);
  CGContextEOFillPath(ctx); // even-odd: compound contours read as holes
  CGContextRelease(ctx);

  int W = contentW + 2, H = contentH + 2;
  uint8_t *grid = calloc((size_t)W * H, 1);
  long filled = 0;
  if (grid) {
    for (int y = 0; y < contentH; y++)
      for (int x = 0; x < contentW; x++)
        if (gray[(size_t)y * bytesPerRow + x] > 127) {
          grid[(y + 1) * W + (x + 1)] = 1;
          filled++;
        }
  }
  free(gray);
  *outContentW = contentW;
  *outContentH = contentH;
  *outGridW = W;
  *outGridH = H;
  *outFilled = filled;
  return grid;
}

static CGImageRef CenterlineLoadCGImage(NSString *path) {
  NSURL *url = [NSURL fileURLWithPath:path];
  CGImageSourceRef s = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
  if (!s)
    return NULL;
  CGImageRef img = CGImageSourceCreateImageAtIndex(s, 0, NULL);
  CFRelease(s);
  return img; // caller releases
}

// Build the binary mask for an IMAGE layer: draw the image into the content
// grid at its object-space rect (CG handles scaling/AA), then threshold.
// Foreground = the drawn shape: alpha when the image is mostly transparent
// (outline on clear background), otherwise dark luminance (dark line on an
// opaque background). Same 1px-padded grid + Y mapping as CenterlineRasterize,
// so the trace and CenterlinePixelToObject read it identically.
uint8_t *CenterlineBuildImageMask(KKBezierPath *src, CGFloat aspect,
                                  int *outContentW, int *outContentH,
                                  int *outGridW, int *outGridH,
                                  long *outFilled) {
  KKRectShape *rect = src.rectShape;
  if (!src.imagePath.length || !rect)
    return NULL;
  CGImageRef img = CenterlineLoadCGImage(src.imagePath);
  if (!img)
    return NULL;

  int contentH = kCenterlineRasterHeight;
  int contentW = (int)lround((double)contentH * (aspect > 0.01 ? aspect : 1.0));
  if (contentW < 8)
    contentW = 8;
  uint8_t *rgba = calloc((size_t)contentW * contentH, 4);
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(
      rgba, contentW, contentH, 8, (size_t)contentW * 4, cs,
      (CGBitmapInfo)((uint32_t)kCGImageAlphaPremultipliedLast |
                     (uint32_t)kCGBitmapByteOrder32Big));
  CGColorSpaceRelease(cs);
  if (!ctx) {
    free(rgba);
    CGImageRelease(img);
    return NULL;
  }
  // Object 0-1 space (Y-up) onto the bottom-left-origin context; the memory
  // rows come out top-down (row 0 = object y max), matching
  // CenterlinePixelToObject.
  CGContextScaleCTM(ctx, contentW, contentH);
  simd_float2 mn = rect.min, mx = rect.max;
  // CGContextDrawImage draws bottom-up vs the top-row-first CGImage data, so
  // flip vertically about the rect to keep the trace right-side up.
  CGContextSaveGState(ctx);
  CGContextTranslateCTM(ctx, 0, mn.y + mx.y);
  CGContextScaleCTM(ctx, 1, -1);
  CGContextDrawImage(ctx, CGRectMake(mn.x, mn.y, mx.x - mn.x, mx.y - mn.y),
                     img);
  CGContextRestoreGState(ctx);
  CGImageRelease(img);
  CGContextRelease(ctx);

  // Pick alpha- vs luminance-keying from the transparency inside the image
  // rect.
  int cc0 = (int)floor(mn.x * contentW), cc1 = (int)ceil(mx.x * contentW);
  int cr0 = (int)floor((1.0 - mx.y) * contentH);
  int cr1 = (int)ceil((1.0 - mn.y) * contentH);
  if (cc0 < 0)
    cc0 = 0;
  if (cc1 > contentW)
    cc1 = contentW;
  if (cr0 < 0)
    cr0 = 0;
  if (cr1 > contentH)
    cr1 = contentH;
  long total = 0, transp = 0;
  for (int r = cr0; r < cr1; r++)
    for (int c = cc0; c < cc1; c++) {
      total++;
      if (rgba[(r * contentW + c) * 4 + 3] < 128)
        transp++;
    }
  BOOL alphaMode = total > 0 && (double)transp / (double)total > 0.15;

  int W = contentW + 2, H = contentH + 2;
  uint8_t *grid = calloc((size_t)W * H, 1);
  long filled = 0;
  if (grid)
    for (int r = 0; r < contentH; r++)
      for (int c = 0; c < contentW; c++) {
        uint8_t *px = &rgba[(r * contentW + c) * 4];
        BOOL fg;
        if (alphaMode)
          fg = px[3] >= 128;
        else {
          int lum = (px[0] * 30 + px[1] * 59 + px[2] * 11) / 100;
          fg = px[3] >= 128 && lum < 128; // dark line on opaque background
        }
        if (fg) {
          grid[(r + 1) * W + (c + 1)] = 1;
          filled++;
        }
      }
  free(rgba);
  *outContentW = contentW;
  *outContentH = contentH;
  *outGridW = W;
  *outGridH = H;
  *outFilled = filled;
  return grid;
}
