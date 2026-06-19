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
  scale.integerValued = YES; // whole percentages only (1% scrub step)
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

  // Rotation: 3-axis (X/Y/Z) Euler degrees, modelled on MagicMove's Rotation
  // lane so the kit's KKRotationOSC + mini rotation rings drop straight in.
  // Identity = 0. Unbounded (angles accumulate past 360). Z is the in-plane
  // spin (rendered today); X/Y tilt renders once the perspective transform
  // lands. Axis ring colours match MagicMove (X red, Y green, Z blue).
  KKLane *rotation = [KKLane laneWithLabel:@"Rotation"];
  rotation.valueType = KKLaneValueTypeAngle;
  rotation.componentMin = @[];
  rotation.componentMax = @[];
  rotation.componentUnits = @[ @"°", @"°", @"°" ];
  rotation.componentLabels = @[ @"X", @"Y", @"Z" ];
  rotation.componentLabelColors = @[
    [NSColor colorWithSRGBRed:0.95 green:0.35 blue:0.35 alpha:1.0],
    [NSColor colorWithSRGBRed:0.40 green:0.85 blue:0.45 alpha:1.0],
    [NSColor colorWithSRGBRed:0.40 green:0.60 blue:0.95 alpha:1.0],
  ];
  rotation.enabled = NO; // constant by default; animate per-layer via dropdown
  rotation.categoryKey = @"Transform";
  rotation.categorySymbol = @"arrow.up.and.down.and.arrow.left.and.right";
  [rotation insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                            values:@[ @0.0, @0.0, @0.0 ]]];

  // Opacity: shared kit definition (0-100%, identity 100). Per-layer; the
  // render multiplies the layer's premultiplied RGBA by value/100. No OSC.
  KKLane *opacity = [KKLane opacityLane];
  opacity.enabled = NO; // constant by default; animate per-layer via dropdown
  opacity.categoryKey = @"Transform";
  opacity.categorySymbol = @"arrow.up.and.down.and.arrow.left.and.right";

  return @[ scale, position, rotation, opacity ];
}

+ (NSArray<NSArray<NSString *> *> *)oscCompounds {
  return @[
    @[ @"Position", @"Path" ], @[ @"Scale" ],
    @[ @"Rotation", @"Rotation.X", @"Rotation.Y", @"Rotation.Z" ]
  ];
}

+ (NSDictionary<NSString *, NSNumber *> *)defaultOSCElements {
  // Transform OSCs start hidden so the viewer is clean; Opt-peek reveals them
  // as ghosts to Opt-click on. Rotation hides its individual X/Y/Z RINGS rather
  // than the group: Opt-peek only reveals individually-hidden elements, and a
  // hidden GROUP wouldn't make its axes reveal-eligible (you could never
  // Opt-click them back). Leaving the group on keeps the rings per-axis
  // revealable + re-enableable.
  return @{
    @"Position" : @NO,
    @"Path" : @NO,
    @"Scale" : @NO,
    @"Rotation.X" : @NO,
    @"Rotation.Y" : @NO,
    @"Rotation.Z" : @NO
  };
}

- (void)canvasApplyOSCForLayer:(NSString *)layerID
                          keys:(NSArray<NSString *> *)keys {
  KKPluginInstanceState *ist = KKInstanceStateForAPI(self.apiManager);
  if (!ist)
    return;
  NSDictionary *els = ist.oscElementsByOwner[layerID ?: @""];
  if (![els isKindOfClass:[NSDictionary class]])
    els = [CanvasPlugin defaultOSCElements]; // new / unseen layer -> default
  // Refresh through the kit from a synthesized state (global master + THIS
  // layer's element map); this sets the active hiddenOSCElements + view + mini.
  NSDictionary *state =
      @{@"oscMasterVisible" : @(ist.oscMasterVisible), @"oscElements" : els};
  [self kkRefreshOSCVisibilityFromState:state
                                   view:(KKTimelineInspectorView *)
                                            self.inspectorView
                               renderer:nil
                            elementKeys:keys];
  [(CanvasInspectorView *)self.inspectorView syncMiniHandleVisibility];
  // If the OSC settings popover is open (companion layer list drove the
  // switch), refresh its checkboxes to this layer's set.
  [(KKTimelineInspectorView *)self.inspectorView refreshOpenOSCChecklist];
}

