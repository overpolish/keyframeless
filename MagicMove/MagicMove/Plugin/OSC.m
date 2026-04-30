/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC.h"
#import "Constants.h"
#import <CoreGraphics/CGEventSource.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKSquarePointOSC.h>
#import <QuartzCore/QuartzCore.h>

#define CLAMP(x, lo, hi) MAX((lo), MIN((hi), (x)))

static const float kPathHitThreshold = 10.0f;
static const float kPathPointHitRadius = 8.0f;
static const float kPathSnapThreshold = 8.0f;
static const NSUInteger kPathHitResolution = 24;

// Path-part encoding: segmentIndex * 1000 + role-offset.
//   curve = 50, point[i] = 100+i, inHandle[i] = 200+i, outHandle[i] = 300+i
static inline NSInteger pathPartCurve(NSInteger seg) { return seg * 1000 + 50; }
static inline NSInteger pathPartPoint(NSInteger seg, NSUInteger i) {
  return seg * 1000 + 100 + (NSInteger)i;
}
static inline NSInteger pathPartInHandle(NSInteger seg, NSUInteger i) {
  return seg * 1000 + 200 + (NSInteger)i;
}
static inline NSInteger pathPartOutHandle(NSInteger seg, NSUInteger i) {
  return seg * 1000 + 300 + (NSInteger)i;
}
static inline BOOL isPathPart(NSInteger part) { return part >= 50; }
static inline NSInteger pathSegFromPart(NSInteger part) { return part / 1000; }
static inline NSInteger pathRoleOffset(NSInteger part) { return part % 1000; }

@interface KKArcOSC (FxOSC) <FxOnScreenControl_v4>
@end

@implementation MagicMoveOSC {
  KKRingOSC *_scaleRing;
  KKRotationOSC *_rot;
  KKRingOSC *_rotXRing;
  KKRingOSC *_rotYRing;
  KKIconButtonOSC *_opacityIcon;
  KKIconButtonOSC *_scaleIcon;
  KKSquarePointOSC *_anchorOSC;
  KKPointOSC *_pathPointOSC;
  KKPointOSC *_pathHandleOSC;
  KKSnapEngine *_positionSnap;
  KKSnapEngine *_anchorSnap;
  KKSnapEngine *_pathSnap;

  // Path interaction state (step 4 will populate; declared early so the
  // draw path can read it for active highlighting).
  NSInteger _pathDragSegIndex;
  NSInteger _pathDragPointIndex;
  BOOL _pathDragIsInHandle;
  BOOL _pathDragIsOutHandle;
  simd_float2 _pathDragStartObj;
  NSTimeInterval _pathLastClickTime;
  NSInteger _pathLastClickSegIdx;
  NSInteger _pathLastClickPointIdx;

  BOOL _arcHovered, _arcDragging;
  double _arcDragStartX, _arcDragStartY;

  BOOL _scaleRingHovered, _scaleRingDragging;
  double _scaleDragStartDist, _scaleDragStartAngle;
  double _scaleDragStartValX, _scaleDragStartValY;
  NSTimeInterval _scaleLastClickTime;

  BOOL _rotHovered, _rotDragging;
  double _rotDragPrevAngle, _rotDragAccum;
  UInt32 _rotDragTargetParam;

  BOOL _rotXRingHovered, _rotXRingDragging;
  BOOL _rotYRingHovered, _rotYRingDragging;
  double _rotRingDragPrevPos;

  BOOL _anchorHovered, _anchorDragging;

  CFTimeInterval _lastHitTestTimestamp;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    self.clearsOnDraw = NO;

    _scaleRing = [[KKRingOSC alloc] initWithAPIManager:apiManager];
    _scaleRing.clearsOnDraw = NO;

    _rot = [[KKRotationOSC alloc] initWithAPIManager:apiManager];

    _rotXRing = [[KKRingOSC alloc] initWithAPIManager:apiManager];
    _rotXRing.tintColor = [NSColor colorWithRed:0.9 green:0.2 blue:0.2 alpha:1];
    _rotXRing.ringRadius = 70.0f;
    _rotXRing.ringRadiusY = 40.0f;
    _rotXRing.fillWidth = 3.0f;
    _rotXRing.hoverCursor = [NSCursor resizeLeftRightCursor];

    _rotYRing = [[KKRingOSC alloc] initWithAPIManager:apiManager];
    _rotYRing.tintColor = [NSColor colorWithRed:0.2 green:0.8 blue:0.2 alpha:1];
    _rotYRing.ringRadius = 40.0f;
    _rotYRing.ringRadiusY = 70.0f;
    _rotYRing.fillWidth = 3.0f;
    _rotYRing.hoverCursor = [NSCursor resizeUpDownCursor];

    _opacityIcon = [[KKIconButtonOSC alloc] initWithAPIManager:apiManager];
    _opacityIcon.iconName = @"circle.fill";
    _scaleIcon = [[KKIconButtonOSC alloc] initWithAPIManager:apiManager];
    _scaleIcon.iconName = @"squareshape.fill";

    _anchorOSC = [[KKSquarePointOSC alloc] initWithAPIManager:apiManager];
    _anchorOSC.clearsOnDraw = NO;

    _pathPointOSC = [[KKPointOSC alloc] initWithAPIManager:apiManager];
    _pathPointOSC.clearsOnDraw = NO;
    _pathPointOSC.oscRadius = 5.0f;
    _pathPointOSC.outlineWidth = 1.5f;
    _pathHandleOSC = [[KKPointOSC alloc] initWithAPIManager:apiManager];
    _pathHandleOSC.clearsOnDraw = NO;
    _pathHandleOSC.oscRadius = 3.0f;
    _pathHandleOSC.outlineWidth = 1.0f;

    _positionSnap = [[KKSnapEngine alloc] init];
    _anchorSnap = [[KKSnapEngine alloc] init];
    _pathSnap = [[KKSnapEngine alloc] init];
    _pathDragSegIndex = -1;
    _pathDragPointIndex = -1;
    _pathLastClickSegIdx = -1;
    _pathLastClickPointIdx = -1;
  }
  return self;
}

- (CGPoint)oscPositionAtTime:(CMTime)time {
  return [self canvasPositionForParam:kParamPoint atTime:time];
}

