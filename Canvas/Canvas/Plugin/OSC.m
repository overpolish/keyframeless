/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC.h"
#import "Constants.h"
#import <CoreGraphics/CGEventSource.h>
#import <FxPlug/FxPlugSDK.h>

static NSCursor *cursorFromBundle(NSString *name, NSPoint hotSpot) {
  NSBundle *bundle = [NSBundle bundleForClass:[CanvasOSC class]];
  NSImage *image = [bundle imageForResource:name];
  if (!image)
    return [NSCursor crosshairCursor];
  return [[NSCursor alloc] initWithImage:image hotSpot:hotSpot];
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
    _moveCursor = cursorFromBundle(@"Move", NSMakePoint(8, 7));
    _editPointsCursor = cursorFromBundle(@"EditPoints", NSMakePoint(11, 8));
    _penDeleteCursor = cursorFromBundle(@"PenX", NSMakePoint(15, 5));

    self.toolbar = [[KKToolbar alloc]
        initWithAPIManager:apiManager
                     items:@[
                       [KKToolbarItem itemWithIcon:@"cursorarrow"
                                               tag:kOSCToolbarCursor],
                       [KKToolbarItem itemWithIcon:@"pencil.and.outline"
                                               tag:kOSCToolbarPen],
                       [KKToolbarItem itemWithIcon:@"rectangle"
                                               tag:kOSCToolbarRect],
                     ]];
    self.toolbar.activeTag = kOSCToolbarPen;
  }
  return self;
}

- (CGPoint)oscPositionAtTime:(CMTime)time {
  return CGPointZero;
}

- (KKBezierPath *)activePath {
  if (self.activePathIndex >= 0 &&
      self.activePathIndex < (NSInteger)self.paths.count)
    return self.paths[self.activePathIndex];
  return nil;
}

// Multi-path serialization: [uint32 pathCount] [pathData...]
// Each pathData: [uint32 length] [bytes...]
- (NSMutableArray<KKBezierPath *> *)readPaths {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSString *str = nil;
  [paramGetAPI getStringParameterValue:&str fromParameter:kParamPathData];
  if (str.length == 0)
    return [NSMutableArray array];

  NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
  if (!blob || blob.length < 4)
    return [NSMutableArray array];

  const uint8_t *bytes = blob.bytes;
  NSUInteger offset = 0;

  uint32_t pathCount;
  memcpy(&pathCount, bytes + offset, 4);
  offset += 4;

  // Backwards compat: if this doesn't look like multi-path format,
  // try reading as a single path
  if (pathCount > 10000 || offset + pathCount * 4 > blob.length) {
    KKBezierPath *single = [KKBezierPath pathWithData:blob];
    if (single && single.count > 0)
      return [NSMutableArray arrayWithObject:single];
    return [NSMutableArray array];
  }

  NSMutableArray *result = [NSMutableArray arrayWithCapacity:pathCount];
  for (uint32_t i = 0; i < pathCount; i++) {
    if (offset + 4 > blob.length)
      break;
    uint32_t len;
    memcpy(&len, bytes + offset, 4);
    offset += 4;
    if (offset + len > blob.length)
      break;
    NSData *pathData = [blob subdataWithRange:NSMakeRange(offset, len)];
    KKBezierPath *path = [KKBezierPath pathWithData:pathData];
    if (path)
      [result addObject:path];
    offset += len;
  }
  return result;
}

