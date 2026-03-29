/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC.h"
#import "Constants.h"
#import "MagicMovePath.h"
#import <CoreGraphics/CGEventSource.h>
#import <FxPlug/FxPlugSDK.h>

@interface KKArcOSC (FxOSC) <FxOnScreenControl_v4>
@end

#define CLAMP(x, lo, hi) MAX((lo), MIN((hi), (x)))
#define kPointCount 4

typedef struct {
  UInt32 pointParam, rotParam, scaleParam, previewParam, opacityParam;
  NSInteger arcPart, ringPart, rotPart, iconPart, opacityIconPart;
  __unsafe_unretained KKArcOSC *arc;
  __unsafe_unretained KKOSCLabel *label;
  __unsafe_unretained KKRingOSC *ring;
  __unsafe_unretained KKRotationOSC *rot;
  __unsafe_unretained KKIconButtonOSC *icon;
  __unsafe_unretained KKIconButtonOSC *opacityIcon;
  BOOL arcHovered, arcDragging;
  BOOL ringHovered, ringDragging;
  BOOL rotHovered, rotDragging;
  double rotDragPrevAngle, rotDragAccum;
  double ringDragStartDist, ringDragStartVal;
} PointOSCState;

static const float kSnapThreshold = 8.0f;
static const float kPathHitThreshold = 10.0f;
static const float kPathPointHitRadius = 8.0f;
static const NSUInteger kPathDrawResolution = 20;

// Part ID ranges for path elements
static const NSInteger kPartPathCurve = 50;
static const NSInteger kPartPathPointBase = 100;
static const NSInteger kPartPathInHandleBase = 200;
static const NSInteger kPartPathOutHandleBase = 300;

@implementation MagicMoveOSC {
  PointOSCState _points[kPointCount];
  KKOSCLabel *_labelA;
  KKRingOSC *_ringA;
  KKRotationOSC *_rotA;
  KKIconButtonOSC *_iconA;
  KKIconButtonOSC *_opacityIconA;
  KKArcOSC *_arcB;
  KKOSCLabel *_labelB;
  KKRingOSC *_ringB;
  KKRotationOSC *_rotB;
  KKIconButtonOSC *_iconB;
  KKIconButtonOSC *_opacityIconB;
  KKArcOSC *_arcDrift;
  KKOSCLabel *_labelDrift;
  KKRingOSC *_ringDrift;
  KKRotationOSC *_rotDrift;
  KKIconButtonOSC *_iconDrift;
  KKIconButtonOSC *_opacityIconDrift;
  KKArcOSC *_arcExit;
  KKOSCLabel *_labelExit;
  KKRingOSC *_ringExit;
  KKRotationOSC *_rotExit;
  KKIconButtonOSC *_iconExit;
  KKIconButtonOSC *_opacityIconExit;
  BOOL _snapX;
  BOOL _snapY;
  float _snapXVal;
  float _snapYVal;
  KKPointOSC *_pathPointOSC;
  KKPointOSC *_pathHandleOSC;
  NSInteger _pathDragIndex;
  BOOL _pathDragIsInHandle;
  BOOL _pathDragIsOutHandle;
  simd_float2 _pathDragStartObj;
  NSTimeInterval _pathLastClickTime;
  NSInteger _pathLastClickIndex;
  BOOL _pathSnapX;
  BOOL _pathSnapY;
  float _pathSnapXVal;
  float _pathSnapYVal;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    self.clearsOnDraw = NO;

    _labelA = [[KKOSCLabel alloc] initWithAPIManager:apiManager];
    _labelA.text = @"Point A";
    _ringA = [[KKRingOSC alloc] initWithAPIManager:apiManager];
    _rotA = [[KKRotationOSC alloc] initWithAPIManager:apiManager];
    _iconA = [[KKIconButtonOSC alloc] initWithAPIManager:apiManager];
    _iconA.iconName = @"eye";
    _opacityIconA = [[KKIconButtonOSC alloc] initWithAPIManager:apiManager];
    _opacityIconA.iconName = @"circle.fill";

    _arcB = [[KKArcOSC alloc] initWithAPIManager:apiManager];
    _arcB.clearsOnDraw = NO;
    _labelB = [[KKOSCLabel alloc] initWithAPIManager:apiManager];
    _labelB.text = @"Point B";
    _ringB = [[KKRingOSC alloc] initWithAPIManager:apiManager];
    _rotB = [[KKRotationOSC alloc] initWithAPIManager:apiManager];
    _iconB = [[KKIconButtonOSC alloc] initWithAPIManager:apiManager];
    _iconB.iconName = @"eye";
    _opacityIconB = [[KKIconButtonOSC alloc] initWithAPIManager:apiManager];
    _opacityIconB.iconName = @"circle.fill";

    _points[0] = (PointOSCState){
        .pointParam = kParamPointA,
        .rotParam = kParamRotationA,
        .scaleParam = kParamScaleA,
        .previewParam = kParamPreviewA,
        .opacityParam = kParamOpacityA,
        .arcPart = 1,
        .ringPart = 2,
        .rotPart = 3,
        .iconPart = 13,
        .opacityIconPart = 17,
        .arc = self,
        .label = _labelA,
        .ring = _ringA,
        .rot = _rotA,
        .icon = _iconA,
        .opacityIcon = _opacityIconA,
    };
    _points[1] = (PointOSCState){
        .pointParam = kParamPointB,
        .rotParam = kParamRotationB,
        .scaleParam = kParamScaleB,
        .previewParam = kParamPreviewB,
        .opacityParam = kParamOpacityB,
        .arcPart = 4,
        .ringPart = 5,
        .rotPart = 6,
        .iconPart = 14,
        .opacityIconPart = 18,
        .arc = _arcB,
        .label = _labelB,
        .ring = _ringB,
        .rot = _rotB,
        .icon = _iconB,
        .opacityIcon = _opacityIconB,
    };

    _arcDrift = [[KKArcOSC alloc] initWithAPIManager:apiManager];
    _arcDrift.clearsOnDraw = NO;
    _labelDrift = [[KKOSCLabel alloc] initWithAPIManager:apiManager];
    _labelDrift.text = @"Drift";
    _ringDrift = [[KKRingOSC alloc] initWithAPIManager:apiManager];
    _rotDrift = [[KKRotationOSC alloc] initWithAPIManager:apiManager];
    _iconDrift = [[KKIconButtonOSC alloc] initWithAPIManager:apiManager];
    _iconDrift.iconName = @"eye";
    _opacityIconDrift = [[KKIconButtonOSC alloc] initWithAPIManager:apiManager];
    _opacityIconDrift.iconName = @"circle.fill";

    _points[2] = (PointOSCState){
        .pointParam = kParamDriftPoint,
        .rotParam = kParamDriftRotation,
        .scaleParam = kParamDriftScale,
        .previewParam = kParamPreviewDrift,
        .opacityParam = kParamDriftOpacity,
        .arcPart = 7,
        .ringPart = 8,
        .rotPart = 9,
        .iconPart = 15,
        .opacityIconPart = 19,
        .arc = _arcDrift,
        .label = _labelDrift,
        .ring = _ringDrift,
        .rot = _rotDrift,
        .icon = _iconDrift,
        .opacityIcon = _opacityIconDrift,
    };

    _arcExit = [[KKArcOSC alloc] initWithAPIManager:apiManager];
    _arcExit.clearsOnDraw = NO;
    _labelExit = [[KKOSCLabel alloc] initWithAPIManager:apiManager];
    _labelExit.text = @"Exit";
    _ringExit = [[KKRingOSC alloc] initWithAPIManager:apiManager];
    _rotExit = [[KKRotationOSC alloc] initWithAPIManager:apiManager];
    _iconExit = [[KKIconButtonOSC alloc] initWithAPIManager:apiManager];
    _iconExit.iconName = @"eye";
    _opacityIconExit = [[KKIconButtonOSC alloc] initWithAPIManager:apiManager];
    _opacityIconExit.iconName = @"circle.fill";

    _points[3] = (PointOSCState){
        .pointParam = kParamExitPoint,
        .rotParam = kParamExitRotation,
        .scaleParam = kParamExitScale,
        .previewParam = kParamPreviewExit,
        .opacityParam = kParamExitOpacity,
        .arcPart = 10,
        .ringPart = 11,
        .rotPart = 12,
        .iconPart = 16,
        .opacityIconPart = 20,
        .arc = _arcExit,
        .label = _labelExit,
        .ring = _ringExit,
        .rot = _rotExit,
        .icon = _iconExit,
        .opacityIcon = _opacityIconExit,
    };

    _pathPointOSC = [[KKPointOSC alloc] initWithAPIManager:apiManager];
    _pathPointOSC.clearsOnDraw = NO;
    _pathPointOSC.oscRadius = 5.0f;
    _pathPointOSC.outlineWidth = 1.5f;
    _pathHandleOSC = [[KKPointOSC alloc] initWithAPIManager:apiManager];
    _pathHandleOSC.clearsOnDraw = NO;
    _pathHandleOSC.oscRadius = 3.0f;
    _pathHandleOSC.outlineWidth = 1.0f;
    _pathDragIndex = -1;
    _pathLastClickIndex = -1;
  }
  return self;
}