- (CGPoint)canvasCenter {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return CGPointZero;
  CGPoint c = CGPointZero;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:0.5
                          fromY:0.5
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&c.x
                            toY:&c.y];
  return c;
}

- (void)updateScaleRingAtTime:(CMTime)time {
  float minDim = [self canvasMinDimension];
  double sx = 1.0, sy = 1.0;
  id<FxParameterRetrievalAPI_v6> api =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  [api getFloatValue:&sx fromParameter:kParamScale atTime:time];
  [api getFloatValue:&sy fromParameter:kParamScaleY atTime:time];
  _scaleRing.ringRadius = minDim * 0.1f * (float)sx;
  _scaleRing.ringRadiusY = minDim * 0.1f * (float)sy;
}

- (void)layoutCenterIcons:(CGPoint)center
                 arcOuter:(float)arcOuter
                opacityAt:(CGPoint *)outOpacity
                  scaleAt:(CGPoint *)outScale {
  float gap = 6.0f;
  float totalWidth = _opacityIcon.size.width + gap + _scaleIcon.size.width;
  float iconY = center.y + arcOuter + 4.0f + _opacityIcon.size.height / 2.0f;
  float iconX = center.x - totalWidth / 2.0f;
  *outOpacity = CGPointMake(iconX + _opacityIcon.size.width / 2.0f, iconY);
  *outScale = CGPointMake(iconX + _opacityIcon.size.width + gap +
                              _scaleIcon.size.width / 2.0f,
                          iconY);
}

- (KKTimingLane *)_positionLaneAtTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!getAPI)
    return nil;
  NSString *json = nil;
  [getAPI getStringParameterValue:&json fromParameter:kKKParamMultiStageData];
  for (KKTimingLane *lane in [KKTimingLane lanesFromJSON:json]) {
    if ([lane.propertyLabel isEqualToString:@"Position"])
      return lane;
  }
  return nil;
}

- (KKBezierPath *)_pathForSegment:(KKTimingSegment *)seg {
  if (seg.pathData.length > 0)
    return [KKBezierPath pathWithData:seg.pathData];
  return [[KKBezierPath alloc] init];
}

- (void)_writePath:(KKBezierPath *)path forSegmentIndex:(NSInteger)segIdx {
  NSData *data = [path dataRepresentation];
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!setAPI || !getAPI)
    return;
  [actAPI startAction:self];
  NSString *json = nil;
  [getAPI getStringParameterValue:&json fromParameter:kKKParamMultiStageData];
  NSMutableArray<KKTimingLane *> *lanes =
      [[KKTimingLane lanesFromJSON:json] mutableCopy];
  if (lanes) {
    for (NSUInteger li = 0; li < lanes.count; li++) {
      KKTimingLane *lane = lanes[li];
      if (![lane.propertyLabel isEqualToString:@"Position"])
        continue;
      if (segIdx < 0 || (NSUInteger)segIdx >= lane.segments.count)
        break;
      KKTimingLane *mLane = [lane copy];
      NSMutableArray *mSegs = [mLane.segments mutableCopy];
      KKTimingSegment *mSeg = [mSegs[segIdx] copy];
      mSeg.pathData = data.length > 0 ? data : nil;
      mSegs[segIdx] = mSeg;
      mLane.segments = mSegs;
      lanes[li] = mLane;
      NSString *outJSON = [KKTimingLane jsonFromLanes:lanes];
      if (outJSON)
        [setAPI setStringParameterValue:outJSON
                            toParameter:kKKParamMultiStageData];
      break;
    }
  }
  [actAPI endAction:self];
}

- (void)_drawPositionPathsAtTime:(CMTime)time
                destinationImage:(FxImageTile *)dest {
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!getAPI)
    return;
  NSString *json = nil;
  [getAPI getStringParameterValue:&json fromParameter:kKKParamMultiStageData];
  NSArray<KKTimingLane *> *lanes = [KKTimingLane lanesFromJSON:json];
  KKTimingLane *posLane = nil;
  for (KKTimingLane *lane in lanes) {
    if ([lane.propertyLabel isEqualToString:@"Position"]) {
      posLane = lane;
      break;
    }
  }
  if (!posLane.enabled || !posLane.segments.count)
    return;

  simd_float4 pathColor = (simd_float4){1.0f, 0.2f, 0.2f, 1.0f};
  static const NSUInteger kRes = 24;

  for (NSUInteger idx = 0; idx < posLane.segments.count; idx++) {
    KKTimingSegment *seg = posLane.segments[idx];
    if (seg.type != KKSegmentTypeTransition)
      continue;

    NSArray<NSNumber *> *fromVals =
        KKTimingBoundaryBefore(idx, posLane.segments);
    NSArray<NSNumber *> *toVals = KKTimingBoundaryAfter(idx, posLane.segments);
    if (fromVals.count < 2 || toVals.count < 2)
      continue;
    simd_float2 startObj = {(float)fromVals[0].doubleValue,
                            (float)fromVals[1].doubleValue};
    simd_float2 endObj = {(float)toVals[0].doubleValue,
                          (float)toVals[1].doubleValue};

    KKBezierPath *path = seg.pathData.length > 0
                             ? [KKBezierPath pathWithData:seg.pathData]
                             : [[KKBezierPath alloc] init];
    NSUInteger segCount = path.segmentCount;

    for (NSUInteger s = 0; s < segCount; s++) {
      CGPoint prev = CGPointZero;
      for (NSUInteger i = 0; i <= kRes; i++) {
        float localT = (float)i / (float)kRes;
        simd_float2 objPt = [path evaluateSegment:s
                                              atT:localT
                                            start:startObj
                                              end:endObj];
        CGPoint cur = [self canvasPointFromObjectPoint:objPt];
        if (i > 0)
          [self drawLineFrom:prev
                            to:cur
                         color:pathColor
                     halfWidth:2.0f
              destinationImage:dest];
        prev = cur;
      }
    }

    for (NSUInteger i = 0; i < path.count; i++) {
      KKBezierPoint pt = [path pointAtIndex:i];
      CGPoint ptCanvas =
          [self canvasPointFromObjectPoint:(simd_float2){pt.x, pt.y}];

      if (pt.type == KKBezierPointBezier) {
        CGPoint inC =
            [self canvasPointFromObjectPoint:(simd_float2){pt.x + pt.inX,
                                                           pt.y + pt.inY}];
        CGPoint outC =
            [self canvasPointFromObjectPoint:(simd_float2){pt.x + pt.outX,
                                                           pt.y + pt.outY}];
        simd_float4 handleColor = pathColor;
        handleColor.w = 0.33f;
        [self drawLineFrom:ptCanvas
                          to:inC
                       color:handleColor
                   halfWidth:2.0f
            destinationImage:dest];
        [self drawLineFrom:ptCanvas
                          to:outC
                       color:handleColor
                   halfWidth:2.0f
            destinationImage:dest];
        [_pathHandleOSC drawAtCanvasPosition:inC
                                   isHovered:NO
                                    isActive:NO
                            destinationImage:dest
                                      atTime:time];
        [_pathHandleOSC drawAtCanvasPosition:outC
                                   isHovered:NO
                                    isActive:NO
                            destinationImage:dest
                                      atTime:time];
      }

      BOOL active = (_pathDragSegIndex == (NSInteger)idx &&
                     _pathDragPointIndex == (NSInteger)i &&
                     !_pathDragIsInHandle && !_pathDragIsOutHandle);
      [_pathPointOSC drawAtCanvasPosition:ptCanvas
                                isHovered:NO
                                 isActive:active
                         destinationImage:dest
                                   atTime:time];
    }
  }
}

