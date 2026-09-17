/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MagicMoveOSC.h"
#import "Constants.h"
#import "Plugin.h"
#import "MMLanes.h"

// Reads the rendered footprint the control draws and drags: the position,
// scale, rotation and anchor lanes.
@implementation MagicMoveOSC {
  BOOL _hasLastPose;
  OSCBoxPose _lastPose;
  KFPropertyPoseCache *_positionCache;
  KFPropertyPoseCache *_scaleCache;
  KFPropertyPoseCache *_rotationCache;
  KFPropertyPoseCache *_anchorCache;
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
  NSArray<NSValue *> *times = @[[NSValue valueWithBytes:&time objCType:@encode(CMTime)]];
  NSArray<NSNumber *> *position = [MMPositionLane() readSamples:self.apiManager times:times error:nil].firstObject.values;
  NSArray<NSNumber *> *scale = [MMScaleLane() readSamples:self.apiManager times:times error:nil].firstObject.values;
  if (!position || !scale) {
    // A transient host gap (keyframe API absent in some callbacks) keeps the
    // last footprint.
    if (_hasLastPose) { *pose = _lastPose; return YES; }
    return NO;
  }
  result.positionX = position[0].doubleValue;
  result.positionY = position[1].doubleValue;
  result.scaleX = scale[0].doubleValue;
  result.scaleY = scale[1].doubleValue;
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
  return MMRotationLane().componentColors;
}

// The host decodes custom values through the object it calls back, so the
// control must expose the same classes as the effect.
- (NSSet<Class> *)classesForCustomParameterID:(UInt32)parameterID {
  return MMClassesForCustomParameter(parameterID);
}

- (void)beginDragOfKind:(OSCViewerElement)kind atTime:(CMTime)time {
  switch (kind) {
  case OSCViewerElementRings:
    _rotationCache = KFPropertyEditingCache(MMRotationLane(), self.apiManager, time);
    break;
  case OSCViewerElementAnchor:
    _anchorCache = KFPropertyEditingCache(MMAnchorLane(), self.apiManager, time);
    break;
  default:
    _positionCache = KFPropertyEditingCache(MMPositionLane(), self.apiManager, time);
    _scaleCache = KFPropertyEditingCache(MMScaleLane(), self.apiManager, time);
    break;
  }
}

- (void)endDrag {
  _positionCache = nil;
  _scaleCache = nil;
  _rotationCache = nil;
  _anchorCache = nil;
}
- (BOOL)writePose:(OSCBoxPose)pose kind:(OSCViewerElement)kind modifiers:(FxModifierKeys)modifiers atTime:(CMTime)time {
  BOOL explicit = NO;
  id<FxParameterRetrievalAPI_v6> get = [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (![get getBoolValue:&explicit fromParameter:MMExplicitCreation atTime:time]) return NO;
  switch (kind) {
  case OSCViewerElementPosition:
    return [MMPositionLane() writeValues:@[@(MAX(-200, MIN(200, pose.positionX))), @(MAX(-200, MIN(200, pose.positionY)))]
                                manager:self.apiManager cache:_positionCache time:time explicit:explicit];
  case OSCViewerElementHandles:
    return [MMScaleLane() writeValues:@[@(pose.scaleX), @(pose.scaleY)]
                              manager:self.apiManager cache:_scaleCache time:time explicit:explicit];
  case OSCViewerElementRings:
    return [MMRotationLane() writeValues:@[@(pose.rotationX), @(pose.rotationY), @(pose.rotation)]
                                 manager:self.apiManager cache:_rotationCache time:time explicit:explicit];
  case OSCViewerElementAnchor:
    return [MMAnchorLane() writeValues:@[@(pose.anchorX), @(pose.anchorY)]
                               manager:self.apiManager cache:_anchorCache time:time explicit:explicit];
  }
}

@end
