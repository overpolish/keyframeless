/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "OSC_Private.h"
#import "ObjectParams.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation CanvasOSC (Input)

- (void)flushInspectorParamsToSelectedPaths {
  if (self.toolbar.activeTag == kOSCToolbarCursor) {
    id<FxParameterRetrievalAPI_v6> pGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    KKParamsToSelectedPaths(pGetAPI, self.selectedPathIndices, self.paths);
  }
}

- (void)handleBooleanOp:(NSInteger)activePart {
  self.paths = [self readPaths];
  [self flushInspectorParamsToSelectedPaths];
  if (self.selectedPathIndices.count < 2)
    return;

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
  if (operands.count < 2)
    return;

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
  if (!result)
    return;

  NSUInteger insertIdx = operandIndices.firstIndex;
  [operandIndices enumerateIndexesWithOptions:NSEnumerationReverse
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

- (void)handleOutlineOp {
  self.paths = [self readPaths];
  [self flushInspectorParamsToSelectedPaths];

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
  if (operands.count == 0)
    return;

  NSArray<KKBezierPath *> *outlines = KKPathStrokeToOutline(
      operands, (CGFloat)self.imageWidth, (CGFloat)self.imageHeight);
  if (outlines.count == 0)
    return;

  __block NSUInteger outlineIdx = 0;
  [operandIndices enumerateIndexesWithOptions:NSEnumerationReverse
                                   usingBlock:^(NSUInteger idx, BOOL *stop) {
                                     self.paths[idx].strokeEnabled = NO;
                                     NSUInteger insertAt = idx + 1;
                                     [self.paths
                                         insertObject:outlines[outlineIdx]
                                              atIndex:insertAt];
                                     outlineIdx++;
                                   }];

  [self writePaths:self.paths];
  [self.selectedPathIndices removeAllIndexes];
  self.activePathIndex = -1;
  [self syncStrokeParamsToSelectionWithPrevious:[NSIndexSet indexSet]];
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {

  if (kkIsOSCPositionPath(activePart)) {
    [self mouseDownOnPositionPathPart:activePart
                            positionX:positionX
                            positionY:positionY
                            modifiers:modifiers
                          forceUpdate:forceUpdate
                               atTime:time];
    return;
  }

  if (activePart == kOSCTransformPosition) {
    self.transformPositionDragging = YES;
    self.transformPositionDragStartX = positionX;
    self.transformPositionDragStartY = positionY;
    self.transformPositionDragStartObj =
        [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
    self.transformPositionDragStartParam =
        [self objectPositionForParam:kParamPosition atTime:time];
    id<FxOnScreenControlAPI_v4> oscAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    [oscAPI setCursor:[NSCursor closedHandCursor]];
    *forceUpdate = YES;
    return;
  }

  if (activePart == kOSCTransformScaleRing) {
    // MM pattern: double-click links axes to the smaller value.
    NSTimeInterval now = CACurrentMediaTime();
    if ((now - self.scaleRingLastClickTime) < 0.35) {
      id<FxParameterRetrievalAPI_v6> getAPI = [self.apiManager
          apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      double sx = 1.0, sy = 1.0;
      [getAPI getFloatValue:&sx fromParameter:kParamScaleX atTime:time];
      [getAPI getFloatValue:&sy fromParameter:kParamScaleY atTime:time];
      if (sx != sy) {
        double smaller = fmin(sx, sy);
        id<FxCustomParameterActionAPI_v4> actAPI = [self.apiManager
            apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
        id<FxParameterSettingAPI_v5> setAPI = [self.apiManager
            apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
        [actAPI startAction:self];
        [setAPI setFloatValue:smaller toParameter:kParamScaleX atTime:time];
        [setAPI setFloatValue:smaller toParameter:kParamScaleY atTime:time];
        [actAPI endAction:self];
        *forceUpdate = YES;
      }
      self.scaleRingLastClickTime = 0;
      return;
    }
    self.scaleRingLastClickTime = now;

    self.scaleRingDragging = YES;
    CGPoint anchorCanvas = [self transformAnchorCanvasPointAtTime:time];
    double dx = positionX - anchorCanvas.x;
    double dy = positionY - anchorCanvas.y;
    self.scaleRingDragStartDist = sqrt(dx * dx + dy * dy);
    self.scaleRingDragStartAngle = atan2(fabs(dy), fabs(dx));
    id<FxParameterRetrievalAPI_v6> getAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    double sx = 1.0, sy = 1.0;
    [getAPI getFloatValue:&sx fromParameter:kParamScaleX atTime:time];
    [getAPI getFloatValue:&sy fromParameter:kParamScaleY atTime:time];
    self.scaleRingDragStartValX = sx;
    self.scaleRingDragStartValY = sy;
    [self.scaleRingOSC updateCursorForMouseX:positionX positionY:positionY];
    *forceUpdate = YES;
    return;
  }

  if (activePart == kOSCTransformAnchor) {
    self.anchorDragging = YES;
    id<FxOnScreenControlAPI_v4> oscAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    [oscAPI setCursor:[NSCursor openHandCursor]];
    *forceUpdate = YES;
    return;
  }

  if (activePart == kOSCTransformRotZ) {
    self.rotZDragging = YES;
    CGPoint anchorCanvas = [self transformAnchorCanvasPointAtTime:time];
    double dx = positionX - anchorCanvas.x;
    double dy = positionY - anchorCanvas.y;
    self.rotZDragPrevAngle = atan2(-dy, dx);
    double rz = 0.0;
    id<FxParameterRetrievalAPI_v6> getAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    [getAPI getFloatValue:&rz fromParameter:kParamRotation atTime:time];
    self.rotZDragAccum = rz;
    id<FxOnScreenControlAPI_v4> oscAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    [oscAPI setCursor:[NSCursor crosshairCursor]];
    *forceUpdate = YES;
    return;
  }

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
    {
      id<FxParameterSettingAPI_v5> toolSetAPI =
          [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      [toolSetAPI setIntValue:(int)activePart
                  toParameter:kParamLastTool
                       atTime:kCMTimeZero];
    }
    *forceUpdate = YES;
    return;
  }
  if (activePart == kOSCGridToggle) {
    self.gridEnabled = !self.gridEnabled;
    id<FxParameterSettingAPI_v5> setAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    [setAPI setBoolValue:self.gridEnabled
             toParameter:kParamGridEnabled
                  atTime:kCMTimeZero];
    *forceUpdate = YES;
    return;
  }
  if (activePart == kOSCGridStepper) {
    self.stepperDragging = YES;
    self.stepperDragOriginY = positionY;
    self.stepperAccumulatedDelta = 0;
    self.stepperDragStartValue = self.gridSpacing;
    self.stepperShiftWasDown = (modifiers & kFxModifierKey_SHIFT) != 0;
    return;
  }
  if (activePart == kOSCSnapToggle) {
    self.snapToGrid = !self.snapToGrid;
    id<FxParameterSettingAPI_v5> setAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    [setAPI setBoolValue:self.snapToGrid
             toParameter:kParamSnapToGrid
                  atTime:kCMTimeZero];
    *forceUpdate = YES;
    return;
  }
  if (activePart == kOSCGridAdaptive) {
    self.gridAdaptive = !self.gridAdaptive;
    id<FxParameterSettingAPI_v5> setAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    [setAPI setBoolValue:self.gridAdaptive
             toParameter:kParamGridAdaptive
                  atTime:kCMTimeZero];
    *forceUpdate = YES;
    return;
  }
  if (activePart == -1)
    return;

  // Path combine actions.
  if (activePart == kOSCPathUnion || activePart == kOSCPathSubtract ||
      activePart == kOSCPathIntersect || activePart == kOSCPathXOR) {
    [self handleBooleanOp:activePart];
    *forceUpdate = YES;
    return;
  }

  // Stroke-to-path (outline) action.
  if (activePart == kOSCPathOutline) {
    [self handleOutlineOp];
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
  objPos = [self snapToGridPosition:objPos];
  self.rectStart = objPos;
  self.dragOrigin = objPos;
  self.dragIsRect = (self.toolbar.activeTag == kOSCToolbarRect);
  self.dragIsEllipse = (self.toolbar.activeTag == kOSCToolbarEllipse);
  self.dragIsLine = (self.toolbar.activeTag == kOSCToolbarLine);
  *forceUpdate = YES;
}

- (void)mouseMovedAtPositionX:(double)positionX
                    positionY:(double)positionY
                   activePart:(NSInteger)activePart
                    modifiers:(FxModifierKeys)modifiers
                  forceUpdate:(BOOL *)forceUpdate
                       atTime:(CMTime)time {
  self.hoverCanvasPosition = CGPointMake(positionX, positionY);
  BOOL needsIndicator = self.toolbar.activeTag != kOSCToolbarCursor &&
                        self.toolbar.activeTag != 0 && self.gridEnabled &&
                        self.snapToGrid;
  if (needsIndicator)
    *forceUpdate = YES;
}

@end
#pragma clang diagnostic pop
