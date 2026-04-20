/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC_Private.h"
#import "ObjectParams.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation CanvasOSC (Input)

// ---------------------------------------------------------------------------
// Bezier utilities
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Image helper — restore original aspect ratio on double-click
// ---------------------------------------------------------------------------

- (void)restoreImageAspectRatio:(KKBezierPath *)path {
  if (!path.isImage || path.imageAspect <= 0 || path.count < 4)
    return;

  float imgAspect = path.imageAspect;

  // Current bounding box in object space.
  simd_float2 bmin, bmax;
  [self boundsOfPath:path min:&bmin max:&bmax];
  float curW = bmax.x - bmin.x;
  float curH = bmax.y - bmin.y;

  // Keep the larger dimension, adjust the other.
  // Object space uses non-square units (X / outputWidth, Y / outputHeight),
  // so convert to pixels, apply aspect, then convert back.
  float pxW = curW * self.imageWidth;
  float pxH = curH * self.imageHeight;
  float newPxW, newPxH;
  if (pxW >= pxH) {
    newPxW = pxW;
    newPxH = pxW / imgAspect;
  } else {
    newPxH = pxH;
    newPxW = pxH * imgAspect;
  }
  float newW = newPxW / self.imageWidth;
  float newH = newPxH / self.imageHeight;

  // Center the new rect around the old center.
  float cx = (bmin.x + bmax.x) * 0.5f;
  float cy = (bmin.y + bmax.y) * 0.5f;
  float x0 = cx - newW * 0.5f;
  float x1 = cx + newW * 0.5f;
  float y0 = cy - newH * 0.5f;
  float y1 = cy + newH * 0.5f;

  // Point order: 0=TL, 1=TR, 2=BR, 3=BL (matching import).
  [path moveAtIndex:0 to:(simd_float2){x0, y1}];
  [path moveAtIndex:1 to:(simd_float2){x1, y1}];
  [path moveAtIndex:2 to:(simd_float2){x1, y0}];
  [path moveAtIndex:3 to:(simd_float2){x0, y0}];
}

// ---------------------------------------------------------------------------
// Selection helper — keeps selectedPathIndices consistent with activePathIndex
// ---------------------------------------------------------------------------

- (void)selectActivePath {
  [self.selectedPathIndices removeAllIndexes];
  if (self.activePathIndex >= 0)
    [self.selectedPathIndices addIndex:self.activePathIndex];
}

// ---------------------------------------------------------------------------
// Pen tool: close path
// ---------------------------------------------------------------------------

- (void)penClosePath:(KKBezierPath *)active forceUpdate:(BOOL *)forceUpdate {
  active.closed = YES;
  [self selectActivePath];
  [self writePaths:self.paths];

  // The closed flag lives in both the blob AND kParamClosedPath. Sync the
  // FxPlug param so that KKParamsToPath (called by syncStrokeParamsToSelection
  // and drawOSC) does not revert the flag.
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  [paramSetAPI setBoolValue:YES
                toParameter:kParamClosedPath
                     atTime:kCMTimeZero];

  // Set up handle drag on point 0 so the user can drag to create a curve
  // at the close point (standard pen tool behavior).
  self.dragIndex = 0;
  self.dragIsNewPoint = NO;
  self.dragIsInHandle = YES;
  self.dragIsOutHandle = NO;

  *forceUpdate = YES;
}

// ---------------------------------------------------------------------------
// Pen tool: delete point (Option+click)
// ---------------------------------------------------------------------------

- (void)penDeletePoint:(NSInteger)idx
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
  [self selectActivePath];
  [self writePaths:self.paths];
  *forceUpdate = YES;
}

// ---------------------------------------------------------------------------
// Pen tool: click on existing point (single = drag, double = toggle bezier)
// ---------------------------------------------------------------------------