- (void)drawOSCWithWidth:(NSInteger)width
                  height:(NSInteger)height
              activePart:(NSInteger)activePart
        destinationImage:(FxImageTile *)destinationImage
                  atTime:(CMTime)time {
  [KKPlugin multiStageDrawOSCTickForAPI:self.apiManager atTime:time];

  [self encodeRenderCommandsForDestinationImage:destinationImage
                                 canvasPosition:CGPointZero
                               clearDestination:YES
                                       commands:^(id<MTLRenderCommandEncoder> e,
                                                  CGPoint p, simd_uint2 v){
                                       }];

  [_positionSnap drawSnapGuidesWithOSC:self
                         isObjectSpace:NO
                      destinationImage:destinationImage];
  [_anchorSnap drawSnapGuidesWithOSC:self
                       isObjectSpace:YES
                    destinationImage:destinationImage];
  [_pathSnap drawSnapGuidesWithOSC:self
                     isObjectSpace:YES
                  destinationImage:destinationImage];

  CGPoint center = [self canvasCenter];
  CGPoint posPos = [self oscPositionAtTime:time];

  CGEventFlags flags =
      CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
  // Only treat Opt as a canvas "peek" modifier if the mouse has recently
  // moved over the canvas viewer (hit-test is the only signal we get for
  // canvas hover). Otherwise an Opt-click in the inspector would force-show
  // the rot X/Y rings until the next mouse move clears them.
  BOOL canvasActive = (CACurrentMediaTime() - _lastHitTestTimestamp) < 0.5 ||
                      _arcDragging || _scaleRingDragging || _rotDragging ||
                      _rotXRingDragging || _rotYRingDragging || _anchorDragging;
  BOOL optHeld = ((flags & kCGEventFlagMaskAlternate) != 0) && canvasActive;

  BOOL positionVisible = [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                                        label:@"Position"];
  BOOL scaleVisible = [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                                     label:@"Scale"];
  BOOL rotZVisible = [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                                    label:@"Rot Z"];
  BOOL rotXVisible = [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                                    label:@"Rot X"];
  BOOL rotYVisible = [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                                    label:@"Rot Y"];
  BOOL opacityVisible = [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                                       label:@"Opacity"];

  BOOL rotXEnabled =
      rotXVisible || optHeld || _rotXRingDragging || _rotXRingHovered;
  BOOL rotYEnabled =
      rotYVisible || optHeld || _rotYRingDragging || _rotYRingHovered;
  BOOL showRotX = rotXEnabled;
  BOOL showRotY = rotYEnabled;

  if (scaleVisible) {
    [self updateScaleRingAtTime:time];
    _scaleRing.center = center;
    [_scaleRing drawAtCanvasPosition:center
                           isHovered:_scaleRingHovered
                            isActive:_scaleRingDragging
                    destinationImage:destinationImage
                              atTime:time];
  }

  if (rotZVisible) {
    float rotAngle = [self floatValueForParam:kParamRotation atTime:time];
    _rot.center = center;
    _rot.angle = rotAngle;
    [_rot drawAtCanvasPosition:center
                     isHovered:_rotHovered
                      isActive:_rotDragging
              destinationImage:destinationImage
                        atTime:time];
  }

  if (showRotX) {
    _rotXRing.center = center;
    [_rotXRing drawAtCanvasPosition:center
                          isHovered:_rotXRingHovered
                           isActive:_rotXRingDragging
                   destinationImage:destinationImage
                             atTime:time];
  }

  if (showRotY) {
    _rotYRing.center = center;
    [_rotYRing drawAtCanvasPosition:center
                          isHovered:_rotYRingHovered
                           isActive:_rotYRingDragging
                   destinationImage:destinationImage
                             atTime:time];
  }

  // Update icon glyphs based on opacity / scale.
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  double opacity = 1.0;
  [paramGetAPI getFloatValue:&opacity fromParameter:kParamOpacity atTime:time];
  if (opacity >= 1.0)
    _opacityIcon.iconName = @"circle.fill";
  else if (opacity <= 0.0)
    _opacityIcon.iconName = @"circle";
  else
    _opacityIcon.iconName =
        @"circle.lefthalf.filled.righthalf.striped.horizontal.inverse";

  double sx = 1.0, sy = 1.0;
  [paramGetAPI getFloatValue:&sx fromParameter:kParamScale atTime:time];
  [paramGetAPI getFloatValue:&sy fromParameter:kParamScaleY atTime:time];
  double scale = fmax(sx, sy);
  if (scale > 1.0)
    _scaleIcon.iconName = @"squareshape.dotted.squareshape";
  else if (scale == 1.0)
    _scaleIcon.iconName = @"squareshape.fill";
  else if (scale <= 0.0)
    _scaleIcon.iconName = @"squareshape";
  else
    _scaleIcon.iconName = @"squareshape.squareshape.dotted";

  float arcOuter = self.oscRadius + self.outlineWidth;
  CGPoint opacityCenter, scaleCenter;
  [self layoutCenterIcons:center
                 arcOuter:arcOuter
                opacityAt:&opacityCenter
                  scaleAt:&scaleCenter];
  if (opacityVisible)
    [_opacityIcon drawAtCanvasPosition:opacityCenter
                      destinationImage:destinationImage];
  if (scaleVisible)
    [_scaleIcon drawAtCanvasPosition:scaleCenter
                    destinationImage:destinationImage];

  if (positionVisible)
    [self _drawPositionPathsAtTime:time destinationImage:destinationImage];

  // Position handle follows the position param.
  if (positionVisible) {
    self.fillAlpha = (opacity < 1.0) ? 0.25f : 1.0f;
    [self drawAtCanvasPosition:posPos
                     isHovered:_arcHovered
                      isActive:_arcDragging
              destinationImage:destinationImage
                        atTime:time];
  }

  // Anchor square is independent.
  CGPoint anchorCanvas = [self canvasPositionForParam:kParamAnchorPoint
                                               atTime:time];
  [_anchorOSC drawAtCanvasPosition:anchorCanvas
                         isHovered:_anchorHovered
                          isActive:_anchorDragging
                  destinationImage:destinationImage
                            atTime:time];
}

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  *activePart = 0;
  _arcHovered = NO;
  _scaleRingHovered = NO;
  _rotHovered = NO;
  _rotXRingHovered = NO;
  _rotYRingHovered = NO;
  _anchorHovered = NO;
  _lastHitTestTimestamp = CACurrentMediaTime();

  CGPoint center = [self canvasCenter];
  float arcOuter = self.oscRadius + self.outlineWidth;
  CGPoint opacityCenter, scaleCenter;
  [self layoutCenterIcons:center
                 arcOuter:arcOuter
                opacityAt:&opacityCenter
                  scaleAt:&scaleCenter];

  BOOL positionVisible = [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                                        label:@"Position"];
  BOOL scaleVisible = [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                                     label:@"Scale"];
  BOOL rotZVisible = [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                                    label:@"Rot Z"];
  BOOL rotXVisible = [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                                    label:@"Rot X"];
  BOOL rotYVisible = [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                                    label:@"Rot Y"];
  BOOL opacityVisible = [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                                       label:@"Opacity"];

  CGEventFlags flags =
      CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
  BOOL optHeld = (flags & kCGEventFlagMaskAlternate) != 0;

  if (opacityVisible && [_opacityIcon hitTestAtMousePositionX:positionX
                                                    positionY:positionY
                                                       center:opacityCenter]) {
    *activePart = kOSCOpacityIconPart;
    return;
  }
  if (scaleVisible && [_scaleIcon hitTestAtMousePositionX:positionX
                                                positionY:positionY
                                                   center:scaleCenter]) {
    *activePart = kOSCScaleIconPart;
    return;
  }

  // Anchor.
  CGPoint anchorCanvas = [self canvasPositionForParam:kParamAnchorPoint
                                               atTime:time];
  if (fmax(fabs(positionX - anchorCanvas.x), fabs(positionY - anchorCanvas.y)) <
      [_anchorOSC hitRadius]) {
    _anchorHovered = YES;
    *activePart = kOSCAnchorPart;
    return;
  }

  // Rotation X/Y rings — interactive when their lane is on, or Opt held.
  if (rotXVisible || optHeld) {
    _rotXRing.center = center;
    if ([_rotXRing hitTestAtMousePositionX:positionX
                                 positionY:positionY
                                    atTime:time]) {
      _rotXRingHovered = YES;
      *activePart = kOSCRotXRingPart;
      return;
    }
  } else {
    [_rotXRing clearCursorIfSet];
  }
  if (rotYVisible || optHeld) {
    _rotYRing.center = center;
    if ([_rotYRing hitTestAtMousePositionX:positionX
                                 positionY:positionY
                                    atTime:time]) {
      _rotYRingHovered = YES;
      *activePart = kOSCRotYRingPart;
      return;
    }
  } else {
    [_rotYRing clearCursorIfSet];
  }

  if (scaleVisible) {
    [self updateScaleRingAtTime:time];
    _scaleRing.center = center;
    if ([_scaleRing hitTestAtMousePositionX:positionX
                                  positionY:positionY
                                     atTime:time]) {
      _scaleRingHovered = YES;
      *activePart = kOSCScaleRingPart;
      return;
    }
  }

  if (rotZVisible) {
    _rot.center = center;
    _rot.angle = [self floatValueForParam:kParamRotation atTime:time];
    if ([_rot hitTestAtMousePositionX:positionX
                            positionY:positionY
                               atTime:time]) {
      _rotHovered = YES;
      *activePart = kOSCRotPart;
      return;
    }
  }

  // Position arc.
  if (positionVisible) {
    CGPoint posPos = [self oscPositionAtTime:time];
    double dx = positionX - posPos.x;
    double dy = positionY - posPos.y;
    if (sqrt(dx * dx + dy * dy) < self.hitRadius) {
      _arcHovered = YES;
      *activePart = kOSCPositionPart;
      return;
    }
  }

  // Position path (transition segments).
  if (positionVisible) {
    KKTimingLane *posLane = [self _positionLaneAtTime:time];
    if (posLane.enabled) {
      CGEventFlags hflags =
          CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
      BOOL hOpt = (hflags & kCGEventFlagMaskAlternate) != 0;
      id<FxOnScreenControlAPI_v4> oscAPI =
          [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
      for (NSUInteger idx = 0; idx < posLane.segments.count; idx++) {
        KKTimingSegment *seg = posLane.segments[idx];
        if (seg.type != KKSegmentTypeTransition)
          continue;
        NSArray<NSNumber *> *fromVals =
            KKTimingBoundaryBefore(idx, posLane.segments);
        NSArray<NSNumber *> *toVals =
            KKTimingBoundaryAfter(idx, posLane.segments);
        if (fromVals.count < 2 || toVals.count < 2)
          continue;
        simd_float2 startObj = {(float)fromVals[0].doubleValue,
                                (float)fromVals[1].doubleValue};
        simd_float2 endObj = {(float)toVals[0].doubleValue,
                              (float)toVals[1].doubleValue};
        KKBezierPath *path = [self _pathForSegment:seg];

        // Handles first (smaller, top-most).
        BOOL hit = NO;
        for (NSUInteger i = 0; i < path.count && !hit; i++) {
          KKBezierPoint pt = [path pointAtIndex:i];
          if (pt.type != KKBezierPointBezier)
            continue;
          CGPoint inC =
              [self canvasPointFromObjectPoint:(simd_float2){pt.x + pt.inX,
                                                             pt.y + pt.inY}];
          CGPoint outC =
              [self canvasPointFromObjectPoint:(simd_float2){pt.x + pt.outX,
                                                             pt.y + pt.outY}];
          if (hypot(positionX - inC.x, positionY - inC.y) <
              kPathPointHitRadius) {
            *activePart = pathPartInHandle(idx, i);
            hit = YES;
            break;
          }
          if (hypot(positionX - outC.x, positionY - outC.y) <
              kPathPointHitRadius) {
            *activePart = pathPartOutHandle(idx, i);
            hit = YES;
            break;
          }
        }
        if (hit)
          return;

        // Path control points.
        for (NSUInteger i = 0; i < path.count; i++) {
          KKBezierPoint pt = [path pointAtIndex:i];
          CGPoint ptC =
              [self canvasPointFromObjectPoint:(simd_float2){pt.x, pt.y}];
          if (hypot(positionX - ptC.x, positionY - ptC.y) <
              kPathPointHitRadius) {
            *activePart = pathPartPoint(idx, i);
            [oscAPI setCursor:hOpt ? [NSCursor disappearingItemCursor]
                                   : [NSCursor arrowCursor]];
            return;
          }
        }

        // Path curve.
        NSUInteger segCount = path.segmentCount;
        float bestDist = FLT_MAX;
        for (NSUInteger s = 0; s < segCount; s++) {
          CGPoint prev = CGPointZero;
          for (NSUInteger i = 0; i <= kPathHitResolution; i++) {
            float localT = (float)i / (float)kPathHitResolution;
            simd_float2 objPt = [path evaluateSegment:s
                                                  atT:localT
                                                start:startObj
                                                  end:endObj];
            CGPoint cur = [self canvasPointFromObjectPoint:objPt];
            if (i > 0) {
              double dxC = cur.x - prev.x, dyC = cur.y - prev.y;
              double lenSq = dxC * dxC + dyC * dyC;
              double t2 = (lenSq > 0) ? CLAMP(((positionX - prev.x) * dxC +
                                               (positionY - prev.y) * dyC) /
                                                  lenSq,
                                              0, 1)
                                      : 0;
              double cx = prev.x + t2 * dxC, cy = prev.y + t2 * dyC;
              float d = (float)hypot(positionX - cx, positionY - cy);
              if (d < bestDist)
                bestDist = d;
            }
            prev = cur;
          }
        }
        if (bestDist < kPathHitThreshold) {
          *activePart = pathPartCurve(idx);
          [oscAPI setCursor:hOpt ? [NSCursor crosshairCursor]
                                 : [NSCursor arrowCursor]];
          return;
        }
      }
    }
  }
}

