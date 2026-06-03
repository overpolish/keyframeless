/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKCropOSC.h"
#import <CoreGraphics/CGEventSource.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKHostInfo.h>
#import <KeyframelessKit/KKOSCLabel.h>
#import <KeyframelessKit/KKPointOSC.h>
#import <KeyframelessKit/KKRectBorderOSC.h>

#define CLAMP(x, lo, hi) MAX((lo), MIN((hi), (x)))

typedef struct {
  BOOL left;
  BOOL right;
  BOOL top;
  BOOL bottom;
  BOOL isEdge;
} CropPointConfig;

// Which edge(s) each handle moves, in KKBoxOSC's canonical index order:
// 0-3 corners (BL, BR, TR, TL), 4-7 edge midpoints (bottom, right, top, left).
static const CropPointConfig kCropConfigs[KKCropPointCount] = {
    {YES, NO, NO, YES, NO}, // 0 bottom-left
    {NO, YES, NO, YES, NO}, // 1 bottom-right
    {NO, YES, YES, NO, NO}, // 2 top-right
    {YES, NO, YES, NO, NO}, // 3 top-left
    {NO, NO, NO, YES, YES}, // 4 bottom edge
    {NO, YES, NO, NO, YES}, // 5 right edge
    {NO, NO, YES, NO, YES}, // 6 top edge
    {YES, NO, NO, NO, YES}, // 7 left edge
};

@implementation KKCropOSC {
  double _dragStartObjX;
  double _dragStartObjY;
  double _dragStartCropTop;
  double _dragStartCropBottom;
  double _dragStartCropLeft;
  double _dragStartCropRight;
  double _cropStartAspect;
}

// Bridge between the plugin-facing `[w, h, x, y]` model (KKCropModel.h -
// w/h size, x/y centre offset from image centre) and the internal L/R/T/B
// edge-inset representation the drag math uses. Y mapping mirrors the
// in-viewer empirical convention validated against the radius OSC anchor.
- (void)readCropValues:(double *)cL
                    cR:(double *)cR
                    cT:(double *)cT
                    cB:(double *)cB
                atTime:(CMTime)time {
  *cL = 0;
  *cR = 0;
  *cT = 0;
  *cB = 0;
  NSArray<NSNumber *> *vals =
      self.valuesProvider ? self.valuesProvider(time) : nil;
  if (vals.count < 4)
    return; // nil/short → full image (all insets 0)
  double w = vals[0].doubleValue;
  double h = vals[1].doubleValue;
  double x = vals[2].doubleValue;
  double y = vals[3].doubleValue;
  *cL = 0.5 + x - w * 0.5;
  *cR = 0.5 - x - w * 0.5;
  *cT = 0.5 + y - h * 0.5;
  *cB = 0.5 - y - h * 0.5;
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
  NSString *readout = [NSString stringWithFormat:@"%ld x %ld", pxW, pxH];

  NSInteger active =
      self.draggingIndex >= 0 ? self.draggingIndex : self.hoveredIndex;
  [self drawWithTopRight:topRight
              bottomLeft:bottomLeft
                 readout:readout
            activeHandle:active
        destinationImage:destinationImage
                  atTime:time];
}

- (NSInteger)hitTestAtMousePositionX:(double)positionX
                           positionY:(double)positionY
                              atTime:(CMTime)time {
  self.hoveredIndex = -1;

  CGPoint topRight = {0, 0}, bottomLeft = {0, 0};
  if (![self getTopRight:&topRight
               bottomLeft:&bottomLeft
          fullImageCanvas:NULL
                   atTime:time])
    return KKCropPartNone;

  return [self hitTestAtX:positionX
                        y:positionY
                 topRight:topRight
               bottomLeft:bottomLeft];
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
  if (!self.valuesWriter)
    return;
  // Inverse of -readCropValues:'s mapping.
  double w = 1.0 - cL - cR;
  double h = 1.0 - cT - cB;
  double x = (cL - cR) * 0.5;
  double y = (cT - cB) * 0.5;
  self.valuesWriter(@[ @(w), @(h), @(x), @(y) ], time);
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
  [self resetHover];
}

@end
