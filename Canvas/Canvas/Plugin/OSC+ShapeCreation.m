/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC_Private.h"

@implementation CanvasOSC (ShapeCreation)

- (void)finalizeMarqueeAtX:(double)positionX
                         y:(double)positionY
                 modifiers:(NSUInteger)modifiers {
  self.marqueeEnd = CGPointMake(positionX, positionY);

  CGFloat minX = MIN(self.marqueeStart.x, self.marqueeEnd.x);
  CGFloat maxX = MAX(self.marqueeStart.x, self.marqueeEnd.x);
  CGFloat minY = MIN(self.marqueeStart.y, self.marqueeEnd.y);
  CGFloat maxY = MAX(self.marqueeStart.y, self.marqueeEnd.y);

  if (maxX - minX < 2.0 && maxY - minY < 2.0)
    return;

  BOOL isCursorMode = (self.toolbar.activeTag == kOSCToolbarCursor);

  if (isCursorMode) {
    for (NSUInteger p = 0; p < self.paths.count; p++) {
      KKBezierPath *path = self.paths[p];
      if (path.count == 0 || path.hidden || path.locked)
        continue;
      simd_float2 bmin, bmax;
      [self boundsOfPath:path min:&bmin max:&bmax];
      CGPoint bl = [self canvasPointFromObjectPoint:bmin];
      CGPoint tr = [self canvasPointFromObjectPoint:bmax];
      CGFloat pMinX = MIN(bl.x, tr.x), pMaxX = MAX(bl.x, tr.x);
      CGFloat pMinY = MIN(bl.y, tr.y), pMaxY = MAX(bl.y, tr.y);
      BOOL fullyInside =
          (pMinX >= minX && pMaxX <= maxX && pMinY >= minY && pMaxY <= maxY);
      if (fullyInside) {
        [self.selectedPathIndices addIndex:p];
        self.activePathIndex = (NSInteger)p;
      }
    }
    return;
  }

  BOOL shiftDown = (modifiers & kFxModifierKey_SHIFT) != 0;
  BOOL optDown = (modifiers & kFxModifierKey_OPTION) != 0;
  if (!shiftDown && !optDown)
    [self.selectedPoints removeAllIndexes];
  for (NSUInteger p = 0; p < self.paths.count; p++) {
    KKBezierPath *path = self.paths[p];
    if (path.hidden || path.locked)
      continue;
    for (NSUInteger i = 0; i < path.count; i++) {
      KKBezierPoint pt = [path pointAtIndex:i];
      CGPoint canvas = [self canvasPointForBezierPoint:pt];
      BOOL inside = (canvas.x >= minX && canvas.x <= maxX && canvas.y >= minY &&
                     canvas.y <= maxY);
      if (!inside)
        continue;
      NSUInteger key = selKey(p, i);
      if (optDown)
        [self.selectedPoints removeIndex:key];
      else
        [self.selectedPoints addIndex:key];
    }
  }
}

- (void)finalizeRect {
  simd_float2 a = self.rectStart;
  simd_float2 b = self.dragOrigin;
  float minX = fminf(a.x, b.x), maxX = fmaxf(a.x, b.x);
  float minY = fminf(a.y, b.y), maxY = fmaxf(a.y, b.y);
  if (maxX - minX < 0.001f || maxY - minY < 0.001f)
    return;

  KKBezierPath *rect = [[KKBezierPath alloc] init];
  rect.name = [NSString
      stringWithFormat:@"Rectangle %lu", (unsigned long)(self.paths.count + 1)];
  [rect insertAtIndex:0 position:(simd_float2){minX, maxY}];
  [rect insertAtIndex:1 position:(simd_float2){maxX, maxY}];
  [rect insertAtIndex:2 position:(simd_float2){maxX, minY}];
  [rect insertAtIndex:3 position:(simd_float2){minX, minY}];
  rect.closed = YES;
  rect.isRect = YES;
  [self.paths insertObject:rect atIndex:0];
  self.activePathIndex = 0;
  [self.selectedPathIndices removeAllIndexes];
  [self.selectedPathIndices addIndex:0];
  [self writePaths:self.paths];
}

- (void)finalizeEllipse {
  simd_float2 a = self.rectStart;
  simd_float2 b = self.dragOrigin;
  float minX = fminf(a.x, b.x), maxX = fmaxf(a.x, b.x);
  float minY = fminf(a.y, b.y), maxY = fmaxf(a.y, b.y);
  if (maxX - minX < 0.001f || maxY - minY < 0.001f)
    return;

  float cx = (minX + maxX) * 0.5f, cy = (minY + maxY) * 0.5f;
  float rx = (maxX - minX) * 0.5f, ry = (maxY - minY) * 0.5f;
  float kx = rx * 0.5522847498f, ky = ry * 0.5522847498f;

  KKBezierPath *ellipse = [[KKBezierPath alloc] init];
  ellipse.name = [NSString
      stringWithFormat:@"Ellipse %lu", (unsigned long)(self.paths.count + 1)];
  [ellipse insertAtIndex:0 position:(simd_float2){cx, cy + ry}];
  [ellipse insertAtIndex:1 position:(simd_float2){cx + rx, cy}];
  [ellipse insertAtIndex:2 position:(simd_float2){cx, cy - ry}];
  [ellipse insertAtIndex:3 position:(simd_float2){cx - rx, cy}];

  [ellipse setOutHandle:(simd_float2){kx, 0} atIndex:0];
  [ellipse setInHandle:(simd_float2){-kx, 0} atIndex:0];
  [ellipse setType:KKBezierPointBezier atIndex:0];

  [ellipse setOutHandle:(simd_float2){0, -ky} atIndex:1];
  [ellipse setInHandle:(simd_float2){0, ky} atIndex:1];
  [ellipse setType:KKBezierPointBezier atIndex:1];

  [ellipse setOutHandle:(simd_float2){-kx, 0} atIndex:2];
  [ellipse setInHandle:(simd_float2){kx, 0} atIndex:2];
  [ellipse setType:KKBezierPointBezier atIndex:2];

  [ellipse setOutHandle:(simd_float2){0, ky} atIndex:3];
  [ellipse setInHandle:(simd_float2){0, -ky} atIndex:3];
  [ellipse setType:KKBezierPointBezier atIndex:3];

  ellipse.closed = YES;
  [self.paths insertObject:ellipse atIndex:0];
  self.activePathIndex = 0;
  [self.selectedPathIndices removeAllIndexes];
  [self.selectedPathIndices addIndex:0];
  [self writePaths:self.paths];
}

