/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC.h"
#import "Constants.h"
#import <FxPlug/FxPlugSDK.h>

#define CLAMP(x, lo, hi) MAX((lo), MIN((hi), (x)))

static const NSInteger kRadiusPart = 1;
static const NSInteger kCropTopLeftPart = 2;
static const NSInteger kCropRectPart = 3;

/// Computes canvas-space padding offset for a given radius value and image
/// size. Matches squicle/circle inset geometry used to position the OSC.
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

/// Fetches crop-adjusted corner geometry in canvas space.
/// The crop parameters define a sub-rectangle of the image; the returned
/// corners reflect that bounding box.
/// @returns NO if API is unavailable.
static BOOL getCornerPoints(id<PROAPIAccessing> apiManager, CGPoint *topRight,
                            CGPoint *bottomLeft, CGSize *fullImageCanvas,
                            CMTime time) {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return NO;

  // Get full image corners in canvas space
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

  // Read crop edge insets
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

  // Apply edge insets to canvas corners
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
    self.cropTopLeftOSC = [[KKPointOSC alloc] initWithAPIManager:apiManager];
    self.cropTopLeftOSC.clearsOnDraw = NO;
    self.cropTopLeftOSC.oscRadius = 5.0f;
    self.cropTopLeftOSC.outlineWidth = 1.5f;
    self.cropBorderOSC =
        [[KKRectBorderOSC alloc] initWithAPIManager:apiManager];
    self.cropBorderOSC.clearsOnDraw = NO;
    self.cropSizeLabel = [[KKOSCLabel alloc] initWithAPIManager:apiManager];
    self.cropSizeLabel.monospaced = YES;
  }
  return self;
}

- (CGPoint)cropTopLeftCanvasPositionAtTime:(CMTime)time {
  CGPoint topRight = {0, 0}, bottomLeft = {0, 0};
  if (!getCornerPoints(self.apiManager, &topRight, &bottomLeft, NULL, time))
    return CGPointZero;
  return CGPointMake(bottomLeft.x, topRight.y);
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
  }

  CGPoint cropTL = {bottomLeft.x, topRight.y};
  [self.cropTopLeftOSC drawAtCanvasPosition:cropTL
                                  isHovered:self.cropTopLeftHovered
                                   isActive:self.cropTopLeftDragging
                           destinationImage:destinationImage
                                     atTime:time];

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
  self.cropTopLeftHovered = NO;
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
  }

  if ([self hitTestAtMousePositionX:positionX
                          positionY:positionY
                             atTime:time]) {
    *activePart = kRadiusPart;
  }

  CGPoint cropTL = [self cropTopLeftCanvasPositionAtTime:time];
  double dx = positionX - cropTL.x;
  double dy = positionY - cropTL.y;
  if (sqrt(dx * dx + dy * dy) < self.cropTopLeftOSC.hitRadius) {
    self.cropTopLeftHovered = YES;
    *activePart = kCropTopLeftPart;
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
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    if (paramGetAPI) {
      [paramGetAPI getFloatValue:&_dragStartCropTop
                   fromParameter:kParamCropTop
                          atTime:time];
      [paramGetAPI getFloatValue:&_dragStartCropBottom
                   fromParameter:kParamCropBottom
                          atTime:time];
      [paramGetAPI getFloatValue:&_dragStartCropLeft
                   fromParameter:kParamCropLeft
                          atTime:time];
      [paramGetAPI getFloatValue:&_dragStartCropRight
                   fromParameter:kParamCropRight
                          atTime:time];
    }
    *forceUpdate = YES;
    return;
  }

  if (activePart == kCropTopLeftPart) {
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    double cL = 0, cR = 0, cT = 0, cB = 0;
    if (paramGetAPI) {
      [paramGetAPI getFloatValue:&cL fromParameter:kParamCropLeft atTime:time];
      [paramGetAPI getFloatValue:&cR fromParameter:kParamCropRight atTime:time];
      [paramGetAPI getFloatValue:&cT fromParameter:kParamCropTop atTime:time];
      [paramGetAPI getFloatValue:&cB
                   fromParameter:kParamCropBottom
                          atTime:time];
    }
    double startW = 1.0 - cL - cR;
    double startH = 1.0 - cT - cB;
    _cropStartAspect = (startH > 0.001) ? startW / startH : 1.0;

    self.cropTopLeftDragging = YES;
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

  if (activePart == kCropTopLeftPart) {
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

    double cropLeft = CLAMP(objX, 0.0, 1.0);
    double cropTop = CLAMP(1.0 - objY, 0.0, 1.0);

    CGEventFlags flags =
        CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
    if (flags & kCGEventFlagMaskShift) {
      id<FxParameterRetrievalAPI_v6> paramGetAPI = [self.apiManager
          apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      double cropRight = 0.0, cropBottom = 0.0;
      if (paramGetAPI) {
        [paramGetAPI getFloatValue:&cropRight
                     fromParameter:kParamCropRight
                            atTime:time];
        [paramGetAPI getFloatValue:&cropBottom
                     fromParameter:kParamCropBottom
                            atTime:time];
      }
      double w = 1.0 - cropLeft - cropRight;
      double h = w / _cropStartAspect;
      cropTop = CLAMP(1.0 - cropBottom - h, 0.0, 1.0);
    } else if (flags & kCGEventFlagMaskAlternate) {
      id<FxParameterRetrievalAPI_v6> paramGetAPI = [self.apiManager
          apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      double cropRight = 0.0, cropBottom = 0.0;
      if (paramGetAPI) {
        [paramGetAPI getFloatValue:&cropRight
                     fromParameter:kParamCropRight
                            atTime:time];
        [paramGetAPI getFloatValue:&cropBottom
                     fromParameter:kParamCropBottom
                            atTime:time];
      }
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
      double w = 1.0 - cropLeft - cropRight;
      double h = w * aspect;
      cropTop = CLAMP(1.0 - cropBottom - h, 0.0, 1.0);
    }

    id<FxParameterSettingAPI_v5> paramSetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    if (paramSetAPI) {
      [paramSetAPI setFloatValue:cropLeft
                     toParameter:kParamCropLeft
                          atTime:time];
      [paramSetAPI setFloatValue:cropTop toParameter:kParamCropTop atTime:time];
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

  // Use signed distance along the diagonal axis
  double dx = positionX - topRight.x;
  double dy = positionY - topRight.y;
  double signX = isFlippedX ? -1.0 : 1.0;
  double signY = isFlippedY ? -1.0 : 1.0;

  // Projected distance from corner to mouse along the OSC's diagonal axis,
  // minus oscSize since padding(t) is what we're solving for, not the full
  // offset.
  double mouseDist = (-dx * signX + -dy * signY) * 0.5 - self.oscSize;

  // Binary search for t such that padding(t) == mouseDist
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
  self.cropTopLeftDragging = NO;
  self.cropTopLeftHovered = NO;
  [super mouseUpAtPositionX:positionX
                  positionY:positionY
                 activePart:activePart
                  modifiers:modifiers
                forceUpdate:forceUpdate
                     atTime:time];
}

@end
