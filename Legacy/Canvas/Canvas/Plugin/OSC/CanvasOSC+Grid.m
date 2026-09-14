/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasOSC_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>

// Below this on-screen cell size (points), adaptive mode doubles the spacing so
// a zoomed-out grid stays legible instead of turning into a grey wash.
static const CGFloat kCanvasGridMinScreenSpacing = 30.0;

// The OSC draws onto a transparent overlay and can't read the video underneath,
// so a "halo" line (a light core over a slightly wider dark edge) stands in for
// true content-aware contrast: the dark edge carries it over light footage, the
// light core over dark footage. Content-independent, works on any GPU.
//
// Colours are FULLY OPAQUE solids: where two lines cross, opaque-over-opaque
// yields the same colour (no accumulation), so intersections match the lines
// instead of doubling up. (Translucent lines would stack at the crossings.)
static const simd_float4 kCanvasGridHalo = {0.15f, 0.15f, 0.15f, 1.0f};
static const simd_float4 kCanvasGridCore = {0.22f, 0.22f, 0.22f, 1.0f};
static const float kCanvasGridHaloHalfW = 1.4f; // wider: dark edge peeks out
static const float kCanvasGridCoreHalfW = 0.9f; // the visible core

@implementation CanvasOSC (Grid)

// The on-screen (post-Auto) grid spacing in OBJECT units for the given render
// dims, matching exactly what's drawn. Spacing starts in OUTPUT pixels (so the
// grid is fixed to the canvas and scales with zoom); Auto doubles it while the
// cells would be too small on screen. Returns NO if it can't be computed.
- (BOOL)_gridObjSpacingForWidth:(double)width
                         height:(double)height
                          outX:(double *)outX
                          outY:(double *)outY {
  if (width <= 0 || height <= 0)
    return NO;
  double spacing = (double)[self _gridSpacing];
  if ([self _gridAdaptive]) {
    CGPoint origin = [self _rawCanvasFromObjX:0 y:0];
    CGPoint unit = [self _rawCanvasFromObjX:(1.0 / width) y:0];
    double pxPerOutputPx = fabs(unit.x - origin.x);
    double screenSpacing = spacing * pxPerOutputPx;
    while (screenSpacing < kCanvasGridMinScreenSpacing && spacing < 10000.0) {
      spacing *= 2.0;
      screenSpacing *= 2.0;
    }
  }
  double sx = spacing / width, sy = spacing / height;
  if (sx <= 0 || sy <= 0)
    return NO;
  *outX = sx;
  *outY = sy;
  return YES;
}

// Pin a CANVAS point to the nearest grid intersection (the generic snap hook the
// Position / Anchor controls call, and a future pen tool will too). No-op unless
// Snap is on. Round to the nearest cell in object space, then back to canvas, so
// it lands on the same lines the grid draws.
- (CGPoint)_snapCanvasPointToGrid:(CGPoint)cp {
  // No snap unless the grid is both shown AND snap is on (don't snap to an
  // invisible grid).
  if (![self _gridEnabled] || ![self _gridSnap])
    return cp;
  // Use the EXACT cell size the grid last drew, so the snap can't drift to a
  // half-cell vs the drawn lines.
  double sx = self.drawnGridObjSpacingX, sy = self.drawnGridObjSpacingY;
  if (sx <= 0 || sy <= 0)
    return cp;
  CGPoint o = [self _rawObjFromCanvasX:cp.x y:cp.y];
  double snX = round(o.x / sx) * sx;
  double snY = round(o.y / sy) * sy;
  return [self _rawCanvasFromObjX:snX y:snY];
}

// Spacing is in OUTPUT pixels (width/height = the render dims), so the grid is
// fixed to the canvas and scales on screen with zoom; Auto doubles it when the
// cells get too small.
- (void)_drawGridWithWidth:(NSInteger)width
                    height:(NSInteger)height
          destinationImage:(FxImageTile *)destinationImage {
  if (![self _gridEnabled] || width <= 0 || height <= 0)
    return;

  double objSpacingX = 0, objSpacingY = 0;
  if (![self _gridObjSpacingForWidth:(double)width
                              height:(double)height
                                outX:&objSpacingX
                                outY:&objSpacingY])
    return;
  // Cache for the snap so it pins to exactly these lines (no recompute drift).
  self.drawnGridObjSpacingX = objSpacingX;
  self.drawnGridObjSpacingY = objSpacingY;

  // Lines span the FULL preview (edge to edge), and the visible object range
  // comes from the viewport corners UNCLAMPED - so the grid continues past the
  // output/playback rect into the letterbox margins, covering the whole preview.
  float ioW = [destinationImage.ioSurface width];
  float ioH = [destinationImage.ioSurface height];
  CGFloat left = 0, right = ioW, top = 0, bottom = ioH;
  CGPoint vpTL = [self _rawObjFromCanvasX:0 y:0];
  CGPoint vpBR = [self _rawObjFromCanvasX:ioW y:ioH];
  double visMinX = fmin(vpTL.x, vpBR.x) - objSpacingX;
  double visMaxX = fmax(vpTL.x, vpBR.x) + objSpacingX;
  double visMinY = fmin(vpTL.y, vpBR.y) - objSpacingY;
  double visMaxY = fmax(vpTL.y, vpBR.y) + objSpacingY;

  // Build the pixel-snapped segment endpoints once; both halo passes draw them.
  NSMutableData *pts = [NSMutableData data];
  NSInteger iStart = (NSInteger)ceil(visMinX / objSpacingX);
  NSInteger iEnd = (NSInteger)floor(visMaxX / objSpacingX);
  NSInteger jStart = (NSInteger)ceil(visMinY / objSpacingY);
  NSInteger jEnd = (NSInteger)floor(visMaxY / objSpacingY);
  // Safety: at an extreme zoom-out the unclamped range could blow up the count
  // (it'd be a grey wash anyway) - bail rather than churn.
  if ((iEnd - iStart) > 4000 || (jEnd - jStart) > 4000)
    return;
  for (NSInteger i = iStart; i <= iEnd; i++) {
    CGFloat cx = floor([self _rawCanvasFromObjX:(i * objSpacingX) y:0].x) + 0.5;
    CGPoint a = CGPointMake(cx, top), b = CGPointMake(cx, bottom);
    [pts appendBytes:&a length:sizeof(CGPoint)];
    [pts appendBytes:&b length:sizeof(CGPoint)];
  }
  for (NSInteger j = jStart; j <= jEnd; j++) {
    CGFloat cy = floor([self _rawCanvasFromObjX:0 y:(j * objSpacingY)].y) + 0.5;
    CGPoint a = CGPointMake(left, cy), b = CGPointMake(right, cy);
    [pts appendBytes:&a length:sizeof(CGPoint)];
    [pts appendBytes:&b length:sizeof(CGPoint)];
  }

  NSUInteger count = pts.length / sizeof(CGPoint);
  if (count < 2)
    return;
  const CGPoint *p = (const CGPoint *)pts.bytes;
  // Dark edge first (wider), then the light core on top.
  [self drawLineSegmentsWithPoints:p
                             count:count
                             color:kCanvasGridHalo
                         halfWidth:kCanvasGridHaloHalfW
                  destinationImage:destinationImage];
  [self drawLineSegmentsWithPoints:p
                             count:count
                             color:kCanvasGridCore
                         halfWidth:kCanvasGridCoreHalfW
                  destinationImage:destinationImage];
}

@end