- (void)finalizeLine {
  simd_float2 a = self.rectStart;
  simd_float2 b = self.dragOrigin;
  if (fabs(a.x - b.x) < 0.001f && fabs(a.y - b.y) < 0.001f)
    return;

  KKBezierPath *line = [[KKBezierPath alloc] init];
  line.name = [NSString
      stringWithFormat:@"Line %lu", (unsigned long)(self.paths.count + 1)];
  [line insertAtIndex:0 position:a];
  [line insertAtIndex:1 position:b];
  line.closed = NO;
  line.isLine = YES;
  [self.paths insertObject:line atIndex:0];
  self.activePathIndex = 0;
  [self.selectedPathIndices removeAllIndexes];
  [self.selectedPathIndices addIndex:0];
  [self writePaths:self.paths];
}

- (void)resetDragState {
  self.dragIndex = -1;
  self.dragResizeHandle = -1;
  self.dragIsInHandle = NO;
  self.dragIsOutHandle = NO;
  self.dragIsNewPoint = NO;
  self.dragIsPath = NO;
  self.dragIsMarquee = NO;
  self.dragIsSelection = NO;
  self.dragIsRect = NO;
  self.dragIsEllipse = NO;
  self.dragIsLine = NO;
  self.dragDidDuplicate = NO;
  self.dragIsRotation = NO;
  self.resizeOrigSnapshots = nil;
  self.resizeOrigIndices = nil;
  self.rotateOrigSnapshots = nil;
  self.rotateOrigIndices = nil;
}

- (void)keyDownAtPositionX:(double)positionX
                 positionY:(double)positionY
                keyPressed:(unsigned short)asciiKey
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                 didHandle:(BOOL *)didHandle
                    atTime:(CMTime)time {
  BOOL isCursorMode = (self.toolbar.activeTag == kOSCToolbarCursor);

  if (asciiKey == 27) {
    [self.selectedPoints removeAllIndexes];
    [self.selectedPathIndices removeAllIndexes];
    self.activePathIndex = -1;
    self.toolbar.activeTag = kOSCToolbarCursor;
    [self syncStrokeParamsToSelection];
    *forceUpdate = YES;
    *didHandle = YES;
    return;
  }

  if (asciiKey != 127 && asciiKey != 8)
    return;

  self.paths = [self readPaths];

  if (isCursorMode && self.selectedPathIndices.count > 0) {
    [self.selectedPathIndices
        enumerateIndexesWithOptions:NSEnumerationReverse
                         usingBlock:^(NSUInteger idx, BOOL *stop) {
                           if (idx < self.paths.count)
                             [self.paths removeObjectAtIndex:idx];
                         }];
    [self.selectedPathIndices removeAllIndexes];
    self.activePathIndex = -1;
    NSString *delUUID = KKLayerUUIDForAPI(self.apiManager);
    if (delUUID)
      KKCanvasUpdateSelection(delUUID, self.selectedPathIndices);
    id<FxParameterSettingAPI_v5> delSetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    KKSaveSelectedIndex(delSetAPI, -1);
    [self writePaths:self.paths];
    *forceUpdate = YES;
    *didHandle = YES;
    return;
  }

  KKBezierPath *active = [self activePath];
  if (!active)
    return;

  if (isCursorMode) {
    [self.paths removeObjectAtIndex:self.activePathIndex];
    [self.selectedPathIndices removeAllIndexes];
    self.activePathIndex = -1;
    NSString *delUUID = KKLayerUUIDForAPI(self.apiManager);
    if (delUUID)
      KKCanvasUpdateSelection(delUUID, self.selectedPathIndices);
    id<FxParameterSettingAPI_v5> delSetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    KKSaveSelectedIndex(delSetAPI, -1);
    [self writePaths:self.paths];
    *forceUpdate = YES;
    *didHandle = YES;
  } else if (active.count > 0) {
    [active removeAtIndex:active.count - 1];
    if (active.count < 2) {
      [self.paths removeObjectAtIndex:self.activePathIndex];
      [self.selectedPathIndices removeAllIndexes];
      self.activePathIndex = -1;
    }
    [self writePaths:self.paths];
    *forceUpdate = YES;
    *didHandle = YES;
  }
}

@end
