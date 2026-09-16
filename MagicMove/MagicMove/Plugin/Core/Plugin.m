#import "MMResetParameter.h"
/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MMNativeLinks.h"
#import "Plugin_Private.h"
#import "Constants.h"
#import "MMInspectorHeader.h"
#import "MMDestinations.h"
#import "MMCombinedPose.h"
#import "MMScalePose.h"
#import "MMScalarPose.h"
#import "MMRotationPose.h"
#import <CoreGraphics/CoreGraphics.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wprotocol"

NSNotificationName const MMInspectorPresentationChanged = @"MMInspectorPresentationChanged";

@implementation MMTimingLane
- (void)publishDurationSnapshot:(NSData *)data generation:(NSUInteger)generation {
  @synchronized (self) {
    // An in-flight render must not restore a snapshot invalidated by an edit.
    if (generation == self.durationGeneration) self.durationSnapshot = data;
  }
}

@end

@implementation MagicMovePlugin

- (nullable instancetype)initWithAPIManager:(id<PROAPIAccessing>)newApiManager;
{
  self = [super init];
  if (self) {
    _apiManager = newApiManager;
    MMTimingLane *position = [MMTimingLane new];
    position.valueID = MMPositionX;
    position.durationID = MMTransitionDuration;
    position.dataID = MMDurationData;
    position.availableTimeID = MMPositionAvailableTime;
    position.easingID = MMPositionEasing;
    position.addedMotionID = MMPositionAddedMotion;
    position.linkEditorID = MMPositionLink;
    position.matchEditorID = MMPositionMatch;
    MMTimingLane *scale = [MMTimingLane new];
    scale.valueID = MMScale;
    scale.durationID = MMScaleDuration;
    scale.dataID = MMScaleDurationData;
    scale.availableTimeID = MMScaleAvailableTime;
    scale.easingID = MMScaleEasing;
    scale.addedMotionID = MMScaleAddedMotion;
    scale.linkEditorID = MMScaleLink;
    scale.matchEditorID = MMScaleMatch;
    _timingLanes = @[position, scale];
  }
  return self;
}

- (BOOL)properties:(NSDictionary *_Nonnull *)properties
             error:(NSError *_Nullable *)error {
  *properties = @{
    kFxPropertyKey_MayRemapTime : @NO,
    kFxPropertyKey_PixelTransformSupport : @(kFxPixelTransform_ScaleTranslate),
    kFxPropertyKey_VariesWhenParamsAreStatic : @YES
  };

  return YES;
}

// Shared with the on-screen control: the host decodes secure-coded custom
// values through whichever object it is calling back, so both must agree.
NSSet<Class> *MMClassesForCustomParameter(UInt32 parameterID) {
  if (parameterID == MMHostRefreshToken) return [NSSet setWithObject:NSString.class];
  if (parameterID == MMTimingControls || parameterID == MMHeaderControls) return [NSSet setWithObject:NSNumber.class];
  MMPropertyLane *lane=MMPropertyLaneForParameter(parameterID);
  if(lane) return [NSSet setWithObject:[(NSObject *)lane.defaultPose class]];
  if (parameterID == MMScaleControls) return [NSSet setWithObject:MMScalePose.class];
  if (parameterID == MMCustomControls) return [NSSet setWithObjects:MMCombinedPose.class, NSNumber.class, nil];
  if (parameterID == MMDurationData || parameterID == MMScaleDurationData) return [NSSet setWithObject:KKDataBlob.class];
  return [NSSet set];
}
- (NSSet<Class> *)classesForCustomParameterID:(UInt32)parameterID {
  return MMClassesForCustomParameter(parameterID);
}

- (BOOL)destinationImageRect:(FxRect *)rect sourceImages:(NSArray<FxImageTile *> *)sources
           destinationImage:(FxImageTile *)destination pluginState:(NSData *)state
                     atTime:(CMTime)time error:(NSError **)error {
  if (!rect || sources.count == 0) {
    if (error) *error = [NSError errorWithDomain:FxPlugErrorDomain code:1
        userInfo:@{NSLocalizedDescriptionKey:@"Missing source image bounds."}];
    return NO;
  }
  *rect = sources.firstObject.imagePixelBounds;
  return YES;
}

