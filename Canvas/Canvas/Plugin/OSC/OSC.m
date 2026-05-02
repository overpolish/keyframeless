/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKParamSync.h"
#import "LayerList_Private.h"
#import "OSC_Private.h"

NSCursor *cursorFromBundle(NSString *name, NSPoint hotSpot) {
  NSBundle *bundle = [NSBundle bundleForClass:[CanvasOSC class]];
  NSImage *image = [bundle imageForResource:name];
  if (!image)
    return [NSCursor crosshairCursor];
  return [[NSCursor alloc] initWithImage:image hotSpot:hotSpot];
}

NSUInteger selKey(NSUInteger pathIdx, NSUInteger ptIdx) {
  return pathIdx * 100000 + ptIdx;
}

@implementation CanvasOSC

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    self.clearsOnDraw = NO;
    self.paths = [NSMutableArray array];
    self.activePathIndex = -1;
    self.dragIndex = -1;
    self.lastClickIndex = -1;
    self.selectedPoints = [NSMutableIndexSet indexSet];
    self.selectedPathIndices = [NSMutableIndexSet indexSet];

    self.pathPointOSC = [[KKPointOSC alloc] initWithAPIManager:apiManager];
    self.pathPointOSC.clearsOnDraw = NO;
    self.pathPointOSC.oscRadius = 5.0f;
    self.pathPointOSC.outlineWidth = 1.5f;

    self.pathHandleOSC = [[KKPointOSC alloc] initWithAPIManager:apiManager];
    self.pathHandleOSC.clearsOnDraw = NO;
    self.pathHandleOSC.oscRadius = 3.0f;
    self.pathHandleOSC.outlineWidth = 1.0f;

    self.penCursor = cursorFromBundle(@"Pen", NSMakePoint(15, 5));
    self.penCloseCursor =
        cursorFromBundle(@"PenCloseShape", NSMakePoint(10, 5));
    self.penAddCursor =
        cursorFromBundle(@"PenAddControlPoint", NSMakePoint(10, 5));
    self.moveCursor = cursorFromBundle(@"Move", NSMakePoint(8, 7));
    self.editPointsCursor = cursorFromBundle(@"EditPoints", NSMakePoint(11, 8));
    self.penDeleteCursor = cursorFromBundle(@"PenX", NSMakePoint(15, 5));

    self.toolbar = [[KKToolbar alloc]
        initWithAPIManager:apiManager
                     items:@[
                       [KKToolbarItem itemWithIcon:@"cursorarrow"
                                               tag:kOSCToolbarCursor
                                     shortcutLabel:@"^V"],
                       [KKToolbarItem itemWithIcon:@"pencil.and.outline"
                                               tag:kOSCToolbarPen
                                     shortcutLabel:@"^X"],
                       [KKToolbarItem itemWithIcon:@"rectangle.fill"
                                               tag:kOSCToolbarRect
                                     shortcutLabel:@"^B"],
                       [KKToolbarItem itemWithIcon:@"circle.fill"
                                               tag:kOSCToolbarEllipse
                                     shortcutLabel:@"^G"],
                       [KKToolbarItem itemWithIcon:@"line.diagonal"
                                               tag:kOSCToolbarLine
                                     shortcutLabel:@"^M"],
                     ]];
    self.toolbar.activeTag = kOSCToolbarCursor;

    self.pathToolbar = [[KKToolbar alloc]
        initWithAPIManager:apiManager
                     items:@[
                       [KKToolbarItem itemWithIcon:@"square.on.square"
                                               tag:kOSCPathUnion
                                     shortcutLabel:@"Union"],
                       [KKToolbarItem itemWithIcon:@"minus.square"
                                               tag:kOSCPathSubtract
                                     shortcutLabel:@"Diff"],
                       [KKToolbarItem
                            itemWithIcon:@"square.on.square.intersection.dashed"
                                     tag:kOSCPathIntersect
                           shortcutLabel:@"Intersect"],
                       [KKToolbarItem itemWithIcon:@"xmark.square"
                                               tag:kOSCPathXOR
                                     shortcutLabel:@"XOR"],
                       [KKToolbarItem itemWithIcon:@"square.dashed"
                                               tag:kOSCPathOutline
                                     shortcutLabel:@"Stroke\nto Path"],
                     ]];
    self.pathToolbar.activeTag = 0;

    {
      KKToolbarItem *snapItem =
          [KKToolbarItem itemWithIcon:@"dot.squareshape.split.2x2"
                                  tag:kOSCSnapToggle
                        shortcutLabel:@"Snap"];

      KKToolbarItem *gridItem = [KKToolbarItem itemWithIcon:@"grid"
                                                        tag:kOSCGridToggle
                                              shortcutLabel:@"Grid"];

      KKToolbarItem *stepperItem =
          [KKToolbarItem itemWithIcon:@"digitalcrown.arrow.clockwise.fill"
                                  tag:kOSCGridStepper
                        shortcutLabel:nil];

      KKToolbarItem *adaptiveItem =
          [KKToolbarItem itemWithIcon:@"squareshape.split.2x2.dotted"
                                  tag:kOSCGridAdaptive
                        shortcutLabel:@"Auto"];

      self.gridToolbar = [[KKToolbar alloc]
          initWithAPIManager:apiManager
                       items:@[
                         snapItem, gridItem, adaptiveItem, stepperItem
                       ]];
      self.gridToolbar.activeTag = 0;
      self.gridToolbar.rightMargin = 16.0;
    }

    self.gridSpacing = 10;
    self.gridAdaptive = YES;

    self.sizeLabel = [[KKOSCLabel alloc] initWithAPIManager:apiManager];
    self.sizeLabel.monospaced = YES;

    self.borderOSC = [[KKRectBorderOSC alloc] initWithAPIManager:apiManager];
    self.borderOSC.clearsOnDraw = NO;
    NSMutableArray *handles = [NSMutableArray arrayWithCapacity:8];
    for (int i = 0; i < 8; i++) {
      KKPointOSC *h = [[KKPointOSC alloc] initWithAPIManager:apiManager];
      h.clearsOnDraw = NO;
      h.oscRadius = 5.0f;
      h.outlineWidth = 1.5f;
      [handles addObject:h];
    }
    self.resizeHandleOSCs = handles;
    self.dragResizeHandle = -1;

    self.rotateHandleOSC = [[KKPointOSC alloc] initWithAPIManager:apiManager];
    self.rotateHandleOSC.clearsOnDraw = NO;
    self.rotateHandleOSC.oscRadius = 5.0f;
    self.rotateHandleOSC.outlineWidth = 1.5f;
    self.rotateHandleOSC.fillColorOverride = [NSColor accent];

    self.transformPositionOSC =
        [[KKArcOSC alloc] initWithAPIManager:apiManager];
    self.transformPositionOSC.clearsOnDraw = NO;

    self.scaleRingOSC = [[KKRingOSC alloc] initWithAPIManager:apiManager];
    self.scaleRingOSC.clearsOnDraw = NO;
    self.scaleRingOSC.fillWidth = 2.0f;
    self.scaleRingOSC.ringOutlineWidth = 1.5f;
    self.scaleRingOSC.hoverCursor = [NSCursor crosshairCursor];

    self.anchorOSC = [[KKSquarePointOSC alloc] initWithAPIManager:apiManager];
    self.anchorOSC.clearsOnDraw = NO;
    self.anchorOSC.oscSize = 6.0f;
    self.anchorOSC.cornerRadius = 1.0f;
    self.anchorOSC.outlineWidth = 1.5f;
    self.anchorSnapEngine = [[KKSnapEngine alloc] init];

    self.positionPathPointOSC =
        [[KKPointOSC alloc] initWithAPIManager:apiManager];
    self.positionPathPointOSC.clearsOnDraw = NO;
    self.positionPathPointOSC.oscRadius = 5.0f;
    self.positionPathPointOSC.outlineWidth = 1.5f;
    self.positionPathHandleOSC =
        [[KKPointOSC alloc] initWithAPIManager:apiManager];
    self.positionPathHandleOSC.clearsOnDraw = NO;
    self.positionPathHandleOSC.oscRadius = 3.0f;
    self.positionPathHandleOSC.outlineWidth = 1.0f;

    self.positionPathDragSegIndex = -1;
    self.positionPathDragPointIndex = -1;
    self.positionPathLastClickSegIdx = -1;
    self.positionPathLastClickPointIdx = -1;
  }
  return self;
}

