/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC_Private.h"
#import "ObjectParams.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation CanvasOSC (Input)

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
    // Flush pending inspector param edits into the in-memory paths so
    // operations see the latest stroke/fill values, not stale blob data.
    if (self.toolbar.activeTag == kOSCToolbarCursor) {
      id<FxParameterRetrievalAPI_v6> pGetAPI = [self.apiManager
          apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      KKParamsToSelectedPaths(pGetAPI, self.selectedPathIndices, self.paths);
    }
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
    // Flush pending inspector param edits (e.g. stroke width) into the
    // in-memory paths before converting, so the outline uses current values.
    if (self.toolbar.activeTag == kOSCToolbarCursor) {
      id<FxParameterRetrievalAPI_v6> pGetAPI = [self.apiManager
          apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      KKParamsToSelectedPaths(pGetAPI, self.selectedPathIndices, self.paths);
    }
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

@end
#pragma clang diagnostic pop
