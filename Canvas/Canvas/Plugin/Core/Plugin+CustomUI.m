/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasInspectorView.h"
#import "CanvasLayerTimeline.h"
#import "Constants.h"
#import "Plugin_Private.h"
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKDataBlob.h>
#import <KeyframelessKit/KKPlugin+InspectorCallbacks.h>
#import <KeyframelessKit/KKTimingStage.h>

@implementation CanvasPlugin (CustomUI)

+ (NSArray<KKLane *> *)availableLanes {
  // Transform group. These are lane TEMPLATES: each layer owns its own timeline
  // built from them (per-layer transforms; the inspector shows the selected
  // layer's), so a fresh layer starts at identity. The render ignores them
  // until the transform plumbing lands; stroke / fill groups come later.
  //
  // Scale: 2-component aspect-linked percent, modelled on MagicMove's box-OSC
  // Scale lane so the box OSC drops straight in. Identity = 100%. Unbounded
  // above (like MagicMove); 0 floor.
  KKLane *scale = [KKLane laneWithLabel:@"Scale"];
  scale.valueType = KKLaneValueTypeFloat;
  scale.componentMin = @[ @0.0, @0.0 ];
  scale.componentUnits = @[ @"%", @"%" ];
  scale.componentLabels = @[ @"X", @"Y" ];
  scale.aspectLinkable = YES;
  scale.aspectLinked = YES;
  scale.enabled = NO; // constant by default; animate per-layer via the dropdown
  scale.categoryKey = @"Transform";
  scale.categorySymbol = @"arrow.up.and.down.and.arrow.left.and.right";
  [scale insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                         values:@[ @100.0, @100.0 ]]];

  // Position: 2D spatial, stored normalised 0..1 (0.5,0.5 = centred =
  // identity), displayed as pixels. Same reusable curved-path Position as
  // Glow/MagicMove (spatialCurvable). Off-canvas allowed, so no min/max.
  KKLane *position = [KKLane laneWithLabel:@"Position"];
  position.valueType = KKLaneValueTypeGeneric;
  position.componentMin = @[];
  position.componentMax = @[];
  position.componentUnits = @[ @"px", @"px" ];
  position.componentsScaleWithMedia = YES; // stored 0..1, displayed as pixels
  position.componentLabels = @[ @"X", @"Y" ];
  position.spatialCurvable = YES;
  position.enabled = NO; // constant by default; animate per-layer via dropdown
  position.categoryKey = @"Transform";
  position.categorySymbol = @"arrow.up.and.down.and.arrow.left.and.right";
  [position insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0.5, @0.5 ]]];

  return @[ scale, position ];
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
    // Per-layer timelines: the kit inspector EDITS the SELECTED layer's own
    // animationJSON with PLAIN labels (so the Animated dropdown / Constants /
    // Keypose work unchanged). The all-layers overview is drawn separately as
    // read-only context. (NOT the global kKKParamTimelineData; st.timeline is
    // unused here.) Selection is the topmost layer until panel-driven selection
    // lands.
    NSString *layerB64 = KKReadCustomParamString(getAPI, kParamLayerData);
    NSMutableArray<KKBezierPath *> *layerPaths =
        layerB64.length
            ? [KKBezierPath
                  pathsFromBlob:[[NSData alloc]
                                    initWithBase64EncodedString:layerB64
                                                        options:0]]
            : [NSMutableArray array];
    KKTimeline *layerTL =
        CanvasLayerTimelineForPath(CanvasSelectedLayerForPaths(layerPaths, nil),
                                   [CanvasPlugin availableLanes]);
    KKTimeline *timeline = [self timelineStampedWithClipDuration:layerTL];

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

    // Mint the per-instance state UUID here (inside the action scope, where the
    // setting API resolves) so the viewer Transform OSC can read its visibility
    // - without it the OSC reads no state and defaults to visible.
    KKInstanceStateEnsureForAPI(self.apiManager);

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
    // Seed the motion-blur toolbar row from the persisted blob (the standard
    // callbacks below own the write-back; this restores the toggle on reopen).
    [view setMotionBlurEnabled:st.motionBlurEnabled];
    [view setMotionBlurShutterAngle:st.motionBlurShutterAngle
                            samples:st.motionBlurSamples];
    [view setMotionBlurMode:(KKMotionBlurMode)st.motionBlurMode];

    [self kkWireStandardInspectorCallbacksForView:view
                                   uiStateParamID:kParamUIState
                               renderNudgeParamID:kParamRenderNudge
                                    dragUndoLabel:@"Adjust Canvas"
                               detachedWindowSize:CGSizeMake(720.0, 460.0)];

    // Persist timeline edits PER LAYER instead of to the global timeline param:
    // decompose the edited merged timeline by layerKey and write each layer's
    // clean animationJSON back into the layer blob. Overrides the shared
    // wiring's onTimelineMutated (which targets kKKParamTimelineData). Runs in
    // an action scope so it nests inside the drag undo group (onDragBegin/End).
    __weak CanvasPlugin *weakSelf = self;
    view.onTimelineMutated = ^(KKTimeline *updated) {
      __strong CanvasPlugin *s = weakSelf;
      if (!s)
        return;
      id<FxCustomParameterActionAPI_v4> act = [s.apiManager
          apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
      if (!act)
        return;
      [act startAction:s];
      id<FxParameterRetrievalAPI_v6> get =
          [s.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      id<FxParameterSettingAPI_v5> set =
          [s.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      NSString *b64 = KKReadCustomParamString(get, kParamLayerData);
      NSMutableArray<KKBezierPath *> *cur =
          b64.length
              ? [KKBezierPath pathsFromBlob:[[NSData alloc]
                                                initWithBase64EncodedString:b64
                                                                    options:0]]
              : [NSMutableArray array];
      CanvasApplyTimelineToPath(
          updated,
          CanvasSelectedLayerForPaths(
              cur, ((CanvasInspectorView *)s.inspectorView).selectedLayerID));
      NSData *blob = [KKBezierPath blobFromPaths:cur];
      KKWriteCustomParamString(set, [blob base64EncodedStringWithOptions:0],
                               kParamLayerData);
      [act endAction:s];
    };

    // Keypose edits in either graph mutate the ALL-LAYERS graph timeline; split
    // it back per layer (by layerKey) and write each layer's animationJSON.
    view.basicLanesView.onGraphTimelineMutated = ^(KKTimeline *merged) {
      __strong CanvasPlugin *s = weakSelf;
      if (!s)
        return;
      id<FxCustomParameterActionAPI_v4> act = [s.apiManager
          apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
      if (!act)
        return;
      [act startAction:s];
      id<FxParameterRetrievalAPI_v6> get =
          [s.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      id<FxParameterSettingAPI_v5> set =
          [s.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      NSString *b64 = KKReadCustomParamString(get, kParamLayerData);
      NSMutableArray<KKBezierPath *> *cur =
          b64.length
              ? [KKBezierPath pathsFromBlob:[[NSData alloc]
                                                initWithBase64EncodedString:b64
                                                                    options:0]]
              : [NSMutableArray array];
      CanvasApplyMergedTimelineToPaths(merged, cur,
                                       [CanvasPlugin availableLanes]);
      NSData *blob = [KKBezierPath blobFromPaths:cur];
      KKWriteCustomParamString(set, [blob base64EncodedStringWithOptions:0],
                               kParamLayerData);
      [act endAction:s];
    };

    self.inspectorView = view;

    // Viewer OSC visibility: a global "show controls" toggle + per-element
    // opt-click hide/show, HIDDEN by default (master defaults OFF for Canvas).
    // nil renderer so the toggle drives only the viewer OSC's instance state
    // (which CanvasOSC reads), not the popover MINI handles
    // (editing-contextual, stay shown). Two pills: Position (+ its motion Path)
    // and Scale.
    NSArray<NSArray<NSString *> *> *oscCompounds =
        @[ @[ @"Position", @"Path" ], @[ @"Scale" ] ];
    // Wire the REAL mini renderer here so onHandleVisibilityToggled is set -
    // the mini's opt-reveal ghost gates on (revealHidden &&
    // onHandleVisibilityToggled
    // != nil); the kit overlay already drives revealHidden on Option-hold, so
    // this is the missing half (it also gives opt-click-in-mini hide/show, like
    // MagicMove/Glow). handlesHidden + hiddenHandleLabels stay owned by
    // -syncMiniHandleVisibility (so lock ORs in without fighting the kit's
    // async master set); kkRefresh below keeps nil for the same reason.
    [self kkWireOSCVisibilityForView:view
                            renderer:(KKMiniViewerRenderer *)
                                         view.miniViewerDelegate
                           compounds:oscCompounds
                             paramID:kParamUIState];
    NSMutableDictionary *visState =
        [st.uiState mutableCopy] ?: [NSMutableDictionary dictionary];
    // Default: global controls ON, but the Transform (Position + Path + Scale)
    // individually hidden - so the viewer is clean yet opt-hold reveals the
    // ghost controls to opt-click on (no need to flip the global toggle first).
    if (!visState[@"oscMasterVisible"])
      visState[@"oscMasterVisible"] = @YES;
    if (!visState[@"oscElements"])
      visState[@"oscElements"] =
          @{@"Position" : @NO, @"Path" : @NO, @"Scale" : @NO};
    [self kkRefreshOSCVisibilityFromState:visState
                                     view:view
                                 renderer:nil
                              elementKeys:[CanvasPlugin
                                              kkOSCElementKeysForCompounds:
                                                  oscCompounds]];
    // Push that visibility onto the popover mini handles too (Canvas owns this
    // - the wiring uses a nil renderer so it doesn't fight the lock state).
    [view syncMiniHandleVisibility];

    // The Layers panel opens parameter actions to read/write kParamLayerData;
    // they only persist if the action sender is a host-recognized editor (the
    // plugin), like the playhead poller's actionTarget below.
    [view setLayerParamActionTarget:self];
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
