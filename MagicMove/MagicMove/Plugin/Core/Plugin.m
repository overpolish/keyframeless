/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Plugin_Private.h"
#import "Constants.h"
#import "MMInspectorHeader.h"
#import <CoreGraphics/CoreGraphics.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wprotocol"

@implementation MagicMovePlugin

- (BOOL)properties:(NSDictionary *_Nonnull *)properties
             error:(NSError *_Nullable *)error {
  // Position, Scale and rotation redistribute pixels: an output pixel can come
  // from anywhere in the input, and the output reaches past the input frame.
  // ChangesOutputSize makes the host call -destinationImageRect: and size its
  // output from that rect. NeedsFullBuffer is also required, despite its
  // documented performance cost: the host tiles this render in full-width
  // horizontal bands and stops issuing bands before it covers the grown
  // output, so moved content is clipped along a band edge. That clipping can
  // only appear vertically, because the bands are never split horizontally.
  // Answering -sourceTileRect: per tile does not change which bands the host
  // enumerates, so the whole buffer is the only correct declaration.
  *properties = @{
    kFxPropertyKey_MayRemapTime : @NO,
    kFxPropertyKey_PixelTransformSupport : @(kFxPixelTransform_ScaleTranslate),
    kFxPropertyKey_VariesWhenParamsAreStatic : @YES,
    kFxPropertyKey_NeedsFullBuffer : @YES,
    kFxPropertyKey_ChangesOutputSize : @YES
  };

  return YES;
}

// Shared with the on-screen control: the host decodes secure-coded custom
// values through whichever object it is calling back, so both must agree.
NSSet<Class> *MMClassesForCustomParameter(UInt32 parameterID) {
  if (parameterID == MMHostRefreshToken) return [NSSet setWithObject:NSString.class];
  if (parameterID == MMTimingControls || parameterID == MMHeaderControls) return [NSSet setWithObject:NSNumber.class];
  // Every keyframed property archives a KFPose holding a KFPoseTiming.
  if (KFPropertyLaneForParameter(parameterID)) return [NSSet setWithObjects:KFPose.class, KFPoseTiming.class, nil];
  return [NSSet set];
}
- (NSSet<Class> *)classesForCustomParameterID:(UInt32)parameterID {
  return MMClassesForCustomParameter(parameterID);
}

- (void)pluginInstanceAddedToDocument {
  // Which on-screen controls exist decides whether the playhead nudge has
  // anything to bring back.
  NSMutableArray<NSNumber *> *toggles = [NSMutableArray array];
  for (KFPropertyLane *lane in KFPropertyLanes())
    if (lane.visibilityToggleID) [toggles addObject:@(lane.visibilityToggleID)];
  self.onScreenControlVisibilityParameters = toggles;
  [self publishViewCaches];
  // Parameter creation also happens for detached library/drag instances.
  // A timer action there makes Motion request timing for a nonexistent input.
  // FxPlug guarantees host API readiness only after document attachment.
  [self startNativeLinkCommits];
}

- (BOOL)parameterChanged:(UInt32)parameterID atTime:(CMTime)time error:(NSError **)error {
  if (parameterID == MMMotionBlur || parameterID == MMExplicitCreation ||
      parameterID == MMMotionBlurSamples || parameterID == MMMotionBlurShutterAngle) {
    [NSNotificationCenter.defaultCenter postNotificationName:MMHeaderSettingsChanged object:self.apiManager];
    KFPropertyMenuParametersChanged(self.apiManager);
  }
  if (parameterID == MMHostRefreshToken) return YES; // Host invalidation only.
  // A native value callback may overlap the commit tick on another thread;
  // the link state is guarded internally.
  for (KFPropertyLane *lane in KFPropertyLanes()) {
    if (parameterID != lane.parameterID && parameterID != lane.cacheTokenID) continue;
    KFPrimeDefaultKeyTracker(self.apiManager, lane.parameterID);
    [lane refreshCacheForManager:self.apiManager time:time];
    KFObserveNativeLinks(self.apiManager, lane.parameterID,
                         CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft));
    KFPropertyMenuParametersChanged(self.apiManager);
    return YES;
  }
  return YES;
}
@end
#pragma clang diagnostic pop