- (void)_pathMouseDownAtPart:(NSInteger)activePart
                   positionX:(double)positionX
                   positionY:(double)positionY
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  BOOL optHeld = (modifiers & kFxModifierKey_OPTION) != 0;
  NSInteger segIdx = pathSegFromPart(activePart);
  NSInteger offset = pathRoleOffset(activePart);

  KKTimingLane *lane = [self _positionLaneAtTime:time];
  if (segIdx < 0 || (NSUInteger)segIdx >= lane.segments.count)
    return;
  KKTimingSegment *seg = lane.segments[segIdx];
  if (seg.type != KKSegmentTypeTransition)
    return;

  NSArray<NSNumber *> *fromVals = KKTimingBoundaryBefore(segIdx, lane.segments);
  NSArray<NSNumber *> *toVals = KKTimingBoundaryAfter(segIdx, lane.segments);
  if (fromVals.count < 2 || toVals.count < 2)
    return;
  simd_float2 startObj = {(float)fromVals[0].doubleValue,
                          (float)fromVals[1].doubleValue};
  simd_float2 endObj = {(float)toVals[0].doubleValue,
                        (float)toVals[1].doubleValue};

  KKBezierPath *path = [self _pathForSegment:seg];

  // Path control point.
  if (offset >= 100 && offset < 200) {
    NSUInteger idx = (NSUInteger)(offset - 100);
    if (idx >= path.count)
      return;
    if (optHeld) {
      [path removeAtIndex:idx];
      [self _writePath:path forSegmentIndex:segIdx];
      *forceUpdate = YES;
      return;
    }
    NSTimeInterval now = CACurrentMediaTime();
    if (_pathLastClickSegIdx == segIdx &&
        _pathLastClickPointIdx == (NSInteger)idx &&
        (now - _pathLastClickTime) < 0.35) {
      [path toggleTypeAtIndex:idx start:startObj end:endObj];
      [self _writePath:path forSegmentIndex:segIdx];
      _pathLastClickSegIdx = -1;
      _pathLastClickPointIdx = -1;
      *forceUpdate = YES;
      return;
    }
    _pathLastClickTime = now;
    _pathLastClickSegIdx = segIdx;
    _pathLastClickPointIdx = (NSInteger)idx;
    KKBezierPoint dragPt = [path pointAtIndex:idx];
    _pathDragStartObj = (simd_float2){dragPt.x, dragPt.y};
    _pathDragSegIndex = segIdx;
    _pathDragPointIndex = (NSInteger)idx;
    _pathDragIsInHandle = NO;
    _pathDragIsOutHandle = NO;
    *forceUpdate = YES;
    return;
  }

  // In handle.
  if (offset >= 200 && offset < 300) {
    NSUInteger idx = (NSUInteger)(offset - 200);
    if (idx < path.count) {
      KKBezierPoint pt = [path pointAtIndex:idx];
      _pathDragStartObj = (simd_float2){pt.x + pt.inX, pt.y + pt.inY};
    }
    _pathDragSegIndex = segIdx;
    _pathDragPointIndex = (NSInteger)idx;
    _pathDragIsInHandle = YES;
    _pathDragIsOutHandle = NO;
    *forceUpdate = YES;
    return;
  }

  // Out handle.
  if (offset >= 300 && offset < 400) {
    NSUInteger idx = (NSUInteger)(offset - 300);
    if (idx < path.count) {
      KKBezierPoint pt = [path pointAtIndex:idx];
      _pathDragStartObj = (simd_float2){pt.x + pt.outX, pt.y + pt.outY};
    }
    _pathDragSegIndex = segIdx;
    _pathDragPointIndex = (NSInteger)idx;
    _pathDragIsInHandle = NO;
    _pathDragIsOutHandle = YES;
    *forceUpdate = YES;
    return;
  }

  // Curve: alt-click inserts a new point at the closest segment.
  if (offset == 50 && optHeld) {
    simd_float2 mouseObj =
        [self objectPointFromCanvasPoint:(CGPoint){positionX, positionY}];
    NSUInteger bestSeg = 0;
    float bestDist = FLT_MAX;
    for (NSUInteger s = 0; s < path.segmentCount; s++) {
      for (NSUInteger i = 1; i <= kPathHitResolution; i++) {
        float localT = (float)i / (float)kPathHitResolution;
        simd_float2 objPt = [path evaluateSegment:s
                                              atT:localT
                                            start:startObj
                                              end:endObj];
        float d = simd_length(objPt - mouseObj);
        if (d < bestDist) {
          bestDist = d;
          bestSeg = s;
        }
      }
    }
    [path insertAtIndex:bestSeg position:mouseObj];
    [self _writePath:path forSegmentIndex:segIdx];
    _pathDragSegIndex = segIdx;
    _pathDragPointIndex = (NSInteger)bestSeg;
    _pathDragIsInHandle = NO;
    _pathDragIsOutHandle = NO;
    *forceUpdate = YES;
    return;
  }
}

