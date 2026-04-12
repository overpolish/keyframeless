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
    self.selectedPoints = [NSMutableIndexSet indexSet];

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
               pathIndex:(NSUInteger)pathIndex
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

    BOOL isSelected = [self isPointSelected:pathIndex point:i];
    // Live preview: highlight/unhighlight points inside marquee rect
    if (self.dragIsMarquee) {
      CGFloat minX = MIN(self.marqueeStart.x, self.marqueeEnd.x);
      CGFloat maxX = MAX(self.marqueeStart.x, self.marqueeEnd.x);
      CGFloat minY = MIN(self.marqueeStart.y, self.marqueeEnd.y);
      CGFloat maxY = MAX(self.marqueeStart.y, self.marqueeEnd.y);
      BOOL inside = (ptCanvas.x >= minX && ptCanvas.x <= maxX &&
                     ptCanvas.y >= minY && ptCanvas.y <= maxY);
      CGEventFlags mf =
          CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
      BOOL optHeld = (mf & kCGEventFlagMaskAlternate) != 0;
      if (inside) {
        if (optHeld)
          isSelected = NO; // opt-marquee removes
        else
          isSelected = YES; // normal/shift-marquee adds
      }
    }
    BOOL ptActive =
        isSelected || (self.dragIndex == (NSInteger)i && !self.dragIsInHandle &&
                       !self.dragIsOutHandle);
    BOOL ptHovered = (activePart == kOSCPathPointBase + (NSInteger)i);
    self.pathPointOSC.fillColorOverride =
        isSelected ? [NSColor systemBlueColor] : nil;
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

  BOOL hasSelection = self.selectedPoints.count > 0;
  BOOL showAllControls = hasSelection || self.dragIsMarquee;

  // Draw all paths; show controls for active path, or all when selecting
  for (NSUInteger p = 0; p < self.paths.count; p++) {
    KKBezierPath *path = self.paths[p];
    if (path.count == 0)
      continue;

    BOOL isActive = ((NSInteger)p == self.activePathIndex);
    [self
        drawPathSegments:path
                   color:(isActive || showAllControls) ? strokeColor : dimColor
        destinationImage:destinationImage];

    if (isActive || showAllControls) {
      [self drawPathControls:path
                   pathIndex:p
                  activePart:activePart
                       color:strokeColor
            destinationImage:destinationImage
                      atTime:time];
    }
  }

  // Draw marquee rectangle (dashed, pixel-snapped)
  if (self.dragIsMarquee) {
    simd_float4 marqueeColor = {1.0f, 1.0f, 1.0f, 0.9f};
    simd_float4 darkColor = {0.0f, 0.0f, 0.0f, 0.6f};
    CGFloat hw = 1.5f;
    CGFloat dash = 8.0f, gap = 5.0f;
    // Snap to pixel centers to avoid sub-pixel brightness variation
    CGFloat x0 = floor(MIN(self.marqueeStart.x, self.marqueeEnd.x)) + 0.5f;
    CGFloat x1 = floor(MAX(self.marqueeStart.x, self.marqueeEnd.x)) + 0.5f;
    CGFloat y0 = floor(MIN(self.marqueeStart.y, self.marqueeEnd.y)) + 0.5f;
    CGFloat y1 = floor(MAX(self.marqueeStart.y, self.marqueeEnd.y)) + 0.5f;
    CGPoint tl = {x0, y0}, tr = {x1, y0}, br = {x1, y1}, bl = {x0, y1};
    CGPoint edges[4][2] = {{tl, tr}, {tr, br}, {br, bl}, {bl, tl}};
    for (int e = 0; e < 4; e++) {
      CGPoint from = edges[e][0], to = edges[e][1];
      CGFloat dx = to.x - from.x, dy = to.y - from.y;
      CGFloat len = hypot(dx, dy);
      if (len < 0.1)
        continue;
      CGFloat nx = dx / len, ny = dy / len;
      CGFloat pos = 0;
      BOOL on = YES;
      while (pos < len) {
        CGFloat seg = on ? dash : gap;
        CGFloat end = MIN(pos + seg, len);
        CGPoint dFrom = {from.x + nx * pos, from.y + ny * pos};
        CGPoint dTo = {from.x + nx * end, from.y + ny * end};
        [self drawLineFrom:dFrom
                          to:dTo
                       color:on ? marqueeColor : darkColor
                   halfWidth:hw
            destinationImage:destinationImage];
        pos = end;
        on = !on;
      }
    }
  }
}

static NSUInteger selKey(NSUInteger pathIdx, NSUInteger ptIdx) {
  return pathIdx * 100000 + ptIdx;
}