- (void)canvasToggleOSCElement:(NSString *)key
                       visible:(BOOL)visible
                          keys:(NSArray<NSString *> *)keys {
  CanvasInspectorView *view = (CanvasInspectorView *)self.inspectorView;
  NSString *layerID = view.resolvedSelectedLayerID ?: @"";
  KKPluginInstanceState *ist = KKInstanceStateForAPI(self.apiManager);
  if (!ist)
    return;
  // Flip the ACTIVE set (the selected layer's), then write it back into that
  // layer's slot in the per-layer map and persist the whole map.
  NSMutableSet<NSString *> *hidden =
      [(ist.hiddenOSCElements ?: [NSSet set]) mutableCopy];
  if (visible)
    [hidden removeObject:key];
  else
    [hidden addObject:key];
  ist.hiddenOSCElements = hidden;
  NSMutableDictionary<NSString *, NSNumber *> *els =
      [NSMutableDictionary dictionaryWithCapacity:keys.count];
  for (NSString *k in keys)
    els[k] = @(![hidden containsObject:k]);
  NSMutableDictionary *byLayer = [(ist.oscElementsByOwner ?: @{}) mutableCopy];
  byLayer[layerID] = els;
  ist.oscElementsByOwner = byLayer;
  [self patchUIStateKey:@"oscElementsByLayer"
                  value:byLayer
                paramID:kParamUIState];
  [view syncMiniHandleVisibility];
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

    // Publish the full UIState JSON for the viewer OSC (it can't read the custom
    // param) - it reads view-prefs like "autoSelect" and uses it as the base to
    // merge a new selection into on a hit-test click.
    CanvasSetUIStateSnapshot(KKReadCustomParamString(getAPI, kParamUIState));

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
    // (editing-contextual, stay shown). Pills: Position (+ its motion Path),
    // Scale, and Rotation (+ its X/Y/Z rings). Shared definition so the
    // parameterChanged refresh uses the identical element-key set.
    NSArray<NSArray<NSString *> *> *oscCompounds = [CanvasPlugin oscCompounds];
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
    NSArray<NSString *> *oscKeys =
        [CanvasPlugin kkOSCElementKeysForCompounds:oscCompounds];
    NSMutableDictionary *visState =
        [st.uiState mutableCopy] ?: [NSMutableDictionary dictionary];
    // Master "show controls" toggle stays GLOBAL (kkWire persists it under
    // oscMasterVisible). Default ON so opt-hold can reveal the per-layer
    // ghosts.
    KKPluginInstanceState *ist = KKInstanceStateEnsureForAPI(self.apiManager);
    ist.oscMasterVisible = visState[@"oscMasterVisible"]
                               ? [visState[@"oscMasterVisible"] boolValue]
                               : YES;
    // Per-LAYER element visibility: each layer keeps its own hidden set, stored
    // in kParamUIState["oscElementsByLayer"] keyed by layerID and mirrored into
    // the per-instance state. The ACTIVE set (ist.hiddenOSCElements, read by
    // the viewer OSC + mini in this same process) tracks the selected layer;
    // switch layers -> swap the active set (see -canvasApplyOSCForLayer:keys:).
    // A new layer with no entry falls back to the shared default seed.
    NSDictionary *byLayer = visState[@"oscElementsByLayer"];
    ist.oscElementsByOwner =
        [byLayer isKindOfClass:[NSDictionary class]] ? byLayer : @{};
    // Restore the SAVED selected layer. createView otherwise starts at the
    // topmost layer, so after a reboot the inspector/OSC/Constants target layer
    // 1 instead of the layer that was selected when the project was saved. Do it
    // BEFORE canvasApplyOSCForLayer so the OSC visibility set is the restored
    // layer's. restoreSelectedLayerID self-guards no-ops; the persist-on-select
    // block isn't wired yet (so no churn), but flag restoringSelection anyway.
    NSString *savedSel = visState[@"selectedLayerID"];
    if ([savedSel isKindOfClass:[NSString class]] && savedSel.length) {
      self.restoringSelection = YES;
      [view restoreSelectedLayerID:savedSel];
      self.restoringSelection = NO;
    }
    [self canvasApplyOSCForLayer:view.resolvedSelectedLayerID keys:oscKeys];

    __weak CanvasPlugin *weakOSC = self;
    // Element toggle routes to the SELECTED layer (replaces the kit's global
    // per-element handler wired above; master + states stay as kkWire set
    // them).
    view.oscVisibilityElementToggled = ^(NSInteger compoundIdx,
                                         NSInteger segIdx, BOOL isOn) {
      __strong CanvasPlugin *s = weakOSC;
      if (compoundIdx < 0 || compoundIdx >= (NSInteger)oscCompounds.count ||
          segIdx < 0 || segIdx >= (NSInteger)oscCompounds[compoundIdx].count)
        return;
      [s canvasToggleOSCElement:oscCompounds[compoundIdx][segIdx]
                        visible:isOn
                           keys:oscKeys];
    };
    // Opt-click a handle in the MINI viewer hides it for the SELECTED layer too
    // (kkWire pointed this at the kit's global toggle; re-point per-layer).
    KKMiniViewerRenderer *miniRenderer =
        (KKMiniViewerRenderer *)view.miniViewerDelegate;
    miniRenderer.onHandleVisibilityToggled = ^(NSString *label) {
      __strong CanvasPlugin *s = weakOSC;
      BOOL currentlyHidden =
          [KKInstanceStateForAPI(s.apiManager).hiddenOSCElements
              containsObject:label];
      [s canvasToggleOSCElement:label visible:currentlyHidden keys:oscKeys];
    };
    // Layer-selection change swaps the active OSC set to that layer's. The mini
    // updates synchronously (syncMiniHandleVisibility); the VIEWER OSC only
    // re-reads on its next drawOSC, and a selection isn't a param write, so
    // nudge a render to redraw it immediately (else it lags a few ticks).
    // Toggles already nudge via the kParamUIState write.
    view.onSelectedLayerChanged = ^(NSString *resolvedLayerID) {
      __strong CanvasPlugin *s = weakOSC;
      [s canvasApplyOSCForLayer:resolvedLayerID keys:oscKeys];
      // Persist the selection so it lands on the undo stack (like standard
      // editors: changing the active layer is itself undoable). Skip while
      // restoring from an undo/redo, else we'd push a duplicate entry. The
      // kParamUIState write also forces the render round-trip that redraws the
      // viewer OSC, so no separate kParamRenderNudge is needed (it would only
      // add a phantom undo entry - the "takes two cmd-Z" problem).
      if (!s.restoringSelection)
        [s patchUIStateKey:@"selectedLayerID"
                     value:(resolvedLayerID ?: @"")
                   paramID:kParamUIState];
    };

    // "Auto-select layers" toggle: seed the checkbox from the persisted state
    // (OFF when absent) and persist flips to kParamUIState. The write triggers
    // parameterChanged, which re-publishes the UIState snapshot the viewer OSC
    // reads.
    [view setAutoSelect:[visState[@"autoSelect"] boolValue]];
    view.onAutoSelectChanged = ^(BOOL on) {
      __strong CanvasPlugin *s = weakOSC;
      [s patchUIStateKey:@"autoSelect" value:@(on) paramID:kParamUIState];
    };

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