- (void)pluginInstanceAddedToDocument {

  // Parameter creation also happens for detached library/drag instances.
  // A timer action there makes Motion request timing for a nonexistent input.
  // FxPlug guarantees host API readiness only after document attachment.
  [self startDurationRefresh];
}

- (void)dealloc {
  [_durationTimer invalidate];
}

- (void)startDurationRefresh {
  __weak MagicMovePlugin *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    MagicMovePlugin *plugin = weakSelf;
    if (!plugin || plugin.durationTimer) return;
    // Native FxPlug sliders have no view callback for playhead movement.
    // Refresh the transient editor on the main run loop, never from rendering.
    plugin.durationTimer = [NSTimer timerWithTimeInterval:(1.0/30.0) repeats:YES block:^(NSTimer *timer) {
      MagicMovePlugin *p = weakSelf;
      if (!p) { [timer invalidate]; return; }
      if (p.syncingDuration || p.activeNativeCallbacks) return;
      // Scrubbing may refresh cached inspector state while held. A native
      // linked-key drag still avoids host actions until release.
      BOOL mouseDown = CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft);
      if (mouseDown && (p.hasPendingNativeEdits || MMHasPendingNativeLinkMoves(p.apiManager))) return;
      id<FxCustomParameterActionAPI_v4> action =
          [p.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
      if (!action) return;

      [action startAction:p];

      @try {
        NSError *error = nil;
        CMTime time = [action currentTime];
        if (![p updateTimingEditorsAtTime:time mouseDown:mouseDown error:&error])
          NSLog(@"Magic Move deferred linked edit failed: %@", error);
      }
      @finally {

        [action endAction:p];

      }
    }];
    [[NSRunLoop mainRunLoop] addTimer:plugin.durationTimer forMode:NSRunLoopCommonModes];
  });
}

- (BOOL)updateTimingEditorsAtTime:(CMTime)time mouseDown:(BOOL)mouseDown error:(NSError **)error {
  if (self.syncingDuration || self.activeNativeCallbacks) return YES;
  if (!MMCommitNativeLinkMoves(self.apiManager,mouseDown,error)) return NO;
  if (![self commitPendingEditsWithMouseDown:mouseDown atTime:time error:error]) return NO;
  [self refreshDurationAtTime:time allowNativeReads:!mouseDown];
  return YES;
}

- (void)refreshDurationAtTime:(CMTime)time {
  [self refreshDurationAtTime:time allowNativeReads:YES];
}

- (void)refreshDurationAtTime:(CMTime)time allowNativeReads:(BOOL)allowNativeReads {
  if (self.syncingDuration || self.hasPendingNativeEdits) return;
  [self refreshCombinedEasingAtTime:time];
  [self refreshCombinedAddedMotionAtTime:time];
  for (MMTimingLane *lane in self.timingLanes) {
    [self refreshDurationForLane:lane atTime:time allowNativeReads:allowNativeReads];
  }
}

