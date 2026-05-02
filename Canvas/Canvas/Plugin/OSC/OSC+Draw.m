/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "LayerList_Private.h"
#import "OSC_Private.h"
#import "ObjectParams.h"

static const CGFloat kPathToolbarGap = 6.0;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation CanvasOSC (Draw)

- (void)restoreToolbarStateFromParams {
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  BOOL gridVal = NO;
  [getAPI getBoolValue:&gridVal
         fromParameter:kParamGridEnabled
                atTime:kCMTimeZero];
  self.gridEnabled = gridVal;

  int spacingVal = 10;
  [getAPI getIntValue:&spacingVal
        fromParameter:kParamGridSpacing
               atTime:kCMTimeZero];
  if (spacingVal < 1)
    spacingVal = 1;
  if (spacingVal > 1000)
    spacingVal = 1000;
  self.gridSpacing = spacingVal;

  BOOL adaptiveVal = YES;
  [getAPI getBoolValue:&adaptiveVal
         fromParameter:kParamGridAdaptive
                atTime:kCMTimeZero];
  self.gridAdaptive = adaptiveVal;

  BOOL snapVal = NO;
  [getAPI getBoolValue:&snapVal
         fromParameter:kParamSnapToGrid
                atTime:kCMTimeZero];
  self.snapToGrid = snapVal;

  if (!self.restoredTool) {
    self.restoredTool = YES;
    int toolVal = (int)kOSCToolbarCursor;
    [getAPI getIntValue:&toolVal
          fromParameter:kParamLastTool
                 atTime:kCMTimeZero];
    if (toolVal > 0)
      self.toolbar.activeTag = toolVal;
  }
}

- (void)syncGridToolbarState {
  self.gridToolbar.activeTag = self.gridEnabled ? kOSCGridToggle : 0;
  self.gridToolbar.secondaryActiveTag =
      self.gridAdaptive ? kOSCGridAdaptive : 0;
  self.gridToolbar.tertiaryActiveTag = self.snapToGrid ? kOSCSnapToggle : 0;
  self.gridToolbar.items[2].iconName = self.gridAdaptive
                                           ? @"squareshape.split.2x2.dotted"
                                           : @"squareshape.split.2x2";
  self.gridToolbar.items[2].shortcutLabel =
      self.gridAdaptive ? @"Auto" : @"Static";
  self.gridToolbar.items[3].shortcutLabel =
      [NSString stringWithFormat:@"%ld", (long)self.gridSpacing];
}

- (BOOL)syncStoreState {
  NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
  if (!uuid)
    return NO;

  KKLayerInstanceState *lst = KKLayerStateForUUID(uuid);
  KKCanvasStore *store = lst.store;

  // Consume pending selection from UI actions.
  NSIndexSet *uiSelection = KKCanvasConsumePendingSelection(uuid);
  if (uiSelection) {
    [self.selectedPathIndices removeAllIndexes];
    [self.selectedPathIndices addIndexes:uiSelection];
    if (uiSelection.count > 0)
      self.activePathIndex = (NSInteger)uiSelection.lastIndex;
    else
      self.activePathIndex = -1;
  }

  // Detect undo/redo: if kParamLastSelectedIndex disagrees with the
  // in-memory selection, undo restored a different selection state.
  BOOL undoDetected = NO;
  {
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    NSInteger paramIdx = KKReadSelectedIndex(paramGetAPI);
    __block NSInteger memIdx = -1;
    [self.selectedPathIndices
        enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
          if (idx < self.paths.count && !self.paths[idx].isGroup) {
            memIdx = (NSInteger)idx;
            *stop = YES;
          }
        }];
    if (paramIdx != memIdx) {
      undoDetected = YES;
      lst.visHash = 0;
      [self.selectedPathIndices removeAllIndexes];
      if (paramIdx >= 0 && (NSUInteger)paramIdx < self.paths.count) {
        [self.selectedPathIndices addIndex:(NSUInteger)paramIdx];
        self.activePathIndex = paramIdx;
      } else {
        self.activePathIndex = -1;
      }
    }
  }

  // Write path/selection/UI state to the store.
  NSString *readBlob = self.lastReadBlobString;
  NSString *storeBlob = self.storeBlobString;
  BOOL blobChanged =
      (readBlob != storeBlob && ![readBlob isEqualToString:storeBlob]);
  [store performBatch:^{
    if (blobChanged) {
      [store setPaths:self.paths];
      self.storeBlobString = self.lastReadBlobString;
    }
    [store setSelectedIndices:self.selectedPathIndices];
    [store setSoloActive:lst.soloActive];
    [store setEditing:lst.isEditing];
    [store setDragging:lst.isDragging];
    [store setCollapsedGroupIDs:lst.collapsedGroupIDs ?: [NSSet set]];
    if (undoDetected && self.activePathIndex >= 0 &&
        (NSUInteger)self.activePathIndex < self.paths.count) {
      KKBezierPath *p = self.paths[self.activePathIndex];
      if (!p.isGroup) {
        [store setStrokeEnabled:p.strokeEnabled];
        [store setFillEnabled:p.fillEnabled];
        [store setSketchEnabled:p.sketchEnabled];
      }
    }
    [store syncSelectedPathProperties];
  }];

  lst.selectedIndices = [self.selectedPathIndices copy];
  lst.uiSelection = lst.selectedIndices;
  return undoDetected;
}