- (BOOL)_pathMouseDraggedAtPositionX:(double)positionX
                           positionY:(double)positionY
                              atTime:(CMTime)time {
  if (_pathDragSegIndex < 0 || _pathDragPointIndex < 0)
    return NO;
  KKTimingLane *lane = [self _positionLaneAtTime:time];
  if ((NSUInteger)_pathDragSegIndex >= lane.segments.count)
    return NO;
  KKTimingSegment *seg = lane.segments[_pathDragSegIndex];
  KKBezierPath *path = [self _pathForSegment:seg];
  if ((NSUInteger)_pathDragPointIndex >= path.count)
    return NO;

  simd_float2 mouseObj =
      [self objectPointFromCanvasPoint:(CGPoint){positionX, positionY}];
  CGEventFlags flags =
      CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
  BOOL optHeld = (flags & kCGEventFlagMaskAlternate) != 0;
  BOOL shiftHeld = (flags & kCGEventFlagMaskShift) != 0;
  BOOL ctrlHeld = (flags & kCGEventFlagMaskControl) != 0;
  [_pathSnap reset];

  if (shiftHeld) {
    float dx = fabsf(mouseObj.x - _pathDragStartObj.x);
    float dy = fabsf(mouseObj.y - _pathDragStartObj.y);
    if (dx > dy)
      mouseObj.y = _pathDragStartObj.y;
    else
      mouseObj.x = _pathDragStartObj.x;
  }

  if (_pathDragIsInHandle || _pathDragIsOutHandle) {
    KKBezierPoint pt = [path pointAtIndex:(NSUInteger)_pathDragPointIndex];
    simd_float2 handlePos = mouseObj;
    if (!shiftHeld && !ctrlHeld) {
      CGPoint ptC = [self canvasPointFromObjectPoint:(simd_float2){pt.x, pt.y}];
      CGPoint hC = [self canvasPointFromObjectPoint:handlePos];
      if (fabs(hC.y - ptC.y) < kPathSnapThreshold) {
        handlePos.y = pt.y;
        _pathSnap.snappedY = YES;
        _pathSnap.snapValueY = pt.y;
      }
      if (fabs(hC.x - ptC.x) < kPathSnapThreshold) {
        handlePos.x = pt.x;
        _pathSnap.snappedX = YES;
        _pathSnap.snapValueX = pt.x;
      }
    }
    simd_float2 offset = {handlePos.x - pt.x, handlePos.y - pt.y};
    simd_float2 mirror = {-offset.x, -offset.y};
    if (_pathDragIsInHandle) {
      [path setInHandle:offset atIndex:(NSUInteger)_pathDragPointIndex];
      if (!optHeld)
        [path setOutHandle:mirror atIndex:(NSUInteger)_pathDragPointIndex];
    } else {
      [path setOutHandle:offset atIndex:(NSUInteger)_pathDragPointIndex];
      if (!optHeld)
        [path setInHandle:mirror atIndex:(NSUInteger)_pathDragPointIndex];
    }
  } else {
    if (!ctrlHeld) {
      // Snap to other points in this path + boundary endpoints.
      NSUInteger n = path.count + 2;
      simd_float2 targets[n];
      NSUInteger nc = 0;
      NSArray<NSNumber *> *fromVals =
          KKTimingBoundaryBefore(_pathDragSegIndex, lane.segments);
      NSArray<NSNumber *> *toVals =
          KKTimingBoundaryAfter(_pathDragSegIndex, lane.segments);
      if (fromVals.count >= 2)
        targets[nc++] = (simd_float2){(float)fromVals[0].doubleValue,
                                      (float)fromVals[1].doubleValue};
      if (toVals.count >= 2)
        targets[nc++] = (simd_float2){(float)toVals[0].doubleValue,
                                      (float)toVals[1].doubleValue};
      for (NSUInteger i = 0; i < path.count; i++) {
        if ((NSInteger)i == _pathDragPointIndex)
          continue;
        KKBezierPoint p = [path pointAtIndex:i];
        targets[nc++] = (simd_float2){p.x, p.y};
      }
      CGPoint c0 = [self canvasPointFromObjectPoint:(simd_float2){0, 0}];
      CGPoint c1 = [self canvasPointFromObjectPoint:(simd_float2){1, 0}];
      float pixPerUnit = (float)fabs(c1.x - c0.x);
      mouseObj = [_pathSnap snapObjectPoint:mouseObj
                                  toTargets:targets
                                      count:nc
                              pixelsPerUnit:pixPerUnit];
    }
    [path moveAtIndex:(NSUInteger)_pathDragPointIndex to:mouseObj];
  }

  [self _writePath:path forSegmentIndex:_pathDragSegIndex];
  return YES;
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

  if (activePart == kOSCOpacityIconPart) {
    double opacity = 1.0;
    [paramGetAPI getFloatValue:&opacity
                 fromParameter:kParamOpacity
                        atTime:time];
    [paramSetAPI setFloatValue:(opacity >= 1.0) ? 0.0 : 1.0
                   toParameter:kParamOpacity
                        atTime:time];
    *forceUpdate = YES;
    return;
  }

  if (activePart == kOSCScaleIconPart) {
    double sx = 1.0, sy = 1.0;
    [paramGetAPI getFloatValue:&sx fromParameter:kParamScale atTime:time];
    [paramGetAPI getFloatValue:&sy fromParameter:kParamScaleY atTime:time];
    double newVal = (fmax(sx, sy) >= 1.0) ? 0.0 : 1.0;
    [paramSetAPI setFloatValue:newVal toParameter:kParamScale atTime:time];
    [paramSetAPI setFloatValue:newVal toParameter:kParamScaleY atTime:time];
    *forceUpdate = YES;
    return;
  }

  if (activePart == kOSCAnchorPart) {
    _anchorDragging = YES;
    [oscAPI setCursor:[NSCursor openHandCursor]];
    *forceUpdate = YES;
    return;
  }

  if (activePart == kOSCRotPart) {
    _rotDragging = YES;
    _rotDragTargetParam = kParamRotation;
    CGPoint center = [self canvasCenter];
    double dx = positionX - center.x;
    double dy = positionY - center.y;
    _rotDragPrevAngle = atan2(-dy, dx);
    _rotDragAccum = [self floatValueForParam:_rotDragTargetParam atTime:time];
    [oscAPI setCursor:[NSCursor crosshairCursor]];
    *forceUpdate = YES;
    return;
  }

  if (activePart == kOSCRotXRingPart || activePart == kOSCRotYRingPart) {
    if (activePart == kOSCRotXRingPart) {
      _rotXRingDragging = YES;
      _rotDragTargetParam = kParamRotationY;
      _rotRingDragPrevPos = positionX;
    } else {
      _rotYRingDragging = YES;
      _rotDragTargetParam = kParamRotationX;
      _rotRingDragPrevPos = positionY;
    }
    _rotDragAccum = [self floatValueForParam:_rotDragTargetParam atTime:time];
    [oscAPI setCursor:[NSCursor crosshairCursor]];
    *forceUpdate = YES;
    return;
  }

  if (activePart == kOSCScaleRingPart) {
    NSTimeInterval now = CACurrentMediaTime();
    if ((now - _scaleLastClickTime) < 0.35) {
      double sx = 1.0, sy = 1.0;
      [paramGetAPI getFloatValue:&sx fromParameter:kParamScale atTime:time];
      [paramGetAPI getFloatValue:&sy fromParameter:kParamScaleY atTime:time];
      if (sx != sy) {
        double smaller = fmin(sx, sy);
        [paramSetAPI setFloatValue:smaller toParameter:kParamScale atTime:time];
        [paramSetAPI setFloatValue:smaller
                       toParameter:kParamScaleY
                            atTime:time];
        *forceUpdate = YES;
      }
      _scaleLastClickTime = 0;
      return;
    }
    _scaleLastClickTime = now;

    _scaleRingDragging = YES;
    CGPoint center = [self canvasCenter];
    double dx = positionX - center.x;
    double dy = positionY - center.y;
    _scaleDragStartDist = sqrt(dx * dx + dy * dy);
    _scaleDragStartAngle = atan2(fabs(dy), fabs(dx));
    double sx = 1.0, sy = 1.0;
    [paramGetAPI getFloatValue:&sx fromParameter:kParamScale atTime:time];
    [paramGetAPI getFloatValue:&sy fromParameter:kParamScaleY atTime:time];
    _scaleDragStartValX = sx;
    _scaleDragStartValY = sy;
    [_scaleRing updateCursorForMouseX:positionX positionY:positionY];
    *forceUpdate = YES;
    return;
  }

  if (activePart == kOSCPositionPart) {
    _arcDragging = YES;
    _arcDragStartX = positionX;
    _arcDragStartY = positionY;
    [oscAPI setCursor:[NSCursor openHandCursor]];
    *forceUpdate = YES;
    return;
  }

  if (isPathPart(activePart)) {
    [self _pathMouseDownAtPart:activePart
                     positionX:positionX
                     positionY:positionY
                     modifiers:modifiers
                   forceUpdate:forceUpdate
                        atTime:time];
    return;
  }

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
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

  if (activePart == kOSCAnchorPart) {
    double objX, objY;
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                            fromX:positionX
                            fromY:positionY
                          toSpace:kFxDrawingCoordinates_OBJECT
                              toX:&objX
                              toY:&objY];
    simd_float2 pos = {(float)objX, (float)objY};

    CGEventFlags flags =
        CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
    BOOL snapDisabled = (flags & kCGEventFlagMaskAlternate) != 0;
    if (!snapDisabled) {
      static const simd_float2 kAnchorTargets[] = {
          {0.5f, 0.5f},        {0.0f, 0.0f},        {1.0f, 0.0f},
          {0.0f, 1.0f},        {1.0f, 1.0f},        {0.5f, 0.0f},
          {1.0f, 0.5f},        {0.5f, 1.0f},        {0.0f, 0.5f},
          {1.0f / 3.0f, 0.0f}, {2.0f / 3.0f, 0.0f}, {1.0f / 3.0f, 1.0f},
          {2.0f / 3.0f, 1.0f}, {0.0f, 1.0f / 3.0f}, {0.0f, 2.0f / 3.0f},
          {1.0f, 1.0f / 3.0f}, {1.0f, 2.0f / 3.0f},
      };
      static const NSUInteger kCount =
          sizeof(kAnchorTargets) / sizeof(kAnchorTargets[0]);
      CGPoint c0 = [self canvasPointFromObjectPoint:(simd_float2){0, 0}];
      CGPoint c1 = [self canvasPointFromObjectPoint:(simd_float2){1, 0}];
      float pixPerUnit = (float)fabs(c1.x - c0.x);
      pos = [_anchorSnap snapObjectPoint:pos
                               toTargets:kAnchorTargets
                                   count:kCount
                           pixelsPerUnit:pixPerUnit];
    } else {
      [_anchorSnap reset];
    }

    [paramSetAPI setXValue:pos.x
                    YValue:pos.y
               toParameter:kParamAnchorPoint
                    atTime:time];
    *forceUpdate = YES;
    return;
  }

  if (activePart == kOSCRotXRingPart || activePart == kOSCRotYRingPart) {
    double pos = (activePart == kOSCRotXRingPart) ? positionX : positionY;
    double delta = (pos - _rotRingDragPrevPos) * (M_PI / 200.0);
    if (activePart == kOSCRotYRingPart)
      delta = -delta;
    _rotRingDragPrevPos = pos;
    _rotDragAccum += delta;
    static const double kSnapToZero = 3.0 * (M_PI / 180.0);
    double value = _rotDragAccum;
    if (fabs(value) < kSnapToZero)
      value = 0.0;
    [paramSetAPI setFloatValue:value
                   toParameter:_rotDragTargetParam
                        atTime:time];
    *forceUpdate = YES;
    return;
  }

  if (activePart == kOSCRotPart) {
    CGPoint center = [self canvasCenter];
    double dx = positionX - center.x;
    double dy = positionY - center.y;
    double angle = atan2(-dy, dx);
    double delta = angle - _rotDragPrevAngle;
    if (delta > M_PI)
      delta -= 2.0 * M_PI;
    else if (delta < -M_PI)
      delta += 2.0 * M_PI;
    _rotDragAccum += delta;
    _rotDragPrevAngle = angle;
    static const double kSnapToZero = 3.0 * (M_PI / 180.0);
    double value = _rotDragAccum;
    if (fabs(value) < kSnapToZero)
      value = 0.0;
    [paramSetAPI setFloatValue:value
                   toParameter:_rotDragTargetParam
                        atTime:time];
    *forceUpdate = YES;
    return;
  }

  if (activePart == kOSCScaleRingPart) {
    CGPoint center = [self canvasCenter];
    double dx = positionX - center.x;
    double dy = positionY - center.y;
    double dist = sqrt(dx * dx + dy * dy);
    if (_scaleDragStartDist > 0) {
      double ratio = dist / _scaleDragStartDist;
      CGEventFlags flags =
          CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
      BOOL shiftHeld = (flags & kCGEventFlagMaskShift) != 0;
      if (shiftHeld) {
        BOOL horizontal = _scaleDragStartAngle < M_PI / 4.0;
        if (horizontal)
          [paramSetAPI
              setFloatValue:CLAMP(_scaleDragStartValX * ratio, 0.0, 10.0)
                toParameter:kParamScale
                     atTime:time];
        else
          [paramSetAPI
              setFloatValue:CLAMP(_scaleDragStartValY * ratio, 0.0, 10.0)
                toParameter:kParamScaleY
                     atTime:time];
      } else {
        [paramSetAPI setFloatValue:CLAMP(_scaleDragStartValX * ratio, 0.0, 10.0)
                       toParameter:kParamScale
                            atTime:time];
        [paramSetAPI setFloatValue:CLAMP(_scaleDragStartValY * ratio, 0.0, 10.0)
                       toParameter:kParamScaleY
                            atTime:time];
      }
    }
    [_scaleRing updateCursorForMouseX:positionX positionY:positionY];
    *forceUpdate = YES;
    return;
  }

  if (activePart == kOSCPositionPart) {
    CGEventFlags flags =
        CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
    if (flags & kCGEventFlagMaskShift) {
      double dx = fabs(positionX - _arcDragStartX);
      double dy = fabs(positionY - _arcDragStartY);
      if (dx > dy)
        positionY = _arcDragStartY;
      else
        positionX = _arcDragStartX;
    }

    CGPoint canvasCenter = [self canvasCenter];
    BOOL ctrlHeld = (flags & kCGEventFlagMaskControl) != 0;

    if (!ctrlHeld) {
      CGPoint thirds[4];
      double tx, ty;
      [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                              fromX:1.0 / 3.0
                              fromY:0.5
                            toSpace:kFxDrawingCoordinates_CANVAS
                                toX:&tx
                                toY:&ty];
      thirds[0] = (CGPoint){tx, ty};
      [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                              fromX:2.0 / 3.0
                              fromY:0.5
                            toSpace:kFxDrawingCoordinates_CANVAS
                                toX:&tx
                                toY:&ty];
      thirds[1] = (CGPoint){tx, ty};
      [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                              fromX:0.5
                              fromY:1.0 / 3.0
                            toSpace:kFxDrawingCoordinates_CANVAS
                                toX:&tx
                                toY:&ty];
      thirds[2] = (CGPoint){tx, ty};
      [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                              fromX:0.5
                              fromY:2.0 / 3.0
                            toSpace:kFxDrawingCoordinates_CANVAS
                                toX:&tx
                                toY:&ty];
      thirds[3] = (CGPoint){tx, ty};

      CGPoint targets[5] = {canvasCenter, thirds[0], thirds[1], thirds[2],
                            thirds[3]};
      CGPoint snapped =
          [_positionSnap snapCanvasPoint:(CGPoint){positionX, positionY}
                               toTargets:targets
                                   count:5];
      positionX = snapped.x;
      positionY = snapped.y;
    } else {
      [_positionSnap reset];
    }

    double objX, objY;
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                            fromX:positionX
                            fromY:positionY
                          toSpace:kFxDrawingCoordinates_OBJECT
                              toX:&objX
                              toY:&objY];
    [paramSetAPI setXValue:objX
                    YValue:objY
               toParameter:kParamPoint
                    atTime:time];
    *forceUpdate = YES;
    return;
  }

  if (isPathPart(activePart) || _pathDragSegIndex >= 0) {
    if ([self _pathMouseDraggedAtPositionX:positionX
                                 positionY:positionY
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
  _arcDragging = NO;
  _arcHovered = NO;
  _scaleRingDragging = NO;
  _scaleRingHovered = NO;
  _rotDragging = NO;
  _rotHovered = NO;
  _rotXRingDragging = NO;
  _rotXRingHovered = NO;
  _rotYRingDragging = NO;
  _rotYRingHovered = NO;
  _anchorDragging = NO;
  _anchorHovered = NO;
  _pathDragSegIndex = -1;
  _pathDragPointIndex = -1;
  _pathDragIsInHandle = NO;
  _pathDragIsOutHandle = NO;
  [_positionSnap reset];
  [_anchorSnap reset];
  [_pathSnap reset];
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
