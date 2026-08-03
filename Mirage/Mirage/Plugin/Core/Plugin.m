/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"

#import <QuartzCore/QuartzCore.h>

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
  // Paste-attributes clones the instance-id param and the inspector re-mints a
  // fresh one; this refreshes THIS process's cached UUID so the mini-viewer
  // rendezvous paths follow instead of publishing to the old id forever.
  KKInstanceUUIDHandleParameterChanged(self.apiManager, parameterID);

  if (parameterID == kParamUIState) {
    __block NSString *json = nil;
    KKPerformUndoable(self.apiManager, self, nil,
                      ^(id<FxParameterRetrievalAPI_v6> getAPI,
                        id<FxParameterSettingAPI_v5> setAPI,
                        CMTime actionTime) {
                        json = KKReadCustomParamString(getAPI, kParamUIState);
                      });
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
    // Undo/redo of a rack selection (its own, or the one folded into an append
    // or a remove). The strip's own writes come back through here too, and the
    // view's restore self-guards on "already there", so an unrelated UI-state
    // write (a pill, the OSC checklist) is a no-op rather than churn.
    NSString *restoredEntry =
        [state[@"selectedRackEntryID"] isKindOfClass:[NSString class]]
            ? state[@"selectedRackEntryID"]
            : nil;
    // The OSC and the AI author read the entry off the per-instance state and
    // never see the blob, so it is updated HERE, synchronously - the next
    // drawOSC tick can land before the main-queue hop below.
    if (restoredEntry.length)
      KKInstanceStateEnsureForAPI(self.apiManager).selectedRackEntryID =
          restoredEntry;
    // Shared glue: refresh OSC master + lastUIState + hidden set, and push the
    // tick + mini-viewer (undo/redo of the tick or a pill repaints live). Use
    // the SOURCE-AWARE element keys (the shader's `osc` lanes) - the static
    // oscCompounds is empty, so passing it would rebuild the hidden set from no
    // keys and wipe an opt-click hide the instant it persists.
    //
    // EVERY rack entry's keys, not just the selected one's: the hidden set this
    // rebuilds is the whole instance's, and restricting it to the visible entry
    // would drop the other entries' hides on the next persist.
    [self kkRefreshOSCVisibilityFromState:state
                                     view:self.inspectorView
                                 renderer:(KKMiniViewerRenderer *)self
                                              .inspectorView.miniViewerDelegate
                              elementKeys:[MiragePlugin
                                              oscElementKeysForRackTimeline:
                                                  KKProcessTimelineSnapshot()]];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self.inspectorView setLoopEnabled:enabled];
      [self.inspectorView setActiveTab:tab];
      // Inside the flag: the push re-drives the strip through the same funnel a
      // click uses, and any path that reached the persist hook from in here
      // would write the value it just read back - a duplicate undo entry
      // directly behind the one the user is walking through.
      self.restoringRackSelection = YES;
      [self.inspectorView applyPersistedRackSelection:restoredEntry];
      self.restoringRackSelection = NO;
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