- (CGPoint)oscPositionAtTime:(CMTime)time {
  return CGPointZero;
}

- (KKBezierPath *)activePath {
  if (self.activePathIndex >= 0 &&
      self.activePathIndex < (NSInteger)self.paths.count &&
      !self.paths[self.activePathIndex].locked &&
      !self.paths[self.activePathIndex].isGroup)
    return self.paths[self.activePathIndex];
  return nil;
}

- (CGPoint)canvasPointForBezierPoint:(KKBezierPoint)pt {
  return [self canvasPointFromObjectPoint:(simd_float2){pt.x, pt.y}];
}

- (CGPoint)canvasPointForBezierPoint:(KKBezierPoint)pt
                      inHandleOffset:(BOOL)useIn {
  if (useIn)
    return [self
        canvasPointFromObjectPoint:(simd_float2){pt.x + pt.inX, pt.y + pt.inY}];
  return [self
      canvasPointFromObjectPoint:(simd_float2){pt.x + pt.outX, pt.y + pt.outY}];
}

- (BOOL)isPointSelected:(NSUInteger)pathIdx point:(NSUInteger)ptIdx {
  return [self.selectedPoints containsIndex:selKey(pathIdx, ptIdx)];
}

- (double)strokeWidth {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  double width = 8.0;
  [paramGetAPI getFloatValue:&width
               fromParameter:kParamStrokeWidth
                      atTime:kCMTimeZero];
  return width;
}

