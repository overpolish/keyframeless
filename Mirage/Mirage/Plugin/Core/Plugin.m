/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wprotocol"

@implementation MiragePlugin

@dynamic inspectorView;

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
  [_linkWatcher invalidate];
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
    // Shared glue: refresh OSC master + lastUIState + hidden set, and push the
    // tick + mini-viewer (undo/redo of the tick or a pill repaints live). Use
    // the SOURCE-AWARE element keys (the shader's `osc` lanes) - the static
    // oscCompounds is empty, so passing it would rebuild the hidden set from no
    // keys and wipe an opt-click hide the instant it persists.
    NSString *oscSrc =
        [MiragePlugin shaderSourceFromTimeline:KKProcessTimelineSnapshot()];
    [self
        kkRefreshOSCVisibilityFromState:state
                                   view:self.inspectorView
                               renderer:(KKMiniViewerRenderer *)self
                                            .inspectorView.miniViewerDelegate
                            elementKeys:[KKPlugin
                                            kkOSCElementKeysForCompounds:
                                                [MiragePlugin
                                                    oscCompoundsForShaderSource:
                                                        oscSrc]]];
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
    // A source pick lands here, as a lane value. Deferred rather than done
    // inline: this is already inside the handler's action scope, and opening a
    // second one mid-change is what FCP complains about. By the next tick the
    // change has settled and the snapshot is the one the user just made.
    dispatch_async(dispatch_get_main_queue(), ^{
      [weakSelf syncAudioTicketsForTimeline:KKProcessTimelineSnapshot()];
    });
  }

  if (parameterID == kKKParamMotionBlurData)
    [self kkHandleMotionBlurDataChangedPushingTechnique:NO];

  return YES;
}

- (NSSet<Class> *)classesForCustomParameterID:(UInt32)parameterID {
  if (parameterID == kParamUIState || parameterID == kParamRenderNudge)
    return [NSSet setWithObject:[KKDataBlob class]];
  return [super classesForCustomParameterID:parameterID];
}

#pragma clang diagnostic pop
@end
