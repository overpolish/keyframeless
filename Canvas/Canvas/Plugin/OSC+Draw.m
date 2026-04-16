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

  NSUInteger maxPoints = segCount * 32 + 2;
  CGPoint *points = malloc(sizeof(CGPoint) * maxPoints);
  NSUInteger pointCount = 0;

  for (NSUInteger i = 0; i < segCount; i++) {
    NSUInteger nextIdx = (i + 1) % path.count;
    NSUInteger startS = (pointCount > 0 && i > 0) ? 1 : 0;
    for (NSUInteger s = startS; s <= 32; s++) {
      float t = (float)s / 32.0f;
      simd_float2 pos = [path evaluatePointAtIndex:i nextIndex:nextIdx atT:t];
      points[pointCount++] = [self canvasPointFromObjectPoint:pos];
    }
  }
  if (path.closed && pointCount > 0) {
    simd_float2 firstPos = [path evaluatePointAtIndex:0 nextIndex:1 atT:0.0f];
    points[pointCount++] = [self canvasPointFromObjectPoint:firstPos];
  }

  [self drawLineStripWithPoints:points
                          count:pointCount
                          color:color
                      halfWidth:1.5f
               destinationImage:dest];
  free(points);
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

- (void)drawBoundingBoxWithMin:(simd_float2)bmin
                           max:(simd_float2)bmax
                    activePart:(NSInteger)activePart
              destinationImage:(FxImageTile *)dest
                        atTime:(CMTime)time {
  CGPoint bl = [self canvasPointFromObjectPoint:bmin];
  CGPoint tr = [self canvasPointFromObjectPoint:bmax];

  [self.borderOSC drawWithTopRight:tr bottomLeft:bl destinationImage:dest];

  for (NSInteger i = 0; i < 8; i++) {
    CGPoint pos = [self resizeHandlePosition:i topRight:tr bottomLeft:bl];
    BOOL hovered = (activePart == kOSCResizeHandleBase + i);
    BOOL active = (self.dragResizeHandle == i);
    [self.resizeHandleOSCs[i] drawAtCanvasPosition:pos
                                         isHovered:hovered
                                          isActive:active
                                  destinationImage:dest
                                            atTime:time];
  }

  NSInteger pxW = (NSInteger)round(fabs(tr.x - bl.x));
  NSInteger pxH = (NSInteger)round(fabs(tr.y - bl.y));
  self.sizeLabel.text =
      [NSString stringWithFormat:@"%ld × %ld", (long)pxW, (long)pxH];
  CGSize labelSize = self.sizeLabel.size;
  CGPoint labelPos = {MAX(tr.x, bl.x) - labelSize.width * 0.5f,
                      MIN(tr.y, bl.y) - labelSize.height * 0.5f - 6.0f};
  [self.sizeLabel drawAtCanvasPosition:labelPos destinationImage:dest];
}

- (void)drawCornerRadiusHandles:(KKBezierPath *)path
                     activePart:(NSInteger)activePart
               destinationImage:(FxImageTile *)dest
                         atTime:(CMTime)time {
  if (!path.isRect)
    return;
  NSInteger crParts[4] = {kOSCCornerRadiusTL, kOSCCornerRadiusTR,
                          kOSCCornerRadiusBR, kOSCCornerRadiusBL};
  for (int ci = 0; ci < 4; ci++) {
    CGPoint handlePos = [self cornerRadiusHandlePosition:ci forPath:path];
    BOOL crActive = (activePart == crParts[ci]);
    self.pathPointOSC.fillColorOverride = [NSColor warning];
    [self.pathPointOSC drawAtCanvasPosition:handlePos
                                  isHovered:NO
                                   isActive:crActive
                           destinationImage:dest
                                     atTime:time];
  }
}

- (void)drawRectPreview:(simd_float4)color
       destinationImage:(FxImageTile *)dest {
  simd_float2 a = self.rectStart, b = self.dragOrigin;
  CGPoint ca = [self canvasPointFromObjectPoint:a];
  CGPoint cb = [self canvasPointFromObjectPoint:b];
  NSInteger ix0 = (NSInteger)round(MIN(ca.x, cb.x));
  NSInteger ix1 = (NSInteger)round(MAX(ca.x, cb.x));
  NSInteger iy0 = (NSInteger)round(MIN(ca.y, cb.y));
  NSInteger iy1 = (NSInteger)round(MAX(ca.y, cb.y));
  CGFloat x0 = ix0 + 0.5f, x1 = ix1 + 0.5f;
  CGFloat y0 = iy0 + 0.5f, y1 = iy1 + 0.5f;
  if (ix1 - ix0 <= 0 || iy1 - iy0 <= 0)
    return;

  CGPoint points[5] = {{x0, y0}, {x1, y0}, {x1, y1}, {x0, y1}, {x0, y0}};
  [self drawLineStripWithPoints:points
                          count:5
                          color:color
                      halfWidth:1.5f
               destinationImage:dest];

  NSInteger pxW = ix1 - ix0, pxH = iy1 - iy0;
  self.sizeLabel.text =
      [NSString stringWithFormat:@"%ld × %ld", (long)pxW, (long)pxH];
  CGSize labelSize = self.sizeLabel.size;
  CGPoint labelPos = {x1 - labelSize.width * 0.5f,
                      y0 - labelSize.height * 0.5f - 6.0f};
  [self.sizeLabel drawAtCanvasPosition:labelPos destinationImage:dest];
}

