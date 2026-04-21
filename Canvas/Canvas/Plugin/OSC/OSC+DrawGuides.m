/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC_Private.h"

@implementation CanvasOSC (DrawGuides)

- (void)drawGridWithDestinationImage:(FxImageTile *)destinationImage {
  if (!self.gridEnabled || self.imageWidth <= 0 || self.imageHeight <= 0)
    return;

  CGFloat spacing = (CGFloat)self.gridSpacing;

  if (self.gridAdaptive) {
    CGPoint originCanvas =
        [self canvasPointFromObjectPoint:(simd_float2){0, 0}];
    CGPoint unitCanvas = [self
        canvasPointFromObjectPoint:(simd_float2){1.0f / self.imageWidth, 0}];
    CGFloat pxPerSourcePx = fabs(unitCanvas.x - originCanvas.x);
    CGFloat screenSpacing = spacing * pxPerSourcePx;
    static const CGFloat kMinScreenSpacing = 30.0;
    while (screenSpacing < kMinScreenSpacing && spacing < 10000) {
      spacing *= 2.0;
      screenSpacing *= 2.0;
    }
  }

  float objSpacingX = (float)(spacing / self.imageWidth);
  float objSpacingY = (float)(spacing / self.imageHeight);
  simd_float4 gridColor = {1.0f, 1.0f, 1.0f, 0.15f};

  CGPoint canvasTL = [self canvasPointFromObjectPoint:(simd_float2){0, 0}];
  CGPoint canvasBR = [self canvasPointFromObjectPoint:(simd_float2){1, 1}];
  CGFloat canvasLeft = fmin(canvasTL.x, canvasBR.x);
  CGFloat canvasRight = fmax(canvasTL.x, canvasBR.x);
  CGFloat canvasTop = fmin(canvasTL.y, canvasBR.y);
  CGFloat canvasBottom = fmax(canvasTL.y, canvasBR.y);

  // Visible object-space range from viewport corners (with margin).
  float ioW = [destinationImage.ioSurface width];
  float ioH = [destinationImage.ioSurface height];
  simd_float2 vpTL = [self objectPointFromCanvasPoint:CGPointMake(0, 0)];
  simd_float2 vpBR = [self objectPointFromCanvasPoint:CGPointMake(ioW, ioH)];
  float visMinX = fmaxf(0.0f, fminf(vpTL.x, vpBR.x) - objSpacingX);
  float visMaxX = fminf(1.0f, fmaxf(vpTL.x, vpBR.x) + objSpacingX);
  float visMinY = fmaxf(0.0f, fminf(vpTL.y, vpBR.y) - objSpacingY);
  float visMaxY = fminf(1.0f, fmaxf(vpTL.y, vpBR.y) + objSpacingY);

  // Vertical lines (constant X).
  {
    NSInteger iStart = (NSInteger)ceilf(visMinX / objSpacingX);
    NSInteger iEnd = (NSInteger)floorf(visMaxX / objSpacingX);
    for (NSInteger i = iStart; i <= iEnd; i++) {
      float ox = i * objSpacingX;
      CGFloat rawX = [self canvasPointFromObjectPoint:(simd_float2){ox, 0}].x;
      CGFloat cx = floor(rawX) + 0.5;
      [self drawLineFrom:(CGPoint){cx, canvasTop}
                        to:(CGPoint){cx, canvasBottom}
                     color:gridColor
                 halfWidth:1.0f
          destinationImage:destinationImage];
    }
  }

  // Horizontal lines (constant Y).
  {
    NSInteger iStart = (NSInteger)ceilf(visMinY / objSpacingY);
    NSInteger iEnd = (NSInteger)floorf(visMaxY / objSpacingY);
    for (NSInteger i = iStart; i <= iEnd; i++) {
      float oy = i * objSpacingY;
      CGFloat rawY = [self canvasPointFromObjectPoint:(simd_float2){0, oy}].y;
      CGFloat cy = floor(rawY) + 0.5;
      [self drawLineFrom:(CGPoint){canvasLeft, cy}
                        to:(CGPoint){canvasRight, cy}
                     color:gridColor
                 halfWidth:1.0f
          destinationImage:destinationImage];
    }
  }
}

- (void)drawGridSnapIndicatorForCursorMode:(BOOL)isCursorMode
                          destinationImage:(FxImageTile *)destinationImage {
  if (!self.gridEnabled || self.imageWidth <= 0 || self.imageHeight <= 0)
    return;
  BOOL isDrawingTool = !isCursorMode;
  BOOL isDragging = self.dragIsRect || self.dragIsEllipse || self.dragIsLine ||
                    self.dragIsNewPoint || self.dragIsPath ||
                    self.dragIsInHandle || self.dragIsOutHandle ||
                    self.dragIsSelection || self.dragIsMarquee ||
                    self.dragIsRotation || self.dragResizeHandle >= 0;
  if (!isDrawingTool || !self.snapToGrid || isDragging)
    return;

  simd_float2 hoverObj =
      [self objectPointFromCanvasPoint:self.hoverCanvasPosition];
  simd_float2 snapped = [self snapToGridPosition:hoverObj];
  if (snapped.x < 0.0f || snapped.x > 1.0f || snapped.y < 0.0f ||
      snapped.y > 1.0f)
    return;

  CGPoint raw = [self canvasPointFromObjectPoint:snapped];
  CGPoint c = {floor(raw.x) + 0.5, floor(raw.y) + 0.5};
  CGFloat sr = 6.0;
  simd_float4 indicatorColor = {0.5f, 0.5f, 0.5f, 1.0f};
  NSUInteger segs = 32;
  CGPoint ring[segs + 1];
  for (NSUInteger i = 0; i <= segs; i++) {
    float t = (float)i / (float)segs * 2.0f * M_PI;
    ring[i] = (CGPoint){c.x + sr * cosf(t), c.y + sr * sinf(t)};
  }
  [self drawLineStripWithPoints:ring
                          count:segs + 1
                          color:indicatorColor
                      halfWidth:1.5f
               destinationImage:destinationImage];
}

