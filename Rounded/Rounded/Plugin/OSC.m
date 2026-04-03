/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC.h"
#import "Constants.h"
#import <CoreGraphics/CGEventSource.h>
#import <FxPlug/FxPlugSDK.h>

#define CLAMP(x, lo, hi) MAX((lo), MIN((hi), (x)))

static const NSInteger kRadiusPart = 1;
static const NSInteger kCropPointBasePart = 2;
static const NSInteger kCropRectPart = 10;

enum {
  kCropPt_TopLeft = 0,
  kCropPt_TopCenter,
  kCropPt_TopRight,
  kCropPt_RightCenter,
  kCropPt_BottomRight,
  kCropPt_BottomCenter,
  kCropPt_BottomLeft,
  kCropPt_LeftCenter,
};

typedef struct {
  BOOL left;
  BOOL right;
  BOOL top;
  BOOL bottom;
  BOOL isEdge;
} CropPointConfig;

static const CropPointConfig kCropConfigs[kCropPointCount] = {
    {YES, NO, YES, NO, NO}, // TopLeft
    {NO, NO, YES, NO, YES}, // TopCenter
    {NO, YES, YES, NO, NO}, // TopRight
    {NO, YES, NO, NO, YES}, // RightCenter
    {NO, YES, NO, YES, NO}, // BottomRight
    {NO, NO, NO, YES, YES}, // BottomCenter
    {YES, NO, NO, YES, NO}, // BottomLeft
    {YES, NO, NO, NO, YES}, // LeftCenter
};

static CGPoint cropPointPosition(NSInteger idx, CGPoint topRight,
                                 CGPoint bottomLeft) {
  double mx = (topRight.x + bottomLeft.x) * 0.5;
  double my = (topRight.y + bottomLeft.y) * 0.5;
  switch (idx) {
  case kCropPt_TopLeft:
    return (CGPoint){bottomLeft.x, topRight.y};
  case kCropPt_TopCenter:
    return (CGPoint){mx, topRight.y};
  case kCropPt_TopRight:
    return (CGPoint){topRight.x, topRight.y};
  case kCropPt_RightCenter:
    return (CGPoint){topRight.x, my};
  case kCropPt_BottomRight:
    return (CGPoint){topRight.x, bottomLeft.y};
  case kCropPt_BottomCenter:
    return (CGPoint){mx, bottomLeft.y};
  case kCropPt_BottomLeft:
    return (CGPoint){bottomLeft.x, bottomLeft.y};
  case kCropPt_LeftCenter:
    return (CGPoint){bottomLeft.x, my};
  default:
    return CGPointZero;
  }
}

static float paddingForRadius(double radius, float minDim) {
  float t = radius / 100.0f;
  float power = 5.0f * (1.0f - t) + 2.0f * t;
  float cornerRadiusPixels = minDim * 0.5f * t;
  float circleInsetFactor = 1.0f - 1.0f / sqrtf(2.0f);
  float squircleInsetFactor = 1.0f - 1.0f / powf(2.0f, 1.0f / power);
  float insetFactor = squircleInsetFactor * (1.0f - t) + circleInsetFactor * t;
  float squircleCorrection = 1.0f - 0.22f * sinf(t * M_PI);
  return minDim * 0.05f + cornerRadiusPixels * insetFactor * squircleCorrection;
}

static BOOL getCornerPoints(id<PROAPIAccessing> apiManager, CGPoint *topRight,
                            CGPoint *bottomLeft, CGSize *fullImageCanvas,
                            CMTime time) {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return NO;

  CGPoint fullTR = {0, 0}, fullBL = {0, 0};
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:1.0
                          fromY:1.0
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&fullTR.x
                            toY:&fullTR.y];
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:0.0
                          fromY:0.0
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&fullBL.x
                            toY:&fullBL.y];

  double cropTop = 0.0, cropBottom = 0.0, cropLeft = 0.0, cropRight = 0.0;
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (paramGetAPI) {
    [paramGetAPI getFloatValue:&cropTop
                 fromParameter:kParamCropTop
                        atTime:time];
    [paramGetAPI getFloatValue:&cropBottom
                 fromParameter:kParamCropBottom
                        atTime:time];
    [paramGetAPI getFloatValue:&cropLeft
                 fromParameter:kParamCropLeft
                        atTime:time];
    [paramGetAPI getFloatValue:&cropRight
                 fromParameter:kParamCropRight
                        atTime:time];
  }

  float canvasW = fullTR.x - fullBL.x;
  float canvasH = fullTR.y - fullBL.y;
  topRight->x = fullTR.x - cropRight * canvasW;
  topRight->y = fullTR.y - cropTop * canvasH;
  bottomLeft->x = fullBL.x + cropLeft * canvasW;
  bottomLeft->y = fullBL.y + cropBottom * canvasH;

  if (fullImageCanvas)
    *fullImageCanvas = CGSizeMake(fabs(canvasW), fabs(canvasH));

  return YES;
}