- (void)drawEllipsePreview:(simd_float4)color
          destinationImage:(FxImageTile *)dest {
  simd_float2 a = self.rectStart, b = self.dragOrigin;
  CGPoint ca = [self canvasPointFromObjectPoint:a];
  CGPoint cb = [self canvasPointFromObjectPoint:b];
  CGFloat cx = (ca.x + cb.x) * 0.5f, cy = (ca.y + cb.y) * 0.5f;
  CGFloat rx = fabs(cb.x - ca.x) * 0.5f, ry = fabs(cb.y - ca.y) * 0.5f;
  if (rx < 1.0 || ry < 1.0)
    return;

  NSUInteger segments = 64;
  CGPoint points[segments + 1];
  for (NSUInteger i = 0; i <= segments; i++) {
    float t = (float)i / (float)segments * 2.0f * M_PI;
    points[i] = (CGPoint){cx + rx * cosf(t), cy + ry * sinf(t)};
  }
  [self drawLineStripWithPoints:points
                          count:segments + 1
                          color:color
                      halfWidth:1.5f
               destinationImage:dest];

  NSInteger pxW = (NSInteger)round(rx * 2.0), pxH = (NSInteger)round(ry * 2.0);
  self.sizeLabel.text =
      [NSString stringWithFormat:@"%ld × %ld", (long)pxW, (long)pxH];
  CGSize labelSize = self.sizeLabel.size;
  CGPoint labelPos = {MAX(ca.x, cb.x) - labelSize.width * 0.5f,
                      MIN(ca.y, cb.y) - labelSize.height * 0.5f - 6.0f};
  [self.sizeLabel drawAtCanvasPosition:labelPos destinationImage:dest];
}

