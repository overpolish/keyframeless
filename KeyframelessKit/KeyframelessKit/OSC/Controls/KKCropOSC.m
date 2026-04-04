/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKCropOSC.h"
#import <CoreGraphics/CGEventSource.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKHostInfo.h>
#import <KeyframelessKit/KKOSCLabel.h>
#import <KeyframelessKit/KKPointOSC.h>
#import <KeyframelessKit/KKRectBorderOSC.h>

#define CLAMP(x, lo, hi) MAX((lo), MIN((hi), (x)))

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

static const CropPointConfig kCropConfigs[KKCropPointCount] = {
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

@implementation KKCropOSC {
  double _dragStartObjX;
  double _dragStartObjY;
  double _dragStartCropTop;
  double _dragStartCropBottom;
  double _dragStartCropLeft;
  double _dragStartCropRight;
  double _cropStartAspect;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super init];
  if (self) {
    _apiManager = apiManager;
    _hoveredIndex = -1;
    _draggingIndex = -1;

    NSMutableArray *points =
        [NSMutableArray arrayWithCapacity:KKCropPointCount];
    for (int i = 0; i < KKCropPointCount; i++) {
      KKPointOSC *pt = [[KKPointOSC alloc] initWithAPIManager:apiManager];
      pt.clearsOnDraw = NO;
      pt.oscRadius = 5.0f;
      pt.outlineWidth = 1.5f;
      [points addObject:pt];
    }
    _pointOSCs = points;

    _borderOSC = [[KKRectBorderOSC alloc] initWithAPIManager:apiManager];
    _borderOSC.clearsOnDraw = NO;
    _sizeLabel = [[KKOSCLabel alloc] initWithAPIManager:apiManager];
    _sizeLabel.monospaced = YES;
  }
  return self;
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
    [paramGetAPI getFloatValue:cL fromParameter:self.cropLeftParam atTime:time];
    [paramGetAPI getFloatValue:cR
                 fromParameter:self.cropRightParam
                        atTime:time];
    [paramGetAPI getFloatValue:cT fromParameter:self.cropTopParam atTime:time];
    [paramGetAPI getFloatValue:cB
                 fromParameter:self.cropBottomParam
                        atTime:time];
  }
}

- (BOOL)getTopRight:(CGPoint *)topRight
         bottomLeft:(CGPoint *)bottomLeft
    fullImageCanvas:(CGSize *)fullImageCanvas
             atTime:(CMTime)time {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
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

  double cL, cR, cT, cB;
  [self readCropValues:&cL cR:&cR cT:&cT cB:&cB atTime:time];

  float canvasW = fullTR.x - fullBL.x;
  float canvasH = fullTR.y - fullBL.y;
  topRight->x = fullTR.x - cR * canvasW;
  topRight->y = fullTR.y - cT * canvasH;
  bottomLeft->x = fullBL.x + cL * canvasW;
  bottomLeft->y = fullBL.y + cB * canvasH;

  if (fullImageCanvas)
    *fullImageCanvas = CGSizeMake(fabs(canvasW), fabs(canvasH));

  return YES;
}

- (void)drawWithDestinationImage:(FxImageTile *)destinationImage
                          atTime:(CMTime)time {
  CGPoint topRight = {0, 0}, bottomLeft = {0, 0};
  CGSize fullCanvas = {0, 0};
  if (![self getTopRight:&topRight
               bottomLeft:&bottomLeft
          fullImageCanvas:&fullCanvas
                   atTime:time])
    return;

  [self.borderOSC drawWithTopRight:topRight
                        bottomLeft:bottomLeft
                  destinationImage:destinationImage];

  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  double zoom = [oscAPI canvasZoom];
  if (zoom < 0.001)
    zoom = 1.0;

  double cL, cR, cT, cB;
  [self readCropValues:&cL cR:&cR cT:&cT cB:&cB atTime:time];
  // Motion under-reports by ~1px without the nudge, FCP over-reports with it.
  double nudge = [KKHostInfo isRunningInFinalCut] ? 0.0 : 0.5;
  double fullW = round(fabs(fullCanvas.width) / zoom + nudge);
  double fullH = round(fabs(fullCanvas.height) / zoom + nudge);
  double cropW = (1.0 - cL - cR) * lround(fullW);
  double cropH = (1.0 - cT - cB) * lround(fullH);
  long pxW = lround(cropW);
  long pxH = lround(cropH);
  self.sizeLabel.text = [NSString stringWithFormat:@"%ld x %ld", pxW, pxH];
  CGPoint labelPos = {topRight.x, bottomLeft.y};
  CGSize labelSize = self.sizeLabel.size;
  labelPos.x -= labelSize.width / 2.0;
  BOOL flippedY = topRight.y > bottomLeft.y;
  labelPos.y += flippedY ? -(labelSize.height / 2.0 + 4.0)
                         : (labelSize.height / 2.0 + 4.0);
  [self.sizeLabel drawAtCanvasPosition:labelPos
                      destinationImage:destinationImage];

  for (int i = 0; i < KKCropPointCount; i++) {
    CGPoint pos = cropPointPosition(i, topRight, bottomLeft);
    [self.pointOSCs[i] drawAtCanvasPosition:pos
                                  isHovered:(self.hoveredIndex == i)
                                   isActive:(self.draggingIndex == i)
                           destinationImage:destinationImage
                                     atTime:time];
  }
}