- (void)refreshCombinedEasingAtTime:(CMTime)time {
  int easing = 0;
  BOOL enabled = MMCombinedIncomingEasing(self.apiManager, time, &easing, NULL);
  BOOL flagsChanged = !self.combinedEasingEnabled || self.combinedEasingEnabled.boolValue != enabled;
  BOOL valueChanged = !self.publishedCombinedEasing || self.publishedCombinedEasing.intValue != easing;
  if (!flagsChanged && !valueChanged) return;
  id<FxParameterSettingAPI_v5> set = [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  self.syncingDuration = YES;
  @try {
    if (flagsChanged && [set setParameterFlags:(kFxParameterFlag_HIDDEN | kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_DONT_SAVE |
                                                (enabled ? 0 : kFxParameterFlag_DISABLED)) toParameter:MMCombinedEasing])
      self.combinedEasingEnabled = @(enabled);
    if (valueChanged && [set setIntValue:easing toParameter:MMCombinedEasing atTime:time])
      self.publishedCombinedEasing = @(easing);
  } @finally { self.syncingDuration = NO; }
}

- (void)refreshCombinedAddedMotionAtTime:(CMTime)time {
  int motion = 0;
  BOOL enabled = MMCombinedOutgoingMotion(self.apiManager, time, &motion, NULL);
  BOOL flagsChanged = !self.combinedAddedMotionEnabled || self.combinedAddedMotionEnabled.boolValue != enabled;
  BOOL valueChanged = !self.publishedCombinedAddedMotion || self.publishedCombinedAddedMotion.intValue != motion;
  if (!flagsChanged && !valueChanged) return;
  id<FxParameterSettingAPI_v5> set = [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  self.syncingDuration = YES;
  @try {
    if (flagsChanged && [set setParameterFlags:(kFxParameterFlag_HIDDEN | kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_DONT_SAVE |
                                                (enabled ? 0 : kFxParameterFlag_DISABLED)) toParameter:MMCombinedAddedMotion])
      self.combinedAddedMotionEnabled = @(enabled);
    if (valueChanged && [set setIntValue:motion toParameter:MMCombinedAddedMotion atTime:time])
      self.publishedCombinedAddedMotion = @(motion);
  } @finally { self.syncingDuration = NO; }
}

- (void)refreshDurationForLane:(MMTimingLane *)lane atTime:(CMTime)time allowNativeReads:(BOOL)allowNativeReads {
  NSData *data = lane.durationSnapshot;
  if (!data && allowNativeReads) {
    NSUInteger generation = lane.durationGeneration;
    data = MMReadDestinations(self.apiManager, lane.valueID, lane.dataID, nil);
    if (data) [lane publishDurationSnapshot:data generation:generation];
  }
  NSInteger poseIndex = data ? MMKeyposeAtTime(data, time) : NSNotFound;
  BOOL linkEnabled = poseIndex != NSNotFound;
  NSUInteger poseCount = data.length/sizeof(MTDurationRecord);
  BOOL matchEnabled = linkEnabled && (poseIndex == 0 || poseIndex == (NSInteger)poseCount-1);
  BOOL matched = poseCount && ((const MTDurationRecord *)data.bytes)[0].matchEndpoints;
  BOOL matchValue = matchEnabled && matched;
  BOOL matchFlagsChanged = !lane.durationEditorKnown || lane.matchEnabled != matchEnabled;
  BOOL matchValueChanged = !lane.publishedMatch || lane.publishedMatch.boolValue != matchValue;
  BOOL linked = linkEnabled && ((const MTDurationRecord *)data.bytes)[poseIndex].linkID != 0;
  BOOL linkFlagsChanged = !lane.durationEditorKnown || lane.linkEditorEnabled != linkEnabled;
  BOOL linkValueChanged = !lane.durationEditorKnown || lane.linkEditorValue != linked;
  NSInteger index = data ? MMDestinationAtTime(data, time) : NSNotFound;
  BOOL enabled = index != NSNotFound;
  double value = enabled ? ((const MTDurationRecord *)data.bytes)[index].duration : 0;
  int easing = enabled ? ((const MTDurationRecord *)data.bytes)[index].easing : MTEasingSmooth;
  BOOL easingChanged = !lane.publishedEasing || lane.publishedEasing.intValue != easing;
  NSInteger origin = data ? MMOriginAtTime(data, time) : NSNotFound;
  BOOL motionEnabled = origin != NSNotFound;
  int motion = motionEnabled ? ((const MTDurationRecord *)data.bytes)[origin].addedMotion : MTAddedMotionNone;
  BOOL motionFlagsChanged = !lane.addedMotionEnabled || lane.addedMotionEnabled.boolValue != motionEnabled;
  BOOL motionChanged = !lane.publishedAddedMotion || lane.publishedAddedMotion.intValue != motion;
  BOOL available = enabled && ((const MTDurationRecord *)data.bytes)[index].useAvailableTime;
  BOOL modeChanged = !lane.durationEditorKnown || lane.editorAvailableTime != available;
  BOOL flagsChanged = !lane.durationEditorKnown || lane.durationEditorEnabled != enabled;
  BOOL valueChanged = enabled && (!lane.durationEditorKnown ||
                                 !lane.durationEditorEnabled || lane.durationEditorValue != value);
  if (!flagsChanged && !valueChanged && !modeChanged && !linkFlagsChanged && !linkValueChanged &&
      !matchFlagsChanged && !matchValueChanged && !easingChanged && !motionChanged && !motionFlagsChanged) return;

  id<FxParameterSettingAPI_v5> set = [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  FxParameterFlags flags = kFxParameterFlag_HIDDEN | kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_DONT_SAVE |
                           (enabled ? 0 : kFxParameterFlag_DISABLED);
  self.syncingDuration = YES;
  @try {
    BOOL ok = YES;
    if (motionFlagsChanged) {
      BOOL written = [set setParameterFlags:(kFxParameterFlag_HIDDEN | kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_DONT_SAVE |
                       (motionEnabled ? 0 : kFxParameterFlag_DISABLED)) toParameter:lane.addedMotionID];
      if (written) lane.addedMotionEnabled = @(motionEnabled);
      ok = written && ok;
    }
    if (motionChanged) {
      BOOL written = [set setIntValue:motion toParameter:lane.addedMotionID atTime:time];
      if (written) lane.publishedAddedMotion = @(motion);
      ok = written && ok;
    }
    if (flagsChanged) ok = [set setParameterFlags:flags toParameter:lane.easingID] && ok;
    if (easingChanged) {
      BOOL written = [set setIntValue:easing toParameter:lane.easingID atTime:time];
      if (written) lane.publishedEasing = @(easing);
      ok = written && ok;
    }
    if (matchFlagsChanged) {
      FxParameterFlags base = kFxParameterFlag_HIDDEN | kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_DONT_SAVE;
      ok = [set setParameterFlags:base | (matchEnabled ? 0 : kFxParameterFlag_DISABLED) toParameter:lane.matchEditorID] && ok;
    }
    if (matchValueChanged) {
      BOOL written = [set setBoolValue:matchValue toParameter:lane.matchEditorID atTime:time];
      if (written) lane.publishedMatch = @(matchValue);
      ok = written && ok;
    }
    if (linkFlagsChanged)
      ok = [set setParameterFlags:(kFxParameterFlag_HIDDEN | kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_DONT_SAVE |
                                  (linkEnabled ? 0 : kFxParameterFlag_DISABLED)) toParameter:lane.linkEditorID];
    if (linkValueChanged) {
      BOOL written = [set setBoolValue:linked toParameter:lane.linkEditorID atTime:time];
      if (written) lane.publishedLinkValue = @(linked);
      ok = written && ok;
    }
    if (flagsChanged) ok = [set setParameterFlags:flags toParameter:lane.availableTimeID] && ok;
    if (flagsChanged || modeChanged)
      ok = [set setParameterFlags:(flags | (available ? kFxParameterFlag_DISABLED : 0))
                     toParameter:lane.durationID] && ok;
    if (modeChanged) {
      BOOL written = [set setBoolValue:available toParameter:lane.availableTimeID atTime:time];
      if (written) lane.publishedAvailableValue = @(available);
      ok = written && ok;
    }
    if (valueChanged) {
      BOOL written = [set setFloatValue:value toParameter:lane.durationID atTime:time];
      if (written) lane.publishedDurationValue = @(value);
      ok = written && ok;
    }

    lane.durationEditorKnown = ok;
    if (ok) {
      lane.matchEnabled = matchEnabled;
      lane.linkEditorEnabled = linkEnabled;
      lane.linkEditorValue = linked;
      lane.durationEditorEnabled = enabled;
      lane.editorAvailableTime = available;
      lane.durationEditorValue = value;
    }
  } @finally { self.syncingDuration = NO; }
}

- (BOOL)commitPendingEditsWithMouseDown:(BOOL)mouseDown atTime:(CMTime)time error:(NSError **)error {
  @synchronized (self) {
    if (!self.hasPendingNativeEdits || mouseDown || self.syncingDuration || self.activeNativeCallbacks) return YES;
    self.syncingDuration = YES;
  }

  id<FxUndoAPI> undo = [self.apiManager apiForProtocol:@protocol(FxUndoAPI)];
  BOOL grouped = undo && [undo startUndoGroup:@"Move linked keyposes"];

  self.syncingDuration = YES;
  BOOL ok = YES;
  @try {
    MMLinkEdit *edit = self.pendingLinkEdit;

    ok = edit && [self applyLinkedEdit:edit error:error];
    // Include transient inspector writes in the same group as native keys and
    // saved associations. They can create undo entries even with DONT_SAVE.
    self.hasPendingNativeEdits = NO;
    self.syncingDuration = NO;
    [self refreshDurationAtTime:time];
  } @finally {
    // Never spin on a failed host edit. Existing rollback leaves it undoable.
    for (MMTimingLane *lane in self.timingLanes) lane.pendingDestinations = nil;
    self.hasPendingNativeEdits = NO;
    self.pendingLinkEdit = nil;
    self.syncingDuration = NO;
    if (grouped) {

      [undo endUndoGroup];

    }
  }
  return ok;
}

- (BOOL)parameterChanged:(UInt32)parameterID atTime:(CMTime)time error:(NSError **)error {
  if (parameterID == MMMotionBlur || parameterID == MMExplicitCreation || parameterID == MMMotionBlurSamples || parameterID == MMMotionBlurShutterAngle) {
    [NSNotificationCenter.defaultCenter postNotificationName:MMHeaderSettingsChanged object:self.apiManager];
    MMPropertyMenuParametersChanged(self.apiManager);
  }
  if (parameterID == MMHostRefreshToken) return YES; // Host invalidation only.
  // FxPlug callbacks can overlap the timer on another thread. Never release a
  // prepared plan while a native callback is still updating its snapshots.
  for(MMPropertyLane *lane in MMPropertyLanes()) {
    if(parameterID!=lane.parameterID && parameterID!=lane.cacheTokenID) continue;
    MMPrimeDefaultKeyTracker(self.apiManager,lane.parameterID);
    [lane refreshCacheForManager:self.apiManager time:time];
    MMObserveNativeLinks(self.apiManager,lane.parameterID,CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState,kCGMouseButtonLeft));
    MMPropertyMenuParametersChanged(self.apiManager);
    return YES;
  }
  if (parameterID == MMScaleControls || parameterID == MMScaleCacheToken) {
    MMPrimeDefaultKeyTracker(self.apiManager,MMScaleControls);
    MMRefreshScalePoseCache(self.apiManager, time);
    MMObserveNativeLinks(self.apiManager,MMScaleControls,CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState,kCGMouseButtonLeft));
    MMPropertyMenuParametersChanged(self.apiManager);
    return YES;
  }
  if (parameterID == MMCustomControls || parameterID == MMCombinedCacheToken) {
    MMPrimeDefaultKeyTracker(self.apiManager,MMCustomControls);
    MMRefreshCombinedPoseCache(self.apiManager, time);
    MMObserveNativeLinks(self.apiManager,MMCustomControls,CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState,kCGMouseButtonLeft));
    MMPropertyMenuParametersChanged(self.apiManager);
    return YES;
  }
  BOOL native = NO;
  for (MMTimingLane *lane in self.timingLanes) if (lane.valueID == parameterID) native = YES;
  if (!native) return [self handleParameterChanged:parameterID atTime:time error:error];
  @synchronized (self) {
    if (self.syncingDuration) return YES;
    self.activeNativeCallbacks += 1;
  }
  @try { return [self handleParameterChanged:parameterID atTime:time error:error]; }
  @finally { @synchronized (self) { self.activeNativeCallbacks -= 1; } }
}

