/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import "RoundedOSCRadiusMath.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wprotocol"

@implementation RoundedPlugin

- (nullable instancetype)initWithAPIManager:(id<PROAPIAccessing>)newApiManager;
{
  self = [super initWithAPIManager:newApiManager];
  if (self) {
    _renderCache = [[KKRenderCache alloc] init];
  }
  return self;
}

- (void)dealloc {
  [_playheadPoller invalidate];
  [_playheadPoller release];
  [_renderCache release];
  [_miniCanvasFeed release];
  [super dealloc];
}

- (BOOL)properties:(NSDictionary *_Nonnull *)properties
             error:(NSError *_Nullable *)error {
  *properties = @{
    // YES so FCP calls -scheduleInputs: and honors FxImageTileRequests at
    // times other than the output time (the boundary-preview source-at-time).
    kFxPropertyKey_MayRemapTime : @YES,
    kFxPropertyKey_PixelTransformSupport : @(kFxPixelTransform_ScaleTranslate),
    kFxPropertyKey_VariesWhenParamsAreStatic : @YES
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

  if (parameterID == kKKParamMotionBlurData) {
    id<FxCustomParameterActionAPI_v4> actionAPI = [self.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actionAPI startAction:self];
    id<FxParameterRetrievalAPI_v6> getAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    NSString *json = KKReadCustomParamString(getAPI, kKKParamMotionBlurData);
    [actionAPI endAction:self];
    NSDictionary *mb =
        (json.length ? [NSJSONSerialization
                           JSONObjectWithData:
                               [json dataUsingEncoding:NSUTF8StringEncoding]
                                      options:0
                                        error:nil]
                     : nil)
            ?: @{};
    BOOL mbEnabled = [mb[@"enabled"] boolValue];
    double mbShutterAngle =
        mb[@"shutterAngle"] ? [mb[@"shutterAngle"] doubleValue] : 180.0;
    NSInteger mbSamples = mb[@"samples"] ? [mb[@"samples"] integerValue] : 16;
    dispatch_async(dispatch_get_main_queue(), ^{
      [self.inspectorView setMotionBlurEnabled:mbEnabled];
      [self.inspectorView setMotionBlurShutterAngle:mbShutterAngle
                                            samples:mbSamples];
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
  KKTimeline *out = [[timeline copy] autorelease];
  NSMutableArray<KKLane *> *lanes = [[out.lanes mutableCopy] autorelease];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    KKLane *l = [[lanes[i] copy] autorelease];
    l.lastKnownClipDuration = durSec;
    lanes[i] = l;
  }
  out.lanes = lanes;
  return out;
}

- (NSSet<Class> *)classesForCustomParameterID:(UInt32)parameterID {
  if (parameterID == kKKParamTimelineData || parameterID == kParamUIState ||
      parameterID == kParamRenderNudge || parameterID == kKKParamMotionBlurData)
    return [NSSet setWithObject:[KKDataBlob class]];
  return [super classesForCustomParameterID:parameterID];
}

#pragma clang diagnostic pop
@end
