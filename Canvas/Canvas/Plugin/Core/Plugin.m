/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerTimeline.h"
#import "Constants.h"
#import "Plugin_Private.h"
#import <KeyframelessKit/KKDataBlob.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wprotocol"

@implementation CanvasPlugin

@dynamic inspectorView;

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
    // Keep the viewer OSC's UIState snapshot fresh after every write (toggle,
    // selection, OSC visibility, undo/redo).
    CanvasSetUIStateSnapshot(json);
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
    // Re-apply the viewer OSC visibility (toggle / pills changed, or
    // undo/redo). Master is global; the per-element set is PER-LAYER
    // (oscElementsByLayer), so reload that map into the instance state and
    // re-apply the SELECTED layer's set. nil renderer keeps the popover MINI
    // handles independent.
    BOOL oscMaster = state[@"oscMasterVisible"]
                         ? [state[@"oscMasterVisible"] boolValue]
                         : YES;
    NSDictionary *byLayer = state[@"oscElementsByLayer"];
    NSArray<NSString *> *oscKeys =
        [CanvasPlugin kkOSCElementKeysForCompounds:[CanvasPlugin oscCompounds]];
    // Undo/redo of a layer-selection change: the persisted selectedLayerID is
    // the resolved id (or "" / absent = topmost, i.e. the baseline before any
    // selection persisted). The view method self-guards no-ops, so it's safe to
    // run on every UIState change (OSC toggles preserve the key, so they no-op).
    NSString *restoredSel = state[@"selectedLayerID"];
    NSArray<NSString *> *restoredSelIDs =
        [state[@"selectedLayerIDs"] isKindOfClass:[NSArray class]]
            ? state[@"selectedLayerIDs"]
            : nil;
    // Auto-select defaults ON (absent key) - the common case is clicking layers
    // on the canvas; persisted NO is respected once the user toggles it off.
    BOOL autoSelect =
        state[@"autoSelect"] ? [state[@"autoSelect"] boolValue] : YES;
    // Shared alignment-grid state - mirror onto the popover mini-viewer so its
    // grid matches the viewer's (same keys the OSC writes via _writeUIStateMerging).
    BOOL gridEnabled = [state[@"gridEnabled"] boolValue];
    BOOL gridAdaptive =
        state[@"gridAdaptive"] ? [state[@"gridAdaptive"] boolValue] : YES;
    NSInteger gridSpacing =
        state[@"gridSpacing"] ? [state[@"gridSpacing"] integerValue] : 10;
    BOOL gridSnap = [state[@"gridSnap"] boolValue];
    // The active tool is shared (a logical editing mode). The toolbar POSITION is
    // per-surface (the viewer + mini differ in size/aspect, and the mini render is
    // Y-mirrored): the mini reads/writes its own `miniToolbarPos`, not the viewer's
    // `toolbarPos`. Absent -> {-1,-1} = the mini's own default anchor (top).
    NSInteger tbTool = state[@"tool"] ? [state[@"tool"] integerValue] : 0;
    NSArray *tbPos = state[@"miniToolbarPos"];
    CGPoint tbNorm =
        ([tbPos isKindOfClass:[NSArray class]] && tbPos.count == 2)
            ? CGPointMake([tbPos[0] doubleValue], [tbPos[1] doubleValue])
            : CGPointMake(-1, -1);
    dispatch_async(dispatch_get_main_queue(), ^{
      [self.inspectorView setLoopEnabled:enabled];
      [self.inspectorView setActiveTab:tab];
      [(CanvasInspectorView *)self.inspectorView setAutoSelect:autoSelect];
      [(CanvasInspectorView *)self.inspectorView setGridEnabled:gridEnabled
                                                      adaptive:gridAdaptive
                                                       spacing:gridSpacing
                                                          snap:gridSnap];
      [(CanvasInspectorView *)self.inspectorView setToolbarTool:tbTool
                                                       normPos:tbNorm];
      KKPluginInstanceState *ist = KKInstanceStateEnsureForAPI(self.apiManager);
      ist.oscMasterVisible = oscMaster;
      ist.oscElementsByOwner =
          [byLayer isKindOfClass:[NSDictionary class]] ? byLayer : @{};
      CanvasInspectorView *view = (CanvasInspectorView *)self.inspectorView;
      self.restoringSelection = YES;
      [view restoreSelectedLayerIDs:restoredSelIDs primary:restoredSel];
      self.restoringSelection = NO;
      [self canvasApplyOSCForLayer:view.resolvedSelectedLayerID keys:oscKeys];
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

  // Undo/redo of the motion-blur toolbar settings: re-seed the inspector row.
  if (parameterID == kKKParamMotionBlurData)
    [self kkHandleMotionBlurDataChangedPushingTechnique:YES];

  return YES;
}

- (NSSet<Class> *)classesForCustomParameterID:(UInt32)parameterID {
  if (parameterID == kParamUIState || parameterID == kParamRenderNudge ||
      parameterID == kParamLayerData)
    return [NSSet setWithObject:[KKDataBlob class]];
  return [super classesForCustomParameterID:parameterID];
}

// Canvas's render samples + accumulates the layer composite across sub-frame
// times when motion blur is on (see Plugin+Render.m), so opt into the shared
// motion-blur infrastructure (toolbar toggle + help docs).
- (BOOL)usesMotionBlur {
  return YES;
}

#pragma clang diagnostic pop
@end