- (BOOL)patchSelectedPathsFromParams {
  BOOL hideOSCPending = NO;
  {
    id<FxParameterRetrievalAPI_v6> hideGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    [hideGetAPI getBoolValue:&hideOSCPending
               fromParameter:kParamHideOSC
                      atTime:kCMTimeZero];
  }
  KKBezierPath *selPath = KKSelectedPath(self.selectedPathIndices, self.paths);
  if (selPath) {
    BOOL isCursorMode =
        (self.toolbar.activeTag == kOSCToolbarCursor) || hideOSCPending;
    if (isCursorMode) {
      id<FxParameterRetrievalAPI_v6> paramGetAPI = [self.apiManager
          apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      KKParamsToSelectedPaths(paramGetAPI, self.selectedPathIndices,
                              self.paths);
    }
    if (isCursorMode && selPath.isRect && !selPath.isImage &&
        selPath.count >= 4) {
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
  }
  return hideOSCPending;
}

- (void)drawOSCWithWidth:(NSInteger)width
                  height:(NSInteger)height
              activePart:(NSInteger)activePart
        destinationImage:(FxImageTile *)destinationImage
                  atTime:(CMTime)time {
  [KKPlugin multiStageDrawOSCTickForAPI:self.apiManager atTime:time];

  self.imageWidth = width;
  self.imageHeight = height;

  [self encodeRenderCommandsForDestinationImage:destinationImage
                                 canvasPosition:CGPointZero
                               clearDestination:YES
                                       commands:^(id<MTLRenderCommandEncoder> e,
                                                  CGPoint p, simd_uint2 v){
                                       }];

  [self restoreToolbarStateFromParams];
  [self syncGridToolbarState];

  self.paths = [self readPaths];

  // Determine whether path toolbar should show.
  BOOL showPathToolbar = NO;
  if (self.toolbar.activeTag == kOSCToolbarCursor &&
      self.selectedPathIndices.count >= 2) {
    __block NSUInteger pathCount = 0;
    [self.selectedPathIndices
        enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
          if (idx < self.paths.count && !self.paths[idx].isImage &&
              !self.paths[idx].isGroup)
            pathCount++;
        }];
    showPathToolbar = (pathCount >= 2);
  }
  if (showPathToolbar) {
    NSRect mainFrame = self.toolbar.toolbarFrame;
    self.pathToolbar.bottomMargin =
        mainFrame.size.height + kPathToolbarGap + 8.0;
  }

  [self syncStoreState];
  BOOL hideOSCPending = [self patchSelectedPathsFromParams];

  if (hideOSCPending) {
    self.toolbar.activeTag = 0;
    return;
  }
  if (self.toolbar.activeTag == 0)
    self.toolbar.activeTag = kOSCToolbarCursor;

  simd_float4 strokeColor = [[NSColor systemRedColor] simdFloat4];
  simd_float4 dimColor = strokeColor;
  dimColor.w = 0.3f;

  BOOL isCursorMode = (self.toolbar.activeTag == kOSCToolbarCursor);
  BOOL isPenMode = (self.toolbar.activeTag == kOSCToolbarPen);

  // Draw grid and snap indicator.
  [self drawGridWithDestinationImage:destinationImage];
  [self drawGridSnapIndicatorForCursorMode:isCursorMode
                          destinationImage:destinationImage];

  // Draw paths.
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

  // Boolean preview overlay.
  if ([self shouldShowBooleanPreview:isCursorMode])
    [self drawBooleanPreviewWithDestinationImage:destinationImage];

  // Selection handles.
  if (isCursorMode && self.selectedPathIndices.count > 0) {
    if (self.dragIsRotation) {
      [self drawRotatedBoundingBoxWithDestinationImage:destinationImage
                                                atTime:time];
    } else {
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
  }

  // Marquee and shape previews.
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

  // Snap guides.
  [self drawAlignmentGuidesWithDestinationImage:destinationImage];
  [self drawSpacingGuidesWithDestinationImage:destinationImage];

  // Per-layer Transform OSC arc (position handle).
  [self drawTransformOSCWithDestinationImage:destinationImage atTime:time];
  // Position-lane motion path (between transition keyframes).
  [self drawPositionPathsAtTime:time destinationImage:destinationImage];

  // Toolbars on top.
  [self.toolbar drawWithDestinationImage:destinationImage];
  [self.gridToolbar drawWithDestinationImage:destinationImage];
  if (showPathToolbar)
    [self.pathToolbar drawWithDestinationImage:destinationImage];
}

@end

@implementation CanvasOSC (TransformOSC)

- (BOOL)isTransformPositionOSCVisibleAtTime:(CMTime)time {
  if (![self selectedTransformablePath])
    return NO;
  return [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                        label:@"Position"];
}

- (CGPoint)transformPositionCanvasPointAtTime:(CMTime)time {
  // Center the arc on the selected layer (its bbox center + translation
  // offset), so dragging always grabs the visual layer rather than the
  // canvas center.
  KKBezierPath *p = [self selectedTransformablePath];
  if (!p)
    return CGPointZero;
  simd_float2 center = [self bboxCenterOfPath:p];
  // Sample the live Position param so the OSC tracks animated values.
  simd_float2 paramPos = [self objectPositionForParam:kParamPosition
                                               atTime:time];
  simd_float2 translation = paramPos - (simd_float2){0.5f, 0.5f};
  return [self canvasPointFromObjectPoint:(center + translation)];
}

- (void)drawTransformOSCWithDestinationImage:(FxImageTile *)dest
                                      atTime:(CMTime)time {
  if (![self isTransformPositionOSCVisibleAtTime:time])
    return;
  CGPoint pos = [self transformPositionCanvasPointAtTime:time];
  [self.transformPositionOSC drawAtCanvasPosition:pos
                                        isHovered:self.transformPositionHovered
                                         isActive:self.transformPositionDragging
                                 destinationImage:dest
                                           atTime:time];
}

@end
#pragma clang diagnostic pop