- (void)penClickPoint:(NSInteger)idx
               active:(KKBezierPath *)active
          forceUpdate:(BOOL *)forceUpdate {
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (self.lastClickIndex == idx && (now - self.lastClickTime) < 0.35) {
    [self toggleBezierAtIndex:idx onPath:active];
    [self selectActivePath];
    [self writePaths:self.paths];
    self.lastClickIndex = -1;
    *forceUpdate = YES;
    return;
  }
  self.lastClickTime = now;
  self.lastClickIndex = idx;

  self.dragIndex = idx;
  self.dragIsNewPoint = NO;
  self.dragIsInHandle = NO;
  self.dragIsOutHandle = NO;
  [self selectActivePath];

  // Persist the selected index so the undo detector in drawOSC doesn't
  // reset activePathIndex between mouseDown and the first mouseDrag.
  {
    id<FxParameterSettingAPI_v5> setAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    KKSaveSelectedIndex(setAPI, self.activePathIndex);
  }

  KKBezierPoint dragPt = [active pointAtIndex:idx];
  self.dragOrigin = (simd_float2){dragPt.x, dragPt.y};
  self.dragAnchor = self.dragOrigin;
  *forceUpdate = YES;
}

// ---------------------------------------------------------------------------
// Pen tool: click on bezier handle
// ---------------------------------------------------------------------------

- (void)penClickHandle:(NSInteger)activePart forceUpdate:(BOOL *)forceUpdate {
  if (activePart >= kOSCInHandleBase && activePart < kOSCOutHandleBase) {
    self.dragIndex = activePart - kOSCInHandleBase;
    self.dragIsInHandle = YES;
    self.dragIsOutHandle = NO;
  } else {
    self.dragIndex = activePart - kOSCOutHandleBase;
    self.dragIsInHandle = NO;
    self.dragIsOutHandle = YES;
  }
  self.dragIsNewPoint = NO;
  [self selectActivePath];
  {
    id<FxParameterSettingAPI_v5> setAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    KKSaveSelectedIndex(setAPI, self.activePathIndex);
  }
  *forceUpdate = YES;
}

// ---------------------------------------------------------------------------
// Pen tool: insert point on segment
// ---------------------------------------------------------------------------

