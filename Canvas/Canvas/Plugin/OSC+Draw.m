/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation CanvasOSC (Draw)

- (void)drawPathSegments:(KKBezierPath *)path
                   color:(simd_float4)color
        destinationImage:(FxImageTile *)dest {
  NSUInteger segCount = path.count - 1;
  if (path.closed && path.count >= 2)
    segCount = path.count;

  CGPoint prev = CGPointZero;
  BOOL hasPrev = NO;
  for (NSUInteger i = 0; i < segCount; i++) {
    NSUInteger nextIdx = (i + 1) % path.count;
    // Skip first point of segment if we already have it from previous segment
    NSUInteger startS = (hasPrev && i > 0) ? 1 : 0;
    for (NSUInteger s = startS; s <= 32; s++) {
      float t = (float)s / 32.0f;
      simd_float2 pos = [path evaluatePointAtIndex:i nextIndex:nextIdx atT:t];
      CGPoint cur = [self canvasPointFromObjectPoint:pos];
      if (hasPrev) {
        [self drawLineFrom:prev
                          to:cur
                       color:color
                   halfWidth:1.5f
            destinationImage:dest];
      }
      prev = cur;
      hasPrev = YES;
    }
  }
  // Close: connect last point back to first
  if (path.closed && hasPrev) {
    simd_float2 firstPos = [path evaluatePointAtIndex:0 nextIndex:1 atT:0.0f];
    CGPoint first = [self canvasPointFromObjectPoint:firstPos];
    [self drawLineFrom:prev
                      to:first
                   color:color
               halfWidth:1.5f
        destinationImage:dest];
  }
}

- (BOOL)isPointVisuallySelected:(NSUInteger)pathIndex
                          point:(NSUInteger)i
                    canvasPoint:(CGPoint)ptCanvas {
  BOOL selected = [self isPointSelected:pathIndex point:i];
  if (self.dragIsMarquee) {
    CGFloat minX = MIN(self.marqueeStart.x, self.marqueeEnd.x);
    CGFloat maxX = MAX(self.marqueeStart.x, self.marqueeEnd.x);
    CGFloat minY = MIN(self.marqueeStart.y, self.marqueeEnd.y);
    CGFloat maxY = MAX(self.marqueeStart.y, self.marqueeEnd.y);
    BOOL inside = (ptCanvas.x >= minX && ptCanvas.x <= maxX &&
                   ptCanvas.y >= minY && ptCanvas.y <= maxY);
    CGEventFlags mf =
        CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
    BOOL optHeld = (mf & kCGEventFlagMaskAlternate) != 0;
    if (inside)
      selected = !optHeld;
  }
  return selected;
}

- (void)drawPathControls:(KKBezierPath *)path
               pathIndex:(NSUInteger)pathIndex
              activePart:(NSInteger)activePart
                   color:(simd_float4)color
        destinationImage:(FxImageTile *)dest
                  atTime:(CMTime)time {
  simd_float4 handleColor = color;
  handleColor.w = 0.33f;

  for (NSUInteger i = 0; i < path.count; i++) {
    KKBezierPoint pt = [path pointAtIndex:i];
    CGPoint ptCanvas = [self canvasPointForBezierPoint:pt];

    if (pt.type == KKBezierPointBezier) {
      CGPoint inCanvas = [self canvasPointForBezierPoint:pt inHandleOffset:YES];
      CGPoint outCanvas = [self canvasPointForBezierPoint:pt inHandleOffset:NO];

      [self drawLineFrom:ptCanvas
                        to:inCanvas
                     color:handleColor
                 halfWidth:2.0f
          destinationImage:dest];
      [self drawLineFrom:ptCanvas
                        to:outCanvas
                     color:handleColor
                 halfWidth:2.0f
          destinationImage:dest];

      BOOL inActive = (self.dragIndex == (NSInteger)i && self.dragIsInHandle);
      BOOL outActive = (self.dragIndex == (NSInteger)i && self.dragIsOutHandle);

      [self.pathHandleOSC drawAtCanvasPosition:inCanvas
                                     isHovered:NO
                                      isActive:inActive
                              destinationImage:dest
                                        atTime:time];
      [self.pathHandleOSC drawAtCanvasPosition:outCanvas
                                     isHovered:NO
                                      isActive:outActive
                              destinationImage:dest
                                        atTime:time];
    }

    BOOL isSelected = [self isPointVisuallySelected:pathIndex
                                              point:i
                                        canvasPoint:ptCanvas];
    BOOL ptActive =
        isSelected || (self.dragIndex == (NSInteger)i && !self.dragIsInHandle &&
                       !self.dragIsOutHandle);
    BOOL ptHovered = (activePart == kOSCPathPointBase + (NSInteger)i);
    self.pathPointOSC.fillColorOverride =
        isSelected ? [NSColor systemBlueColor] : nil;
    [self.pathPointOSC drawAtCanvasPosition:ptCanvas
                                  isHovered:ptHovered
                                   isActive:ptActive
                           destinationImage:dest
                                     atTime:time];
  }
}