- (void)writePaths:(NSArray<KKBezierPath *> *)paths {
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

  NSMutableData *blob = [NSMutableData data];
  uint32_t pathCount = (uint32_t)paths.count;
  [blob appendBytes:&pathCount length:4];
  for (KKBezierPath *path in paths) {
    NSData *pathData = [path dataRepresentation];
    uint32_t len = (uint32_t)pathData.length;
    [blob appendBytes:&len length:4];
    [blob appendData:pathData];
  }

  NSString *str = [blob base64EncodedStringWithOptions:0];
  [paramSetAPI setStringParameterValue:str toParameter:kParamPathData];
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

- (void)drawPathSegments:(KKBezierPath *)path
                   color:(simd_float4)color
        destinationImage:(FxImageTile *)dest {
  NSUInteger segCount = path.count - 1;
  if (path.closed && path.count >= 3)
    segCount = path.count;

  for (NSUInteger i = 0; i < segCount; i++) {
    NSUInteger nextIdx = (i + 1) % path.count;
    CGPoint prev = CGPointZero;
    for (NSUInteger s = 0; s <= 32; s++) {
      float t = (float)s / 32.0f;
      simd_float2 pos = [path evaluatePointAtIndex:i nextIndex:nextIdx atT:t];
      CGPoint cur = [self canvasPointFromObjectPoint:pos];
      if (s > 0) {
        [self drawLineFrom:prev
                          to:cur
                       color:color
                   halfWidth:1.5f
            destinationImage:dest];
      }
      prev = cur;
    }
  }
}

- (void)drawPathControls:(KKBezierPath *)path
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

    BOOL ptActive = (self.dragIndex == (NSInteger)i && !self.dragIsInHandle &&
                     !self.dragIsOutHandle);
    BOOL ptHovered = (activePart == kOSCPathPointBase + (NSInteger)i);
    [self.pathPointOSC drawAtCanvasPosition:ptCanvas
                                  isHovered:ptHovered
                                   isActive:ptActive
                           destinationImage:dest
                                     atTime:time];
  }
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

  simd_float4 strokeColor = [[NSColor systemRedColor] simdFloat4];
  simd_float4 dimColor = strokeColor;
  dimColor.w = 0.3f;

  // Draw all paths, but only show controls for active path
  for (NSUInteger p = 0; p < self.paths.count; p++) {
    KKBezierPath *path = self.paths[p];
    if (path.count == 0)
      continue;

    BOOL isActive = ((NSInteger)p == self.activePathIndex);
    [self drawPathSegments:path
                     color:isActive ? strokeColor : dimColor
          destinationImage:destinationImage];

    if (isActive) {
      [self drawPathControls:path
                  activePart:activePart
                       color:strokeColor
            destinationImage:destinationImage
                      atTime:time];
    }
  }
}

- (double)strokeHitRadius {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  double width = 8.0;
  [paramGetAPI getFloatValue:&width
               fromParameter:kParamStrokeWidth
                      atTime:kCMTimeZero];
  return MAX(width * 0.5 + 4.0, 12.0);
}

// Returns the path index of a path whose segment is near (x, y), or -1
- (NSInteger)pathIndexNearX:(double)x y:(double)y radius:(double)radius {
  for (NSUInteger p = 0; p < self.paths.count; p++) {
    KKBezierPath *path = self.paths[p];
    NSUInteger segCount = path.count - 1;
    if (path.closed && path.count >= 3)
      segCount = path.count;

    for (NSUInteger c = 0; c < segCount; c++) {
      NSUInteger nextIdx = (c + 1) % path.count;
      for (NSUInteger s = 0; s <= 64; s++) {
        float t = (float)s / 64.0f;
        simd_float2 pos = [path evaluatePointAtIndex:c nextIndex:nextIdx atT:t];
        CGPoint cur = [self canvasPointFromObjectPoint:pos];
        if (hypot(x - cur.x, y - cur.y) < radius)
          return (NSInteger)p;
      }
    }
  }
  return -1;
}