@implementation RoundedOSC {
  CGPoint _dragStartPosition;
  double _dragStartRadius;
  double _dragStartCropTop;
  double _dragStartCropBottom;
  double _dragStartCropLeft;
  double _dragStartCropRight;
  double _dragStartObjX;
  double _dragStartObjY;
  double _cropStartAspect;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    self.clearsOnDraw = NO;
    self.cropHoveredIndex = -1;
    self.cropDraggingIndex = -1;

    NSMutableArray *points = [NSMutableArray arrayWithCapacity:kCropPointCount];
    for (int i = 0; i < kCropPointCount; i++) {
      KKPointOSC *pt = [[KKPointOSC alloc] initWithAPIManager:apiManager];
      pt.clearsOnDraw = NO;
      pt.oscRadius = 5.0f;
      pt.outlineWidth = 1.5f;
      [points addObject:pt];
    }
    self.cropPointOSCs = points;

    self.cropBorderOSC =
        [[KKRectBorderOSC alloc] initWithAPIManager:apiManager];
    self.cropBorderOSC.clearsOnDraw = NO;
    self.cropSizeLabel = [[KKOSCLabel alloc] initWithAPIManager:apiManager];
    self.cropSizeLabel.monospaced = YES;
  }
  return self;
}

- (CGPoint)oscPositionAtTime:(CMTime)time {
  CGPoint topRight = {0, 0}, bottomLeft = {0, 0};
  if (!getCornerPoints(self.apiManager, &topRight, &bottomLeft, NULL, time))
    return CGPointZero;

  float canvasImageWidth = topRight.x - bottomLeft.x;
  float canvasImageHeight = topRight.y - bottomLeft.y;
  BOOL isFlippedX = canvasImageWidth < 0;
  BOOL isFlippedY = canvasImageHeight < 0;
  float minDim = fminf(fabsf(canvasImageWidth), fabsf(canvasImageHeight));

  float padding = 0.0f;
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (paramGetAPI) {
    double paramRadius = 0.0;
    [paramGetAPI getFloatValue:&paramRadius fromParameter:1 atTime:time];
    padding = paddingForRadius(paramRadius, minDim);
  }

  float offsetX =
      isFlippedX ? -(self.oscSize + padding) : (self.oscSize + padding);
  float offsetY =
      isFlippedY ? -(self.oscSize + padding) : (self.oscSize + padding);

  return CGPointMake(topRight.x - offsetX, topRight.y - offsetY);
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

  CGPoint topRight = {0, 0}, bottomLeft = {0, 0};
  CGSize fullCanvas = {0, 0};
  if (getCornerPoints(self.apiManager, &topRight, &bottomLeft, &fullCanvas,
                      time)) {
    [self.cropBorderOSC drawWithTopRight:topRight
                              bottomLeft:bottomLeft
                        destinationImage:destinationImage];

    id<FxOnScreenControlAPI_v4> oscAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    double zoom = [oscAPI canvasZoom];
    if (zoom < 0.001)
      zoom = 1.0;
    id<FxParameterRetrievalAPI_v6> sizeParamAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    double cL = 0, cR = 0, cT = 0, cB = 0;
    if (sizeParamAPI) {
      [sizeParamAPI getFloatValue:&cL fromParameter:kParamCropLeft atTime:time];
      [sizeParamAPI getFloatValue:&cR
                    fromParameter:kParamCropRight
                           atTime:time];
      [sizeParamAPI getFloatValue:&cT fromParameter:kParamCropTop atTime:time];
      [sizeParamAPI getFloatValue:&cB
                    fromParameter:kParamCropBottom
                           atTime:time];
    }
    double fullW = round(fabs(fullCanvas.width) / zoom + 0.5);
    double fullH = round(fabs(fullCanvas.height) / zoom + 0.5);
    double cropW = (1.0 - cL - cR) * lround(fullW);
    double cropH = (1.0 - cT - cB) * lround(fullH);
    long pxW = lround(cropW);
    long pxH = lround(cropH);
    self.cropSizeLabel.text =
        [NSString stringWithFormat:@"%ld x %ld", pxW, pxH];
    CGPoint labelPos = {topRight.x, bottomLeft.y};
    CGSize labelSize = self.cropSizeLabel.size;
    labelPos.x -= labelSize.width / 2.0;
    BOOL flippedY = topRight.y > bottomLeft.y;
    labelPos.y += flippedY ? -(labelSize.height / 2.0 + 4.0)
                           : (labelSize.height / 2.0 + 4.0);
    [self.cropSizeLabel drawAtCanvasPosition:labelPos
                            destinationImage:destinationImage];

    for (int i = 0; i < kCropPointCount; i++) {
      CGPoint pos = cropPointPosition(i, topRight, bottomLeft);
      [self.cropPointOSCs[i] drawAtCanvasPosition:pos
                                        isHovered:(self.cropHoveredIndex == i)
                                         isActive:(self.cropDraggingIndex == i)
                                 destinationImage:destinationImage
                                           atTime:time];
    }
  }

  CGPoint radiusPos = [self oscPositionAtTime:time];
  [self drawAtCanvasPosition:radiusPos
                   isHovered:(activePart == kRadiusPart)
                    isActive:self.isDragging && (activePart == kRadiusPart)
            destinationImage:destinationImage
                      atTime:time];
}

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  self.cropHoveredIndex = -1;
  *activePart = 0;

  CGPoint topRight = {0, 0}, bottomLeft = {0, 0};
  if (getCornerPoints(self.apiManager, &topRight, &bottomLeft, NULL, time)) {
    double minX = fmin(bottomLeft.x, topRight.x);
    double maxX = fmax(bottomLeft.x, topRight.x);
    double minY = fmin(bottomLeft.y, topRight.y);
    double maxY = fmax(bottomLeft.y, topRight.y);
    if (positionX >= minX && positionX <= maxX && positionY >= minY &&
        positionY <= maxY) {
      *activePart = kCropRectPart;
    }

    for (int i = 0; i < kCropPointCount; i++) {
      CGPoint pos = cropPointPosition(i, topRight, bottomLeft);
      double dx = positionX - pos.x;
      double dy = positionY - pos.y;
      if (sqrt(dx * dx + dy * dy) < self.cropPointOSCs[i].hitRadius) {
        self.cropHoveredIndex = i;
        *activePart = kCropPointBasePart + i;
      }
    }
  }

  if ([self hitTestAtMousePositionX:positionX
                          positionY:positionY
                             atTime:time]) {
    *activePart = kRadiusPart;
  }
}

