/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "LayerList_Private.h"
#import "OSC_Private.h"
#import "ObjectParams.h"

static const CGFloat kPathToolbarGap = 6.0;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation CanvasOSC (Draw)

- (void)drawOSCWithWidth:(NSInteger)width
                  height:(NSInteger)height
              activePart:(NSInteger)activePart
        destinationImage:(FxImageTile *)destinationImage
                  atTime:(CMTime)time {
  self.imageWidth = width;
  self.imageHeight = height;

  [self encodeRenderCommandsForDestinationImage:destinationImage
                                 canvasPosition:CGPointZero
                               clearDestination:YES
                                       commands:^(id<MTLRenderCommandEncoder> e,
                                                  CGPoint p, simd_uint2 v){
                                       }];

  // Restore persisted toolbar state from params.
  {
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

  // Sync grid toolbar state (drawing deferred to end of method).
  {
    self.gridToolbar.activeTag = self.gridEnabled ? kOSCGridToggle : 0;
    self.gridToolbar.secondaryActiveTag =
        self.gridAdaptive ? kOSCGridAdaptive : 0;
    self.gridToolbar.tertiaryActiveTag = self.snapToGrid ? kOSCSnapToggle : 0;
    self.gridToolbar.items[2].iconName = self.gridAdaptive
                                             ? @"squareshape.split.2x2.dotted"
                                             : @"squareshape.split.2x2";
    self.gridToolbar.items[2].shortcutLabel =
        self.gridAdaptive ? @"Auto" : @"Static";

    // Set the stepper label to the current spacing value.
    self.gridToolbar.items[3].shortcutLabel =
        [NSString stringWithFormat:@"%ld", (long)self.gridSpacing];
  }

  self.paths = [self readPaths];

  // Determine whether path toolbar should show (drawing deferred to end).
  BOOL showPathToolbar = NO;
  {
    if (self.toolbar.activeTag == kOSCToolbarCursor &&
        self.selectedPathIndices.count >= 2) {
      __block NSUInteger pathCount = 0;
      [self.selectedPathIndices
          enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
            if (idx < self.paths.count && !self.paths[idx].isImage &&
                !self.paths[idx].isGroup) {
              pathCount++;
            }
          }];
      showPathToolbar = (pathCount >= 2);
    }
    if (showPathToolbar) {
      NSRect mainFrame = self.toolbar.toolbarFrame;
      self.pathToolbar.bottomMargin =
          mainFrame.size.height + kPathToolbarGap + 8.0;
    }
  }

  NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
  if (uuid) {
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
    // Sync in-memory selection from the param so drawOSC applies the
    // restored inspector params to the correct path.
    BOOL undoDetected = NO;
    {
      id<FxParameterRetrievalAPI_v6> paramGetAPI = [self.apiManager
          apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      NSInteger paramIdx = KKReadSelectedIndex(paramGetAPI);
      // Compare against the first non-group index in the selection, because
      // KKSaveSelectedIndex stores the index from KKSelectedPath which skips
      // groups.  Using firstIndex would mismatch when a group is selected,
      // causing the undo detector to clobber the group selection.
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
    // NOTE: expanded and enabled states are generally NOT set here — they
    // are owned by the UI callbacks (header toggles) and the initial seed.
    // Exception: on undo/redo, enabled states are synced from the restored
    // path since no UI callback fires to update them.
    //
    // Only call setPaths when the blob actually changed to avoid firing
    // KKStoreChangePaths every frame (freshly deserialized objects always
    // fail identity comparison).
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
      // On undo/redo, sync enabled flags from the restored path so
      // KKParamSyncApplyFromSnapshot builds correct visibility conditions.
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

    // Keep old selectedIndices in sync for code that still reads it.
    lst.selectedIndices = [self.selectedPathIndices copy];
    lst.uiSelection = lst.selectedIndices;
  }

  // Patch the selected path's in-memory stroke from current params so that
  // hit testing and OSC drawing use the live inspector values.
  // Also keep param row visibility in sync — ensures the inspector shows
  // per-object controls even if the panel wasn't visible during selection.
  BOOL hideOSCPending = NO;
  {
    id<FxParameterRetrievalAPI_v6> hideGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    [hideGetAPI getBoolValue:&hideOSCPending
               fromParameter:kParamHideOSC
                      atTime:kCMTimeZero];
  }
  // Patch selected paths from inspector params for rendering.
  // Param flag visibility is handled by KKCanvasRefreshLayerList above.
  {
    KKBezierPath *selPath =
        KKSelectedPath(self.selectedPathIndices, self.paths);
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
  }

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

  // Draw grid behind paths.
  if (self.gridEnabled && self.imageWidth > 0 && self.imageHeight > 0) {
    CGFloat spacing = (CGFloat)self.gridSpacing;

    // In adaptive mode, scale spacing by zoom so lines stay ~the same screen
    // distance apart regardless of zoom level.
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

    // Canvas-space bounds of the preview area for line endpoints.
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

    // Vertical lines (constant X) — only visible range.
    {
      NSInteger iStart = (NSInteger)ceilf(visMinX / objSpacingX);
      NSInteger iEnd = (NSInteger)floorf(visMaxX / objSpacingX);
      for (NSInteger i = iStart; i <= iEnd; i++) {
        float ox = i * objSpacingX;
        CGFloat rawX = [self canvasPointFromObjectPoint:(simd_float2){ox, 0}].x;
        CGFloat cx = floor(rawX) + 0.5;
        CGPoint top = {cx, canvasTop};
        CGPoint bot = {cx, canvasBottom};

        [self drawLineFrom:top
                          to:bot
                       color:gridColor
                   halfWidth:1.0f
            destinationImage:destinationImage];
      }
    }

    // Horizontal lines (constant Y) — only visible range.
    {
      NSInteger iStart = (NSInteger)ceilf(visMinY / objSpacingY);
      NSInteger iEnd = (NSInteger)floorf(visMaxY / objSpacingY);
      for (NSInteger i = iStart; i <= iEnd; i++) {
        float oy = i * objSpacingY;
        CGFloat rawY = [self canvasPointFromObjectPoint:(simd_float2){0, oy}].y;
        CGFloat cy = floor(rawY) + 0.5;
        CGPoint left = {canvasLeft, cy};
        CGPoint right = {canvasRight, cy};

        [self drawLineFrom:left
                          to:right
                       color:gridColor
                   halfWidth:1.0f
            destinationImage:destinationImage];
      }
    }
  }

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

  // Path operation preview overlay on hover.
  BOOL showBooleanPreview = isCursorMode && self.hoveredPathOp > 0 &&
                            ((self.hoveredPathOp == kOSCPathOutline &&
                              self.selectedPathIndices.count >= 1) ||
                             (self.hoveredPathOp != kOSCPathOutline &&
                              self.selectedPathIndices.count >= 2));
  if (showBooleanPreview) {
    // Compute preview result if not cached for this op.
    if (self.previewCachedOp != self.hoveredPathOp) {
      NSMutableArray<KKBezierPath *> *operands = [NSMutableArray array];
      [self.selectedPathIndices
          enumerateIndexesWithOptions:NSEnumerationReverse
                           usingBlock:^(NSUInteger idx, BOOL *stop) {
                             if (idx < self.paths.count &&
                                 !self.paths[idx].isImage &&
                                 !self.paths[idx].isGroup) {
                               [operands addObject:self.paths[idx]];
                             }
                           }];
      if (self.hoveredPathOp == kOSCPathOutline) {
        // Preview the outline result (use first outline as preview).
        NSArray<KKBezierPath *> *outlines = KKPathStrokeToOutline(
            operands, (CGFloat)self.imageWidth, (CGFloat)self.imageHeight);
        self.previewResultPath = outlines.firstObject;
      } else if (operands.count >= 2) {
        KKBooleanOp op;
        if (self.hoveredPathOp == kOSCPathUnion)
          op = KKBooleanOpUnion;
        else if (self.hoveredPathOp == kOSCPathSubtract)
          op = KKBooleanOpSubtract;
        else if (self.hoveredPathOp == kOSCPathIntersect)
          op = KKBooleanOpIntersect;
        else
          op = KKBooleanOpXOR;
        self.previewResultPath = KKPathBooleanApply(operands, op);
      } else {
        self.previewResultPath = nil;
      }
      self.previewCachedOp = self.hoveredPathOp;
      self.previewTexture = nil;
    }

    float ioW = [destinationImage.ioSurface width];
    float ioH = [destinationImage.ioSurface height];

    if (!self.previewTexture) {
      NSInteger pixelW = (NSInteger)ioW;
      NSInteger pixelH = (NSInteger)ioH;

      CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
      CGContextRef ctx =
          CGBitmapContextCreate(NULL, pixelW, pixelH, 8, pixelW * 4, cs,
                                (CGBitmapInfo)kCGImageAlphaPremultipliedLast |
                                    kCGBitmapByteOrder32Big);
      CGColorSpaceRelease(cs);

      if (ctx) {
        CGContextSetLineJoin(ctx, kCGLineJoinRound);
        CGContextSetLineCap(ctx, kCGLineCapRound);

        // Helper block: flatten a KKBezierPath to a CGPath in canvas space.
        // Canvas coords: X=0 left, Y=0 top. CGContext: Y=0 bottom.
        CGMutablePathRef (^canvasCGPath)(KKBezierPath *) = ^(KKBezierPath *p) {
          CGMutablePathRef cgp = CGPathCreateMutable();
          NSUInteger nc = p.contourCount;
          for (NSUInteger ci = 0; ci < nc; ci++) {
            NSRange r = [p contourRangeAtIndex:ci];
            NSUInteger cStart = r.location;
            NSUInteger cLen = r.length;
            if (cLen < 2)
              continue;
            NSUInteger segCount = p.closed ? cLen : (cLen - 1);
            for (NSUInteger i = 0; i < segCount; i++) {
              NSUInteger idx = cStart + i;
              NSUInteger nextIdx = cStart + ((i + 1) % cLen);
              for (NSUInteger s = 0; s <= 32; s++) {
                float t = (float)s / 32.0f;
                simd_float2 pos = [p evaluatePointAtIndex:idx
                                                nextIndex:nextIdx
                                                      atT:t];
                CGPoint cp = [self canvasPointFromObjectPoint:pos];
                // Flip Y for CGContext (Y=0 at bottom).
                CGFloat cy = cp.y;
                if (i == 0 && s == 0)
                  CGPathMoveToPoint(cgp, NULL, cp.x, cy);
                else
                  CGPathAddLineToPoint(cgp, NULL, cp.x, cy);
              }
            }
            if (p.closed)
              CGPathCloseSubpath(cgp);
          }
          return cgp;
        };

        // Red tint: selected paths (will be removed).
        [self.selectedPathIndices
            enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
              if (idx >= self.paths.count)
                return;
              KKBezierPath *p = self.paths[idx];
              if (p.isImage || p.isGroup || p.count < 2)
                return;
              CGMutablePathRef cgp = canvasCGPath(p);
              if (p.closed) {
                CGContextSetRGBFillColor(ctx, 1.0, 0.0, 0.0, 0.45);
                CGContextAddPath(ctx, cgp);
                CGContextFillPath(ctx);
              }
              CGPathRelease(cgp);
            }];

        // Green tint: result path (will remain).
        if (self.previewResultPath && self.previewResultPath.count >= 2) {
          KKBezierPath *rp = self.previewResultPath;
          // Inherit stroke width from first selected path.
          float sw = 8.0f;
          NSUInteger firstIdx = self.selectedPathIndices.firstIndex;
          if (firstIdx < self.paths.count)
            sw = self.paths[firstIdx].strokeWidth;
          [self.selectedPathIndices
              enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
                if (idx < self.paths.count && self.paths[idx].fillEnabled) {
                  *stop = YES;
                }
              }];
          CGMutablePathRef cgp = canvasCGPath(rp);
          if (rp.closed) {
            CGContextSetRGBFillColor(ctx, 0.0, 1.0, 0.0, 0.45);
            CGContextAddPath(ctx, cgp);
            CGContextFillPath(ctx);
          }
          CGPathRelease(cgp);
        }

        // Upload to texture.
        KKMetalDeviceCache *pvCache = [KKMetalDeviceCache sharedCache];
        id<MTLDevice> pvDevice =
            [pvCache deviceWithRegistryID:destinationImage.deviceRegistryID];
        MTLTextureDescriptor *desc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                         width:pixelW
                                        height:pixelH
                                     mipmapped:NO];
        desc.usage = MTLTextureUsageShaderRead;
        self.previewTexture = [pvDevice newTextureWithDescriptor:desc];
        [self.previewTexture replaceRegion:MTLRegionMake2D(0, 0, pixelW, pixelH)
                               mipmapLevel:0
                                 withBytes:CGBitmapContextGetData(ctx)
                               bytesPerRow:pixelW * 4];
        CGContextRelease(ctx);
      }
    }

    // Draw the preview overlay texture as a full-screen quad.
    if (self.previewTexture) {
      KKMetalDeviceCache *pvCache = [KKMetalDeviceCache sharedCache];
      uint64_t pvRegID = destinationImage.deviceRegistryID;
      MTLPixelFormat pvFmt =
          [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
      id<MTLRenderPipelineState> pvPS = [pvCache
          buildAndRegisterPipelineStateForPluginID:
              @"co.overpolish.keyframeless.Canvas.Preview"
                                        registryID:pvRegID
                                       pixelFormat:pvFmt
                                          bundleID:@"co.overpolish"
                                                    ".keyframeless"
                                                    ".KeyframelessKit"
                                      vertexShader:@"KKVertexShader"
                                    fragmentShader:@"KKLabelFragment"
                                         blendMode:
                                             KKBlendModePremultipliedAlpha];
      if (pvPS) {
        id<MTLCommandQueue> pvQueue =
            [pvCache commandQueueWithRegistryID:pvRegID pixelFormat:pvFmt];
        if (pvQueue) {
          id<MTLTexture> outTex = [destinationImage
              metalTextureForDevice:[pvCache deviceWithRegistryID:pvRegID]];
          id<MTLCommandBuffer> pvBuf = [pvQueue commandBuffer];
          [pvBuf enqueue];
          MTLRenderPassDescriptor *pvRPD =
              [MTLRenderPassDescriptor renderPassDescriptor];
          pvRPD.colorAttachments[0].texture = outTex;
          pvRPD.colorAttachments[0].loadAction = MTLLoadActionLoad;
          pvRPD.colorAttachments[0].storeAction = MTLStoreActionStore;
          id<MTLRenderCommandEncoder> pvEnc =
              [pvBuf renderCommandEncoderWithDescriptor:pvRPD];
          MTLViewport pvVP = {0, 0, ioW, ioH, -1.0, 1.0};
          [pvEnc setViewport:pvVP];
          [pvEnc setRenderPipelineState:pvPS];
          simd_uint2 vpSize = {(unsigned int)ioW, (unsigned int)ioH};
          [pvEnc setVertexBytes:&vpSize
                         length:sizeof(vpSize)
                        atIndex:KKVertexInputIndex_ViewportSize];

          float halfW = ioW / 2.0f;
          float halfH = ioH / 2.0f;
          KKVertex2D verts[6] = {
              {{-halfW, -halfH}, {0, 0}}, {{halfW, -halfH}, {1, 0}},
              {{halfW, halfH}, {1, 1}},   {{-halfW, -halfH}, {0, 0}},
              {{halfW, halfH}, {1, 1}},   {{-halfW, halfH}, {0, 1}},
          };
          [pvEnc setVertexBytes:verts
                         length:sizeof(verts)
                        atIndex:KKVertexInputIndex_Vertices];
          [pvEnc setFragmentTexture:self.previewTexture atIndex:0];
          [pvEnc drawPrimitives:MTLPrimitiveTypeTriangle
                    vertexStart:0
                    vertexCount:6];
          [pvEnc endEncoding];
          [pvBuf commit];
          [pvBuf waitUntilScheduled];
          [pvCache returnCommandQueueToCache:pvQueue];
        }
      }
    }
  }

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

  // Draw alignment snap guides.
  if (self.alignSnappedX || self.alignSnappedY) {
    CGPoint canvasTL2 = [self canvasPointFromObjectPoint:(simd_float2){0, 0}];
    CGPoint canvasBR2 = [self canvasPointFromObjectPoint:(simd_float2){1, 1}];
    CGFloat guideLeft = fmin(canvasTL2.x, canvasBR2.x);
    CGFloat guideRight = fmax(canvasTL2.x, canvasBR2.x);
    CGFloat guideTop = fmin(canvasTL2.y, canvasBR2.y);
    CGFloat guideBottom = fmax(canvasTL2.y, canvasBR2.y);
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

  // Draw equal spacing indicators.
  if (self.spacingSnapX || self.spacingSnapY) {
    simd_float4 spColor = {1.0f, 1.0f, 0.0f, 1.0f};
    float capLen = 6.0f;

    // Helper: draw a horizontal gap indicator with end caps.
    void (^drawHGap)(float, float, float) =
        ^(float objLeft, float objRight, float objY) {
          CGPoint cA =
              [self canvasPointFromObjectPoint:(simd_float2){objLeft, objY}];
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

    // Helper: draw a vertical gap indicator with end caps.
    void (^drawVGap)(float, float, float) =
        ^(float objTop, float objBottom, float objX) {
          CGPoint cA =
              [self canvasPointFromObjectPoint:(simd_float2){objX, objTop}];
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

  // Draw toolbars last so they appear on top of everything.
  [self.toolbar drawWithDestinationImage:destinationImage];
  [self.gridToolbar drawWithDestinationImage:destinationImage];
  if (showPathToolbar)
    [self.pathToolbar drawWithDestinationImage:destinationImage];
}

@end
#pragma clang diagnostic pop