- (CGPoint)positionForParam:(UInt32)paramID atTime:(CMTime)time {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return CGPointZero;
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  double x = 0.5, y = 0.5;
  [paramGetAPI getXValue:&x YValue:&y fromParameter:paramID atTime:time];
  CGPoint canvas;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:x
                          fromY:y
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&canvas.x
                            toY:&canvas.y];
  return canvas;
}

- (float)rotationForParam:(UInt32)paramID atTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!paramGetAPI)
    return 0.0f;
  double radians = 0.0;
  [paramGetAPI getFloatValue:&radians fromParameter:paramID atTime:time];
  return (float)radians;
}

- (float)canvasMinDim {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return 500.0f;
  CGPoint topRight, bottomLeft;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:1.0
                          fromY:1.0
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&topRight.x
                            toY:&topRight.y];
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:0.0
                          fromY:0.0
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&bottomLeft.x
                            toY:&bottomLeft.y];
  return fmin(fabs(topRight.x - bottomLeft.x), fabs(topRight.y - bottomLeft.y));
}

- (float)ringRadiusForScaleParam:(UInt32)paramID atTime:(CMTime)time {
  float minDim = [self canvasMinDim];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  double scale = 1.0;
  [paramGetAPI getFloatValue:&scale fromParameter:paramID atTime:time];
  return minDim * 0.1f * (float)scale;
}

- (BOOL)animateInEnabledAtTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  BOOL enabled = NO;
  [paramGetAPI getBoolValue:&enabled
              fromParameter:kKKParamAnimateIn
                     atTime:time];
  return enabled;
}

- (BOOL)animateOutEnabledAtTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  BOOL enabled = NO;
  [paramGetAPI getBoolValue:&enabled
              fromParameter:kKKParamAnimateOut
                     atTime:time];
  return enabled;
}

- (BOOL)driftEnabledAtTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  BOOL enabled = NO;
  [paramGetAPI getBoolValue:&enabled fromParameter:kParamDrift atTime:time];
  return enabled;
}

- (BOOL)exitEnabledAtTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  BOOL enabled = NO;
  [paramGetAPI getBoolValue:&enabled fromParameter:kParamExit atTime:time];
  return enabled;
}

- (CGPoint)oscPositionAtTime:(CMTime)time {
  return [self positionForParam:kParamPointA atTime:time];
}

- (MagicMovePath *)readPathABAtTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSString *str = nil;
  [paramGetAPI getStringParameterValue:&str fromParameter:kParamPathAB];
  if (str.length > 0) {
    NSData *data = [[NSData alloc] initWithBase64EncodedString:str options:0];
    if (data)
      return [MagicMovePath pathWithData:data];
  }
  return [[MagicMovePath alloc] init];
}

- (void)writePathAB:(MagicMovePath *)path atTime:(CMTime)time {
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSData *data = [path dataRepresentation];
  NSString *str = [data base64EncodedStringWithOptions:0];
  [paramSetAPI setStringParameterValue:str toParameter:kParamPathAB];
}

- (CGPoint)canvasPointFromObject:(simd_float2)objPt {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  CGPoint canvas;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:objPt.x
                          fromY:objPt.y
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&canvas.x
                            toY:&canvas.y];
  return canvas;
}

- (simd_float2)objectPointFromCanvas:(CGPoint)canvasPt {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  double objX, objY;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                          fromX:canvasPt.x
                          fromY:canvasPt.y
                        toSpace:kFxDrawingCoordinates_OBJECT
                            toX:&objX
                            toY:&objY];
  return (simd_float2){(float)objX, (float)objY};
}

- (simd_float2)objectPositionForParam:(UInt32)paramID atTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  double x = 0.5, y = 0.5;
  [paramGetAPI getXValue:&x YValue:&y fromParameter:paramID atTime:time];
  return (simd_float2){(float)x, (float)y};
}

