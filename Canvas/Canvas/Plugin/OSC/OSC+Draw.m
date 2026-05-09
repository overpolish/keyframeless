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

  // Re-read on every tick (not just first restore) so cmd-Z of a tool
  // change reverts the toolbar visual — the int-slider param's value
  // changes underneath us, and there's no parameterChanged callback in
  // OSC scope to react to it.
  {
    int toolVal = (int)kOSCToolbarCursor;
    [getAPI getIntValue:&toolVal
          fromParameter:kParamLastTool
                 atTime:kCMTimeZero];
    if (toolVal > 0 && self.toolbar.activeTag != toolVal)
      self.toolbar.activeTag = toolVal;
    self.restoredTool = YES;
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
  // Skip when a pending selection was just consumed — that pending came
  // from layer-list / sequencer / kParamCanvasSelection echo and is
  // authoritative (in particular, multi-select pending must not be
  // collapsed by kParamLastSelectedIndex's single-index value).
  BOOL undoDetected = NO;
  if (!uiSelection) {
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
    // kParamCanvasSelection is the authoritative multi-select store; if it
    // matches the in-memory selection, the kParamLastSelectedIndex / memIdx
    // disagreement is benign (e.g. paramLastSel=-1 because layer-list
    // multi-select doesn't write it, while the multi-set is intact).
    BOOL canvasSelMatches = NO;
    if (paramIdx != memIdx) {
      NSString *selStr = nil;
      [paramGetAPI getStringParameterValue:&selStr
                             fromParameter:kParamCanvasSelection];
      NSIndexSet *parsedSel = KKParseCanvasSelection(selStr, self.paths);
      canvasSelMatches = [parsedSel isEqualToIndexSet:self.selectedPathIndices];
    }
    if (paramIdx != memIdx && !canvasSelMatches) {
      undoDetected = YES;
      // Previously reset `lst.visHash = 0` here to force a visibility
      // refresh on undo. With the cmd-Z echo handlers (Plugin.m kParam
      // *Style/*Enabled/Expanded/CanvasSelection) now running
      // KKParamSyncApplyFromSnapshotInScope synchronously inside FCP's
      // own revert scope, visHash is already in sync after cmd-Z. Leaving
      // the reset in caused this draw tick (which runs ~30ms after
      // cmd-Z) to wipe vh, then drawOSC's store writes below fired the
      // async observer in a fresh action scope which re-wrote flags as
      // a separate undo entry — making one cmd-Z silently take 2-3.
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
    // Only push selection when OSC actually has a path selection. OSC can't
    // represent group selection (selectedPathIndices is path-indices only),
    // so when it's empty the authoritative selection lives elsewhere
    // (kParamCanvasSelection echo handler pushes group selections to the
    // store). Pushing empty here would clobber that group selection on the
    // very next drawOSC tick after a cmd-Z that restored a group.
    NSIndexSet *currentStoreSel = store.snapshot.selectedIndices;
    BOOL storeHoldsGroup = NO;
    if (currentStoreSel.count == 1) {
      NSUInteger idx = currentStoreSel.firstIndex;
      if (idx < self.paths.count && self.paths[idx].isGroup)
        storeHoldsGroup = YES;
    }
    if (!(self.selectedPathIndices.count == 0 && storeHoldsGroup))
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
  // Use the transform-aware target so a group-only selection still flushes
  // inspector params to the group's own transform fields (translateX/Y,
  // rotation, scale). Render walks parentGroupID and applies group
  // transforms to descendants — so the group's own transform is what
  // makes "move group" actually move the children.
  KKBezierPath *transformTarget =
      KKSelectedTransformTarget(self.selectedPathIndices, self.paths);
  if (selPath || transformTarget) {
    BOOL isCursorMode =
        (self.toolbar.activeTag == kOSCToolbarCursor) || hideOSCPending;
    if (isCursorMode) {
      id<FxParameterRetrievalAPI_v6> paramGetAPI = [self.apiManager
          apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      KKParamsToSelectedPaths(paramGetAPI, self.selectedPathIndices,
                              self.paths);
    }
    if (isCursorMode && selPath.rectShape && !selPath.isImage &&
        selPath.count >= 4) {
      simd_float2 bmin, bmax;
      [self boundsOfPath:selPath min:&bmin max:&bmax];
      CGPoint cMin = [self canvasPointFromObjectPoint:bmin];
      CGPoint cMax = [self canvasPointFromObjectPoint:bmax];
      float cW = (float)fabs(cMax.x - cMin.x);
      float cH = (float)fabs(cMax.y - cMin.y);
      [selPath.rectShape applyToPath:selPath canvasWidth:cW canvasHeight:cH];
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
  // 2+ non-image, non-group paths → full toolbar (boolean ops +
  // stroke-to-path). 1 non-image, non-group path     → single-button toolbar
  // (stroke-to-path).
  BOOL showPathToolbar = NO;
  BOOL showPathToolbarSingle = NO;
  if (self.toolbar.activeTag == kOSCToolbarCursor &&
      self.selectedPathIndices.count >= 1) {
    __block NSUInteger pathCount = 0;
    [self.selectedPathIndices
        enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
          if (idx < self.paths.count && !self.paths[idx].isImage &&
              !self.paths[idx].isGroup)
            pathCount++;
        }];
    if (pathCount >= 2)
      showPathToolbar = YES;
    else if (pathCount == 1)
      showPathToolbarSingle = YES;
  }
  if (showPathToolbar || showPathToolbarSingle) {
    NSRect mainFrame = self.toolbar.toolbarFrame;
    CGFloat margin = mainFrame.size.height + kPathToolbarGap + 8.0;
    if (showPathToolbar)
      self.pathToolbar.bottomMargin = margin;
    else
      self.pathToolbarSingle.bottomMargin = margin;
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
  if (showPathToolbarSingle)
    [self.pathToolbarSingle drawWithDestinationImage:destinationImage];
}

@end

@implementation CanvasOSC (TransformOSC)

- (BOOL)isTransformPositionOSCVisibleAtTime:(CMTime)time {
  KKBezierPath *p = [self selectedTransformablePath];
  if (!p)
    return NO;
  return [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                        label:@"Position"
                                     groupKey:p.layerID];
}

- (BOOL)isScaleRingOSCVisibleAtTime:(CMTime)time {
  KKBezierPath *p = [self selectedTransformablePath];
  if (!p)
    return NO;
  return [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                        label:@"Scale"
                                     groupKey:p.layerID];
}

- (BOOL)isAnchorOSCVisibleAtTime:(CMTime)time {
  KKBezierPath *p = [self selectedTransformablePath];
  if (!p)
    return NO;
  return [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                        label:@"Anchor"
                                     groupKey:p.layerID];
}

- (BOOL)isRotZOSCVisibleAtTime:(CMTime)time {
  KKBezierPath *p = [self selectedTransformablePath];
  if (!p)
    return NO;
  return [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                        label:@"Rot Z"
                                     groupKey:p.layerID];
}

- (BOOL)_isRotRingVisibleForLabel:(NSString *)label {
  KKBezierPath *p = [self selectedTransformablePath];
  if (!p)
    return NO;
  return [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                        label:label
                                     groupKey:p.layerID];
}

- (BOOL)isRotXRingOSCVisibleAtTime:(CMTime)time {
  return [self _isRotRingVisibleForLabel:@"Rot X"];
}

- (BOOL)isRotYRingOSCVisibleAtTime:(CMTime)time {
  return [self _isRotRingVisibleForLabel:@"Rot Y"];
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

- (CGPoint)transformAnchorCanvasPointAtTime:(CMTime)time {
  // Anchor convention matches Position's: bbox-center is neutral, the param
  // value is an object-space offset on top of that. The visual handle also
  // includes the per-layer translation so the pivot tracks the layer.
  KKBezierPath *p = [self selectedTransformablePath];
  if (!p)
    return CGPointZero;
  simd_float2 center = [self bboxCenterOfPath:p];
  simd_float2 anchorOffset = [self objectPositionForParam:kParamAnchor
                                                   atTime:time];
  simd_float2 paramPos = [self objectPositionForParam:kParamPosition
                                               atTime:time];
  simd_float2 translation = paramPos - (simd_float2){0.5f, 0.5f};
  return
      [self canvasPointFromObjectPoint:(center + anchorOffset + translation)];
}

- (void)getScaleRingRadiiAtTime:(CMTime)time
                             rx:(CGFloat *)outRx
                             ry:(CGFloat *)outRy {
  CGPoint c0 = [self canvasPointFromObjectPoint:(simd_float2){0, 0}];
  CGPoint c1 = [self canvasPointFromObjectPoint:(simd_float2){1, 1}];
  CGFloat minDim = MIN((CGFloat)fabs(c1.x - c0.x), (CGFloat)fabs(c1.y - c0.y));
  double sx = 1.0, sy = 1.0;
  id<FxParameterRetrievalAPI_v6> api =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  [api getFloatValue:&sx fromParameter:kParamScaleX atTime:time];
  [api getFloatValue:&sy fromParameter:kParamScaleY atTime:time];
  if (outRx)
    *outRx = minDim * 0.1 * MAX(0.05, sx);
  if (outRy)
    *outRy = minDim * 0.1 * MAX(0.05, sy);
}

- (void)drawTransformOSCWithDestinationImage:(FxImageTile *)dest
                                      atTime:(CMTime)time {
  BOOL posVisible = [self isTransformPositionOSCVisibleAtTime:time];
  BOOL scaleVisible = [self isScaleRingOSCVisibleAtTime:time];
  BOOL anchorVisible = [self isAnchorOSCVisibleAtTime:time];
  BOOL rotZVisible = [self isRotZOSCVisibleAtTime:time];
  // MM convention: Rot X / Rot Y rings show when their lane toggle is on,
  // OR Opt is held, OR they're currently hovered/being dragged. This lets
  // users grab them even with the lane OSC default-off.
  CGEventFlags flags =
      CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
  // Opt only reveals the X/Y rings when Rot Z is already visible — that's
  // the signal the user is using the transform OSC at all. Otherwise Opt
  // would surface them in unrelated cursor-mode contexts.
  BOOL optHeld = ((flags & kCGEventFlagMaskAlternate) != 0) && rotZVisible;
  BOOL rotXShown = [self isRotXRingOSCVisibleAtTime:time] || optHeld ||
                   self.rotXRingDragging || self.rotXRingHovered;
  BOOL rotYShown = [self isRotYRingOSCVisibleAtTime:time] || optHeld ||
                   self.rotYRingDragging || self.rotYRingHovered;
  if (!posVisible && !scaleVisible && !anchorVisible && !rotZVisible &&
      !rotXShown && !rotYShown)
    return;

  if (posVisible) {
    CGPoint pos = [self transformPositionCanvasPointAtTime:time];
    [self.transformPositionOSC
        drawAtCanvasPosition:pos
                   isHovered:self.transformPositionHovered
                    isActive:self.transformPositionDragging
            destinationImage:dest
                      atTime:time];
  }

  if (rotXShown || rotYShown) {
    CGPoint anchorCanvas = [self transformAnchorCanvasPointAtTime:time];
    void (^drawRotRing)(KKRingOSC *, BOOL, BOOL) =
        ^(KKRingOSC *ring, BOOL hovered, BOOL active) {
          ring.center = anchorCanvas;
          [ring drawAtCanvasPosition:anchorCanvas
                           isHovered:hovered
                            isActive:active
                    destinationImage:dest
                              atTime:time];
        };
    if (rotXShown)
      drawRotRing(self.rotXRingOSC, self.rotXRingHovered,
                  self.rotXRingDragging);
    if (rotYShown)
      drawRotRing(self.rotYRingOSC, self.rotYRingHovered,
                  self.rotYRingDragging);
  }

  if (scaleVisible || anchorVisible || rotZVisible) {
    CGPoint anchorCanvas = [self transformAnchorCanvasPointAtTime:time];
    if (rotZVisible) {
      double rz = 0.0;
      id<FxParameterRetrievalAPI_v6> api = [self.apiManager
          apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      [api getFloatValue:&rz fromParameter:kParamRotation atTime:time];
      self.rotZOSC.center = anchorCanvas;
      self.rotZOSC.angle = (float)rz;
      [self.rotZOSC drawAtCanvasPosition:anchorCanvas
                               isHovered:self.rotZHovered
                                isActive:self.rotZDragging
                        destinationImage:dest
                                  atTime:time];
    }
    if (scaleVisible) {
      CGFloat rx = 0, ry = 0;
      [self getScaleRingRadiiAtTime:time rx:&rx ry:&ry];
      self.scaleRingOSC.center = anchorCanvas;
      self.scaleRingOSC.ringRadius = (float)rx;
      self.scaleRingOSC.ringRadiusY = (float)ry;
      [self.scaleRingOSC drawAtCanvasPosition:anchorCanvas
                                    isHovered:self.scaleRingHovered
                                     isActive:self.scaleRingDragging
                             destinationImage:dest
                                       atTime:time];
    }
    if (anchorVisible) {
      [self.anchorOSC drawAtCanvasPosition:anchorCanvas
                                 isHovered:self.anchorHovered
                                  isActive:self.anchorDragging
                          destinationImage:dest
                                    atTime:time];
    }
  }
}

@end
#pragma clang diagnostic pop
