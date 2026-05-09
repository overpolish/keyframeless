/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "OSC_Private.h"
#import <QuartzCore/QuartzCore.h>

static const float kPositionPathHitThreshold = 10.0f;
static const float kPositionPathPointHitRadius = 8.0f;
static const NSUInteger kPositionPathHitResolution = 24;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation CanvasOSC (PositionPath)

- (NSString *)_selectedSingleLayerID {
  return [self selectedTransformablePath].layerID;
}

/// Position values are stored anchored to canvas (0.5,0.5 = neutral). The
/// layer renders at bboxCenter + (position - 0.5,0.5). This offset shifts
/// the displayed motion-path so it sits on top of the actual layer.
- (simd_float2)_positionPathDisplayOffset {
  KKBezierPath *p = [self selectedTransformablePath];
  if (!p)
    return (simd_float2){0, 0};
  return [self bboxCenterOfPath:p] - (simd_float2){0.5f, 0.5f};
}

- (KKTimingLane *)laneForSelectedLayerProperty:(NSString *)label {
  NSString *layerID = [self _selectedSingleLayerID];
  if (!layerID)
    return nil;
  // OSC scope can't read KKDataBlob params — read from the per-instance
  // lanesSnapshot, populated by the multi-stage pump and the cold-boot
  // mirror seed. See project_osc_custom_blob_unreadable.md.
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  for (KKTimingLane *lane in state.lanesSnapshot) {
    if ([lane.propertyLabel isEqualToString:label] &&
        [lane.groupKey isEqualToString:layerID])
      return lane;
  }
  return nil;
}

- (KKTimingLane *)positionLaneForSelectedLayer {
  return [self laneForSelectedLayerProperty:@"Position"];
}

/// Resolve the from/to object-space endpoints flanking a transition segment.
/// Returns NO if the segment isn't a transition or boundary values are
/// missing. Centralizes the `KKTimingBoundaryBefore/After + simd_float2`
/// boilerplate that used to appear in every drawing/hit/drag method.
static BOOL _segmentBounds(NSArray<KKTimingSegment *> *segs, NSUInteger idx,
                           simd_float2 *outStart, simd_float2 *outEnd) {
  if (idx >= segs.count)
    return NO;
  KKTimingSegment *seg = segs[idx];
  if (seg.type != KKSegmentTypeTransition)
    return NO;
  NSArray<NSNumber *> *fromVals = KKTimingBoundaryBefore(idx, segs);
  NSArray<NSNumber *> *toVals = KKTimingBoundaryAfter(idx, segs);
  if (fromVals.count < 2 || toVals.count < 2)
    return NO;
  *outStart = (simd_float2){(float)fromVals[0].doubleValue,
                            (float)fromVals[1].doubleValue};
  *outEnd =
      (simd_float2){(float)toVals[0].doubleValue, (float)toVals[1].doubleValue};
  return YES;
}

/// Convert a bezier point's in/out handle anchors (in path-storage space)
/// to canvas-space CGPoints, applying the display offset.
- (void)_handleCanvasPointsForBezierPoint:(KKBezierPoint)pt
                            displayOffset:(simd_float2)displayOff
                                  inPoint:(CGPoint *)outIn
                                 outPoint:(CGPoint *)outOut {
  *outIn = [self
      canvasPointFromObjectPoint:(simd_float2){pt.x + pt.inX, pt.y + pt.inY} +
                                 displayOff];
  *outOut = [self
      canvasPointFromObjectPoint:(simd_float2){pt.x + pt.outX, pt.y + pt.outY} +
                                 displayOff];
}

- (BOOL)isPositionPathVisibleAtTime:(CMTime)time {
  KKTimingLane *lane = [self positionLaneForSelectedLayer];
  return lane.oscVisible && lane.enabled && lane.segments.count > 0;
}

- (KKBezierPath *)_pathForSegment:(KKTimingSegment *)seg {
  if (seg.pathData.length > 0)
    return [KKBezierPath pathWithData:seg.pathData];
  return [[KKBezierPath alloc] init];
}

- (void)_writePath:(KKBezierPath *)path forSegmentIndex:(NSInteger)segIdx {
  NSString *layerID = [self _selectedSingleLayerID];
  if (!layerID)
    return;
  NSData *data = [path dataRepresentation];
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!setAPI || !getAPI)
    return;
  // Read merge baseline from the per-instance snapshot — KKDataBlob
  // reads from OSC scope return nil even inside an action scope.
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  NSMutableArray<KKTimingLane *> *lanes = [state.lanesSnapshot mutableCopy];
  [actAPI startAction:self];
  if (lanes) {
    for (NSUInteger li = 0; li < lanes.count; li++) {
      KKTimingLane *lane = lanes[li];
      if (![lane.propertyLabel isEqualToString:@"Position"] ||
          ![lane.groupKey isEqualToString:layerID])
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
      // Use KKWriteLanesJSON: writes blob (undoable) + mirror (OSC/render
      // readable) in lockstep, normalizes HTH, and updates lanesSnapshot.
      KKWriteLanesJSON(lanes, setAPI, self.apiManager);
      break;
    }
  }
  [actAPI endAction:self];
}