- (void)drawPoint:(PointOSCState *)pt
    destinationImage:(FxImageTile *)dest
              atTime:(CMTime)time {
  CGPoint pos = [self positionForParam:pt->pointParam atTime:time];
  float ringRadius = [self ringRadiusForScaleParam:pt->scaleParam atTime:time];
  float rotAngle = [self rotationForParam:pt->rotParam atTime:time];

  pt->ring.center = pos;
  pt->ring.ringRadius = ringRadius;
  [pt->ring drawAtCanvasPosition:pos
                       isHovered:pt->ringHovered
                        isActive:pt->ringDragging
                destinationImage:dest
                          atTime:time];

  pt->rot.center = pos;
  pt->rot.angle = rotAngle;
  [pt->rot drawAtCanvasPosition:pos
                      isHovered:pt->rotHovered
                       isActive:pt->rotDragging
               destinationImage:dest
                         atTime:time];

  [pt->arc drawAtCanvasPosition:pos
                      isHovered:pt->arcHovered
                       isActive:pt->arcDragging
               destinationImage:dest
                         atTime:time];

  float arcOuter = pt->arc.oscRadius + pt->arc.outlineWidth;
  CGPoint labelPos = CGPointMake(pos.x, pos.y - arcOuter - 4.0f -
                                            pt->label.size.height / 2.0f);
  [pt->label drawAtCanvasPosition:labelPos destinationImage:dest];

  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  BOOL previewOn = NO;
  [paramGetAPI getBoolValue:&previewOn
              fromParameter:pt->previewParam
                     atTime:time];
  pt->icon.iconName = previewOn ? @"eye.fill" : @"eye";

  double opacity = 1.0;
  [paramGetAPI getFloatValue:&opacity
               fromParameter:pt->opacityParam
                      atTime:time];
  if (opacity >= 1.0)
    pt->opacityIcon.iconName = @"circle.fill";
  else if (opacity <= 0.0)
    pt->opacityIcon.iconName = @"circle";
  else
    pt->opacityIcon.iconName =
        @"circle.lefthalf.filled.righthalf.striped.horizontal.inverse";

  float gap = 6.0f;
  float totalWidth = pt->icon.size.width + gap + pt->opacityIcon.size.width;
  float iconY = pos.y + arcOuter + 4.0f + pt->icon.size.height / 2.0f;
  CGPoint previewPos = CGPointMake(
      pos.x - totalWidth / 2.0f + pt->icon.size.width / 2.0f, iconY);
  CGPoint opacityPos = CGPointMake(
      pos.x + totalWidth / 2.0f - pt->opacityIcon.size.width / 2.0f, iconY);
  [pt->icon drawAtCanvasPosition:previewPos destinationImage:dest];
  [pt->opacityIcon drawAtCanvasPosition:opacityPos destinationImage:dest];

  pt->arc.fillAlpha = (opacity < 1.0) ? 0.25f : 1.0f;
}

- (void)drawPathABWithDestinationImage:(FxImageTile *)dest
                                 color:(simd_float4)color
                                 inset:(double)inset
                                atTime:(CMTime)time {
  MagicMovePath *path = [self readPathABAtTime:time];
  simd_float2 startObj = [self objectPositionForParam:kParamPointA atTime:time];
  simd_float2 endObj = [self objectPositionForParam:kParamPointB atTime:time];
  NSUInteger segCount = path.segmentCount;

  // Draw curve segments
  for (NSUInteger seg = 0; seg < segCount; seg++) {
    CGPoint prev = CGPointZero;
    for (NSUInteger s = 0; s <= kPathDrawResolution; s++) {
      float localT = (float)s / (float)kPathDrawResolution;
      simd_float2 objPt = [path evaluateSegment:seg
                                            atT:localT
                                          start:startObj
                                            end:endObj];
      CGPoint cur = [self canvasPointFromObject:objPt];
      if (s > 0) {
        // Skip segments too close to endpoints (inset)
        BOOL tooCloseToStart = NO, tooCloseToEnd = NO;
        CGPoint startCanvas = [self canvasPointFromObject:startObj];
        CGPoint endCanvas = [self canvasPointFromObject:endObj];
        double d1 = hypot(cur.x - startCanvas.x, cur.y - startCanvas.y);
        double d2 = hypot(cur.x - endCanvas.x, cur.y - endCanvas.y);
        double d1p = hypot(prev.x - startCanvas.x, prev.y - startCanvas.y);
        double d2p = hypot(prev.x - endCanvas.x, prev.y - endCanvas.y);
        tooCloseToStart = (d1 < inset && d1p < inset);
        tooCloseToEnd = (d2 < inset && d2p < inset);
        if (!tooCloseToStart && !tooCloseToEnd) {
          [self drawLineFrom:prev
                            to:cur
                         color:color
                     halfWidth:2.0f
              destinationImage:dest];
        }
      }
      prev = cur;
    }
  }

  // Draw control points and handles
  for (NSUInteger i = 0; i < path.count; i++) {
    MagicMovePathPoint pt = [path pointAtIndex:i];
    simd_float2 ptObj = {pt.x, pt.y};
    CGPoint ptCanvas = [self canvasPointFromObject:ptObj];

    if (pt.type == MagicMovePathPointBezier) {
      simd_float2 inObj = {pt.x + pt.inX, pt.y + pt.inY};
      simd_float2 outObj = {pt.x + pt.outX, pt.y + pt.outY};
      CGPoint inCanvas = [self canvasPointFromObject:inObj];
      CGPoint outCanvas = [self canvasPointFromObject:outObj];

      simd_float4 handleColor = {0.6f, 0.0f, 0.0f, 1.0f};
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

      [_pathHandleOSC drawAtCanvasPosition:inCanvas
                                 isHovered:NO
                                  isActive:NO
                          destinationImage:dest
                                    atTime:time];
      [_pathHandleOSC drawAtCanvasPosition:outCanvas
                                 isHovered:NO
                                  isActive:NO
                          destinationImage:dest
                                    atTime:time];
    }

    [_pathPointOSC
        drawAtCanvasPosition:ptCanvas
                   isHovered:NO
                    isActive:(_pathDragIndex == (NSInteger)i &&
                              !_pathDragIsInHandle && !_pathDragIsOutHandle)
            destinationImage:dest
                      atTime:time];
  }
}

