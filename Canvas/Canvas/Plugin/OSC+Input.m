/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation CanvasOSC (Input)

- (void)setHandle:(simd_float2)offset
          atIndex:(NSInteger)idx
             isIn:(BOOL)isIn
    breakSymmetry:(BOOL)breakSymmetry
           onPath:(KKBezierPath *)path {
  if (isIn) {
    [path setInHandle:offset atIndex:idx];
    if (!breakSymmetry)
      [path setOutHandle:(simd_float2){-offset.x, -offset.y} atIndex:idx];
  } else {
    [path setOutHandle:offset atIndex:idx];
    if (!breakSymmetry)
      [path setInHandle:(simd_float2){-offset.x, -offset.y} atIndex:idx];
  }
  [path setType:KKBezierPointBezier atIndex:idx];
}

- (void)toggleBezierAtIndex:(NSInteger)idx onPath:(KKBezierPath *)path {
  path.isRect = NO;
  KKBezierPoint pt = [path pointAtIndex:idx];
  if (pt.type == KKBezierPointBezier) {
    [path setType:KKBezierPointLinear atIndex:idx];
    [path setInHandle:(simd_float2){0, 0} atIndex:idx];
    [path setOutHandle:(simd_float2){0, 0} atIndex:idx];
  } else {
    simd_float2 pos = {pt.x, pt.y}, prev = pos, next = pos;
    if (idx > 0) {
      KKBezierPoint pp = [path pointAtIndex:idx - 1];
      prev = (simd_float2){pp.x, pp.y};
    }
    if (idx + 1 < (NSInteger)path.count) {
      KKBezierPoint np = [path pointAtIndex:idx + 1];
      next = (simd_float2){np.x, np.y};
    }
    simd_float2 dir = (next - prev) * 0.25f;
    [path setOutHandle:dir atIndex:idx];
    [path setInHandle:(simd_float2){-dir.x, -dir.y} atIndex:idx];
    [path setType:KKBezierPointBezier atIndex:idx];
  }
}

- (void)mouseDownOnClosePath:(KKBezierPath *)active
                 forceUpdate:(BOOL *)forceUpdate {
  active.closed = YES;
  [self writePaths:self.paths];
  self.dragIndex = 0;
  self.dragIsInHandle = YES;
  self.dragIsOutHandle = NO;
  *forceUpdate = YES;
}

- (void)mouseDownDeletePoint:(NSInteger)idx
                      active:(KKBezierPath *)active
                 forceUpdate:(BOOL *)forceUpdate {
  if (idx < 0 || idx >= (NSInteger)active.count)
    return;
  active.isRect = NO;
  [active removeAtIndex:idx];
  if (active.count < 2) {
    [self.paths removeObjectAtIndex:self.activePathIndex];
    self.activePathIndex = -1;
  }
  [self writePaths:self.paths];
  *forceUpdate = YES;
}

- (void)mouseDownOnPoint:(NSInteger)idx
                  active:(KKBezierPath *)active
             forceUpdate:(BOOL *)forceUpdate {
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (self.lastClickIndex == idx && (now - self.lastClickTime) < 0.35) {
    [self toggleBezierAtIndex:idx onPath:active];
    [self writePaths:self.paths];
    self.lastClickIndex = -1;
    *forceUpdate = YES;
    return;
  }
  self.lastClickTime = now;
  self.lastClickIndex = idx;
  self.dragIndex = idx;
  self.dragIsInHandle = NO;
  self.dragIsOutHandle = NO;
  KKBezierPoint dragPt = [active pointAtIndex:idx];
  self.dragOrigin = (simd_float2){dragPt.x, dragPt.y};
  self.dragAnchor = self.dragOrigin;
  *forceUpdate = YES;
}

- (void)mouseDownOnHandle:(NSInteger)activePart
              forceUpdate:(BOOL *)forceUpdate {
  if (activePart >= kOSCInHandleBase && activePart < kOSCOutHandleBase) {
    self.dragIndex = activePart - kOSCInHandleBase;
    self.dragIsInHandle = YES;
    self.dragIsOutHandle = NO;
  } else {
    self.dragIndex = activePart - kOSCOutHandleBase;
    self.dragIsInHandle = NO;
    self.dragIsOutHandle = YES;
  }
  *forceUpdate = YES;
}

- (void)mouseDownOnCornerRadius:(NSInteger)activePart
                      positionX:(double)positionX
                      positionY:(double)positionY
                         active:(KKBezierPath *)active
                    forceUpdate:(BOOL *)forceUpdate {
  self.dragIndex = -2;
  self.dragCornerIndex = activePart - kOSCCornerRadiusTL;
  self.dragAnchor = (simd_float2){(float)positionX, (float)positionY};
  float fracs[4] = {active.cornerRadiusTL, active.cornerRadiusTR,
                    active.cornerRadiusBR, active.cornerRadiusBL};
  self.dragStartPixelRadius = fracs[self.dragCornerIndex];
  *forceUpdate = YES;
}