- (BOOL)handleParameterChanged:(UInt32)parameterID atTime:(CMTime)time error:(NSError **)error {

  if (self.syncingDuration) return YES;
  if (parameterID == MMCombinedEasing) {
    id<FxParameterRetrievalAPI_v6> get = [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    int easing = 0, oldEasing = 0;
    CMTime targetTime = kCMTimeInvalid;
    if (![get getIntValue:&easing fromParameter:parameterID atTime:time]) return NO;
    if (self.publishedCombinedEasing && self.publishedCombinedEasing.intValue == easing) return YES;
    if (!MMCombinedIncomingEasing(self.apiManager, time, &oldEasing, &targetTime)) { [self refreshCombinedEasingAtTime:time]; return YES; }
    if (easing < MTEasingSmooth || easing > MTEasingEaseOut) return NO;
    MMCombinedPose *old = MMReadCombinedValue(self.apiManager, targetTime);
    if (!old) return NO;
    MMCombinedPose *updated = [[MMCombinedPose alloc] initWithPositionX:old.positionX positionY:old.positionY scale:old.scale authored:YES easing:(MTEasing)easing addedMotion:old.addedMotion];
    id<FxParameterSettingAPI_v5> set = [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    updated=[updated poseByReplacingTiming:old.timing];
    BOOL ok = [set setCustomParameterValue:updated toParameter:MMCustomControls atTime:targetTime];
    if (ok) self.publishedCombinedEasing = @(easing);
    return ok;
  }
  if (parameterID == MMCombinedAddedMotion) {
    id<FxParameterRetrievalAPI_v6> get = [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    int motion = 0, oldMotion = 0;
    CMTime targetTime = kCMTimeInvalid;
    if (![get getIntValue:&motion fromParameter:parameterID atTime:time]) return NO;
    if (self.publishedCombinedAddedMotion && self.publishedCombinedAddedMotion.intValue == motion) return YES;
    if (!MMCombinedOutgoingMotion(self.apiManager, time, &oldMotion, &targetTime)) { [self refreshCombinedAddedMotionAtTime:time]; return YES; }
    if (motion < MTAddedMotionNone || motion > MTAddedMotionHandheld) return NO;
    MMCombinedPose *old = MMReadCombinedValue(self.apiManager, targetTime);
    if (!old) return NO;
    MMCombinedPose *updated = [[MMCombinedPose alloc] initWithPositionX:old.positionX positionY:old.positionY scale:old.scale authored:YES easing:old.easing addedMotion:(MTAddedMotion)motion];
    id<FxParameterSettingAPI_v5> set = [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    updated=[updated poseByReplacingTiming:old.timing];
    BOOL ok = [set setCustomParameterValue:updated toParameter:MMCustomControls atTime:targetTime];
    if (ok) self.publishedCombinedAddedMotion = @(motion);
    return ok;
  }
  MMTimingLane *lane = nil;
  for (MMTimingLane *candidate in self.timingLanes) {
    if (parameterID == candidate.valueID || parameterID == candidate.durationID ||
        parameterID == candidate.dataID || parameterID == candidate.availableTimeID || parameterID == candidate.easingID || parameterID == candidate.addedMotionID ||
        parameterID == candidate.linkEditorID || parameterID == candidate.matchEditorID) { lane = candidate; break; }
  }
  if (!lane) return YES;
  // FxPlug may deliver our inspector write notifications after syncingDuration
  // has cleared, even after the playhead leaves the pose. They must not start
  // another refresh cycle or turn an unchecked display into an unlink command.
  id<FxParameterRetrievalAPI_v6> get = [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (parameterID == lane.easingID && lane.publishedEasing) {
    int easing;
    if ([get getIntValue:&easing fromParameter:parameterID atTime:time] && easing == lane.publishedEasing.intValue) return YES;
  }
  if (parameterID == lane.addedMotionID && lane.publishedAddedMotion) {
    int motion;
    if ([get getIntValue:&motion fromParameter:parameterID atTime:time] && motion == lane.publishedAddedMotion.intValue) return YES;
  }
  if (parameterID == lane.durationID && lane.publishedDurationValue) {
    double value;
    if ([get getFloatValue:&value fromParameter:parameterID atTime:time] &&
        value == lane.publishedDurationValue.doubleValue) {

      return YES;
    }
  } else if (parameterID == lane.matchEditorID) {
    NSNumber *published = lane.publishedMatch;
    BOOL value;
    if (published && [get getBoolValue:&value fromParameter:parameterID atTime:time] && value == published.boolValue) return YES;
  } else if (parameterID == lane.linkEditorID || parameterID == lane.availableTimeID) {
    NSNumber *published = parameterID == lane.linkEditorID ? lane.publishedLinkValue : lane.publishedAvailableValue;
    BOOL value;
    if (published && [get getBoolValue:&value fromParameter:parameterID atTime:time] &&
        value == published.boolValue) {

      return YES;
    }
  }
  if (parameterID == lane.dataID) {
    NSData *saved = MMReadSavedDestinations(self.apiManager, lane.dataID, error);
    if (!saved) return NO;
    if (MMDestinationsEqual(saved, lane.publishedDestinations)) {

      return YES;
    }
    lane.publishedDestinations = saved;
    // Restored host metadata (including undo) supersedes uncommitted edits.
    for (MMTimingLane *other in self.timingLanes) other.pendingDestinations = nil;
    self.hasPendingNativeEdits = NO;
    self.pendingLinkEdit = nil;
  } else if (parameterID != lane.valueID && self.hasPendingNativeEdits) {
    // An explicit timing/link command operates on the completed native edit.
    if (![self commitPendingEditsWithMouseDown:NO atTime:time error:error]) return NO;
  }
  NSUInteger generation;
  @synchronized (lane) {
    generation = lane.durationGeneration + 1;
    lane.durationGeneration = generation;
    lane.durationSnapshot = nil;
  }
  NSData *previous = lane.pendingDestinations;
  NSMutableData *data = [(previous ? MMReadDestinationsFromPrevious(self.apiManager, lane.valueID, previous, error)
                                  : MMReadDestinations(self.apiManager, lane.valueID, lane.dataID, error)) mutableCopy];

  if (!data) return NO;
  if (parameterID == lane.valueID) {
    if (!lane.pendingDestinations && MMDestinationsEqual(data, lane.publishedDestinations)) {
      [lane publishDurationSnapshot:data generation:generation];

      return YES;
    }
    // Rebuild from both current lanes in the native callback. The latest edit
    // becomes the source; its plan includes the partner's current state too.
    MMLinkEdit *edit = [self prepareLinkedLane:lane parameterID:parameterID data:data atTime:time error:error];
    if (!edit) {
      self.pendingLinkEdit = nil;
      self.hasPendingNativeEdits = NO;
      for (MMTimingLane *other in self.timingLanes) other.pendingDestinations = nil;
      return NO;
    }
    self.pendingLinkEdit = edit;
    lane.pendingDestinations = data;
    lane.pendingTime = time;
    self.hasPendingNativeEdits = YES;
    [lane publishDurationSnapshot:data generation:generation];

    return YES;
  }
  if (parameterID == lane.durationID || parameterID == lane.availableTimeID || parameterID == lane.easingID || parameterID == lane.addedMotionID) {
    NSInteger index = parameterID == lane.addedMotionID ? MMOriginAtTime(data, time) : MMDestinationAtTime(data, time);
    if (index == NSNotFound) { [self refreshDurationAtTime:time]; return YES; }
    id<FxParameterRetrievalAPI_v6> get = [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    NSMutableData *edited = [data mutableCopy];
    MTDurationRecord *record = &((MTDurationRecord *)edited.mutableBytes)[index];
    if (parameterID == lane.addedMotionID) {
      int motion;
      if (![get getIntValue:&motion fromParameter:lane.addedMotionID atTime:time] || motion < MTAddedMotionNone || motion > MTAddedMotionHandheld) return NO;
      record->addedMotion = (MTAddedMotion)motion;
    } else if (parameterID == lane.easingID) {
      int easing;
      if (![get getIntValue:&easing fromParameter:lane.easingID atTime:time] || easing < MTEasingSmooth || easing > MTEasingEaseOut) return NO;
      record->easing = (MTEasing)easing;
    } else if (parameterID == lane.availableTimeID) {
      BOOL available = NO;
      if (![get getBoolValue:&available fromParameter:lane.availableTimeID atTime:time]) return NO;
      record->useAvailableTime = available;
    } else {
      // Ignore a stale Duration edit while the incoming gap is automatic.
      if (!record->useAvailableTime &&
          ![get getFloatValue:&record->duration fromParameter:lane.durationID atTime:time]) return NO;
    }
    data = edited;
  }
  BOOL matchEdit = parameterID == lane.matchEditorID;
  id<FxUndoAPI> undo = matchEdit ? [self.apiManager apiForProtocol:@protocol(FxUndoAPI)] : nil;
  BOOL grouped = undo && [undo startUndoGroup:@"Match In/Out"];
  @try {
    // Value edits capture new associations in the same host action. Loading
    // or undoing the blob only refreshes the editor; never overwrite undo state.
    if (parameterID != lane.dataID) {
      self.syncingDuration = YES;
      BOOL ok;
      @try {
        ok = [self syncLinkedLane:lane parameterID:parameterID data:data atTime:time error:error];
      }
      @finally { self.syncingDuration = NO; }

      if (!ok) return NO;
    }
    [lane publishDurationSnapshot:data generation:generation];
    [self refreshDurationAtTime:time];

    return YES;
  } @finally { if (grouped) [undo endUndoGroup]; }

}

@end
#pragma clang diagnostic pop
