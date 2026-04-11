/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC.h"
#import "Constants.h"
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

- (CGPoint)canvasPointForObjectX:(double)objX objY:(double)objY {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  double cx, cy;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:objX
                          fromY:objY
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&cx
                            toY:&cy];
  return CGPointMake(cx, cy);
}

- (simd_float2)objectPointForCanvasX:(double)canvasX canvasY:(double)canvasY {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  double ox, oy;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                          fromX:canvasX
                          fromY:canvasY
                        toSpace:kFxDrawingCoordinates_OBJECT
                            toX:&ox
                            toY:&oy];
  return (simd_float2){(float)ox, (float)oy};
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

  self.path = [self readPath];
  if (self.path.count == 0)
    return;

  simd_float4 strokeColor = [[NSColor systemRedColor] simdFloat4];
  simd_float4 handleColor = strokeColor;
  handleColor.w = 0.33f;

  // Draw bezier segments between consecutive points
  for (NSUInteger i = 0; i + 1 < self.path.count; i++) {
    KKBezierPoint p0 = [self.path pointAtIndex:i];
    KKBezierPoint p1 = [self.path pointAtIndex:i + 1];

    CGPoint prev = CGPointZero;
    for (NSUInteger s = 0; s <= 32; s++) {
      float t = (float)s / 32.0f;
      float u = 1.0f - t;

      simd_float2 a = {p0.x, p0.y};
      simd_float2 cp1 = {p0.x + p0.outX, p0.y + p0.outY};
      simd_float2 cp2 = {p1.x + p1.inX, p1.y + p1.inY};
      simd_float2 b = {p1.x, p1.y};

      simd_float2 pos = u * u * u * a + 3.0f * u * u * t * cp1 +
                        3.0f * u * t * t * cp2 + t * t * t * b;

      CGPoint cur = [self canvasPointForObjectX:pos.x objY:pos.y];
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
    CGPoint ptCanvas = [self canvasPointForObjectX:pt.x objY:pt.y];

    if (pt.type == KKBezierPointBezier) {
      CGPoint inCanvas = [self canvasPointForObjectX:pt.x + pt.inX
                                                objY:pt.y + pt.inY];
      CGPoint outCanvas = [self canvasPointForObjectX:pt.x + pt.outX
                                                 objY:pt.y + pt.outY];

      [self drawLineFrom:ptCanvas
                        to:inCanvas
                     color:handleColor
                 halfWidth:1.0f
          destinationImage:destinationImage];
      [self drawLineFrom:ptCanvas
                        to:outCanvas
                     color:handleColor
                 halfWidth:1.0f
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
  // Always return a non-zero part so FCP routes clicks to us
  *activePart = kOSCCanvas;
  self.path = [self readPath];

  double hitRadius = 8.0;
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];

  // Test handles first
  for (NSUInteger i = 0; i < self.path.count; i++) {
    KKBezierPoint pt = [self.path pointAtIndex:i];
    if (pt.type != KKBezierPointBezier)
      continue;

    CGPoint inCanvas = [self canvasPointForObjectX:pt.x + pt.inX
                                              objY:pt.y + pt.inY];
    if (hypot(positionX - inCanvas.x, positionY - inCanvas.y) < hitRadius) {
      *activePart = kOSCInHandleBase + (NSInteger)i;
      [oscAPI setCursor:_editPointsCursor];
      return;
    }

    CGPoint outCanvas = [self canvasPointForObjectX:pt.x + pt.outX
                                               objY:pt.y + pt.outY];
    if (hypot(positionX - outCanvas.x, positionY - outCanvas.y) < hitRadius) {
      *activePart = kOSCOutHandleBase + (NSInteger)i;
      [oscAPI setCursor:_editPointsCursor];
      return;
    }
  }

  // Test points
  for (NSUInteger i = 0; i < self.path.count; i++) {
    KKBezierPoint pt = [self.path pointAtIndex:i];
    CGPoint ptCanvas = [self canvasPointForObjectX:pt.x objY:pt.y];
    if (hypot(positionX - ptCanvas.x, positionY - ptCanvas.y) < hitRadius) {
      *activePart = kOSCPathPointBase + (NSInteger)i;
      [oscAPI setCursor:_moveCursor];
      return;
    }
  }

  // Empty space - show pen add cursor
  [oscAPI setCursor:self.penAddCursor];
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  self.path = [self readPath];

  // Drag existing point
  if (activePart >= kOSCPathPointBase && activePart < kOSCInHandleBase) {
    self.dragIndex = activePart - kOSCPathPointBase;
    self.dragIsInHandle = NO;
    self.dragIsOutHandle = NO;
    *forceUpdate = YES;
    return;
  }

  // Drag in-handle
  if (activePart >= kOSCInHandleBase && activePart < kOSCOutHandleBase) {
    self.dragIndex = activePart - kOSCInHandleBase;
    self.dragIsInHandle = YES;
    self.dragIsOutHandle = NO;
    *forceUpdate = YES;
    return;
  }

  // Drag out-handle
  if (activePart >= kOSCOutHandleBase && activePart < kOSCPathSegmentBase) {
    self.dragIndex = activePart - kOSCOutHandleBase;
    self.dragIsInHandle = NO;
    self.dragIsOutHandle = YES;
    *forceUpdate = YES;
    return;
  }

  // Canvas area or empty space: add a new point
  simd_float2 objPos = [self objectPointForCanvasX:positionX canvasY:positionY];
  [self.path insertAtIndex:self.path.count position:objPos];
  [self writePath:self.path];

  // Drag the new point's out-handle to create bezier curves
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

  simd_float2 objPos = [self objectPointForCanvasX:positionX canvasY:positionY];

  if (self.dragIsInHandle) {
    KKBezierPoint pt = [self.path pointAtIndex:self.dragIndex];
    simd_float2 offset = {objPos.x - pt.x, objPos.y - pt.y};
    [self.path setInHandle:offset atIndex:self.dragIndex];
  } else if (self.dragIsOutHandle) {
    KKBezierPoint pt = [self.path pointAtIndex:self.dragIndex];
    simd_float2 offset = {objPos.x - pt.x, objPos.y - pt.y};
    [self.path setOutHandle:offset atIndex:self.dragIndex];
    // Mirror in-handle for symmetric bezier
    simd_float2 mirror = {-offset.x, -offset.y};
    [self.path setInHandle:mirror atIndex:self.dragIndex];
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
  // Delete/Backspace removes last point
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