- (void)drawAlignmentGuidesWithDestinationImage:
    (FxImageTile *)destinationImage {
  if (!self.alignSnappedX && !self.alignSnappedY)
    return;

  CGPoint canvasTL = [self canvasPointFromObjectPoint:(simd_float2){0, 0}];
  CGPoint canvasBR = [self canvasPointFromObjectPoint:(simd_float2){1, 1}];
  CGFloat guideLeft = fmin(canvasTL.x, canvasBR.x);
  CGFloat guideRight = fmax(canvasTL.x, canvasBR.x);
  CGFloat guideTop = fmin(canvasTL.y, canvasBR.y);
  CGFloat guideBottom = fmax(canvasTL.y, canvasBR.y);
  simd_float4 guideColor = {1.0f, 1.0f, 0.0f, 1.0f};

  if (self.alignSnappedX) {
    CGPoint c = [self
        canvasPointFromObjectPoint:(simd_float2){self.alignSnapValueX, 0}];
    CGFloat cx = floor(c.x) + 0.5;
    [self drawLineFrom:(CGPoint){cx, guideTop}
                      to:(CGPoint){cx, guideBottom}
                   color:guideColor
               halfWidth:2.0f
        destinationImage:destinationImage];
  }
  if (self.alignSnappedY) {
    CGPoint c = [self
        canvasPointFromObjectPoint:(simd_float2){0, self.alignSnapValueY}];
    CGFloat cy = floor(c.y) + 0.5;
    [self drawLineFrom:(CGPoint){guideLeft, cy}
                      to:(CGPoint){guideRight, cy}
                   color:guideColor
               halfWidth:2.0f
        destinationImage:destinationImage];
  }
}

- (void)drawSpacingGuidesWithDestinationImage:(FxImageTile *)destinationImage {
  if (!self.spacingSnapX && !self.spacingSnapY)
    return;

  simd_float4 spColor = {1.0f, 1.0f, 0.0f, 1.0f};
  float capLen = 6.0f;

  void (^drawHGap)(float, float, float) = ^(float objLeft, float objRight,
                                            float objY) {
    CGPoint cA = [self canvasPointFromObjectPoint:(simd_float2){objLeft, objY}];
    CGPoint cB =
        [self canvasPointFromObjectPoint:(simd_float2){objRight, objY}];
    float x0 = floorf((float)cA.x) + 0.5f;
    float x1 = floorf((float)cB.x) + 0.5f;
    float y = floorf((float)cA.y) + 0.5f;
    if (x1 - x0 < 2.0f)
      return;
    [self drawLineFrom:(CGPoint){x0, y}
                      to:(CGPoint){x1, y}
                   color:spColor
               halfWidth:1.0f
        destinationImage:destinationImage];
    [self drawLineFrom:(CGPoint){x0, y - capLen}
                      to:(CGPoint){x0, y + capLen}
                   color:spColor
               halfWidth:1.0f
        destinationImage:destinationImage];
    [self drawLineFrom:(CGPoint){x1, y - capLen}
                      to:(CGPoint){x1, y + capLen}
                   color:spColor
               halfWidth:1.0f
        destinationImage:destinationImage];
  };

  void (^drawVGap)(float, float, float) = ^(float objTop, float objBottom,
                                            float objX) {
    CGPoint cA = [self canvasPointFromObjectPoint:(simd_float2){objX, objTop}];
    CGPoint cB =
        [self canvasPointFromObjectPoint:(simd_float2){objX, objBottom}];
    float x = floorf((float)cA.x) + 0.5f;
    float y0 = floorf((float)fmin(cA.y, cB.y)) + 0.5f;
    float y1 = floorf((float)fmax(cA.y, cB.y)) + 0.5f;
    if (y1 - y0 < 2.0f)
      return;
    [self drawLineFrom:(CGPoint){x, y0}
                      to:(CGPoint){x, y1}
                   color:spColor
               halfWidth:1.0f
        destinationImage:destinationImage];
    [self drawLineFrom:(CGPoint){x - capLen, y0}
                      to:(CGPoint){x + capLen, y0}
                   color:spColor
               halfWidth:1.0f
        destinationImage:destinationImage];
    [self drawLineFrom:(CGPoint){x - capLen, y1}
                      to:(CGPoint){x + capLen, y1}
                   color:spColor
               halfWidth:1.0f
        destinationImage:destinationImage];
  };

  if (self.spacingSnapX) {
    drawHGap(self.spacingLeftEdge, self.spacingSelLeft, self.spacingMidY);
    drawHGap(self.spacingSelRight, self.spacingRightEdge, self.spacingMidY);
    if (self.spacingRefX)
      drawHGap(self.spacingRefLeftX, self.spacingRefRightX,
               self.spacingRefMidYX);
  }
  if (self.spacingSnapY) {
    drawVGap(self.spacingTopEdge, self.spacingSelTop, self.spacingMidX);
    drawVGap(self.spacingSelBottom, self.spacingBottomEdge, self.spacingMidX);
    if (self.spacingRefY)
      drawVGap(self.spacingRefTopY, self.spacingRefBottomY,
               self.spacingRefMidXY);
  }
}

@end