// Returns the segment index of the active path near (x, y), or -1
- (NSInteger)segmentIndexNearX:(double)x
                             y:(double)y
                        radius:(double)radius
                        inPath:(KKBezierPath *)path {
  if (!path || path.count < 2)
    return -1;

  NSUInteger segCount = path.count - 1;
  if (path.closed && path.count >= 3)
    segCount = path.count;

  for (NSUInteger c = 0; c < segCount; c++) {
    NSUInteger nextIdx = (c + 1) % path.count;
    for (NSUInteger s = 0; s <= 64; s++) {
      float t = (float)s / 64.0f;
      simd_float2 pos = [path evaluatePointAtIndex:c nextIndex:nextIdx atT:t];
      CGPoint cur = [self canvasPointFromObjectPoint:pos];
      if (hypot(x - cur.x, y - cur.y) < radius)
        return (NSInteger)c;
    }
  }
  return -1;
}

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  *activePart = kOSCCanvas;
  self.paths = [self readPaths];

  double hitRadius = 12.0;
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];

  // Test toolbar
  NSInteger toolbarPart = [self.toolbar hitTestAtX:positionX y:positionY];
  if (toolbarPart != 0) {
    *activePart = toolbarPart;
    [oscAPI setCursor:[NSCursor arrowCursor]];
    return;
  }

  BOOL isCursorMode = (self.toolbar.activeTag == kOSCToolbarCursor);
  BOOL isPenMode = (self.toolbar.activeTag == kOSCToolbarPen);

  CGEventFlags flags =
      CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
  BOOL optDown = (flags & kCGEventFlagMaskAlternate) != 0;

  KKBezierPath *active = [self activePath];

  // In cursor or pen mode, test active path's handles and points
  if (active) {
    for (NSUInteger i = 0; i < active.count; i++) {
      KKBezierPoint pt = [active pointAtIndex:i];
      if (pt.type != KKBezierPointBezier)
        continue;

      CGPoint inCanvas = [self canvasPointForBezierPoint:pt inHandleOffset:YES];
      if (hypot(positionX - inCanvas.x, positionY - inCanvas.y) < hitRadius) {
        *activePart = kOSCInHandleBase + (NSInteger)i;
        [oscAPI setCursor:_editPointsCursor];
        return;
      }

      CGPoint outCanvas = [self canvasPointForBezierPoint:pt inHandleOffset:NO];
      if (hypot(positionX - outCanvas.x, positionY - outCanvas.y) < hitRadius) {
        *activePart = kOSCOutHandleBase + (NSInteger)i;
        [oscAPI setCursor:_editPointsCursor];
        return;
      }
    }

    for (NSUInteger i = 0; i < active.count; i++) {
      KKBezierPoint pt = [active pointAtIndex:i];
      CGPoint ptCanvas = [self canvasPointForBezierPoint:pt];
      if (hypot(positionX - ptCanvas.x, positionY - ptCanvas.y) < hitRadius) {
        if (isPenMode && i == 0 && !active.closed && active.count >= 3) {
          *activePart = kOSCClosePath;
          [oscAPI setCursor:self.penCloseCursor];
          return;
        }
        *activePart = kOSCPathPointBase + (NSInteger)i;
        [oscAPI setCursor:optDown ? _penDeleteCursor : _moveCursor];
        return;
      }
    }
  }

  double hitRadiusStroke = [self strokeHitRadius];

  if (isCursorMode) {
    // In cursor mode, test all paths for selection using stroke width
    NSInteger nearPath = [self pathIndexNearX:positionX
                                            y:positionY
                                       radius:hitRadiusStroke];
    if (nearPath >= 0) {
      *activePart = kOSCCanvas; // will handle in mouseDown
      [oscAPI setCursor:[NSCursor arrowCursor]];
      return;
    }
    [oscAPI setCursor:[NSCursor arrowCursor]];
    return;
  }

  // Pen mode: test active path's segments for insertion (open and closed)
  if (isPenMode && active && active.count >= 2) {
    NSInteger segIdx = [self segmentIndexNearX:positionX
                                             y:positionY
                                        radius:hitRadiusStroke
                                        inPath:active];
    if (segIdx >= 0) {
      *activePart = kOSCPathSegmentBase + segIdx;
      [oscAPI setCursor:self.penAddCursor];
      return;
    }
  }

  if (isPenMode) {
    [oscAPI setCursor:self.penAddCursor];
  } else {
    [oscAPI setCursor:[NSCursor arrowCursor]];
  }
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  // Toolbar
  if (activePart == kOSCToolbarCursor || activePart == kOSCToolbarPen ||
      activePart == kOSCToolbarRect) {
    self.toolbar.activeTag = activePart;
    *forceUpdate = YES;
    return;
  }

  self.paths = [self readPaths];
  KKBezierPath *active = [self activePath];

  BOOL isCursorMode = (self.toolbar.activeTag == kOSCToolbarCursor);
  BOOL isPenMode = (self.toolbar.activeTag == kOSCToolbarPen);

  // Close path (pen mode)
  if (activePart == kOSCClosePath && active) {
    active.closed = YES;
    [self writePaths:self.paths];
    *forceUpdate = YES;
    return;
  }

  // Option-click on point: delete
  if (activePart >= kOSCPathPointBase && activePart < kOSCInHandleBase &&
      (modifiers & kFxModifierKey_OPTION) && active) {
    NSInteger idx = activePart - kOSCPathPointBase;
    if (idx >= 0 && idx < (NSInteger)active.count) {
      [active removeAtIndex:idx];
      if (active.count == 0) {
        [self.paths removeObjectAtIndex:self.activePathIndex];
        self.activePathIndex = -1;
      }
      [self writePaths:self.paths];
    }
    *forceUpdate = YES;
    return;
  }

  // Click on point: drag or double-click toggle
  if (activePart >= kOSCPathPointBase && activePart < kOSCInHandleBase &&
      active) {
    NSInteger idx = activePart - kOSCPathPointBase;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

    if (self.lastClickIndex == idx && (now - self.lastClickTime) < 0.35) {
      KKBezierPoint pt = [active pointAtIndex:idx];
      if (pt.type == KKBezierPointBezier) {
        [active setType:KKBezierPointLinear atIndex:idx];
        [active setInHandle:(simd_float2){0, 0} atIndex:idx];
        [active setOutHandle:(simd_float2){0, 0} atIndex:idx];
      } else {
        simd_float2 pos = {pt.x, pt.y};
        simd_float2 prev = pos, next = pos;
        if (idx > 0) {
          KKBezierPoint pp = [active pointAtIndex:idx - 1];
          prev = (simd_float2){pp.x, pp.y};
        }
        if (idx + 1 < (NSInteger)active.count) {
          KKBezierPoint np = [active pointAtIndex:idx + 1];
          next = (simd_float2){np.x, np.y};
        }
        simd_float2 dir = (next - prev) * 0.25f;
        [active setOutHandle:dir atIndex:idx];
        [active setInHandle:(simd_float2){-dir.x, -dir.y} atIndex:idx];
        [active setType:KKBezierPointBezier atIndex:idx];
      }
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
    *forceUpdate = YES;
    return;
  }

  // Drag handles
  if (activePart >= kOSCInHandleBase && activePart < kOSCOutHandleBase) {
    self.dragIndex = activePart - kOSCInHandleBase;
    self.dragIsInHandle = YES;
    self.dragIsOutHandle = NO;
    *forceUpdate = YES;
    return;
  }
  if (activePart >= kOSCOutHandleBase && activePart < kOSCPathSegmentBase) {
    self.dragIndex = activePart - kOSCOutHandleBase;
    self.dragIsInHandle = NO;
    self.dragIsOutHandle = YES;
    *forceUpdate = YES;
    return;
  }

  // Insert on segment (pen mode)
  if (activePart >= kOSCPathSegmentBase && isPenMode && active) {
    NSInteger segIdx = activePart - kOSCPathSegmentBase;
    simd_float2 objPos =
        [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
    [active insertAtIndex:segIdx + 1 position:objPos];
    [self writePaths:self.paths];
    self.dragIndex = segIdx + 1;
    self.dragIsInHandle = NO;
    self.dragIsOutHandle = NO;
    *forceUpdate = YES;
    return;
  }

  // Cursor mode: click near a path to select it, empty space to deselect
  if (isCursorMode) {
    double hitRadiusStroke = [self strokeHitRadius];
    NSInteger nearPath = [self pathIndexNearX:positionX
                                            y:positionY
                                       radius:hitRadiusStroke];
    self.activePathIndex = nearPath;
    *forceUpdate = YES;
    return;
  }

  // Pen mode: add point to active path, or start a new path
  if (isPenMode) {
    // If no active path, start a new one
    if (!active) {
      KKBezierPath *newPath = [[KKBezierPath alloc] init];
      [self.paths addObject:newPath];
      self.activePathIndex = (NSInteger)self.paths.count - 1;
      active = newPath;
    } else if (active.closed) {
      // Closed path: check if clicking on a segment to insert
      double hitRadiusStroke = [self strokeHitRadius];
      NSInteger segIdx = [self segmentIndexNearX:positionX
                                               y:positionY
                                          radius:hitRadiusStroke
                                          inPath:active];
      if (segIdx >= 0) {
        simd_float2 objPos =
            [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
        [active insertAtIndex:segIdx + 1 position:objPos];
        [self writePaths:self.paths];
        self.dragIndex = segIdx + 1;
        self.dragIsInHandle = NO;
        self.dragIsOutHandle = NO;
        *forceUpdate = YES;
        return;
      }
      // Not on a segment: start a new path
      KKBezierPath *newPath = [[KKBezierPath alloc] init];
      [self.paths addObject:newPath];
      self.activePathIndex = (NSInteger)self.paths.count - 1;
      active = newPath;
    }

    simd_float2 objPos =
        [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
    [active insertAtIndex:active.count position:objPos];
    [self writePaths:self.paths];

    self.dragIndex = (NSInteger)active.count - 1;
    self.dragIsInHandle = NO;
    self.dragIsOutHandle = YES;

    *forceUpdate = YES;
    [super mouseDownAtPositionX:positionX
                      positionY:positionY
                     activePart:activePart
                      modifiers:modifiers
                    forceUpdate:forceUpdate
                         atTime:time];
    return;
  }
}

- (void)mouseDraggedAtPositionX:(double)positionX
                      positionY:(double)positionY
                     activePart:(NSInteger)activePart
                      modifiers:(NSUInteger)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time {
  KKBezierPath *active = [self activePath];
  if (!active || self.dragIndex < 0 ||
      self.dragIndex >= (NSInteger)active.count)
    return;

  simd_float2 objPos =
      [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];

  BOOL breakSymmetry = (modifiers & kFxModifierKey_OPTION) != 0;

  if (self.dragIsInHandle) {
    KKBezierPoint pt = [active pointAtIndex:self.dragIndex];
    simd_float2 offset = {objPos.x - pt.x, objPos.y - pt.y};
    [active setInHandle:offset atIndex:self.dragIndex];
    if (!breakSymmetry) {
      simd_float2 mirror = {-offset.x, -offset.y};
      [active setOutHandle:mirror atIndex:self.dragIndex];
    }
    [active setType:KKBezierPointBezier atIndex:self.dragIndex];
  } else if (self.dragIsOutHandle) {
    KKBezierPoint pt = [active pointAtIndex:self.dragIndex];
    simd_float2 offset = {objPos.x - pt.x, objPos.y - pt.y};
    [active setOutHandle:offset atIndex:self.dragIndex];
    if (!breakSymmetry) {
      simd_float2 mirror = {-offset.x, -offset.y};
      [active setInHandle:mirror atIndex:self.dragIndex];
    }
    [active setType:KKBezierPointBezier atIndex:self.dragIndex];
  } else {
    [active moveAtIndex:self.dragIndex to:objPos];
  }

  [self writePaths:self.paths];
  *forceUpdate = YES;
}

- (void)mouseUpAtPositionX:(double)positionX
                 positionY:(double)positionY
                activePart:(NSInteger)activePart
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time {
  self.dragIndex = -1;
  self.dragIsInHandle = NO;
  self.dragIsOutHandle = NO;

  *forceUpdate = YES;
  [super mouseUpAtPositionX:positionX
                  positionY:positionY
                 activePart:activePart
                  modifiers:modifiers
                forceUpdate:forceUpdate
                     atTime:time];
}

- (void)keyDownAtPositionX:(double)positionX
                 positionY:(double)positionY
                keyPressed:(unsigned short)asciiKey
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                 didHandle:(BOOL *)didHandle
                    atTime:(CMTime)time {
  // Delete/Backspace removes last point from active path
  if (asciiKey == 127 || asciiKey == 8) {
    self.paths = [self readPaths];
    KKBezierPath *active = [self activePath];
    if (active && active.count > 0) {
      [active removeAtIndex:active.count - 1];
      if (active.count == 0) {
        [self.paths removeObjectAtIndex:self.activePathIndex];
        self.activePathIndex = -1;
      }
      [self writePaths:self.paths];
      *forceUpdate = YES;
      *didHandle = YES;
    }
  }
}

@end