- (void)hitTestPathAtX:(double)mx
                     Y:(double)my
            activePart:(NSInteger *)activePart
                atTime:(CMTime)time {
  MagicMovePath *path = [self readPathABAtTime:time];
  if (path.count == 0 && path.segmentCount == 1) {
    // Only test curve for insertion on the straight line
  }
  simd_float2 startObj = [self objectPositionForParam:kParamPointA atTime:time];
  simd_float2 endObj = [self objectPositionForParam:kParamPointB atTime:time];

  // Test handles first (highest priority among path elements)
  for (NSUInteger i = 0; i < path.count; i++) {
    MagicMovePathPoint pt = [path pointAtIndex:i];
    if (pt.type != MagicMovePathPointBezier)
      continue;
    simd_float2 inObj = {pt.x + pt.inX, pt.y + pt.inY};
    simd_float2 outObj = {pt.x + pt.outX, pt.y + pt.outY};
    CGPoint inC = [self canvasPointFromObject:inObj];
    CGPoint outC = [self canvasPointFromObject:outObj];
    if (hypot(mx - inC.x, my - inC.y) < kPathPointHitRadius) {
      *activePart = kPartPathInHandleBase + (NSInteger)i;
      return;
    }
    if (hypot(mx - outC.x, my - outC.y) < kPathPointHitRadius) {
      *activePart = kPartPathOutHandleBase + (NSInteger)i;
      return;
    }
  }

  // Test control points
  CGEventFlags flags =
      CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
  BOOL optDown = (flags & kCGEventFlagMaskAlternate) != 0;
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];

  BOOL pathHit = NO;
  for (NSUInteger i = 0; i < path.count; i++) {
    MagicMovePathPoint pt = [path pointAtIndex:i];
    CGPoint ptC = [self canvasPointFromObject:(simd_float2){pt.x, pt.y}];
    if (hypot(mx - ptC.x, my - ptC.y) < kPathPointHitRadius) {
      *activePart = kPartPathPointBase + (NSInteger)i;
      pathHit = YES;
      if (optDown)
        [oscAPI setCursor:[NSCursor disappearingItemCursor]];
      else
        [oscAPI setCursor:[NSCursor arrowCursor]];
      return;
    }
  }

  // Test curve for insertion
  NSUInteger segCount = path.segmentCount;
  float bestDist = FLT_MAX;
  for (NSUInteger seg = 0; seg < segCount; seg++) {
    CGPoint prev = CGPointZero;
    for (NSUInteger s = 0; s <= kPathDrawResolution; s++) {
      float localT = (float)s / (float)kPathDrawResolution;
      simd_float2 objPt = [path evaluateSegment:seg
                                            atT:localT
                                          start:startObj
                                            end:endObj];
      CGPoint cur = [self canvasPointFromObject:objPt];
      if (s > 0) {
        double dx = cur.x - prev.x, dy = cur.y - prev.y;
        double lenSq = dx * dx + dy * dy;
        double t2 =
            (lenSq > 0)
                ? CLAMP(((mx - prev.x) * dx + (my - prev.y) * dy) / lenSq, 0, 1)
                : 0;
        double cx = prev.x + t2 * dx, cy = prev.y + t2 * dy;
        float dist = (float)hypot(mx - cx, my - cy);
        if (dist < bestDist)
          bestDist = dist;
      }
      prev = cur;
    }
  }
  if (bestDist < kPathHitThreshold) {
    *activePart = kPartPathCurve;
    pathHit = YES;
    if (optDown)
      [oscAPI setCursor:[NSCursor crosshairCursor]];
    else
      [oscAPI setCursor:[NSCursor arrowCursor]];
  }

  if (!pathHit)
    [oscAPI setCursor:[NSCursor arrowCursor]];
}

- (BOOL)mouseDownForPathWithPart:(NSInteger)activePart
                       positionX:(double)positionX
                       positionY:(double)positionY
                       modifiers:(NSUInteger)modifiers
                     forceUpdate:(BOOL *)forceUpdate
                          atTime:(CMTime)time {
  BOOL optHeld = (modifiers & kFxModifierKey_OPTION) != 0;

  simd_float2 startObj = [self objectPositionForParam:kParamPointA atTime:time];
  simd_float2 endObj = [self objectPositionForParam:kParamPointB atTime:time];

  if (activePart >= kPartPathPointBase &&
      activePart < kPartPathPointBase + 100) {
    NSUInteger idx = (NSUInteger)(activePart - kPartPathPointBase);
    MagicMovePath *path = [self readPathABAtTime:time];
    if (idx >= path.count)
      return NO;

    if (optHeld) {
      [path removeAtIndex:idx];
      [self writePathAB:path atTime:time];
      *forceUpdate = YES;
      return YES;
    }

    NSTimeInterval now = CACurrentMediaTime();
    if (_pathLastClickIndex == (NSInteger)idx &&
        (now - _pathLastClickTime) < 0.35) {
      [path toggleTypeAtIndex:idx start:startObj end:endObj];
      [self writePathAB:path atTime:time];
      _pathLastClickIndex = -1;
      *forceUpdate = YES;
      return YES;
    }
    _pathLastClickTime = now;
    _pathLastClickIndex = (NSInteger)idx;

    MagicMovePathPoint dragPt = [path pointAtIndex:idx];
    _pathDragStartObj = (simd_float2){dragPt.x, dragPt.y};
    _pathDragIndex = (NSInteger)idx;
    _pathDragIsInHandle = NO;
    _pathDragIsOutHandle = NO;
    *forceUpdate = YES;
    return YES;
  }

  if (activePart >= kPartPathInHandleBase &&
      activePart < kPartPathInHandleBase + 100) {
    NSUInteger idx = (NSUInteger)(activePart - kPartPathInHandleBase);
    MagicMovePath *hPath = [self readPathABAtTime:time];
    if (idx < hPath.count) {
      MagicMovePathPoint dragPt = [hPath pointAtIndex:idx];
      _pathDragStartObj =
          (simd_float2){dragPt.x + dragPt.inX, dragPt.y + dragPt.inY};
    }
    _pathDragIndex = (NSInteger)idx;
    _pathDragIsInHandle = YES;
    _pathDragIsOutHandle = NO;
    *forceUpdate = YES;
    return YES;
  }

  if (activePart >= kPartPathOutHandleBase &&
      activePart < kPartPathOutHandleBase + 100) {
    NSUInteger idx = (NSUInteger)(activePart - kPartPathOutHandleBase);
    MagicMovePath *hPath = [self readPathABAtTime:time];
    if (idx < hPath.count) {
      MagicMovePathPoint dragPt = [hPath pointAtIndex:idx];
      _pathDragStartObj =
          (simd_float2){dragPt.x + dragPt.outX, dragPt.y + dragPt.outY};
    }
    _pathDragIndex = (NSInteger)idx;
    _pathDragIsInHandle = NO;
    _pathDragIsOutHandle = YES;
    *forceUpdate = YES;
    return YES;
  }

  if (activePart == kPartPathCurve && optHeld) {
    MagicMovePath *path = [self readPathABAtTime:time];
    simd_float2 mouseObj =
        [self objectPointFromCanvas:(CGPoint){positionX, positionY}];

    // Find which segment and insert there
    NSUInteger bestSeg = 0;
    float bestDist = FLT_MAX;
    for (NSUInteger seg = 0; seg < path.segmentCount; seg++) {
      for (NSUInteger s = 1; s <= kPathDrawResolution; s++) {
        float localT = (float)s / (float)kPathDrawResolution;
        simd_float2 objPt = [path evaluateSegment:seg
                                              atT:localT
                                            start:startObj
                                              end:endObj];
        float dist = simd_length(objPt - mouseObj);
        if (dist < bestDist) {
          bestDist = dist;
          bestSeg = seg;
        }
      }
    }

    [path insertAtIndex:bestSeg position:mouseObj];
    [self writePathAB:path atTime:time];
    _pathDragIndex = (NSInteger)bestSeg;
    _pathDragIsInHandle = NO;
    _pathDragIsOutHandle = NO;
    *forceUpdate = YES;
    return YES;
  }

  return NO;
}

