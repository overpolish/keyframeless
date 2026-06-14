/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasInspectorView.h"
#import "Constants.h"
#import "Plugin_Private.h"
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKPlugin+InspectorCallbacks.h>
#import <KeyframelessKit/KKTimingStage.h>

@implementation CanvasPlugin (CustomUI)

+ (NSArray<KKLane *> *)availableLanes {
  // Increment 1: a single dummy animatable lane so the shared timeline UI has
  // something to drive. The render ignores it for now (literal passthrough) -
  // real Canvas lanes (path / stroke / fill / transform) land in later steps.
  KKLane *amount = [KKLane laneWithLabel:@"Amount"];
  amount.valueType = KKLaneValueTypeFloat;
  amount.componentMin = @[ @0.0 ];
  amount.componentMax = @[ @100.0 ];
  amount.componentUnits = @[ @"%" ];
  amount.integerValued = YES;
  [amount insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0.0 ]]];
  return @[ amount ];
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == kParamInspectorUI) {
    id<FxCustomParameterActionAPI_v4> actionAPI = [self.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actionAPI startAction:self];
    id<FxParameterRetrievalAPI_v6> getAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];

    KKInspectorPersistedState *st =
        [self kkReadInspectorPersistedStateWithGetAPI:getAPI
                                       uiStateParamID:kParamUIState];
    KKTimeline *timeline = [self timelineStampedWithClipDuration:st.timeline];

    // Frame + clip duration for the keypose-snap epsilon and the basic-view
    // scrubber clamp. FxTimingAPI resolves inside this action scope; we push
    // them into the view right after construction to avoid the render-push
    // race documented in Rounded.
    id<FxTimingAPI_v4> timingAPI =
        [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
    double seedFrameDurSec = 0.0;
    double seedClipDurSec = 0.0;
    if (timingAPI) {
      CMTime frameDur = kCMTimeZero, clipDur = kCMTimeZero;
      [timingAPI frameDuration:&frameDur];
      [timingAPI durationTimeForEffect:&clipDur];
      seedFrameDurSec = CMTimeGetSeconds(frameDur);
      seedClipDurSec = CMTimeGetSeconds(clipDur);
    }

    [actionAPI endAction:self];

    NSArray<KKLane *> *available = [CanvasPlugin availableLanes];
    CanvasInspectorView *view =
        [[CanvasInspectorView alloc] initWithAPIManager:self.apiManager
                                            loopEnabled:st.loopEnabled
                                  maintainTimingEnabled:st.maintainTimingEnabled
                                              activeTab:st.activeTab
                                         availableLanes:available
                                               timeline:timeline];
    if (seedClipDurSec > 0)
      [view setClipDurationSeconds:seedClipDurSec];
    if (seedFrameDurSec > 0)
      [view setFrameDurationSeconds:seedFrameDurSec];

    [self kkWireStandardInspectorCallbacksForView:view
                                   uiStateParamID:kParamUIState
                               renderNudgeParamID:kParamRenderNudge
                                    dragUndoLabel:@"Adjust Canvas"
                               detachedWindowSize:CGSizeMake(720.0, 460.0)];

    self.inspectorView = view;
    if (!self.playheadPoller) {
      self.playheadPoller =
          [[KKPlayheadPoller alloc] initWithAPIManager:self.apiManager
                                          actionTarget:self
                                           renderCache:self.renderCache];
    }
    [self.playheadPoller setInspectorView:view];
    if (self.renderCache.effectDurSec > 0.0)
      [self.playheadPoller ensureRunning];
    return view;
  }
  typedef NSView *(*ViewIMP)(id, SEL, UInt32);
  ViewIMP imp = (ViewIMP)[KKPlugin instanceMethodForSelector:_cmd];
  return imp(self, _cmd, parameterID);
}

@end
