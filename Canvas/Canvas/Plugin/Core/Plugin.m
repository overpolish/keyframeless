/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <KeyframelessKit/KKDataBlob.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wprotocol"

@implementation CanvasPlugin

- (KKTimelineInspectorView *)maintainTimingInspectorView {
  return (KKTimelineInspectorView *)self.inspectorView;
}

- (nullable instancetype)initWithAPIManager:(id<PROAPIAccessing>)newApiManager {
  self = [super initWithAPIManager:newApiManager];
  if (self) {
    _renderCache = [[KKRenderCache alloc] init];
    _imageTextureCache = [NSMutableDictionary dictionary];
  }
  return self;
}

- (void)dealloc {
  [_playheadPoller invalidate];
}

- (BOOL)properties:(NSDictionary *_Nonnull *)properties
             error:(NSError *_Nullable *)error {
  *properties = @{
    // YES so FCP calls -scheduleInputs: - the mini-viewer pulls extra source
    // frames at other clip times for the boundary / filmstrip / onion previews.
    kFxPropertyKey_MayRemapTime : @YES,
    // YES so FCP keeps re-running the render through the clip; the timeline
    // drives per-frame state and the live-scrub poller stays fed. Render is a
    // literal passthrough for now (increment 1).
    kFxPropertyKey_VariesWhenParamsAreStatic : @YES,
    kFxPropertyKey_PixelTransformSupport : @(kFxPixelTransform_ScaleTranslate),
  };
  return YES;
}

- (BOOL)parameterChanged:(UInt32)parameterID
                  atTime:(CMTime)time
                   error:(NSError **)error {
  if (parameterID == kParamUIState) {
    id<FxCustomParameterActionAPI_v4> actionAPI = [self.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actionAPI startAction:self];
    id<FxParameterRetrievalAPI_v6> getAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    NSString *json = KKReadCustomParamString(getAPI, kParamUIState);
    [actionAPI endAction:self];
    NSDictionary *state =
        (json.length ? [NSJSONSerialization
                           JSONObjectWithData:
                               [json dataUsingEncoding:NSUTF8StringEncoding]
                                      options:0
                                        error:nil]
                     : nil)
            ?: @{};
    BOOL enabled = [state[@"loopEnabled"] boolValue];
    NSInteger tab = [state[@"activeTab"] integerValue];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self.inspectorView setLoopEnabled:enabled];
      [self.inspectorView setActiveTab:tab];
    });
  }

  if (parameterID == kKKParamTimelineData) {
    __weak typeof(self) weakSelf = self;
    KKHandleTimelineParamChanged(
        self.apiManager, kKKParamTimelineData, self,
        ^KKTimeline *(KKTimeline *t) {
          return [weakSelf timelineStampedWithClipDuration:t];
        },
        nil, (KKTimelineInspectorView *)self.inspectorView);
  }

  // Undo/redo (or any external change) of the layer stack: refresh the panel.
  if (parameterID == kParamLayerData) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [(CanvasInspectorView *)self.inspectorView reloadLayerList];
    });
  }

  return YES;
}

- (nullable KKTimeline *)timelineStampedWithClipDuration:
    (nullable KKTimeline *)timeline {
  if (!timeline)
    return timeline;
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  CMTime dur = kCMTimeZero;
  [timingAPI durationTimeForEffect:&dur];
  double durSec = CMTimeGetSeconds(dur);
  if (durSec <= 0)
    return timeline;
  KKTimeline *out = [timeline copy];
  NSMutableArray<KKLane *> *lanes = [out.lanes mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    KKLane *l = [lanes[i] copy];
    l.lastKnownClipDuration = durSec;
    lanes[i] = l;
  }
  out.lanes = lanes;
  return out;
}

- (NSSet<Class> *)classesForCustomParameterID:(UInt32)parameterID {
  if (parameterID == kKKParamTimelineData || parameterID == kParamUIState ||
      parameterID == kParamRenderNudge || parameterID == kParamLayerData)
    return [NSSet setWithObject:[KKDataBlob class]];
  return [super classesForCustomParameterID:parameterID];
}

#pragma clang diagnostic pop
@end