- (void)buildPathSnapTargets:(simd_float2 *)targets
                       count:(NSUInteger *)outCount
                        path:(MagicMovePath *)path
                   dragIndex:(NSUInteger)dragIndex
                       start:(simd_float2)start
                         end:(simd_float2)end {
  NSUInteger n = 0;
  targets[n++] = start;
  targets[n++] = end;
  for (NSUInteger i = 0; i < path.count; i++) {
    if (i == dragIndex)
      continue;
    MagicMovePathPoint pt = [path pointAtIndex:i];
    targets[n++] = (simd_float2){pt.x, pt.y};
  }
  *outCount = n;
}

- (simd_float2)applyPathSnap:(simd_float2)pos
                     targets:(simd_float2 *)targets
                       count:(NSUInteger)count {
  _pathSnapX = NO;
  _pathSnapY = NO;

  float canvasSnapThresh = kSnapThreshold;
  // Convert threshold from canvas to object space (approximate)
  CGPoint c0 = [self canvasPointFromObject:(simd_float2){0, 0}];
  CGPoint c1 = [self canvasPointFromObject:(simd_float2){1, 0}];
  float pixPerUnit = (float)fabs(c1.x - c0.x);
  float objThresh = (pixPerUnit > 0) ? canvasSnapThresh / pixPerUnit : 0.005f;

  float bestDX = FLT_MAX, bestDY = FLT_MAX;
  float snapX = pos.x, snapY = pos.y;
  for (NSUInteger i = 0; i < count; i++) {
    float dx = fabsf(pos.x - targets[i].x);
    float dy = fabsf(pos.y - targets[i].y);
    if (dx < objThresh && dx < bestDX) {
      bestDX = dx;
      snapX = targets[i].x;
    }
    if (dy < objThresh && dy < bestDY) {
      bestDY = dy;
      snapY = targets[i].y;
    }
  }
  if (bestDX < FLT_MAX) {
    _pathSnapX = YES;
    _pathSnapXVal = snapX;
    pos.x = snapX;
  }
  if (bestDY < FLT_MAX) {
    _pathSnapY = YES;
    _pathSnapYVal = snapY;
    pos.y = snapY;
  }
  return pos;
}