- (void)penInsertOnSegment:(NSInteger)activePart
                 positionX:(double)positionX
                 positionY:(double)positionY
                    active:(KKBezierPath *)active
               forceUpdate:(BOOL *)forceUpdate {
  NSInteger segIdx = activePart - kOSCPathSegmentBase;
  simd_float2 objPos =
      [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
  active.isRect = NO;
  [active insertAtIndex:segIdx + 1 position:objPos];
  [self selectActivePath];
  [self writePaths:self.paths];

  self.dragIndex = segIdx + 1;
  self.dragIsNewPoint = NO;
  self.dragIsInHandle = NO;
  self.dragIsOutHandle = NO;
  *forceUpdate = YES;
}

// ---------------------------------------------------------------------------
// Pen tool: add new point to path (or create new path)
// ---------------------------------------------------------------------------

- (void)penAddPointX:(double)positionX
                   y:(double)positionY
              active:(KKBezierPath *)active
         forceUpdate:(BOOL *)forceUpdate {
  if (!active) {
    KKBezierPath *newPath = [[KKBezierPath alloc] init];
    newPath.name = [NSString
        stringWithFormat:@"Path %lu", (unsigned long)(self.paths.count + 1)];
    // Inherit stroke/fill/opacity from current inspector values.
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    KKParamsToPath(paramGetAPI, newPath);
    NSString *penUUID = KKLayerUUIDForAPI(self.apiManager);
    if (penUUID)
      KKApplyCachedStyles(penUUID, newPath);
    newPath.closed = NO;
    [self.paths insertObject:newPath atIndex:0];
    self.activePathIndex = 0;
    active = newPath;
  } else if (active.closed) {
    double hitRadius = [self strokeHitRadius];
    NSInteger segIdx = [self segmentIndexNearX:positionX
                                             y:positionY
                                        radius:hitRadius
                                        inPath:active];
    if (segIdx >= 0) {
      [self penInsertOnSegment:kOSCPathSegmentBase + segIdx
                     positionX:positionX
                     positionY:positionY
                        active:active
                   forceUpdate:forceUpdate];
      return;
    }
    KKBezierPath *newPath = [[KKBezierPath alloc] init];
    newPath.name = [NSString
        stringWithFormat:@"Path %lu", (unsigned long)(self.paths.count + 1)];
    id<FxParameterRetrievalAPI_v6> penGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    KKParamsToPath(penGetAPI, newPath);
    NSString *penUUID2 = KKLayerUUIDForAPI(self.apiManager);
    if (penUUID2)
      KKApplyCachedStyles(penUUID2, newPath);
    newPath.closed = NO;
    [self.paths insertObject:newPath atIndex:0];
    self.activePathIndex = 0;
    active = newPath;
  }

  simd_float2 objPos =
      [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
  [active insertAtIndex:active.count position:objPos];
  [self selectActivePath];
  [self writePaths:self.paths];
  {
    id<FxParameterSettingAPI_v5> setAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    KKSaveSelectedIndex(setAPI, self.activePathIndex);
  }

  self.dragIndex = (NSInteger)active.count - 1;
  self.dragIsNewPoint = YES;
  self.dragIsInHandle = NO;
  self.dragIsOutHandle = NO;
  *forceUpdate = YES;
}

// ---------------------------------------------------------------------------
// Cursor-mode helpers (unchanged, kept for resize / corner-radius)
// ---------------------------------------------------------------------------

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

- (void)mouseDownOnRotateHandle:(double)positionX
                              y:(double)positionY
                    forceUpdate:(BOOL *)forceUpdate {
  self.dragIsRotation = YES;
  self.rotateDeltaAngle = 0.0f;

  simd_float2 bmin, bmax;
  [self boundsOfSelectedPaths:&bmin max:&bmax];
  self.rotateCenter =
      (simd_float2){(bmin.x + bmax.x) * 0.5f, (bmin.y + bmax.y) * 0.5f};
  self.rotateOrigMin = bmin;
  self.rotateOrigMax = bmax;

  CGPoint centerCanvas = [self canvasPointFromObjectPoint:self.rotateCenter];
  CGPoint bl = [self canvasPointFromObjectPoint:bmin];
  CGPoint tr = [self canvasPointFromObjectPoint:bmax];
  CGPoint topMid = [self resizeHandlePosition:1 topRight:tr bottomLeft:bl];
  CGPoint handlePos = {topMid.x, topMid.y + 20.0};
  self.rotateStartAngle = atan2f((float)(handlePos.y - centerCanvas.y),
                                 (float)(handlePos.x - centerCanvas.x));

  NSMutableArray<NSData *> *snapshots = [NSMutableArray array];
  NSMutableArray<NSNumber *> *indices = [NSMutableArray array];
  [self.selectedPathIndices
      enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx >= self.paths.count)
          return;
        KKBezierPath *path = self.paths[idx];
        path.isRect = NO;
        NSMutableData *snap =
            [NSMutableData dataWithLength:path.count * sizeof(KKBezierPoint)];
        KKBezierPoint *buf = snap.mutableBytes;
        for (NSUInteger i = 0; i < path.count; i++)
          buf[i] = [path pointAtIndex:i];
        [snapshots addObject:snap];
        [indices addObject:@(idx)];
      }];
  self.rotateOrigSnapshots = snapshots;
  self.rotateOrigIndices = indices;
  [self writePaths:self.paths];
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

// ===========================================================================
// Main mouse-down dispatch
// ===========================================================================

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {

  // --- Toolbar button clicks ---
  if (activePart == kOSCToolbarCursor || activePart == kOSCToolbarPen ||
      activePart == kOSCToolbarRect || activePart == kOSCToolbarEllipse ||
      activePart == kOSCToolbarLine) {
    // Turn off Hide OSC when user interacts with toolbar.
    {
      id<FxParameterRetrievalAPI_v6> getAPI = [self.apiManager
          apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      BOOL hideOSC = NO;
      [getAPI getBoolValue:&hideOSC
             fromParameter:kParamHideOSC
                    atTime:kCMTimeZero];
      if (hideOSC) {
        id<FxParameterSettingAPI_v5> setAPI = [self.apiManager
            apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
        [setAPI setBoolValue:NO toParameter:kParamHideOSC atTime:kCMTimeZero];
        self.toolbar.activeTag = kOSCToolbarCursor;
      }
    }
    // Persist any pending inspector changes before leaving cursor or line
    // mode.  syncStrokeParamsToSelection checks isCursorMode internally,
    // so we call it while the toolbar still shows cursor.  For line modes
    // (rect/ellipse/line) we write params directly since the sync helper
    // is cursor-only.
    NSInteger prevTag = self.toolbar.activeTag;
    if (prevTag != activePart) {
      if (prevTag == kOSCToolbarCursor) {
        self.paths = [self readPaths];
        [self syncStrokeParamsToSelection];
      } else if (prevTag == kOSCToolbarPen || prevTag == kOSCToolbarRect ||
                 prevTag == kOSCToolbarEllipse || prevTag == kOSCToolbarLine) {
        self.paths = [self readPaths];
        KKBezierPath *sel =
            KKSelectedPath(self.selectedPathIndices, self.paths);
        if (sel) {
          id<FxParameterRetrievalAPI_v6> paramGetAPI = [self.apiManager
              apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
          KKParamsToPath(paramGetAPI, sel);
          [self writePaths:self.paths];
        }
      }
    }
    self.toolbar.activeTag = activePart;
    *forceUpdate = YES;
    return;
  }
  if (activePart == -1)
    return;

  // Path combine actions.
  if (activePart == kOSCPathUnion || activePart == kOSCPathSubtract ||
      activePart == kOSCPathIntersect || activePart == kOSCPathXOR) {
    self.paths = [self readPaths];
    if (self.selectedPathIndices.count >= 2) {
      // Collect selected non-image, non-group paths in bottom-to-top order
      // (highest index first). The bottom-most path is the "base" for
      // subtract/intersect, matching Inkscape's z-order convention.
      NSMutableArray<KKBezierPath *> *operands = [NSMutableArray array];
      NSMutableIndexSet *operandIndices = [NSMutableIndexSet indexSet];
      [self.selectedPathIndices
          enumerateIndexesWithOptions:NSEnumerationReverse
                           usingBlock:^(NSUInteger idx, BOOL *stop) {
                             if (idx < self.paths.count &&
                                 !self.paths[idx].isImage &&
                                 !self.paths[idx].isGroup) {
                               [operands addObject:self.paths[idx]];
                               [operandIndices addIndex:idx];
                             }
                           }];

      if (operands.count >= 2) {
        KKBooleanOp op;
        if (activePart == kOSCPathUnion)
          op = KKBooleanOpUnion;
        else if (activePart == kOSCPathSubtract)
          op = KKBooleanOpSubtract;
        else if (activePart == kOSCPathIntersect)
          op = KKBooleanOpIntersect;
        else
          op = KKBooleanOpXOR;

        KKBezierPath *result = KKPathBooleanApply(operands, op);
        if (result) {
          // Replace the operand paths with the result.
          // Insert at the position of the first operand, remove all operands.
          NSUInteger insertIdx = operandIndices.firstIndex;

          // Remove in reverse order to preserve indices.
          [operandIndices
              enumerateIndexesWithOptions:NSEnumerationReverse
                               usingBlock:^(NSUInteger idx, BOOL *stop) {
                                 [self.paths removeObjectAtIndex:idx];
                               }];
          [self.paths insertObject:result atIndex:insertIdx];
          [self writePaths:self.paths];

          [self.selectedPathIndices removeAllIndexes];
          [self.selectedPathIndices addIndex:insertIdx];
          self.activePathIndex = (NSInteger)insertIdx;
          [self syncStrokeParamsToSelection];
        }
      }
    }
    *forceUpdate = YES;
    return;
  }

  // Stroke-to-path (outline) action.
  if (activePart == kOSCPathOutline) {
    self.paths = [self readPaths];
    NSMutableArray<KKBezierPath *> *operands = [NSMutableArray array];
    NSMutableIndexSet *operandIndices = [NSMutableIndexSet indexSet];
    [self.selectedPathIndices
        enumerateIndexesWithOptions:NSEnumerationReverse
                         usingBlock:^(NSUInteger idx, BOOL *stop) {
                           if (idx < self.paths.count &&
                               !self.paths[idx].isImage &&
                               !self.paths[idx].isGroup &&
                               self.paths[idx].strokeEnabled) {
                             [operands addObject:self.paths[idx]];
                             [operandIndices addIndex:idx];
                           }
                         }];

    if (operands.count > 0) {
      NSArray<KKBezierPath *> *outlines = KKPathStrokeToOutline(
          operands, (CGFloat)self.imageWidth, (CGFloat)self.imageHeight);
      if (outlines.count > 0) {
        // For each operand: disable stroke on original, insert outline above.
        // Process in reverse index order so inserts don't shift earlier
        // indices. outlines[0] corresponds to the highest index (operands
        // collected in reverse), so enumerate in reverse to match.
        __block NSUInteger outlineIdx = 0;
        [operandIndices
            enumerateIndexesWithOptions:NSEnumerationReverse
                             usingBlock:^(NSUInteger idx, BOOL *stop) {
                               self.paths[idx].strokeEnabled = NO;
                               NSUInteger insertAt = idx + 1;
                               [self.paths insertObject:outlines[outlineIdx]
                                                atIndex:insertAt];
                               outlineIdx++;
                             }];

        [self writePaths:self.paths];
        [self.selectedPathIndices removeAllIndexes];
        self.activePathIndex = -1;
        // Pass empty previous selection so syncStroke doesn't overwrite
        // the strokeEnabled=NO we just set on the originals.
        [self syncStrokeParamsToSelectionWithPrevious:[NSIndexSet indexSet]];
      }
    }
    *forceUpdate = YES;
    return;
  }

  // --- Read paths from storage ---
  self.paths = [self readPaths];
  KKBezierPath *active = [self activePath];
  BOOL isCursorMode = (self.toolbar.activeTag == kOSCToolbarCursor);
  BOOL isPenMode = (self.toolbar.activeTag == kOSCToolbarPen);

  // Persist any pending inspector changes for the active pen-mode path
  // before the interaction overwrites them.
  if (isPenMode && active) {
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    KKParamsToPath(paramGetAPI, active);
    [self writePaths:self.paths];
  }

  // --- Cursor-mode element interactions ---
  // Must be checked BEFORE pen-mode points because the activePart ranges
  // overlap (kOSCResizeHandleBase 20000 falls inside kOSCPathPointBase 10000
  // .. kOSCInHandleBase 100000).
  if (activePart >= kOSCResizeHandleBase &&
      activePart < kOSCResizeHandleBase + 8 && active) {
    NSInteger handleIndex = activePart - kOSCResizeHandleBase;
    BOOL isCorner = (handleIndex % 2 == 0);
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (isCorner && active.isImage && active.imageAspect > 0 &&
        self.lastClickIndex == activePart &&
        (now - self.lastClickTime) < 0.35) {
      [self restoreImageAspectRatio:active];
      [self selectActivePath];
      [self writePaths:self.paths];
      self.lastClickIndex = -1;
      *forceUpdate = YES;
      return;
    }
    self.lastClickTime = now;
    self.lastClickIndex = activePart;
    [self mouseDownOnResizeHandle:handleIndex
                           active:active
                      forceUpdate:forceUpdate];
    return;
  }
  if (activePart == kOSCBoundingBox && self.selectedPathIndices.count > 0) {
    self.dragIsSelection = YES;
    self.dragOrigin =
        [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
    self.dragAnchor = self.dragOrigin;
    if (self.autoSelect) {
      self.autoSelectPending = YES;
      self.autoSelectClickOrigin = CGPointMake(positionX, positionY);
    }
    *forceUpdate = YES;
    return;
  }
  if (activePart == kOSCRotateHandle && self.selectedPathIndices.count > 0) {
    [self mouseDownOnRotateHandle:positionX
                                y:positionY
                      forceUpdate:forceUpdate];
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

  // --- Pen-mode element interactions ---
  if (activePart == kOSCClosePath && active) {
    [self penClosePath:active forceUpdate:forceUpdate];
    return;
  }
  if (activePart >= kOSCPathPointBase && activePart < kOSCInHandleBase &&
      active) {
    NSInteger idx = activePart - kOSCPathPointBase;
    if (modifiers & kFxModifierKey_OPTION) {
      [self penDeletePoint:idx active:active forceUpdate:forceUpdate];
      return;
    }
    [self penClickPoint:idx active:active forceUpdate:forceUpdate];
    return;
  }
  if (activePart >= kOSCInHandleBase && activePart < kOSCPathSegmentBase) {
    [self penClickHandle:activePart forceUpdate:forceUpdate];
    return;
  }
  if (activePart >= kOSCPathSegmentBase && active) {
    [self penInsertOnSegment:activePart
                   positionX:positionX
                   positionY:positionY
                      active:active
                 forceUpdate:forceUpdate];
    return;
  }

  // --- Mode dispatch for canvas / empty-area clicks ---

  if (isCursorMode) {
    [self handleCursorMouseDownX:positionX
                               y:positionY
                       modifiers:modifiers
                     forceUpdate:forceUpdate];
    return;
  }

  if (isPenMode) {
    // CMD+click: temporary cursor behavior (select/deselect paths).
    if (modifiers & kFxModifierKey_COMMAND) {
      [self handleCursorMouseDownX:positionX
                                 y:positionY
                         modifiers:modifiers
                       forceUpdate:forceUpdate];
      return;
    }

    // OPT+click on canvas: force-start a new path.
    if (modifiers & kFxModifierKey_OPTION) {
      active = nil;
      self.activePathIndex = -1;
    }

    // If marquee-selected points exist, first click clears them.
    if (self.selectedPoints.count > 0) {
      [self.selectedPoints removeAllIndexes];
      *forceUpdate = YES;
      return;
    }

    [self penAddPointX:positionX
                     y:positionY
                active:active
           forceUpdate:forceUpdate];
    return;
  }

  // --- Shape tools (rect, ellipse, line) — start drag preview ---
  simd_float2 objPos =
      [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
  self.rectStart = objPos;
  self.dragOrigin = objPos;
  self.dragIsRect = (self.toolbar.activeTag == kOSCToolbarRect);
  self.dragIsEllipse = (self.toolbar.activeTag == kOSCToolbarEllipse);
  self.dragIsLine = (self.toolbar.activeTag == kOSCToolbarLine);
  *forceUpdate = YES;
}

// ===========================================================================
// Cursor mode handler
// ===========================================================================

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
    // Selecting a path clears any pen-mode point selection.
    [self.selectedPoints removeAllIndexes];

    // Double-click on already-selected path → enter pen mode for editing.
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL wasSelected = [self.selectedPathIndices containsIndex:nearPath];
    if (wasSelected && !shiftDown && (now - self.lastClickTime) < 0.35) {
      self.toolbar.activeTag = kOSCToolbarPen;
      self.activePathIndex = nearPath;
      self.lastClickTime = 0;
      *forceUpdate = YES;
      return;
    }
    self.lastClickTime = now;

    // Snapshot previous selection before modifying, to avoid race with
    // drawOSC updating lst.selectedIndices on the render thread.
    NSIndexSet *prevSel = [self.selectedPathIndices copy];

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
    [self syncStrokeParamsToSelectionWithPrevious:prevSel];
    self.dragIsPath = YES;
    self.dragOrigin =
        [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
    *forceUpdate = YES;
    return;
  }

  if (!shiftDown) {
    KKBezierPath *prev = KKSelectedPath(self.selectedPathIndices, self.paths);
    if (prev) {
      id<FxParameterRetrievalAPI_v6> paramGetAPI = [self.apiManager
          apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      id<FxParameterSettingAPI_v5> paramSetAPI =
          [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      KKParamsToSelectedPaths(paramGetAPI, self.selectedPathIndices,
                              self.paths);
      [self writePaths:self.paths];
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

@end
#pragma clang diagnostic pop