- (void)mouseDownOnSegment:(NSInteger)activePart
                 positionX:(double)positionX
                 positionY:(double)positionY
                    active:(KKBezierPath *)active
               forceUpdate:(BOOL *)forceUpdate {
  NSInteger segIdx = activePart - kOSCPathSegmentBase;
  simd_float2 objPos =
      [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
  active.isRect = NO;
  [active insertAtIndex:segIdx + 1 position:objPos];
  [self writePaths:self.paths];
  self.dragIndex = segIdx + 1;
  self.dragIsInHandle = NO;
  self.dragIsOutHandle = NO;
  *forceUpdate = YES;
}

- (void)mouseDownOnResizeHandle:(NSInteger)handleIndex
                         active:(KKBezierPath *)active
                    forceUpdate:(BOOL *)forceUpdate {
  self.dragResizeHandle = handleIndex;
  simd_float2 bmin, bmax;
  [self boundsOfSelectedPaths:&bmin max:&bmax];
  self.resizeOrigMin = bmin;
  self.resizeOrigMax = bmax;
  float w = bmax.x - bmin.x, h = bmax.y - bmin.y;
  self.resizeOrigAspect = (h > 1e-6f) ? (w / h) : 1.0f;

  NSMutableArray<NSData *> *snapshots = [NSMutableArray array];
  NSMutableArray<NSNumber *> *indices = [NSMutableArray array];
  [self.selectedPathIndices
      enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx >= self.paths.count)
          return;
        KKBezierPath *path = self.paths[idx];
        NSMutableData *snap =
            [NSMutableData dataWithLength:path.count * sizeof(KKBezierPoint)];
        KKBezierPoint *buf = snap.mutableBytes;
        for (NSUInteger i = 0; i < path.count; i++)
          buf[i] = [path pointAtIndex:i];
        [snapshots addObject:snap];
        [indices addObject:@(idx)];
      }];
  self.resizeOrigSnapshots = snapshots;
  self.resizeOrigIndices = indices;
  *forceUpdate = YES;
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  if (activePart == kOSCToolbarCursor || activePart == kOSCToolbarPen ||
      activePart == kOSCToolbarRect || activePart == kOSCToolbarEllipse ||
      activePart == kOSCToolbarLine) {
    self.toolbar.activeTag = activePart;
    *forceUpdate = YES;
    return;
  }
  if (activePart == -1)
    return;

  self.paths = [self readPaths];
  KKBezierPath *active = [self activePath];
  BOOL isCursorMode = (self.toolbar.activeTag == kOSCToolbarCursor);
  BOOL isPenMode = (self.toolbar.activeTag == kOSCToolbarPen);
  BOOL isRectMode = (self.toolbar.activeTag == kOSCToolbarRect);
  BOOL isEllipseMode = (self.toolbar.activeTag == kOSCToolbarEllipse);
  BOOL isLineMode = (self.toolbar.activeTag == kOSCToolbarLine);

  if (activePart >= kOSCResizeHandleBase &&
      activePart < kOSCResizeHandleBase + 8 && active) {
    [self mouseDownOnResizeHandle:activePart - kOSCResizeHandleBase
                           active:active
                      forceUpdate:forceUpdate];
    return;
  }

  if (activePart == kOSCBoundingBox && self.selectedPathIndices.count > 0) {
    self.dragIsSelection = YES;
    self.dragOrigin =
        [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
    self.dragAnchor = self.dragOrigin;
    *forceUpdate = YES;
    return;
  }

  if (activePart >= kOSCCornerRadiusTL && activePart <= kOSCCornerRadiusBL &&
      active) {
    [self mouseDownOnCornerRadius:activePart
                        positionX:positionX
                        positionY:positionY
                           active:active
                      forceUpdate:forceUpdate];
    return;
  }

  if (activePart == kOSCClosePath && active) {
    [self mouseDownOnClosePath:active forceUpdate:forceUpdate];
    return;
  }

  if (activePart >= kOSCPathPointBase && activePart < kOSCInHandleBase &&
      active) {
    NSInteger idx = activePart - kOSCPathPointBase;
    if (modifiers & kFxModifierKey_OPTION) {
      [self mouseDownDeletePoint:idx active:active forceUpdate:forceUpdate];
      return;
    }
    [self mouseDownOnPoint:idx active:active forceUpdate:forceUpdate];
    return;
  }

  if (activePart >= kOSCInHandleBase && activePart < kOSCPathSegmentBase) {
    [self mouseDownOnHandle:activePart forceUpdate:forceUpdate];
    return;
  }

  if (activePart >= kOSCPathSegmentBase && isPenMode && active) {
    [self mouseDownOnSegment:activePart
                   positionX:positionX
                   positionY:positionY
                      active:active
                 forceUpdate:forceUpdate];
    return;
  }

  if (isPenMode && (modifiers & kFxModifierKey_COMMAND)) {
    double hitRadiusStroke = [self strokeHitRadius];
    NSInteger nearPath = [self pathIndexNearX:positionX
                                            y:positionY
                                       radius:hitRadiusStroke];
    if (nearPath >= 0) {
      [self handleCursorMouseDownX:positionX
                                 y:positionY
                         modifiers:modifiers
                       forceUpdate:forceUpdate];
    } else {
      self.activePathIndex = -1;
      [self handlePenMouseDownX:positionX
                              y:positionY
                         active:nil
                      modifiers:modifiers
                    forceUpdate:forceUpdate
                         atTime:time
                     activePart:activePart];
    }
    return;
  }

  if (isCursorMode) {
    [self handleCursorMouseDownX:positionX
                               y:positionY
                       modifiers:modifiers
                     forceUpdate:forceUpdate];
    return;
  }

  if (isPenMode) {
    [self handlePenMouseDownX:positionX
                            y:positionY
                       active:active
                    modifiers:modifiers
                  forceUpdate:forceUpdate
                       atTime:time
                   activePart:activePart];
    return;
  }

  if (isRectMode || isEllipseMode || isLineMode) {
    simd_float2 objPos =
        [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
    self.rectStart = objPos;
    self.dragOrigin = objPos;
    self.dragIsRect = isRectMode;
    self.dragIsEllipse = isEllipseMode;
    self.dragIsLine = isLineMode;
    *forceUpdate = YES;
  }
}

- (void)handleCursorMouseDownX:(double)positionX
                             y:(double)positionY
                     modifiers:(NSUInteger)modifiers
                   forceUpdate:(BOOL *)forceUpdate {
  BOOL shiftDown = (modifiers & kFxModifierKey_SHIFT) != 0;
  double hitRadiusStroke = [self strokeHitRadius];
  NSInteger nearPath = [self pathIndexNearX:positionX
                                          y:positionY
                                     radius:hitRadiusStroke];
  if (nearPath >= 0) {
    if (shiftDown) {
      if ([self.selectedPathIndices containsIndex:nearPath])
        [self.selectedPathIndices removeIndex:nearPath];
      else
        [self.selectedPathIndices addIndex:nearPath];
    } else {
      [self.selectedPathIndices removeAllIndexes];
      [self.selectedPathIndices addIndex:nearPath];
    }
    self.activePathIndex = nearPath;
    [self syncStrokeParamsToSelection];
    self.dragIsPath = YES;
    self.dragOrigin =
        [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
    *forceUpdate = YES;
    return;
  }

  if (!shiftDown) {
    // Write back per-object params before deselecting. Don't use
    // syncStrokeParamsToSelection — it updates KKCanvasCurrentSelection
    // which causes races with drawOSC.
    KKBezierPath *prev = KKSelectedPath(self.selectedPathIndices, self.paths);
    if (prev) {
      id<FxParameterRetrievalAPI_v6> paramGetAPI = [self.apiManager
          apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      id<FxParameterSettingAPI_v5> paramSetAPI =
          [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      KKParamsToPath(paramGetAPI, prev);
      [self writePaths:self.paths];
      KKHideObjectParams(paramSetAPI);
      KKSaveSelectedIndex(paramSetAPI, -1);
    }
    [self.selectedPathIndices removeAllIndexes];
    self.activePathIndex = -1;
  }
  self.dragIsMarquee = YES;
  self.marqueeStart = CGPointMake(positionX, positionY);
  self.marqueeEnd = self.marqueeStart;
  *forceUpdate = YES;
}

- (void)handlePenMouseDownX:(double)positionX
                          y:(double)positionY
                     active:(KKBezierPath *)active
                  modifiers:(NSUInteger)modifiers
                forceUpdate:(BOOL *)forceUpdate
                     atTime:(CMTime)time
                 activePart:(NSInteger)activePart {
  if (!active) {
    KKBezierPath *newPath = [[KKBezierPath alloc] init];
    newPath.name = [NSString
        stringWithFormat:@"Path %lu", (unsigned long)(self.paths.count + 1)];
    [self.paths insertObject:newPath atIndex:0];
    self.activePathIndex = 0;
    active = newPath;
  } else if (active.closed) {
    double hitRadiusStroke = [self strokeHitRadius];
    NSInteger segIdx = [self segmentIndexNearX:positionX
                                             y:positionY
                                        radius:hitRadiusStroke
                                        inPath:active];
    if (segIdx >= 0) {
      [self mouseDownOnSegment:kOSCPathSegmentBase + segIdx
                     positionX:positionX
                     positionY:positionY
                        active:active
                   forceUpdate:forceUpdate];
      return;
    }
    KKBezierPath *newPath = [[KKBezierPath alloc] init];
    newPath.name = [NSString
        stringWithFormat:@"Path %lu", (unsigned long)(self.paths.count + 1)];
    [self.paths insertObject:newPath atIndex:0];
    self.activePathIndex = 0;
    active = newPath;
  }

  simd_float2 objPos =
      [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
  [active insertAtIndex:active.count position:objPos];
  [self writePaths:self.paths];

  self.dragIndex = (NSInteger)active.count - 1;
  self.dragIsInHandle = NO;
  self.dragIsOutHandle = NO;
  self.dragIsNewPoint = YES;

  *forceUpdate = YES;
  [super mouseDownAtPositionX:positionX
                    positionY:positionY
                   activePart:activePart
                    modifiers:modifiers
                  forceUpdate:forceUpdate
                       atTime:time];
}

@end
#pragma clang diagnostic pop