- (BOOL)mouseDraggedForPathWithPart:(NSInteger)activePart
                          positionX:(double)positionX
                          positionY:(double)positionY
                             atTime:(CMTime)time {
  if (_pathDragIndex < 0)
    return NO;

  MagicMovePath *path = [self readPathABAtTime:time];
  if ((NSUInteger)_pathDragIndex >= path.count)
    return NO;

  simd_float2 mouseObj =
      [self objectPointFromCanvas:(CGPoint){positionX, positionY}];

  CGEventFlags flags =
      CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
  BOOL optHeld = (flags & kCGEventFlagMaskAlternate) != 0;
  BOOL shiftHeld = (flags & kCGEventFlagMaskShift) != 0;

  _pathSnapX = NO;
  _pathSnapY = NO;

  // Shift constrains to horizontal or vertical from drag start
  if (shiftHeld) {
    float dx = fabsf(mouseObj.x - _pathDragStartObj.x);
    float dy = fabsf(mouseObj.y - _pathDragStartObj.y);
    if (dx > dy)
      mouseObj.y = _pathDragStartObj.y;
    else
      mouseObj.x = _pathDragStartObj.x;
  }

  simd_float2 startObj = [self objectPositionForParam:kParamPointA atTime:time];
  simd_float2 endObj = [self objectPositionForParam:kParamPointB atTime:time];

  if (_pathDragIsInHandle) {
    MagicMovePathPoint pt = [path pointAtIndex:(NSUInteger)_pathDragIndex];
    simd_float2 handlePos = mouseObj;

    // Snap handle to horizontal/vertical relative to control point
    if (!shiftHeld) {
      CGPoint ptC = [self canvasPointFromObject:(simd_float2){pt.x, pt.y}];
      CGPoint hC = [self canvasPointFromObject:handlePos];
      if (fabs(hC.y - ptC.y) < kSnapThreshold) {
        handlePos.y = pt.y;
        _pathSnapY = YES;
        _pathSnapYVal = pt.y;
      }
      if (fabs(hC.x - ptC.x) < kSnapThreshold) {
        handlePos.x = pt.x;
        _pathSnapX = YES;
        _pathSnapXVal = pt.x;
      }
    }

    simd_float2 offset = {handlePos.x - pt.x, handlePos.y - pt.y};
    [path setInHandle:offset atIndex:(NSUInteger)_pathDragIndex];
    if (!optHeld)
      [path setOutHandle:(simd_float2){-offset.x, -offset.y}
                 atIndex:(NSUInteger)_pathDragIndex];
  } else if (_pathDragIsOutHandle) {
    MagicMovePathPoint pt = [path pointAtIndex:(NSUInteger)_pathDragIndex];
    simd_float2 handlePos = mouseObj;

    if (!shiftHeld) {
      CGPoint ptC = [self canvasPointFromObject:(simd_float2){pt.x, pt.y}];
      CGPoint hC = [self canvasPointFromObject:handlePos];
      if (fabs(hC.y - ptC.y) < kSnapThreshold) {
        handlePos.y = pt.y;
        _pathSnapY = YES;
        _pathSnapYVal = pt.y;
      }
      if (fabs(hC.x - ptC.x) < kSnapThreshold) {
        handlePos.x = pt.x;
        _pathSnapX = YES;
        _pathSnapXVal = pt.x;
      }
    }

    simd_float2 offset = {handlePos.x - pt.x, handlePos.y - pt.y};
    [path setOutHandle:offset atIndex:(NSUInteger)_pathDragIndex];
    if (!optHeld)
      [path setInHandle:(simd_float2){-offset.x, -offset.y}
                atIndex:(NSUInteger)_pathDragIndex];
  } else {
    // Snap control point to other points and endpoints
    simd_float2 snapTargets[path.count + 2];
    NSUInteger snapCount;
    [self buildPathSnapTargets:snapTargets
                         count:&snapCount
                          path:path
                     dragIndex:(NSUInteger)_pathDragIndex
                         start:startObj
                           end:endObj];
    mouseObj = [self applyPathSnap:mouseObj
                           targets:snapTargets
                             count:snapCount];
    [path moveAtIndex:(NSUInteger)_pathDragIndex to:mouseObj];
  }

  [self writePathAB:path atTime:time];
  return YES;
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

  BOOL animInOn = [self animateInEnabledAtTime:time];
  BOOL animOutOn = [self animateOutEnabledAtTime:time];
  BOOL driftOn = [self driftEnabledAtTime:time];
  BOOL exitOn = [self exitEnabledAtTime:time];
  BOOL showA = animInOn || (animOutOn && !exitOn);
  BOOL showExit = exitOn && animOutOn;

  CGPoint posB = [self positionForParam:kParamPointB atTime:time];
  simd_float4 red = {1, 0, 0, 1};
  BOOL anyArcActive = _points[0].arcDragging || _points[1].arcDragging ||
                      _points[2].arcDragging || _points[3].arcDragging;
  double inset = anyArcActive ? 22.0 : 14.0;

  if (showA) {
    [self drawPathABWithDestinationImage:destinationImage
                                   color:red
                                   inset:inset
                                  atTime:time];
  }

  if (driftOn) {
    CGPoint posD = [self positionForParam:kParamDriftPoint atTime:time];
    double d2x = posD.x - posB.x, d2y = posD.y - posB.y;
    double l2 = hypot(d2x, d2y);
    if (l2 > inset * 2.0) {
      double n2x = d2x / l2 * inset, n2y = d2y / l2 * inset;
      [self drawLineFrom:(CGPoint){posB.x + n2x, posB.y + n2y}
                        to:(CGPoint){posD.x - n2x, posD.y - n2y}
                     color:red
                 halfWidth:2.0f
          destinationImage:destinationImage];
    }
    if (showExit) {
      CGPoint posE = [self positionForParam:kParamExitPoint atTime:time];
      double d3x = posE.x - posD.x, d3y = posE.y - posD.y;
      double l3 = hypot(d3x, d3y);
      if (l3 > inset * 2.0) {
        double n3x = d3x / l3 * inset, n3y = d3y / l3 * inset;
        [self drawLineFrom:(CGPoint){posD.x + n3x, posD.y + n3y}
                          to:(CGPoint){posE.x - n3x, posE.y - n3y}
                       color:red
                   halfWidth:2.0f
            destinationImage:destinationImage];
      }
    }
  } else if (showExit) {
    CGPoint posE = [self positionForParam:kParamExitPoint atTime:time];
    double d2x = posE.x - posB.x, d2y = posE.y - posB.y;
    double l2 = hypot(d2x, d2y);
    if (l2 > inset * 2.0) {
      double n2x = d2x / l2 * inset, n2y = d2y / l2 * inset;
      [self drawLineFrom:(CGPoint){posB.x + n2x, posB.y + n2y}
                        to:(CGPoint){posE.x - n2x, posE.y - n2y}
                     color:red
                 halfWidth:2.0f
          destinationImage:destinationImage];
    }
  }

  if (_snapX || _snapY) {
    CGPoint topRight, bottomLeft;
    id<FxOnScreenControlAPI_v4> oscAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                            fromX:0.0
                            fromY:0.0
                          toSpace:kFxDrawingCoordinates_CANVAS
                              toX:&bottomLeft.x
                              toY:&bottomLeft.y];
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                            fromX:1.0
                            fromY:1.0
                          toSpace:kFxDrawingCoordinates_CANVAS
                              toX:&topRight.x
                              toY:&topRight.y];
    float minX = fmin(bottomLeft.x, topRight.x);
    float maxX = fmax(bottomLeft.x, topRight.x);
    float minY = fmin(bottomLeft.y, topRight.y);
    float maxY = fmax(bottomLeft.y, topRight.y);
    simd_float4 yellow = {1, 1, 0, 1};
    if (_snapX) {
      [self drawLineFrom:(CGPoint){_snapXVal, minY}
                        to:(CGPoint){_snapXVal, maxY}
                     color:yellow
                 halfWidth:2.0f
          destinationImage:destinationImage];
    }
    if (_snapY) {
      [self drawLineFrom:(CGPoint){minX, _snapYVal}
                        to:(CGPoint){maxX, _snapYVal}
                     color:yellow
                 halfWidth:2.0f
          destinationImage:destinationImage];
    }
  }

  if (_pathSnapX || _pathSnapY) {
    CGPoint topRight, bottomLeft;
    id<FxOnScreenControlAPI_v4> snapOscAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    [snapOscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                                fromX:0.0
                                fromY:0.0
                              toSpace:kFxDrawingCoordinates_CANVAS
                                  toX:&bottomLeft.x
                                  toY:&bottomLeft.y];
    [snapOscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                                fromX:1.0
                                fromY:1.0
                              toSpace:kFxDrawingCoordinates_CANVAS
                                  toX:&topRight.x
                                  toY:&topRight.y];
    float psMinX = fmin(bottomLeft.x, topRight.x);
    float psMaxX = fmax(bottomLeft.x, topRight.x);
    float psMinY = fmin(bottomLeft.y, topRight.y);
    float psMaxY = fmax(bottomLeft.y, topRight.y);
    simd_float4 yellow = {1, 1, 0, 1};
    if (_pathSnapX) {
      CGPoint snapC =
          [self canvasPointFromObject:(simd_float2){_pathSnapXVal, 0}];
      [self drawLineFrom:(CGPoint){snapC.x, psMinY}
                        to:(CGPoint){snapC.x, psMaxY}
                     color:yellow
                 halfWidth:2.0f
          destinationImage:destinationImage];
    }
    if (_pathSnapY) {
      CGPoint snapC =
          [self canvasPointFromObject:(simd_float2){0, _pathSnapYVal}];
      [self drawLineFrom:(CGPoint){psMinX, snapC.y}
                        to:(CGPoint){psMaxX, snapC.y}
                     color:yellow
                 halfWidth:2.0f
          destinationImage:destinationImage];
    }
  }

  if (showA)
    [self drawPoint:&_points[0] destinationImage:destinationImage atTime:time];
  [self drawPoint:&_points[1] destinationImage:destinationImage atTime:time];

  if (driftOn)
    [self drawPoint:&_points[2] destinationImage:destinationImage atTime:time];

  if (showExit)
    [self drawPoint:&_points[3] destinationImage:destinationImage atTime:time];
}