- (void)drawDashedRectFrom:(CGPoint)a
                        to:(CGPoint)b
          destinationImage:(FxImageTile *)dest {
  simd_float4 lightColor = {1.0f, 1.0f, 1.0f, 0.9f};
  simd_float4 darkColor = {0.0f, 0.0f, 0.0f, 0.6f};
  CGFloat hw = 1.5f, dash = 8.0f, gap = 5.0f;

  CGFloat x0 = floor(MIN(a.x, b.x)) + 0.5f;
  CGFloat x1 = floor(MAX(a.x, b.x)) + 0.5f;
  CGFloat y0 = floor(MIN(a.y, b.y)) + 0.5f;
  CGFloat y1 = floor(MAX(a.y, b.y)) + 0.5f;
  CGPoint tl = {x0, y0}, tr = {x1, y0}, br = {x1, y1}, bl = {x0, y1};
  CGPoint edges[4][2] = {{tl, tr}, {tr, br}, {br, bl}, {bl, tl}};

  for (int e = 0; e < 4; e++) {
    CGPoint from = edges[e][0], to = edges[e][1];
    CGFloat dx = to.x - from.x, dy = to.y - from.y;
    CGFloat len = hypot(dx, dy);
    if (len < 0.1)
      continue;
    CGFloat nx = dx / len, ny = dy / len;
    CGFloat pos = 0;
    BOOL on = YES;
    while (pos < len) {
      CGFloat seg = on ? dash : gap;
      CGFloat end = MIN(pos + seg, len);
      CGPoint dFrom = {from.x + nx * pos, from.y + ny * pos};
      CGPoint dTo = {from.x + nx * end, from.y + ny * end};
      [self drawLineFrom:dFrom
                        to:dTo
                     color:on ? lightColor : darkColor
                 halfWidth:hw
          destinationImage:dest];
      pos = end;
      on = !on;
    }
  }
}

- (void)drawOSCWithWidth:(NSInteger)width
                  height:(NSInteger)height
              activePart:(NSInteger)activePart
        destinationImage:(FxImageTile *)destinationImage
                  atTime:(CMTime)time {
  [self encodeRenderCommandsForDestinationImage:destinationImage
                                 canvasPosition:CGPointZero
                               clearDestination:YES
                                       commands:^(id<MTLRenderCommandEncoder> e,
                                                  CGPoint p, simd_uint2 v){
                                       }];

  [self.toolbar drawWithDestinationImage:destinationImage];

  self.paths = [self readPaths];

  simd_float4 strokeColor = [[NSColor systemRedColor] simdFloat4];
  simd_float4 dimColor = strokeColor;
  dimColor.w = 0.3f;

  BOOL showAllControls = self.selectedPoints.count > 0 || self.dragIsMarquee;

  for (NSUInteger p = 0; p < self.paths.count; p++) {
    KKBezierPath *path = self.paths[p];
    if (path.count == 0)
      continue;

    BOOL isActive = ((NSInteger)p == self.activePathIndex);
    BOOL visible = isActive || showAllControls;
    [self drawPathSegments:path
                     color:visible ? strokeColor : dimColor
          destinationImage:destinationImage];

    if (visible) {
      [self drawPathControls:path
                   pathIndex:p
                  activePart:activePart
                       color:strokeColor
            destinationImage:destinationImage
                      atTime:time];
    }

    // Corner radius handles on active closed paths
    if (isActive && path.closed && path.count >= 4) {
      NSInteger crParts[4] = {kOSCCornerRadiusTL, kOSCCornerRadiusTR,
                              kOSCCornerRadiusBR, kOSCCornerRadiusBL};
      for (int ci = 0; ci < 4; ci++) {
        CGPoint handlePos = [self cornerRadiusHandlePosition:ci forPath:path];
        BOOL crActive = (activePart == crParts[ci]);
        self.pathPointOSC.fillColorOverride = [NSColor warning];
        [self.pathPointOSC drawAtCanvasPosition:handlePos
                                      isHovered:NO
                                       isActive:crActive
                               destinationImage:destinationImage
                                         atTime:time];
      }
    }
  }

  if (self.dragIsMarquee) {
    [self drawDashedRectFrom:self.marqueeStart
                          to:self.marqueeEnd
            destinationImage:destinationImage];
  }

  // Rectangle tool preview
  if (self.dragIsRect) {
    simd_float2 a = self.rectStart, b = self.dragOrigin;
    CGPoint ca = [self canvasPointFromObjectPoint:a];
    CGPoint cb = [self canvasPointFromObjectPoint:b];
    NSInteger ix0 = (NSInteger)round(MIN(ca.x, cb.x));
    NSInteger ix1 = (NSInteger)round(MAX(ca.x, cb.x));
    NSInteger iy0 = (NSInteger)round(MIN(ca.y, cb.y));
    NSInteger iy1 = (NSInteger)round(MAX(ca.y, cb.y));
    CGFloat x0 = ix0 + 0.5f, x1 = ix1 + 0.5f;
    CGFloat y0 = iy0 + 0.5f, y1 = iy1 + 0.5f;
    if (ix1 - ix0 > 0 && iy1 - iy0 > 0) {
      CGPoint tl = {x0, y0}, tr = {x1, y0}, br = {x1, y1}, bl = {x0, y1};
      [self drawLineFrom:tl
                        to:tr
                     color:strokeColor
                 halfWidth:1.0f
          destinationImage:destinationImage];
      [self drawLineFrom:tr
                        to:br
                     color:strokeColor
                 halfWidth:1.0f
          destinationImage:destinationImage];
      [self drawLineFrom:br
                        to:bl
                     color:strokeColor
                 halfWidth:1.0f
          destinationImage:destinationImage];
      [self drawLineFrom:bl
                        to:tl
                     color:strokeColor
                 halfWidth:1.0f
          destinationImage:destinationImage];

      // Size label below bottom-right (canvas Y=0 is bottom)
      NSInteger pxW = ix1 - ix0;
      NSInteger pxH = iy1 - iy0;
      self.sizeLabel.text =
          [NSString stringWithFormat:@"%ld × %ld", (long)pxW, (long)pxH];
      CGSize labelSize = self.sizeLabel.size;
      CGPoint labelPos = {x1 - labelSize.width * 0.5f,
                          y0 - labelSize.height * 0.5f - 6.0f};
      [self.sizeLabel drawAtCanvasPosition:labelPos
                          destinationImage:destinationImage];
    }
  }
}

@end
#pragma clang diagnostic pop