- (void)drawPositionPathsAtTime:(CMTime)time
               destinationImage:(FxImageTile *)dest {
  if (![self isPositionPathVisibleAtTime:time])
    return;
  KKTimingLane *posLane = [self positionLaneForSelectedLayer];
  if (!posLane)
    return;

  simd_float4 pathColor = (simd_float4){1.0f, 0.2f, 0.2f, 1.0f};
  static const NSUInteger kRes = 24;
  simd_float2 displayOff = [self _positionPathDisplayOffset];

  for (NSUInteger idx = 0; idx < posLane.segments.count; idx++) {
    simd_float2 startObj, endObj;
    if (!_segmentBounds(posLane.segments, idx, &startObj, &endObj))
      continue;
    KKTimingSegment *seg = posLane.segments[idx];
    KKBezierPath *path = [self _pathForSegment:seg];
    NSUInteger segCount = path.segmentCount;

    for (NSUInteger s = 0; s < segCount; s++) {
      CGPoint prev = CGPointZero;
      for (NSUInteger i = 0; i <= kRes; i++) {
        float localT = (float)i / (float)kRes;
        simd_float2 objPt = [path evaluateSegment:s
                                              atT:localT
                                            start:startObj
                                              end:endObj];
        CGPoint cur = [self canvasPointFromObjectPoint:objPt + displayOff];
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
      CGPoint ptCanvas = [self
          canvasPointFromObjectPoint:(simd_float2){pt.x, pt.y} + displayOff];

      if (pt.type == KKBezierPointBezier) {
        CGPoint inC, outC;
        [self _handleCanvasPointsForBezierPoint:pt
                                  displayOffset:displayOff
                                        inPoint:&inC
                                       outPoint:&outC];
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
        [self.positionPathHandleOSC drawAtCanvasPosition:inC
                                               isHovered:NO
                                                isActive:NO
                                        destinationImage:dest
                                                  atTime:time];
        [self.positionPathHandleOSC drawAtCanvasPosition:outC
                                               isHovered:NO
                                                isActive:NO
                                        destinationImage:dest
                                                  atTime:time];
      }

      BOOL active = (self.positionPathDragSegIndex == (NSInteger)idx &&
                     self.positionPathDragPointIndex == (NSInteger)i &&
                     !self.positionPathDragIsInHandle &&
                     !self.positionPathDragIsOutHandle);
      [self.positionPathPointOSC drawAtCanvasPosition:ptCanvas
                                            isHovered:NO
                                             isActive:active
                                     destinationImage:dest
                                               atTime:time];
    }
  }
}

- (NSInteger)hitTestPositionPathAtX:(double)x y:(double)y atTime:(CMTime)time {
  if (![self isPositionPathVisibleAtTime:time])
    return 0;
  KKTimingLane *posLane = [self positionLaneForSelectedLayer];
  if (!posLane)
    return 0;
  CGEventFlags flags =
      CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
  BOOL optHeld = (flags & kCGEventFlagMaskAlternate) != 0;
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  simd_float2 displayOff = [self _positionPathDisplayOffset];

  for (NSUInteger idx = 0; idx < posLane.segments.count; idx++) {
    simd_float2 startObj, endObj;
    if (!_segmentBounds(posLane.segments, idx, &startObj, &endObj))
      continue;
    KKTimingSegment *seg = posLane.segments[idx];
    KKBezierPath *path = [self _pathForSegment:seg];

    // Handles first (smaller, top-most).
    for (NSUInteger i = 0; i < path.count; i++) {
      KKBezierPoint pt = [path pointAtIndex:i];
      if (pt.type != KKBezierPointBezier)
        continue;
      CGPoint inC, outC;
      [self _handleCanvasPointsForBezierPoint:pt
                                displayOffset:displayOff
                                      inPoint:&inC
                                     outPoint:&outC];
      if (hypot(x - inC.x, y - inC.y) < kPositionPathPointHitRadius) {
        [oscAPI setCursor:self.editPointsCursor];
        return kkOSCPositionPathInHandle((NSInteger)idx, i);
      }
      if (hypot(x - outC.x, y - outC.y) < kPositionPathPointHitRadius) {
        [oscAPI setCursor:self.editPointsCursor];
        return kkOSCPositionPathOutHandle((NSInteger)idx, i);
      }
    }

    // Path control points.
    for (NSUInteger i = 0; i < path.count; i++) {
      KKBezierPoint pt = [path pointAtIndex:i];
      CGPoint ptC = [self
          canvasPointFromObjectPoint:(simd_float2){pt.x, pt.y} + displayOff];
      if (hypot(x - ptC.x, y - ptC.y) < kPositionPathPointHitRadius) {
        [oscAPI
            setCursor:optHeld ? self.penDeleteCursor : self.editPointsCursor];
        return kkOSCPositionPathPoint((NSInteger)idx, i);
      }
    }

    // Path curve.
    NSUInteger segCount = path.segmentCount;
    float bestDist = FLT_MAX;
    for (NSUInteger s = 0; s < segCount; s++) {
      CGPoint prev = CGPointZero;
      for (NSUInteger i = 0; i <= kPositionPathHitResolution; i++) {
        float localT = (float)i / (float)kPositionPathHitResolution;
        simd_float2 objPt = [path evaluateSegment:s
                                              atT:localT
                                            start:startObj
                                              end:endObj];
        CGPoint cur = [self canvasPointFromObjectPoint:objPt + displayOff];
        if (i > 0) {
          double dxC = cur.x - prev.x, dyC = cur.y - prev.y;
          double lenSq = dxC * dxC + dyC * dyC;
          double t2 =
              (lenSq > 0)
                  ? MAX(0, MIN(1, ((x - prev.x) * dxC + (y - prev.y) * dyC) /
                                      lenSq))
                  : 0;
          double cx = prev.x + t2 * dxC, cy = prev.y + t2 * dyC;
          float d = (float)hypot(x - cx, y - cy);
          if (d < bestDist)
            bestDist = d;
        }
        prev = cur;
      }
    }
    if (bestDist < kPositionPathHitThreshold) {
      [oscAPI setCursor:optHeld ? self.penAddCursor : [NSCursor arrowCursor]];
      return kkOSCPositionPathCurve((NSInteger)idx);
    }
  }
  return 0;
}

- (BOOL)mouseDownOnPositionPathPart:(NSInteger)part
                          positionX:(double)positionX
                          positionY:(double)positionY
                          modifiers:(NSUInteger)modifiers
                        forceUpdate:(BOOL *)forceUpdate
                             atTime:(CMTime)time {
  if (!kkIsOSCPositionPath(part))
    return NO;
  BOOL optHeld = (modifiers & kFxModifierKey_OPTION) != 0;
  NSInteger segIdx = kkOSCPositionPathSeg(part);
  NSInteger offset = kkOSCPositionPathRole(part);

  KKTimingLane *lane = [self positionLaneForSelectedLayer];
  if (segIdx < 0 || (NSUInteger)segIdx >= lane.segments.count)
    return NO;
  simd_float2 startObj, endObj;
  if (!_segmentBounds(lane.segments, (NSUInteger)segIdx, &startObj, &endObj))
    return NO;
  KKTimingSegment *seg = lane.segments[segIdx];
  KKBezierPath *path = [self _pathForSegment:seg];

  // Path control point.
  if (kkOSCPositionPathRoleIsPoint(offset)) {
    NSUInteger idx = kkOSCPositionPathRolePointIndex(offset);
    if (idx >= path.count)
      return NO;
    if (optHeld) {
      [path removeAtIndex:idx];
      [self _writePath:path forSegmentIndex:segIdx];
      *forceUpdate = YES;
      return YES;
    }
    NSTimeInterval now = CACurrentMediaTime();
    if (self.positionPathLastClickSegIdx == segIdx &&
        self.positionPathLastClickPointIdx == (NSInteger)idx &&
        (now - self.positionPathLastClickTime) < 0.35) {
      [path toggleTypeAtIndex:idx start:startObj end:endObj];
      [self _writePath:path forSegmentIndex:segIdx];
      self.positionPathLastClickSegIdx = -1;
      self.positionPathLastClickPointIdx = -1;
      *forceUpdate = YES;
      return YES;
    }
    self.positionPathLastClickTime = now;
    self.positionPathLastClickSegIdx = segIdx;
    self.positionPathLastClickPointIdx = (NSInteger)idx;
    KKBezierPoint dragPt = [path pointAtIndex:idx];
    // Stored in path-storage space (no display offset).
    self.positionPathDragStartObj = (simd_float2){dragPt.x, dragPt.y};
    self.positionPathDragSegIndex = segIdx;
    self.positionPathDragPointIndex = (NSInteger)idx;
    self.positionPathDragIsInHandle = NO;
    self.positionPathDragIsOutHandle = NO;
    *forceUpdate = YES;
    return YES;
  }

  // In handle.
  if (kkOSCPositionPathRoleIsInHandle(offset)) {
    NSUInteger idx = kkOSCPositionPathRolePointIndex(offset);
    if (idx < path.count) {
      KKBezierPoint pt = [path pointAtIndex:idx];
      self.positionPathDragStartObj =
          (simd_float2){pt.x + pt.inX, pt.y + pt.inY};
    }
    self.positionPathDragSegIndex = segIdx;
    self.positionPathDragPointIndex = (NSInteger)idx;
    self.positionPathDragIsInHandle = YES;
    self.positionPathDragIsOutHandle = NO;
    *forceUpdate = YES;
    return YES;
  }

  // Out handle.
  if (kkOSCPositionPathRoleIsOutHandle(offset)) {
    NSUInteger idx = kkOSCPositionPathRolePointIndex(offset);
    if (idx < path.count) {
      KKBezierPoint pt = [path pointAtIndex:idx];
      self.positionPathDragStartObj =
          (simd_float2){pt.x + pt.outX, pt.y + pt.outY};
    }
    self.positionPathDragSegIndex = segIdx;
    self.positionPathDragPointIndex = (NSInteger)idx;
    self.positionPathDragIsInHandle = NO;
    self.positionPathDragIsOutHandle = YES;
    *forceUpdate = YES;
    return YES;
  }

  // Curve: alt-click inserts a new point at the closest segment.
  if (kkOSCPositionPathRoleIsCurve(offset) && optHeld) {
    simd_float2 mouseObj =
        [self objectPointFromCanvasPoint:(CGPoint){positionX, positionY}];
    mouseObj -= [self _positionPathDisplayOffset];
    NSUInteger bestSeg = 0;
    float bestDist = FLT_MAX;
    for (NSUInteger s = 0; s < path.segmentCount; s++) {
      for (NSUInteger i = 1; i <= kPositionPathHitResolution; i++) {
        float localT = (float)i / (float)kPositionPathHitResolution;
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
    self.positionPathDragSegIndex = segIdx;
    self.positionPathDragPointIndex = (NSInteger)bestSeg;
    self.positionPathDragIsInHandle = NO;
    self.positionPathDragIsOutHandle = NO;
    *forceUpdate = YES;
    return YES;
  }
  return YES;
}

- (BOOL)mouseDraggedOnPositionPathAtX:(double)positionX
                                    y:(double)positionY
                            modifiers:(NSUInteger)modifiers
                               atTime:(CMTime)time {
  if (self.positionPathDragSegIndex < 0 || self.positionPathDragPointIndex < 0)
    return NO;
  KKTimingLane *lane = [self positionLaneForSelectedLayer];
  if ((NSUInteger)self.positionPathDragSegIndex >= lane.segments.count)
    return NO;
  KKTimingSegment *seg = lane.segments[self.positionPathDragSegIndex];
  KKBezierPath *path = [self _pathForSegment:seg];
  if ((NSUInteger)self.positionPathDragPointIndex >= path.count)
    return NO;

  simd_float2 mouseObj =
      [self objectPointFromCanvasPoint:(CGPoint){positionX, positionY}];
  // Convert from on-canvas (display) space back to path-storage space.
  mouseObj -= [self _positionPathDisplayOffset];
  BOOL optHeld = (modifiers & kFxModifierKey_OPTION) != 0;
  BOOL shiftHeld = (modifiers & kFxModifierKey_SHIFT) != 0;

  if (shiftHeld) {
    float dx = fabsf(mouseObj.x - self.positionPathDragStartObj.x);
    float dy = fabsf(mouseObj.y - self.positionPathDragStartObj.y);
    if (dx > dy)
      mouseObj.y = self.positionPathDragStartObj.y;
    else
      mouseObj.x = self.positionPathDragStartObj.x;
  }

  if (self.positionPathDragIsInHandle || self.positionPathDragIsOutHandle) {
    KKBezierPoint pt =
        [path pointAtIndex:(NSUInteger)self.positionPathDragPointIndex];
    simd_float2 offset = {mouseObj.x - pt.x, mouseObj.y - pt.y};
    simd_float2 mirror = {-offset.x, -offset.y};
    if (self.positionPathDragIsInHandle) {
      [path setInHandle:offset
                atIndex:(NSUInteger)self.positionPathDragPointIndex];
      if (!optHeld)
        [path setOutHandle:mirror
                   atIndex:(NSUInteger)self.positionPathDragPointIndex];
    } else {
      [path setOutHandle:offset
                 atIndex:(NSUInteger)self.positionPathDragPointIndex];
      if (!optHeld)
        [path setInHandle:mirror
                  atIndex:(NSUInteger)self.positionPathDragPointIndex];
    }
  } else {
    [path moveAtIndex:(NSUInteger)self.positionPathDragPointIndex to:mouseObj];
  }

  [self _writePath:path forSegmentIndex:self.positionPathDragSegIndex];
  return YES;
}

@end
#pragma clang diagnostic pop