- (void)hitTestPoint:(PointOSCState *)pt
           positionX:(double)positionX
           positionY:(double)positionY
          activePart:(NSInteger *)activePart
              atTime:(CMTime)time {
  pt->arcHovered = NO;
  pt->ringHovered = NO;
  pt->rotHovered = NO;

  CGPoint pos = [self positionForParam:pt->pointParam atTime:time];

  // Icon buttons below the arc (preview + opacity, centered as group)
  float arcOuter = pt->arc.oscRadius + pt->arc.outlineWidth;
  float gap = 6.0f;
  float totalWidth = pt->icon.size.width + gap + pt->opacityIcon.size.width;
  float iconY = pos.y + arcOuter + 4.0f + pt->icon.size.height / 2.0f;
  CGPoint previewCenter = CGPointMake(
      pos.x - totalWidth / 2.0f + pt->icon.size.width / 2.0f, iconY);
  CGPoint opacityCenter = CGPointMake(
      pos.x + totalWidth / 2.0f - pt->opacityIcon.size.width / 2.0f, iconY);
  if ([pt->icon hitTestAtMousePositionX:positionX
                              positionY:positionY
                                 center:previewCenter]) {
    *activePart = pt->iconPart;
    return;
  }
  if ([pt->opacityIcon hitTestAtMousePositionX:positionX
                                     positionY:positionY
                                        center:opacityCenter]) {
    *activePart = pt->opacityIconPart;
    return;
  }

  if (pt->arc == self) {
    [super hitTestOSCAtMousePositionX:positionX
                       mousePositionY:positionY
                           activePart:activePart
                               atTime:time];
  } else {
    double dx = positionX - pos.x;
    double dy = positionY - pos.y;
    if (sqrt(dx * dx + dy * dy) < pt->arc.hitRadius) {
      pt->arcHovered = YES;
      *activePart = pt->arcPart;
    }
  }

  pt->ring.center = pos;
  pt->ring.ringRadius = [self ringRadiusForScaleParam:pt->scaleParam
                                               atTime:time];
  if ([pt->ring hitTestAtMousePositionX:positionX
                              positionY:positionY
                                 atTime:time]) {
    pt->ringHovered = YES;
    *activePart = pt->ringPart;
  }

  pt->rot.center = pos;
  pt->rot.angle = [self rotationForParam:pt->rotParam atTime:time];
  if ([pt->rot hitTestAtMousePositionX:positionX
                             positionY:positionY
                                atTime:time]) {
    pt->rotHovered = YES;
    *activePart = pt->rotPart;
  }
}

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  BOOL animInOn = [self animateInEnabledAtTime:time];
  BOOL animOutOn = [self animateOutEnabledAtTime:time];
  BOOL exitOn = [self exitEnabledAtTime:time];
  BOOL showA = animInOn || (animOutOn && !exitOn);

  // Main point controls first (highest priority)
  NSInteger prePart = *activePart;

  if (showA)
    [self hitTestPoint:&_points[0]
             positionX:positionX
             positionY:positionY
            activePart:activePart
                atTime:time];

  [self hitTestPoint:&_points[1]
           positionX:positionX
           positionY:positionY
          activePart:activePart
              atTime:time];

  if ([self driftEnabledAtTime:time])
    [self hitTestPoint:&_points[2]
             positionX:positionX
             positionY:positionY
            activePart:activePart
                atTime:time];

  if (exitOn && animOutOn)
    [self hitTestPoint:&_points[3]
             positionX:positionX
             positionY:positionY
            activePart:activePart
                atTime:time];

  // Path elements only if no main point was hit
  if (*activePart == prePart && showA)
    [self hitTestPathAtX:positionX
                       Y:positionY
              activePart:activePart
                  atTime:time];
}

- (BOOL)mouseDownForPoint:(PointOSCState *)pt
                positionX:(double)positionX
                positionY:(double)positionY
               activePart:(NSInteger)activePart
              forceUpdate:(BOOL *)forceUpdate
                   atTime:(CMTime)time {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];

  if (activePart == pt->iconPart) {
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> paramSetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    BOOL previewOn = NO;
    [paramGetAPI getBoolValue:&previewOn
                fromParameter:pt->previewParam
                       atTime:time];
    [paramSetAPI setBoolValue:!previewOn
                  toParameter:pt->previewParam
                       atTime:time];
    *forceUpdate = YES;
    return YES;
  }

  if (activePart == pt->opacityIconPart) {
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> paramSetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    double opacity = 1.0;
    [paramGetAPI getFloatValue:&opacity
                 fromParameter:pt->opacityParam
                        atTime:time];
    [paramSetAPI setFloatValue:(opacity >= 1.0) ? 0.0 : 1.0
                   toParameter:pt->opacityParam
                        atTime:time];
    *forceUpdate = YES;
    return YES;
  }

  if (activePart == pt->rotPart) {
    pt->rotDragging = YES;
    CGPoint center = [self positionForParam:pt->pointParam atTime:time];
    double dx = positionX - center.x;
    double dy = positionY - center.y;
    pt->rotDragPrevAngle = atan2(-dy, dx);
    pt->rotDragAccum = [self rotationForParam:pt->rotParam atTime:time];
    [oscAPI setCursor:[NSCursor crosshairCursor]];
    *forceUpdate = YES;
    return YES;
  }

  if (activePart == pt->ringPart) {
    pt->ringDragging = YES;
    CGPoint center = [self positionForParam:pt->pointParam atTime:time];
    double dx = positionX - center.x;
    double dy = positionY - center.y;
    pt->ringDragStartDist = sqrt(dx * dx + dy * dy);
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    double s = 1.0;
    [paramGetAPI getFloatValue:&s fromParameter:pt->scaleParam atTime:time];
    pt->ringDragStartVal = s;
    [pt->ring updateCursorForMouseX:positionX positionY:positionY];
    *forceUpdate = YES;
    return YES;
  }

  if (activePart == pt->arcPart) {
    pt->arcDragging = YES;
    if (pt->arc == self) {
      [super mouseDownAtPositionX:positionX
                        positionY:positionY
                       activePart:activePart
                        modifiers:0
                      forceUpdate:forceUpdate
                           atTime:time];
    }
    [oscAPI setCursor:[NSCursor openHandCursor]];
    *forceUpdate = YES;
    return YES;
  }

  return NO;
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  for (int i = 0; i < kPointCount; i++) {
    if ([self mouseDownForPoint:&_points[i]
                      positionX:positionX
                      positionY:positionY
                     activePart:activePart
                    forceUpdate:forceUpdate
                         atTime:time])
      return;
  }
  if ([self mouseDownForPathWithPart:activePart
                           positionX:positionX
                           positionY:positionY
                           modifiers:modifiers
                         forceUpdate:forceUpdate
                              atTime:time])
    return;
  [super mouseDownAtPositionX:positionX
                    positionY:positionY
                   activePart:activePart
                    modifiers:modifiers
                  forceUpdate:forceUpdate
                       atTime:time];
}