- (NSInteger)hitTestAtMousePositionX:(double)positionX
                           positionY:(double)positionY
                              atTime:(CMTime)time {
  self.hoveredIndex = -1;
  NSInteger result = KKCropPartNone;

  CGPoint topRight = {0, 0}, bottomLeft = {0, 0};
  if (![self getTopRight:&topRight
               bottomLeft:&bottomLeft
          fullImageCanvas:NULL
                   atTime:time])
    return result;

  double minX = fmin(bottomLeft.x, topRight.x);
  double maxX = fmax(bottomLeft.x, topRight.x);
  double minY = fmin(bottomLeft.y, topRight.y);
  double maxY = fmax(bottomLeft.y, topRight.y);
  if (positionX >= minX && positionX <= maxX && positionY >= minY &&
      positionY <= maxY) {
    result = KKCropPartRect;
  }

  for (int i = 0; i < KKCropPointCount; i++) {
    CGPoint pos = cropPointPosition(i, topRight, bottomLeft);
    double dx = positionX - pos.x;
    double dy = positionY - pos.y;
    if (sqrt(dx * dx + dy * dy) < self.pointOSCs[i].hitRadius) {
      self.hoveredIndex = i;
      result = KKCropPartPointBase + i;
    }
  }

  return result;
}

- (void)mouseDownForPart:(NSInteger)part
               positionX:(double)positionX
               positionY:(double)positionY
                  atTime:(CMTime)time {
  if (part == KKCropPartRect) {
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
    return;
  }

  NSInteger cropIdx = part - KKCropPartPointBase;
  if (cropIdx >= 0 && cropIdx < KKCropPointCount) {
    double cL, cR, cT, cB;
    [self readCropValues:&cL cR:&cR cT:&cT cB:&cB atTime:time];
    double startW = 1.0 - cL - cR;
    double startH = 1.0 - cT - cB;
    _cropStartAspect = (startH > 0.001) ? startW / startH : 1.0;
    self.draggingIndex = cropIdx;
  }
}

- (void)setCropLeft:(double)cL
              right:(double)cR
                top:(double)cT
             bottom:(double)cB
             atTime:(CMTime)time {
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!paramSetAPI)
    return;
  [paramSetAPI setFloatValue:cL toParameter:self.cropLeftParam atTime:time];
  [paramSetAPI setFloatValue:cR toParameter:self.cropRightParam atTime:time];
  [paramSetAPI setFloatValue:cT toParameter:self.cropTopParam atTime:time];
  [paramSetAPI setFloatValue:cB toParameter:self.cropBottomParam atTime:time];
}

- (void)mouseDraggedForPart:(NSInteger)part
                  positionX:(double)positionX
                  positionY:(double)positionY
                forceUpdate:(BOOL *)forceUpdate
                     atTime:(CMTime)time {
  if (part == KKCropPartRect) {
    [self dragRectAtPositionX:positionX
                    positionY:positionY
                  forceUpdate:forceUpdate
                       atTime:time];
    return;
  }

  NSInteger cropIdx = part - KKCropPartPointBase;
  if (cropIdx >= 0 && cropIdx < KKCropPointCount) {
    [self dragPointAtIndex:cropIdx
                 positionX:positionX
                 positionY:positionY
               forceUpdate:forceUpdate
                    atTime:time];
  }
}

- (void)dragRectAtPositionX:(double)positionX
                  positionY:(double)positionY
                forceUpdate:(BOOL *)forceUpdate
                     atTime:(CMTime)time {
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

  [self setCropLeft:newLeft
              right:newRight
                top:newTop
             bottom:newBottom
             atTime:time];
  *forceUpdate = YES;
}

- (void)dragPointAtIndex:(NSInteger)cropIdx
               positionX:(double)positionX
               positionY:(double)positionY
             forceUpdate:(BOOL *)forceUpdate
                  atTime:(CMTime)time {
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
      double w = 1.0 - cL - cR;
      double targetH = w / _cropStartAspect;
      double currentH = 1.0 - cT - cB;
      double diff = currentH - targetH;
      if (cfg.top)
        cT = CLAMP(cT + diff, 0.0, 1.0);
      else
        cB = CLAMP(cB + diff, 0.0, 1.0);
    } else if (changesW) {
      double w = 1.0 - cL - cR;
      double targetH = w / _cropStartAspect;
      double diff = (1.0 - cT - cB) - targetH;
      cT = CLAMP(cT + diff * 0.5, 0.0, 1.0);
      cB = CLAMP(cB + diff * 0.5, 0.0, 1.0);
    } else {
      double h = 1.0 - cT - cB;
      double targetW = h * _cropStartAspect;
      double diff = (1.0 - cL - cR) - targetW;
      cL = CLAMP(cL + diff * 0.5, 0.0, 1.0);
      cR = CLAMP(cR + diff * 0.5, 0.0, 1.0);
    }
  }

  [self setCropLeft:cL right:cR top:cT bottom:cB atTime:time];
  *forceUpdate = YES;
}

- (void)mouseUp {
  self.draggingIndex = -1;
  self.hoveredIndex = -1;
}

@end