- (void)drawDashedRectFrom:(CGPoint)a
                        to:(CGPoint)b
          destinationImage:(FxImageTile *)dest {
  simd_float4 lightColor = {1.0f, 1.0f, 1.0f, 0.9f};
  simd_float4 darkColor = {0.0f, 0.0f, 0.0f, 0.6f};
  CGFloat dash = 8.0f, gap = 5.0f;

  CGFloat x0 = floor(MIN(a.x, b.x)) + 0.5f;
  CGFloat x1 = floor(MAX(a.x, b.x)) + 0.5f;
  CGFloat y0 = floor(MIN(a.y, b.y)) + 0.5f;
  CGFloat y1 = floor(MAX(a.y, b.y)) + 0.5f;
  CGPoint tl = {x0, y0}, tr = {x1, y0}, br = {x1, y1}, bl = {x0, y1};
  CGPoint edges[4][2] = {{tl, tr}, {tr, br}, {br, bl}, {bl, tl}};

  CGFloat perimeter = 2.0 * (x1 - x0) + 2.0 * (y1 - y0);
  NSUInteger maxSegs = (NSUInteger)(perimeter / MIN(dash, gap)) + 8;
  CGPoint *lightPts = malloc(sizeof(CGPoint) * maxSegs * 2);
  CGPoint *darkPts = malloc(sizeof(CGPoint) * maxSegs * 2);
  NSUInteger lightCount = 0, darkCount = 0;

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
      if (on) {
        lightPts[lightCount++] = dFrom;
        lightPts[lightCount++] = dTo;
      } else {
        darkPts[darkCount++] = dFrom;
        darkPts[darkCount++] = dTo;
      }
      pos = end;
      on = !on;
    }
  }

  [self drawLineSegmentsWithPoints:lightPts
                             count:lightCount
                             color:lightColor
                         halfWidth:1.5f
                  destinationImage:dest];
  [self drawLineSegmentsWithPoints:darkPts
                             count:darkCount
                             color:darkColor
                         halfWidth:1.5f
                  destinationImage:dest];
  free(lightPts);
  free(darkPts);
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

  NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
  if (uuid) {
    NSIndexSet *uiSelection = KKCanvasConsumePendingSelection(uuid);
    if (uiSelection) {
      KKLog *log = [KKLog loggerForPlugin:@"co.overpolish.keyframeless"];
      [log info:@"drawOSC: consumed pending selection=%@", uiSelection];
      [self.selectedPathIndices removeAllIndexes];
      [self.selectedPathIndices addIndexes:uiSelection];
      if (uiSelection.count > 0)
        self.activePathIndex = (NSInteger)uiSelection.lastIndex;
      else
        self.activePathIndex = -1;
    }
    KKCanvasUpdateSelection(uuid, self.selectedPathIndices);
    KKCanvasRefreshLayerList(uuid, self.paths.count, self.paths);
  }

  // Patch the selected path's in-memory stroke from current params so that
  // hit testing and OSC drawing use the live inspector values.
  // Also keep param row visibility in sync — ensures the inspector shows
  // per-object controls even if the panel wasn't visible during selection.
  {
    KKBezierPath *selPath =
        KKSelectedPath(self.selectedPathIndices, self.paths);
    id<FxParameterSettingAPI_v5> paramSetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    if (selPath) {
      id<FxParameterRetrievalAPI_v6> paramGetAPI = [self.apiManager
          apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      KKParamsToPath(paramGetAPI, selPath);
      if (selPath.isRect && selPath.count >= 4) {
        simd_float2 bmin, bmax;
        [self boundsOfPath:selPath min:&bmin max:&bmax];
        CGPoint cMin = [self canvasPointFromObjectPoint:bmin];
        CGPoint cMax = [self canvasPointFromObjectPoint:bmax];
        float cW = (float)fabs(cMax.x - cMin.x);
        float cH = (float)fabs(cMax.y - cMin.y);
        [selPath setRoundedRectWithMin:bmin
                                   max:bmax
                            fractionTL:selPath.cornerRadiusTL
                            fractionTR:selPath.cornerRadiusTR
                            fractionBR:selPath.cornerRadiusBR
                            fractionBL:selPath.cornerRadiusBL
                           canvasWidth:cW
                          canvasHeight:cH];
      }
      KKShowObjectParams(paramSetAPI);
      {
        id<FxParameterRetrievalAPI_v6> getAPI = [self.apiManager
            apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
        BOOL strokeExpanded = NO;
        [getAPI getBoolValue:&strokeExpanded
               fromParameter:kParamExpandedStroke
                      atTime:kCMTimeZero];
        KKSetStrokeChildrenVisible(paramSetAPI, selPath.strokeEnabled,
                                   strokeExpanded);
        BOOL fillExpanded = NO;
        [getAPI getBoolValue:&fillExpanded
               fromParameter:kParamExpandedFill
                      atTime:kCMTimeZero];
        KKSetFillChildrenVisible(paramSetAPI, selPath.fillEnabled,
                                 fillExpanded);
        BOOL sketchExpanded = NO;
        [getAPI getBoolValue:&sketchExpanded
               fromParameter:kParamExpandedSketch
                      atTime:kCMTimeZero];
        KKSetSketchChildrenVisible(paramSetAPI, selPath.sketchEnabled,
                                   sketchExpanded);
      }
    } else if (!KKIsForceShowEnabled([self.apiManager
                   apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)])) {
      KKHideObjectParams(paramSetAPI);
    }
  }

  simd_float4 strokeColor = [[NSColor systemRedColor] simdFloat4];
  simd_float4 dimColor = strokeColor;
  dimColor.w = 0.3f;

  BOOL isCursorMode = (self.toolbar.activeTag == kOSCToolbarCursor);
  BOOL isPenMode = (self.toolbar.activeTag == kOSCToolbarPen);

  for (NSUInteger p = 0; p < self.paths.count; p++) {
    KKBezierPath *path = self.paths[p];
    if (path.count == 0)
      continue;

    BOOL isSelected = [self.selectedPathIndices containsIndex:p];
    if (path.hidden && !isSelected)
      continue;
    [self drawPathSegments:path
                     color:isSelected ? strokeColor : dimColor
          destinationImage:destinationImage];

    if (isPenMode) {
      BOOL isActive = ((NSInteger)p == self.activePathIndex);
      BOOL showControls =
          isActive || self.selectedPoints.count > 0 || self.dragIsMarquee;
      if (showControls) {
        [self drawPathControls:path
                     pathIndex:p
                    activePart:activePart
                         color:strokeColor
              destinationImage:destinationImage
                        atTime:time];
      }
    }
  }

  if (isCursorMode && self.selectedPathIndices.count > 0) {
    simd_float2 bmin, bmax;
    if ([self boundsOfSelectedPaths:&bmin max:&bmax]) {
      [self drawBoundingBoxWithMin:bmin
                               max:bmax
                        activePart:activePart
                  destinationImage:destinationImage
                            atTime:time];
    }
    if (self.selectedPathIndices.count == 1) {
      NSUInteger idx = self.selectedPathIndices.firstIndex;
      if (idx < self.paths.count) {
        [self drawCornerRadiusHandles:self.paths[idx]
                           activePart:activePart
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

  if (self.dragIsRect)
    [self drawRectPreview:strokeColor destinationImage:destinationImage];
  if (self.dragIsEllipse)
    [self drawEllipsePreview:strokeColor destinationImage:destinationImage];
  if (self.dragIsLine) {
    CGPoint ca = [self canvasPointFromObjectPoint:self.rectStart];
    CGPoint cb = [self canvasPointFromObjectPoint:self.dragOrigin];
    [self drawLineFrom:ca
                      to:cb
                   color:strokeColor
               halfWidth:1.5f
        destinationImage:destinationImage];
  }
}

@end
#pragma clang diagnostic pop