- (void)readCropValues:(double *)cL
                    cR:(double *)cR
                    cT:(double *)cT
                    cB:(double *)cB
                atTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  *cL = 0;
  *cR = 0;
  *cT = 0;
  *cB = 0;
  if (paramGetAPI) {
    [paramGetAPI getFloatValue:cL fromParameter:kParamCropLeft atTime:time];
    [paramGetAPI getFloatValue:cR fromParameter:kParamCropRight atTime:time];
    [paramGetAPI getFloatValue:cT fromParameter:kParamCropTop atTime:time];
    [paramGetAPI getFloatValue:cB fromParameter:kParamCropBottom atTime:time];
  }
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  if (activePart == kCropRectPart) {
    id<FxOnScreenControlAPI_v4> oscAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    if (oscAPI) {
      [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                              fromX:positionX
                              fromY:positionY
                            toSpace:kFxDrawingCoordinates_OBJECT
                                toX:&_dragStartObjX
                                toY:&_dragStartObjY];
    }
    [self readCropValues:&_dragStartCropLeft
                      cR:&_dragStartCropRight
                      cT:&_dragStartCropTop
                      cB:&_dragStartCropBottom
                  atTime:time];
    *forceUpdate = YES;
    return;
  }

  NSInteger cropIdx = activePart - kCropPointBasePart;
  if (cropIdx >= 0 && cropIdx < kCropPointCount) {
    double cL, cR, cT, cB;
    [self readCropValues:&cL cR:&cR cT:&cT cB:&cB atTime:time];
    double startW = 1.0 - cL - cR;
    double startH = 1.0 - cT - cB;
    _cropStartAspect = (startH > 0.001) ? startW / startH : 1.0;
    self.cropDraggingIndex = cropIdx;
    *forceUpdate = YES;
    return;
  }

  [super mouseDownAtPositionX:positionX
                    positionY:positionY
                   activePart:activePart
                    modifiers:modifiers
                  forceUpdate:forceUpdate
                       atTime:time];

  if (activePart == 0)
    return;

  _dragStartPosition = CGPointMake(positionX, positionY);

  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (paramGetAPI) {
    [paramGetAPI getFloatValue:&_dragStartRadius fromParameter:1 atTime:time];
  }
}