- (void)setPositionParam:(UInt32)paramID
                   fromX:(double)canvasX
                       Y:(double)canvasY
              snapTarget:(CGPoint)snapTarget
                  atTime:(CMTime)time {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return;

  CGPoint canvasCenter;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:0.5
                          fromY:0.5
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&canvasCenter.x
                            toY:&canvasCenter.y];

  double distPointX = fabs(canvasX - snapTarget.x);
  double distCenterX = fabs(canvasX - canvasCenter.x);
  double distPointY = fabs(canvasY - snapTarget.y);
  double distCenterY = fabs(canvasY - canvasCenter.y);

  _snapX = NO;
  _snapY = NO;

  if (distPointX < kSnapThreshold && distPointX <= distCenterX) {
    _snapX = YES;
    canvasX = snapTarget.x;
    _snapXVal = (float)snapTarget.x;
  } else if (distCenterX < kSnapThreshold) {
    _snapX = YES;
    canvasX = canvasCenter.x;
    _snapXVal = (float)canvasCenter.x;
  }

  if (distPointY < kSnapThreshold && distPointY <= distCenterY) {
    _snapY = YES;
    canvasY = snapTarget.y;
    _snapYVal = (float)snapTarget.y;
  } else if (distCenterY < kSnapThreshold) {
    _snapY = YES;
    canvasY = canvasCenter.y;
    _snapYVal = (float)canvasCenter.y;
  }

  double objX, objY;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                          fromX:canvasX
                          fromY:canvasY
                        toSpace:kFxDrawingCoordinates_OBJECT
                            toX:&objX
                            toY:&objY];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (paramSetAPI)
    [paramSetAPI setXValue:objX YValue:objY toParameter:paramID atTime:time];
}

- (BOOL)mouseDraggedForPoint:(PointOSCState *)pt
                  snapTarget:(CGPoint)snapTarget
                   positionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                      atTime:(CMTime)time {
  CGPoint center = [self positionForParam:pt->pointParam atTime:time];

  if (activePart == pt->rotPart) {
    double dx = positionX - center.x;
    double dy = positionY - center.y;
    double angle = atan2(-dy, dx);
    double delta = angle - pt->rotDragPrevAngle;
    if (delta > M_PI)
      delta -= 2.0 * M_PI;
    else if (delta < -M_PI)
      delta += 2.0 * M_PI;
    pt->rotDragAccum += delta;
    pt->rotDragPrevAngle = angle;
    id<FxParameterSettingAPI_v5> paramSetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    if (paramSetAPI)
      [paramSetAPI setFloatValue:pt->rotDragAccum
                     toParameter:pt->rotParam
                          atTime:time];
    return YES;
  }

  if (activePart == pt->ringPart) {
    double dx = positionX - center.x;
    double dy = positionY - center.y;
    double dist = sqrt(dx * dx + dy * dy);
    if (pt->ringDragStartDist > 0) {
      double newVal = CLAMP(
          pt->ringDragStartVal * (dist / pt->ringDragStartDist), 0.0, 10.0);
      id<FxParameterSettingAPI_v5> paramSetAPI =
          [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      if (paramSetAPI)
        [paramSetAPI setFloatValue:newVal
                       toParameter:pt->scaleParam
                            atTime:time];
    }
    [pt->ring updateCursorForMouseX:positionX positionY:positionY];
    return YES;
  }

  if (activePart == pt->arcPart) {
    [self setPositionParam:pt->pointParam
                     fromX:positionX
                         Y:positionY
                snapTarget:snapTarget
                    atTime:time];
    return YES;
  }

  return NO;
}

- (void)mouseDraggedAtPositionX:(double)positionX
                      positionY:(double)positionY
                     activePart:(NSInteger)activePart
                      modifiers:(NSUInteger)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time {
  if ([self mouseDraggedForPathWithPart:activePart
                              positionX:positionX
                              positionY:positionY
                                 atTime:time]) {
    *forceUpdate = YES;
    return;
  }
  for (int i = 0; i < kPointCount; i++) {
    CGPoint snapTarget =
        [self positionForParam:_points[(i + 1) % kPointCount].pointParam
                        atTime:time];
    if ([self mouseDraggedForPoint:&_points[i]
                        snapTarget:snapTarget
                         positionX:positionX
                         positionY:positionY
                        activePart:activePart
                            atTime:time]) {
      *forceUpdate = YES;
      return;
    }
  }
  [super mouseDraggedAtPositionX:positionX
                       positionY:positionY
                      activePart:activePart
                       modifiers:modifiers
                     forceUpdate:forceUpdate
                          atTime:time];
}

- (void)mouseUpAtPositionX:(double)positionX
                 positionY:(double)positionY
                activePart:(NSInteger)activePart
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time {
  _snapX = NO;
  _snapY = NO;
  _pathDragIndex = -1;
  _pathDragIsInHandle = NO;
  _pathDragIsOutHandle = NO;
  _pathSnapX = NO;
  _pathSnapY = NO;
  for (int i = 0; i < kPointCount; i++) {
    _points[i].arcDragging = NO;
    _points[i].arcHovered = NO;
    _points[i].ringDragging = NO;
    _points[i].ringHovered = NO;
    _points[i].rotDragging = NO;
    _points[i].rotHovered = NO;
  }
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  [oscAPI setCursor:[NSCursor arrowCursor]];
  [super mouseUpAtPositionX:positionX
                  positionY:positionY
                 activePart:activePart
                  modifiers:modifiers
                forceUpdate:forceUpdate
                     atTime:time];
}

@end
