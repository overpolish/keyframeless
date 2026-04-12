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
    self.path = [[KKBezierPath alloc] init];
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
                       [KKToolbarItem itemWithIcon:@"pencil.and.outline"
                                               tag:kOSCToolbarPen],
                       [KKToolbarItem itemWithIcon:@"rectangle"
                                               tag:kOSCToolbarRect],
                     ]];
  }
  return self;
}

- (CGPoint)oscPositionAtTime:(CMTime)time {
  return CGPointZero;
}

- (KKBezierPath *)readPath {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSString *str = nil;
  [paramGetAPI getStringParameterValue:&str fromParameter:kParamPathData];
  if (str.length > 0) {
    NSData *data = [[NSData alloc] initWithBase64EncodedString:str options:0];
    if (data)
      return [KKBezierPath pathWithData:data];
  }
  return [[KKBezierPath alloc] init];
}

- (void)writePath:(KKBezierPath *)path {
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSData *data = [path dataRepresentation];
  NSString *str = [data base64EncodedStringWithOptions:0];
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

  self.path = [self readPath];
  if (self.path.count == 0)
    return;

  simd_float4 strokeColor = [[NSColor systemRedColor] simdFloat4];
  simd_float4 handleColor = strokeColor;
  handleColor.w = 0.33f;

  // Draw bezier segments (+ closing segment if closed)
  NSUInteger segCount = self.path.count - 1;
  if (self.path.closed && self.path.count >= 3)
    segCount = self.path.count;

  for (NSUInteger i = 0; i < segCount; i++) {
    NSUInteger nextIdx = (i + 1) % self.path.count;
    CGPoint prev = CGPointZero;
    for (NSUInteger s = 0; s <= 32; s++) {
      float t = (float)s / 32.0f;
      simd_float2 pos = [self.path evaluatePointAtIndex:i
                                              nextIndex:nextIdx
                                                    atT:t];
      CGPoint cur = [self canvasPointFromObjectPoint:pos];
      if (s > 0) {
        [self drawLineFrom:prev
                          to:cur
                       color:strokeColor
                   halfWidth:1.5f
            destinationImage:destinationImage];
      }
      prev = cur;
    }
  }

  // Draw control points and handles
  for (NSUInteger i = 0; i < self.path.count; i++) {
    KKBezierPoint pt = [self.path pointAtIndex:i];
    CGPoint ptCanvas = [self canvasPointForBezierPoint:pt];

    if (pt.type == KKBezierPointBezier) {
      CGPoint inCanvas = [self canvasPointForBezierPoint:pt inHandleOffset:YES];
      CGPoint outCanvas = [self canvasPointForBezierPoint:pt inHandleOffset:NO];

      [self drawLineFrom:ptCanvas
                        to:inCanvas
                     color:handleColor
                 halfWidth:2.0f
          destinationImage:destinationImage];
      [self drawLineFrom:ptCanvas
                        to:outCanvas
                     color:handleColor
                 halfWidth:2.0f
          destinationImage:destinationImage];

      BOOL inActive = (self.dragIndex == (NSInteger)i && self.dragIsInHandle);
      BOOL outActive = (self.dragIndex == (NSInteger)i && self.dragIsOutHandle);

      [self.pathHandleOSC drawAtCanvasPosition:inCanvas
                                     isHovered:NO
                                      isActive:inActive
                              destinationImage:destinationImage
                                        atTime:time];
      [self.pathHandleOSC drawAtCanvasPosition:outCanvas
                                     isHovered:NO
                                      isActive:outActive
                              destinationImage:destinationImage
                                        atTime:time];
    }

    BOOL ptActive = (self.dragIndex == (NSInteger)i && !self.dragIsInHandle &&
                     !self.dragIsOutHandle);
    BOOL ptHovered = (activePart == kOSCPathPointBase + (NSInteger)i);
    [self.pathPointOSC drawAtCanvasPosition:ptCanvas
                                  isHovered:ptHovered
                                   isActive:ptActive
                           destinationImage:destinationImage
                                     atTime:time];
  }
}

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  *activePart = kOSCCanvas;
  self.path = [self readPath];

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

  CGEventFlags flags =
      CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
  BOOL optDown = (flags & kCGEventFlagMaskAlternate) != 0;

  // Test handles
  for (NSUInteger i = 0; i < self.path.count; i++) {
    KKBezierPoint pt = [self.path pointAtIndex:i];
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

  // Test points
  for (NSUInteger i = 0; i < self.path.count; i++) {
    KKBezierPoint pt = [self.path pointAtIndex:i];
    CGPoint ptCanvas = [self canvasPointForBezierPoint:pt];
    if (hypot(positionX - ptCanvas.x, positionY - ptCanvas.y) < hitRadius) {
      // Hovering first point on open path with 3+ points: close path
      if (i == 0 && !self.path.closed && self.path.count >= 3) {
        *activePart = kOSCClosePath;
        [oscAPI setCursor:self.penCloseCursor];
        return;
      }
      *activePart = kOSCPathPointBase + (NSInteger)i;
      [oscAPI setCursor:optDown ? _penDeleteCursor : _moveCursor];
      return;
    }
  }

  // Test path segments
  if (self.path.count >= 2) {
    double segHitRadius = 10.0;
    for (NSUInteger c = 0; c + 1 < self.path.count; c++) {
      for (NSUInteger s = 0; s <= 64; s++) {
        float t = (float)s / 64.0f;
        simd_float2 pos = [self.path evaluatePointAtIndex:c
                                                nextIndex:c + 1
                                                      atT:t];
        CGPoint cur = [self canvasPointFromObjectPoint:pos];
        if (hypot(positionX - cur.x, positionY - cur.y) < segHitRadius) {
          *activePart = kOSCPathSegmentBase + (NSInteger)c;
          [oscAPI setCursor:self.penAddCursor];
          return;
        }
      }
    }
  }

  [oscAPI setCursor:self.penAddCursor];
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  if (activePart == kOSCToolbarPen || activePart == kOSCToolbarRect) {
    self.toolbar.activeTag = activePart;
    *forceUpdate = YES;
    return;
  }

  self.path = [self readPath];

  // Close path
  if (activePart == kOSCClosePath) {
    self.path.closed = YES;
    [self writePath:self.path];
    *forceUpdate = YES;
    return;
  }

  if (activePart >= kOSCPathPointBase && activePart < kOSCInHandleBase &&
      (modifiers & kFxModifierKey_OPTION)) {
    NSInteger idx = activePart - kOSCPathPointBase;
    if (idx >= 0 && idx < (NSInteger)self.path.count) {
      [self.path removeAtIndex:idx];
      [self writePath:self.path];
    }
    *forceUpdate = YES;
    return;
  }

  if (activePart >= kOSCPathPointBase && activePart < kOSCInHandleBase) {
    NSInteger idx = activePart - kOSCPathPointBase;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

    // Double-click: toggle linear/bezier
    if (self.lastClickIndex == idx && (now - self.lastClickTime) < 0.35) {
      KKBezierPoint pt = [self.path pointAtIndex:idx];
      if (pt.type == KKBezierPointBezier) {
        [self.path setType:KKBezierPointLinear atIndex:idx];
        [self.path setInHandle:(simd_float2){0, 0} atIndex:idx];
        [self.path setOutHandle:(simd_float2){0, 0} atIndex:idx];
      } else {
        // Generate default handles based on neighbouring points
        simd_float2 pos = {pt.x, pt.y};
        simd_float2 prev = pos, next = pos;
        if (idx > 0) {
          KKBezierPoint pp = [self.path pointAtIndex:idx - 1];
          prev = (simd_float2){pp.x, pp.y};
        }
        if (idx + 1 < (NSInteger)self.path.count) {
          KKBezierPoint np = [self.path pointAtIndex:idx + 1];
          next = (simd_float2){np.x, np.y};
        }
        // Tangent direction from prev→next, handle length = 1/4 of that
        simd_float2 dir = (next - prev) * 0.25f;
        [self.path setOutHandle:dir atIndex:idx];
        [self.path setInHandle:(simd_float2){-dir.x, -dir.y} atIndex:idx];
        [self.path setType:KKBezierPointBezier atIndex:idx];
      }
      [self writePath:self.path];
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

  if (activePart >= kOSCPathSegmentBase) {
    NSInteger segIdx = activePart - kOSCPathSegmentBase;
    simd_float2 objPos =
        [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
    [self.path insertAtIndex:segIdx + 1 position:objPos];
    [self writePath:self.path];
    self.dragIndex = segIdx + 1;
    self.dragIsInHandle = NO;
    self.dragIsOutHandle = NO;
    *forceUpdate = YES;
    return;
  }

  simd_float2 objPos =
      [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
  [self.path insertAtIndex:self.path.count position:objPos];
  [self writePath:self.path];

  self.dragIndex = (NSInteger)self.path.count - 1;
  self.dragIsInHandle = NO;
  self.dragIsOutHandle = YES;

  *forceUpdate = YES;
  [super mouseDownAtPositionX:positionX
                    positionY:positionY
                   activePart:activePart
                    modifiers:modifiers
                  forceUpdate:forceUpdate
                       atTime:time];
}

- (void)mouseDraggedAtPositionX:(double)positionX
                      positionY:(double)positionY
                     activePart:(NSInteger)activePart
                      modifiers:(NSUInteger)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time {
  if (self.dragIndex < 0 || self.dragIndex >= (NSInteger)self.path.count)
    return;

  simd_float2 objPos =
      [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];

  BOOL breakSymmetry = (modifiers & kFxModifierKey_OPTION) != 0;

  if (self.dragIsInHandle) {
    KKBezierPoint pt = [self.path pointAtIndex:self.dragIndex];
    simd_float2 offset = {objPos.x - pt.x, objPos.y - pt.y};
    [self.path setInHandle:offset atIndex:self.dragIndex];
    if (!breakSymmetry) {
      simd_float2 mirror = {-offset.x, -offset.y};
      [self.path setOutHandle:mirror atIndex:self.dragIndex];
    }
    [self.path setType:KKBezierPointBezier atIndex:self.dragIndex];
  } else if (self.dragIsOutHandle) {
    KKBezierPoint pt = [self.path pointAtIndex:self.dragIndex];
    simd_float2 offset = {objPos.x - pt.x, objPos.y - pt.y};
    [self.path setOutHandle:offset atIndex:self.dragIndex];
    if (!breakSymmetry) {
      simd_float2 mirror = {-offset.x, -offset.y};
      [self.path setInHandle:mirror atIndex:self.dragIndex];
    }
    [self.path setType:KKBezierPointBezier atIndex:self.dragIndex];
  } else {
    [self.path moveAtIndex:self.dragIndex to:objPos];
  }

  [self writePath:self.path];
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

  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  [oscAPI setCursor:self.penAddCursor];

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
  if (asciiKey == 127 || asciiKey == 8) {
    self.path = [self readPath];
    if (self.path.count > 0) {
      [self.path removeAtIndex:self.path.count - 1];
      [self writePath:self.path];
      *forceUpdate = YES;
      *didHandle = YES;
    }
  }
}

@end