- (double)strokeHitRadius {
  return MAX([self strokeWidth] * 0.5 + 4.0, 12.0);
}

- (NSMutableArray<KKBezierPath *> *)readPaths {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSString *str = nil;
  [paramGetAPI getStringParameterValue:&str fromParameter:kParamPathData];
  self.lastReadBlobString = str;
  if (str.length == 0)
    return [NSMutableArray array];
  NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
  return [KKBezierPath pathsFromBlob:blob];
}

- (void)writePaths:(NSArray<KKBezierPath *> *)paths {
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSData *blob = [KKBezierPath blobFromPaths:paths];
  NSString *str = [blob base64EncodedStringWithOptions:0];
  [paramSetAPI setStringParameterValue:str toParameter:kParamPathData];
  // Invalidate so the next readPaths detects the write as a change.
  self.lastReadBlobString = nil;
}

- (void)syncStrokeParamsToSelection {
  [self syncStrokeParamsToSelectionWithPrevious:nil];
}

- (void)syncStrokeParamsToSelectionWithPrevious:(NSIndexSet *)explicitPrev {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

  // Write back current inspector param values to the previously-selected
  // paths.  Only safe in cursor mode where the user may have edited values
  // in the inspector.  In pen mode, KKParamsToPath would read shared FxPlug
  // params that may belong to a different path and corrupt the target.
  NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
  BOOL isCursorMode = (self.toolbar.activeTag == kOSCToolbarCursor);
  if (isCursorMode) {
    // Use the explicit previous selection when provided to avoid a race
    // with drawOSC updating lst.selectedIndices on the render thread.
    NSIndexSet *prevSel =
        explicitPrev ?: (uuid ? KKCanvasCurrentSelection(uuid) : nil);
    KKBezierPath *prev = KKSelectedPath(prevSel, self.paths);
    if (prev) {
      KKParamsToSelectedPaths(paramGetAPI, prevSel, self.paths);
      [self writePaths:self.paths];
    }
  }

  // Update selection state so pluginState: patches the correct path.
  if (uuid)
    KKCanvasUpdateSelection(uuid, self.selectedPathIndices);

  // Write param values from the newly-selected path.
  // Flag visibility is handled centrally by KKParamSyncApply via
  // KKCanvasRefreshLayerList — do not set flags here.
  KKBezierPath *selPath = KKSelectedPath(self.selectedPathIndices, self.paths);
  NSString *syncUUID = KKLayerUUIDForAPI(self.apiManager);
  if (selPath) {
    KKPathToParams(paramSetAPI, selPath);
    if (syncUUID)
      KKCacheCustomStyles(syncUUID, selPath);
    KKSaveSelectedIndex(
        paramSetAPI, (NSInteger)[self.paths indexOfObjectIdenticalTo:selPath]);
  } else {
    KKSaveSelectedIndex(paramSetAPI, -1);
  }
  if (syncUUID) {
    KKCanvasStore *store = KKLayerStateForUUID(syncUUID).store;
    [store performBatch:^{
      if (selPath) {
        [store setStrokeEnabled:selPath.strokeEnabled];
        [store setFillEnabled:selPath.fillEnabled];
        [store setSketchEnabled:selPath.sketchEnabled];
      }
      [store syncSelectedPathProperties];
    }];
  }
}

@end