- (void)mouseDraggedAtPositionX:(double)positionX
                      positionY:(double)positionY
                     activePart:(NSInteger)activePart
                      modifiers:(NSUInteger)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time {
  if (activePart == kCropRectPart) {
    id<FxOnScreenControlAPI_v4> oscAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    if (!oscAPI)
      return;

    double objX, objY;
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                            fromX:positionX
                            fromY:positionY
                          toSpace:kFxDrawingCoordinates_OBJECT
                              toX:&objX
                              toY:&objY];

    double deltaX = objX - _dragStartObjX;
    double deltaY = objY - _dragStartObjY;

    double newLeft = CLAMP(_dragStartCropLeft + deltaX, 0.0, 1.0);
    double newRight = CLAMP(_dragStartCropRight - deltaX, 0.0, 1.0);
    double newBottom = CLAMP(_dragStartCropBottom + deltaY, 0.0, 1.0);
    double newTop = CLAMP(_dragStartCropTop - deltaY, 0.0, 1.0);

    id<FxParameterSettingAPI_v5> paramSetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    if (paramSetAPI) {
      [paramSetAPI setFloatValue:newTop toParameter:kParamCropTop atTime:time];
      [paramSetAPI setFloatValue:newBottom
                     toParameter:kParamCropBottom
                          atTime:time];
      [paramSetAPI setFloatValue:newLeft
                     toParameter:kParamCropLeft
                          atTime:time];
      [paramSetAPI setFloatValue:newRight
                     toParameter:kParamCropRight
                          atTime:time];
    }
    *forceUpdate = YES;
    return;
  }

  NSInteger cropIdx = activePart - kCropPointBasePart;
  if (cropIdx >= 0 && cropIdx < kCropPointCount) {
    id<FxOnScreenControlAPI_v4> oscAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    if (!oscAPI)
      return;

    double objX, objY;
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                            fromX:positionX
                            fromY:positionY
                          toSpace:kFxDrawingCoordinates_OBJECT
                              toX:&objX
                              toY:&objY];

    CropPointConfig cfg = kCropConfigs[cropIdx];
    double cL, cR, cT, cB;
    [self readCropValues:&cL cR:&cR cT:&cT cB:&cB atTime:time];
    double prevL = cL, prevR = cR, prevT = cT, prevB = cB;

    CGEventFlags flags =
        CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
    BOOL optHeld = (flags & kCGEventFlagMaskAlternate) != 0;
    BOOL shiftHeld = (flags & kCGEventFlagMaskShift) != 0;

    if (cfg.left)
      cL = CLAMP(objX, 0.0, 1.0);
    if (cfg.right)
      cR = CLAMP(1.0 - objX, 0.0, 1.0);
    if (cfg.top)
      cT = CLAMP(1.0 - objY, 0.0, 1.0);
    if (cfg.bottom)
      cB = CLAMP(objY, 0.0, 1.0);

    if (optHeld) {
      if (cfg.isEdge) {
        if (cfg.top)
          cB = CLAMP(prevB + (cT - prevT), 0.0, 1.0);
        else if (cfg.bottom)
          cT = CLAMP(prevT + (cB - prevB), 0.0, 1.0);
        if (cfg.left)
          cR = CLAMP(prevR + (cL - prevL), 0.0, 1.0);
        else if (cfg.right)
          cL = CLAMP(prevL + (cR - prevR), 0.0, 1.0);
      } else {
        // Corner + opt: force pixel-space square
        double cx0, cy0, cx1, cy1;
        [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                                fromX:0.0
                                fromY:0.0
                              toSpace:kFxDrawingCoordinates_CANVAS
                                  toX:&cx0
                                  toY:&cy0];
        [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                                fromX:1.0
                                fromY:1.0
                              toSpace:kFxDrawingCoordinates_CANVAS
                                  toX:&cx1
                                  toY:&cy1];
        double imgW = fabs(cx1 - cx0);
        double imgH = fabs(cy1 - cy0);
        double aspect = (imgH > 0.001) ? imgW / imgH : 1.0;
        double w = 1.0 - cL - cR;
        double targetH = w * aspect;
        double currentH = 1.0 - cT - cB;
        double diff = currentH - targetH;
        if (cfg.top)
          cT = CLAMP(cT + diff, 0.0, 1.0);
        else
          cB = CLAMP(cB + diff, 0.0, 1.0);
      }
    }

    if (shiftHeld) {
      BOOL changesH = cfg.top || cfg.bottom;
      BOOL changesW = cfg.left || cfg.right;

      if (changesW && changesH) {
        // Corner: width drives, adjust the corner's own vertical edge
        double w = 1.0 - cL - cR;
        double targetH = w / _cropStartAspect;
        double currentH = 1.0 - cT - cB;
        double diff = currentH - targetH;
        if (cfg.top)
          cT = CLAMP(cT + diff, 0.0, 1.0);
        else
          cB = CLAMP(cB + diff, 0.0, 1.0);
      } else if (changesW) {
        // LeftCenter/RightCenter: width drives, adjust height symmetrically
        double w = 1.0 - cL - cR;
        double targetH = w / _cropStartAspect;
        double diff = (1.0 - cT - cB) - targetH;
        cT = CLAMP(cT + diff * 0.5, 0.0, 1.0);
        cB = CLAMP(cB + diff * 0.5, 0.0, 1.0);
      } else {
        // TopCenter/BottomCenter: height drives, adjust width symmetrically
        double h = 1.0 - cT - cB;
        double targetW = h * _cropStartAspect;
        double diff = (1.0 - cL - cR) - targetW;
        cL = CLAMP(cL + diff * 0.5, 0.0, 1.0);
        cR = CLAMP(cR + diff * 0.5, 0.0, 1.0);
      }
    }

    id<FxParameterSettingAPI_v5> paramSetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    if (paramSetAPI) {
      [paramSetAPI setFloatValue:cL toParameter:kParamCropLeft atTime:time];
      [paramSetAPI setFloatValue:cR toParameter:kParamCropRight atTime:time];
      [paramSetAPI setFloatValue:cT toParameter:kParamCropTop atTime:time];
      [paramSetAPI setFloatValue:cB toParameter:kParamCropBottom atTime:time];
    }
    *forceUpdate = YES;
    return;
  }

  if (activePart == 0)
    return;

  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!paramSetAPI)
    return;

  CGPoint topRight = {0, 0}, bottomLeft = {0, 0};
  if (!getCornerPoints(self.apiManager, &topRight, &bottomLeft, NULL, time))
    return;

  float canvasImageWidth = topRight.x - bottomLeft.x;
  float canvasImageHeight = topRight.y - bottomLeft.y;
  float minDim = fminf(fabsf(canvasImageWidth), fabsf(canvasImageHeight));
  BOOL isFlippedX = canvasImageWidth < 0;
  BOOL isFlippedY = canvasImageHeight < 0;

  double dx = positionX - topRight.x;
  double dy = positionY - topRight.y;
  double signX = isFlippedX ? -1.0 : 1.0;
  double signY = isFlippedY ? -1.0 : 1.0;

  double mouseDist = (-dx * signX + -dy * signY) * 0.5 - self.oscSize;

  float lo = 0.0f, hi = 100.0f;
  for (int i = 0; i < 32; i++) {
    float mid = (lo + hi) * 0.5f;
    float padding = paddingForRadius(mid, minDim);

    if (padding < mouseDist)
      lo = mid;
    else
      hi = mid;
  }

  double newRadius = CLAMP((lo + hi) * 0.5, 0.0, 100.0);
  [paramSetAPI setFloatValue:newRadius toParameter:1 atTime:time];
  *forceUpdate = YES;
}

- (void)mouseUpAtPositionX:(double)positionX
                 positionY:(double)positionY
                activePart:(NSInteger)activePart
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time {
  self.cropDraggingIndex = -1;
  self.cropHoveredIndex = -1;
  [super mouseUpAtPositionX:positionX
                  positionY:positionY
                 activePart:activePart
                  modifiers:modifiers
                forceUpdate:forceUpdate
                     atTime:time];
}

@end