- (BOOL)isPointSelected:(NSUInteger)pathIdx point:(NSUInteger)ptIdx {
  return [self.selectedPoints containsIndex:selKey(pathIdx, ptIdx)];
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
  BOOL shiftDown = (flags & kCGEventFlagMaskShift) != 0;
  BOOL cmdDown = (flags & kCGEventFlagMaskCommand) != 0;

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
    // Empty space: marquee cursor, show +/- hints only when there's a selection
    if (self.selectedPoints.count > 0 && shiftDown)
      [oscAPI setCursor:[NSCursor dragCopyCursor]];
    else if (self.selectedPoints.count > 0 && optDown)
      [oscAPI setCursor:[NSCursor operationNotAllowedCursor]];
    else
      [oscAPI setCursor:[NSCursor crosshairCursor]];
    return;
  }

  // Pen mode + Cmd: show arrow cursor for path selection
  if (isPenMode && cmdDown) {
    NSInteger nearPath = [self pathIndexNearX:positionX
                                            y:positionY
                                       radius:hitRadiusStroke];
    if (nearPath >= 0) {
      *activePart = kOSCCanvas;
      [oscAPI setCursor:[NSCursor arrowCursor]];
      return;
    }
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

  // Close path (pen mode): allow drag to adjust first point's in-handle
  if (activePart == kOSCClosePath && active) {
    active.closed = YES;
    [self writePaths:self.paths];
    self.dragIndex = 0;
    self.dragIsInHandle = YES;
    self.dragIsOutHandle = NO;
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

  // Cursor mode
  if (isCursorMode) {
    BOOL shiftDown = (modifiers & kFxModifierKey_SHIFT) != 0;
    BOOL optDown = (modifiers & kFxModifierKey_OPTION) != 0;

    // Check if clicking a selected point → drag selection
    if (self.selectedPoints.count > 0) {
      for (NSUInteger p = 0; p < self.paths.count; p++) {
        KKBezierPath *path = self.paths[p];
        for (NSUInteger i = 0; i < path.count; i++) {
          if (![self isPointSelected:p point:i])
            continue;
          KKBezierPoint pt = [path pointAtIndex:i];
          CGPoint ptCanvas = [self canvasPointForBezierPoint:pt];
          if (hypot(positionX - ptCanvas.x, positionY - ptCanvas.y) < 12.0) {
            self.dragIsSelection = YES;
            self.dragOrigin = [self
                objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
            *forceUpdate = YES;
            return;
          }
        }
      }
    }

    // Check if clicking near a path
    double hitRadiusStroke = [self strokeHitRadius];
    NSInteger nearPath = [self pathIndexNearX:positionX
                                            y:positionY
                                       radius:hitRadiusStroke];
    if (nearPath >= 0) {
      KKBezierPath *hitPath = self.paths[nearPath];
      if (shiftDown) {
        // Shift+click: add all points of this path to selection
        for (NSUInteger i = 0; i < hitPath.count; i++)
          [self.selectedPoints addIndex:selKey(nearPath, i)];
        *forceUpdate = YES;
        return;
      } else if (optDown) {
        // Opt+click: remove all points of this path from selection
        for (NSUInteger i = 0; i < hitPath.count; i++)
          [self.selectedPoints removeIndex:selKey(nearPath, i)];
        *forceUpdate = YES;
        return;
      }
      // Plain click: select path + start drag
      [self.selectedPoints removeAllIndexes];
      self.activePathIndex = nearPath;
      self.dragIsPath = YES;
      self.dragOrigin =
          [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
      *forceUpdate = YES;
      return;
    }

    // Empty space: start marquee (or clear selection if no modifier)
    if (!shiftDown && !optDown)
      [self.selectedPoints removeAllIndexes];
    self.activePathIndex = -1;
    self.dragIsMarquee = YES;
    self.marqueeStart = CGPointMake(positionX, positionY);
    self.marqueeEnd = self.marqueeStart;
    *forceUpdate = YES;
    return;
  }

  // Pen mode + Cmd: select path (like cursor mode)
  if (isPenMode && (modifiers & kFxModifierKey_COMMAND)) {
    double hitRadiusStroke = [self strokeHitRadius];
    NSInteger nearPath = [self pathIndexNearX:positionX
                                            y:positionY
                                       radius:hitRadiusStroke];
    if (nearPath >= 0) {
      self.activePathIndex = nearPath;
      *forceUpdate = YES;
      return;
    }
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
    self.dragIsOutHandle = NO;
    self.dragIsNewPoint = YES;

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
  // Marquee drag
  if (self.dragIsMarquee) {
    self.marqueeEnd = CGPointMake(positionX, positionY);
    *forceUpdate = YES;
    return;
  }

  // Drag selected points
  if (self.dragIsSelection) {
    simd_float2 objPos =
        [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
    simd_float2 delta = objPos - self.dragOrigin;
    self.dragOrigin = objPos;
    for (NSUInteger p = 0; p < self.paths.count; p++) {
      KKBezierPath *path = self.paths[p];
      for (NSUInteger i = 0; i < path.count; i++) {
        if ([self isPointSelected:p point:i]) {
          KKBezierPoint pt = [path pointAtIndex:i];
          [path moveAtIndex:i to:(simd_float2){pt.x + delta.x, pt.y + delta.y}];
        }
      }
    }
    [self writePaths:self.paths];
    *forceUpdate = YES;
    return;
  }

  KKBezierPath *active = [self activePath];
  if (!active)
    return;

  simd_float2 objPos =
      [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];

  // Whole-path drag (cursor mode)
  if (self.dragIsPath) {
    simd_float2 delta = objPos - self.dragOrigin;
    [active translateBy:delta];
    self.dragOrigin = objPos;
    [self writePaths:self.paths];
    *forceUpdate = YES;
    return;
  }

  if (self.dragIndex < 0 || self.dragIndex >= (NSInteger)active.count)
    return;

  BOOL breakSymmetry = (modifiers & kFxModifierKey_OPTION) != 0;

  if (self.dragIsNewPoint) {
    // New point: convert from linear to bezier on first drag
    KKBezierPoint pt = [active pointAtIndex:self.dragIndex];
    simd_float2 offset = {objPos.x - pt.x, objPos.y - pt.y};
    [active setOutHandle:offset atIndex:self.dragIndex];
    simd_float2 mirror = {-offset.x, -offset.y};
    [active setInHandle:mirror atIndex:self.dragIndex];
    [active setType:KKBezierPointBezier atIndex:self.dragIndex];
  } else if (self.dragIsInHandle) {
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
  // Finalize marquee selection
  if (self.dragIsMarquee) {
    self.marqueeEnd = CGPointMake(positionX, positionY);
    BOOL shiftDown = (modifiers & kFxModifierKey_SHIFT) != 0;
    BOOL optDown = (modifiers & kFxModifierKey_OPTION) != 0;

    CGFloat minX = MIN(self.marqueeStart.x, self.marqueeEnd.x);
    CGFloat maxX = MAX(self.marqueeStart.x, self.marqueeEnd.x);
    CGFloat minY = MIN(self.marqueeStart.y, self.marqueeEnd.y);
    CGFloat maxY = MAX(self.marqueeStart.y, self.marqueeEnd.y);

    // Only select if the marquee has some size (not just a click)
    if (maxX - minX > 2.0 || maxY - minY > 2.0) {
      for (NSUInteger p = 0; p < self.paths.count; p++) {
        KKBezierPath *path = self.paths[p];
        for (NSUInteger i = 0; i < path.count; i++) {
          KKBezierPoint pt = [path pointAtIndex:i];
          CGPoint canvas = [self canvasPointForBezierPoint:pt];
          BOOL inside = (canvas.x >= minX && canvas.x <= maxX &&
                         canvas.y >= minY && canvas.y <= maxY);
          NSUInteger key = selKey(p, i);
          if (inside) {
            if (optDown)
              [self.selectedPoints removeIndex:key];
            else
              [self.selectedPoints addIndex:key];
          }
        }
      }
    }
  }

  self.dragIndex = -1;
  self.dragIsInHandle = NO;
  self.dragIsOutHandle = NO;
  self.dragIsNewPoint = NO;
  self.dragIsPath = NO;
  self.dragIsMarquee = NO;
  self.dragIsSelection = NO;

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
  BOOL isCursorMode = (self.toolbar.activeTag == kOSCToolbarCursor);

  // Escape: clear selection, deselect path, switch to cursor mode
  if (asciiKey == 27) {
    [self.selectedPoints removeAllIndexes];
    self.activePathIndex = -1;
    self.toolbar.activeTag = kOSCToolbarCursor;
    *forceUpdate = YES;
    *didHandle = YES;
    return;
  }

  // Delete/Backspace
  if (asciiKey == 127 || asciiKey == 8) {
    self.paths = [self readPaths];

    // If there's a marquee selection, delete selected points
    if (isCursorMode && self.selectedPoints.count > 0) {
      // Remove selected points in reverse order to preserve indices
      for (NSInteger p = (NSInteger)self.paths.count - 1; p >= 0; p--) {
        KKBezierPath *path = self.paths[p];
        for (NSInteger i = (NSInteger)path.count - 1; i >= 0; i--) {
          if ([self isPointSelected:p point:i])
            [path removeAtIndex:i];
        }
        if (path.count == 0)
          [self.paths removeObjectAtIndex:p];
      }
      [self.selectedPoints removeAllIndexes];
      self.activePathIndex = -1;
      [self writePaths:self.paths];
      *forceUpdate = YES;
      *didHandle = YES;
      return;
    }

    KKBezierPath *active = [self activePath];
    if (!active)
      return;

    if (isCursorMode) {
      // Cursor mode: delete entire selected path
      [self.paths removeObjectAtIndex:self.activePathIndex];
      self.activePathIndex = -1;
      [self writePaths:self.paths];
      *forceUpdate = YES;
      *didHandle = YES;
    } else if (active.count > 0) {
      // Pen mode: remove last point
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
