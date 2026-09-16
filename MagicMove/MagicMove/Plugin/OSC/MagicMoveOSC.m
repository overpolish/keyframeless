/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MagicMoveOSC.h"
#import "Constants.h"
#import "Plugin.h"
#import "MMAnchorPose.h"
#import "MMCombinedPose.h"
#import "MMInspectorColors.h"
#import "MMPropertyLane.h"
#import "MMRotationPose.h"
#import "MMScalePose.h"

// Reads the rendered footprint the control draws and drags: the combined
// pose (with the scalar-lane legacy fallback), the scale override, then the
// rotation and anchor lanes.
@implementation MagicMoveOSC {
  BOOL _hasLastPose;
  OSCBoxPose _lastPose;
  MMCombinedPoseCache *_combinedCache;
  MMScalePoseCache *_scaleCache;
  MMPropertyPoseCache *_rotationCache;
  MMPropertyPoseCache *_anchorCache;
}

- (BOOL)boxPoseAtTime:(CMTime)time pose:(OSCBoxPose *)pose {
  id<FxParameterRetrievalAPI_v6> get = [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!get || !CMTIME_IS_NUMERIC(time)) return NO;
  OSCBoxPose result = {0, 0, 100, 100, 0, 0, 0};
  // Hover and exit callbacks arrive without the keyframe API; reading there
  // fails and would disturb the shared caches, so keep the last footprint.
  if (![self.apiManager apiForProtocol:@protocol(FxKeyframeAPI_v3)]) {
    if (_hasLastPose) { *pose = _lastPose; return YES; }
    return NO;
  }
  BOOL combinedActive = NO;
  NSError *error = nil;
  MMCombinedPose *combined = MMReadCombinedPose(self.apiManager, time, &combinedActive, &error);
  if (!combined) {
    // A transient host gap (keyframe API absent in some callbacks) keeps the
    // last footprint.
    if (_hasLastPose) { *pose = _lastPose; return YES; }
    return NO;
  }
  if (combinedActive) {
    result.positionX = combined.positionX;
    result.positionY = combined.positionY;
    result.scaleX = result.scaleY = combined.scale;
  } else {
    // Older effects without a combined key still drive the scalar lanes.
    double value = 0;
    if ([get getFloatValue:&value fromParameter:MMPositionX atTime:time]) result.positionX = value;
    if ([get getFloatValue:&value fromParameter:MMScale atTime:time]) result.scaleX = result.scaleY = value;
  }
  BOOL scaleActive = NO;
  MMScalePose *scale = MMReadScalePose(self.apiManager, time, &scaleActive, &error);
  if (!scale) return NO;
  if (scaleActive) { result.scaleX = scale.x; result.scaleY = scale.y; }
  NSArray<NSValue *> *times = @[[NSValue valueWithBytes:&time objCType:@encode(CMTime)]];
  NSArray<NSNumber *> *angles = [MMRotationLane() readSamples:self.apiManager times:times error:nil].firstObject.values;
  if (angles.count > 2) {
    result.rotation = angles[2].doubleValue;
    result.rotationX = angles[0].doubleValue;
    result.rotationY = angles[1].doubleValue;
  }
  NSArray<NSNumber *> *anchor = [MMAnchorLane() readSamples:self.apiManager times:times error:nil].firstObject.values;
  if (anchor.count > 1) { result.anchorX = anchor[0].doubleValue; result.anchorY = anchor[1].doubleValue; }
  *pose = result;
  _lastPose = result;
  _hasLastPose = YES;
  return YES;
}

- (UInt32)visibilityParameterForElement:(OSCViewerElement)element {
  switch (element) {
  case OSCViewerElementHandles: return MMShowScaleOSC;
  case OSCViewerElementRings: return MMShowRotationOSC;
  case OSCViewerElementAnchor: return MMShowAnchorOSC;
  default: return MMShowPositionOSC;
  }
}

- (NSArray<NSColor *> *)ringColors {
  return MMInspectorColors(MMRotationControls);
}

// The host decodes custom values through the object it calls back, so the
// control must expose the same classes as the effect.
- (NSSet<Class> *)classesForCustomParameterID:(UInt32)parameterID {
  return MMClassesForCustomParameter(parameterID);
}

- (void)beginDragOfKind:(OSCViewerElement)kind atTime:(CMTime)time {
  switch (kind) {
  case OSCViewerElementRings:
    _rotationCache = MMPropertyEditingCache(MMRotationLane(), self.apiManager, time);
    break;
  case OSCViewerElementAnchor:
    _anchorCache = MMPropertyEditingCache(MMAnchorLane(), self.apiManager, time);
    break;
  default:
    _combinedCache = MMCombinedEditingCache(self.apiManager, time);
    _scaleCache = MMScaleEditingCache(self.apiManager, time);
    break;
  }
}

- (void)endDrag {
  _combinedCache = nil;
  _scaleCache = nil;
  _rotationCache = nil;
  _anchorCache = nil;
}

- (BOOL)writePose:(OSCBoxPose)pose kind:(OSCViewerElement)kind modifiers:(FxModifierKeys)modifiers atTime:(CMTime)time {
  switch (kind) {
  case OSCViewerElementPosition:
    return MMWriteCombinedValues(self.apiManager, _combinedCache,
                                 @(MAX(-200, MIN(200, pose.positionX))), @(MAX(-200, MIN(200, pose.positionY))), nil,
                                 time);
  case OSCViewerElementHandles:
    return MMWriteScaleValues(self.apiManager, _scaleCache, pose.scaleX, pose.scaleY, time);
  case OSCViewerElementRings: {
    BOOL explicit = NO;
    id<FxParameterRetrievalAPI_v6> get = [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    if (![get getBoolValue:&explicit fromParameter:MMExplicitCreation atTime:time]) return NO;
    return [MMRotationLane() writeValues:@[@(pose.rotationX), @(pose.rotationY), @(pose.rotation)]
                                 manager:self.apiManager cache:_rotationCache time:time explicit:explicit];
  }
  case OSCViewerElementAnchor: {
    BOOL explicit = NO;
    id<FxParameterRetrievalAPI_v6> get = [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    if (![get getBoolValue:&explicit fromParameter:MMExplicitCreation atTime:time]) return NO;
    return [MMAnchorLane() writeValues:@[@(pose.anchorX), @(pose.anchorY)]
                               manager:self.apiManager cache:_anchorCache time:time explicit:explicit];
  }
  }
}

@end
