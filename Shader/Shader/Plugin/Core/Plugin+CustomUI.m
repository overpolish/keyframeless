/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import "ShaderAISchema.h"
#import "ShaderColorSpace.h"
#import "ShaderInspectorView+Guides.h"
#import "ShaderInspectorView.h"
#import "ShaderLaneCatalog.h"
#import "ShaderLocalized.h"
#import "ShaderMiniViewerRenderer.h" // per-instance mini-viewer rendezvous paths
#import "ShaderOSCSnapshot.h" // OSC timeline snapshot + frame-duration setters
#import "ShaderPresets.h"     // ShaderBuiltinPresets (built-in look presets)
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKColorLanes.h>
#import <KeyframelessKit/KKDataBlob.h>
#import <KeyframelessKit/KKHelpSection.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKPlugin+InspectorCallbacks.h>
#import <KeyframelessKit/KKPresets.h>
#import <KeyframelessKit/KKTimelineAIMerge.h>
#import <KeyframelessKit/KKTimelineInspectorView+Guide.h> // guide help-button provider
#import <KeyframelessKit/KKTimingCompat.h>
#import <KeyframelessKit/KKTimingStage.h>
#import <KeyframelessKit/KKUpdateChecker.h>
@import KeyframelessAI;

@implementation ShaderPlugin (CustomUI)

- (BOOL)usesMotionBlur {
  return YES;
}

+ (NSArray<KKLane *> *)availableLanes {
  return ShaderBuildAvailableLanes();
}

// Source-aware lane set: the Core lanes plus whatever dynamic lanes the given
// shader source declares (e.g. the `// #color` Colours group).
+ (NSArray<KKLane *> *)availableLanesForShaderSource:(NSString *)source {
  return ShaderBuildAvailableLanesForSource(
      source.length ? source : ShaderCustomDefaultShaderSource());
}

// The current shader source from a timeline's "Shader" code lane (the baked
// default when absent/empty), for deriving the source-aware lane set.
+ (NSString *)shaderSourceFromTimeline:(KKTimeline *)timeline {
  for (KKLane *l in timeline.lanes)
    if ([l.label isEqualToString:@"Shader"] && l.codeString.length)
      return l.codeString;
  return ShaderCustomDefaultShaderSource();
}

+ (NSArray<NSArray<NSString *> *> *)oscCompounds {
  // The legacy Origin / Scale / Rotation on-screen controls are gone; no OSC
  // elements until shader-exposed OSCs land.
  return @[];
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
    BOOL loopEnabled = st.loopEnabled;
    NSInteger activeTab = st.activeTab;
    BOOL oscMasterVisible = st.oscMasterVisible;
    KKMiniViewerRenderMode renderMode = (KKMiniViewerRenderMode)st.renderMode;
    BOOL motionBlurEnabled = st.motionBlurEnabled;
    double motionBlurShutterAngle = st.motionBlurShutterAngle;
    NSInteger motionBlurSamples = st.motionBlurSamples;
    NSInteger motionBlurTechnique = st.motionBlurTechnique;
    NSDictionary *uiState = st.uiState;
    KKTimeline *timeline = [self timelineStampedWithClipDuration:st.timeline];

    // Cold-boot seed for the OSC. Without this, the first drawOSC tick after
    // FCP relaunch sees an empty snapshot → falls through to "no lane =
    // constant", Origin reads default 0.5,0.5 → the handle sits at frame
    // centre regardless of saved state. parameterChanged eventually catches
    // up, but only after a redraw nudge.
    ShaderSetTimelineSnapshot(timeline);

    // Frame + clip duration for the keypose-snap epsilon AND the basic-view
    // scrubber clamp. FxTimingAPI resolves inside this action scope. We
    // also push these into the view itself right after construction (below)
    // because the Plugin+Render push is gated on lastPushedClipDuration and
    // can race with view creation: if the first render fires before the
    // inspector view exists, the push targets a nil weak ref and the basic
    // view never learns the frame duration for the lifetime of this session.
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
      if (seedFrameDurSec > 0)
        ShaderSetFrameDurationSeconds(seedFrameDurSec);
    }

    // Per-instance OSC-visibility state: mint the UUID here (inside the action
    // scope where the setting API resolves) and seed the master tick.
    KKInstanceStateEnsureForAPI(self.apiManager).oscMasterVisible =
        oscMasterVisible;

    [actionAPI endAction:self];

    // Source-aware: derive the lane set (incl. the dynamic Colours group) from
    // the current shader source, so a shader's `// #color` directive surfaces
    // its swatches + palette generator.
    NSArray<KKLane *> *available = [ShaderPlugin
        availableLanesForShaderSource:[ShaderPlugin
                                          shaderSourceFromTimeline:timeline]];
    ShaderInspectorView *view =
        [[ShaderInspectorView alloc] initWithAPIManager:self.apiManager
                                            loopEnabled:loopEnabled
                                  maintainTimingEnabled:st.maintainTimingEnabled
                                              activeTab:activeTab
                                         availableLanes:available
                                               timeline:timeline];
    // Per-instance rendezvous paths (keyed by the instance UUID minted above)
    // so two stacked Shader clips read/write distinct /tmp files instead of the
    // clip below showing the top clip's source in its mini-viewer.
    NSString *instUUID = KKInstanceUUIDForAPI(self.apiManager);
    view.miniViewerDescriptorPath =
        ShaderMiniViewerDescriptorPathForUUID(instUUID);
    view.miniViewerRequestPath = ShaderMiniViewerRequestPathForUUID(instUUID);
    // Live source-derived lanes: when the shader code commits (debounced), the
    // inspector re-derives the lane set from the new source so a `// #color`
    // directive's Colours group appears/updates without a clip reselect.
    view.availableLanesProvider = ^NSArray<KKLane *> *(NSString *code) {
      return [ShaderPlugin availableLanesForShaderSource:code];
    };
    // Seed the basic-view scrubber clamp immediately. Plugin+Render's
    // dispatch_async push runs once on first render - if it raced ahead
    // and weakSelf.inspectorView was still nil, the basic view would
    // never see the frame duration. Pushing here too is idempotent.
    if (seedClipDurSec > 0)
      [view setClipDurationSeconds:seedClipDurSec];
    if (seedFrameDurSec > 0)
      [view setFrameDurationSeconds:seedFrameDurSec];
    [view setMotionBlurEnabled:motionBlurEnabled];
    [view setMotionBlurShutterAngle:motionBlurShutterAngle
                            samples:motionBlurSamples];
    [view setMotionBlurTechnique:(KKMotionBlurTechnique)motionBlurTechnique];

    // On-screen-control visibility: master tick + per-element pills (Origin,
    // Path) + opt-click-hide + opt-reveal. The element key is the lane label
    // (KKPositionOSC / the mini controller key their visibility on it). Shared
    // glue in KKPlugin (OSCVisibility); the renderer is the mini-viewer
    // delegate.
    KKMiniViewerRenderer *oscRenderer =
        (KKMiniViewerRenderer *)view.miniViewerDelegate;
    // The Scale mini box reads the plugin's lane templates for the aspect-link
    // default of an untouched (not-yet-in-timeline) constant Scale.
    if ([oscRenderer isKindOfClass:[ShaderMiniViewerRenderer class]])
      ((ShaderMiniViewerRenderer *)oscRenderer).laneTemplates = available;
    NSArray<NSArray<NSString *> *> *oscCompounds = [ShaderPlugin oscCompounds];
    oscRenderer.handlesHidden = !oscMasterVisible;
    [self kkApplyOSCVisibilityFromState:uiState
                            elementKeys:[KKPlugin kkOSCElementKeysForCompounds:
                                                      oscCompounds]
                               renderer:oscRenderer];
    [self kkWireOSCVisibilityForView:view
                            renderer:oscRenderer
                           compounds:oscCompounds
                             paramID:kParamUIState];
    [view setOSCVisible:oscMasterVisible];
    [view setRenderMode:renderMode];

    // Force OSCs visible while a guide runs (so its mini-viewer + viewer
    // handles are usable), then restore the user's OSC setting on guide end.
    [self kkInstallGuideOSCForcingOnHost:[(ShaderInspectorView *)
                                                 view timingGuideHost]
                                    view:view
                             elementKeys:[KKPlugin kkOSCElementKeysForCompounds:
                                                       oscCompounds]
                            nudgeParamID:kParamRenderNudge];

    [self kkWireStandardInspectorCallbacksForView:view
                                   uiStateParamID:kParamUIState
                               renderNudgeParamID:kParamRenderNudge
                                    dragUndoLabel:@"Adjust Shader"
                               detachedWindowSize:CGSizeMake(720.0, 460.0)];

    // Built-in "look" presets (Type + curated palette) for the shared Presets
    // popover, under this plugin's preset key (set by kkWire above, the key the
    // popover queries). Idempotent - re-registering replaces the same set.
    [[KKPresets shared] registerBuiltinPresets:ShaderBuiltinPresets()
                                  forPluginKey:[self presetPluginKey]];

    self.inspectorView = view;

    // Let the intro guide's closing step spotlight this effect's Help button
    // (owned by the plugin's logo banner, resolved live).
    __weak typeof(self) weakHelp = self;
    view.guideHelpButtonScreenRectProvider = ^NSRect {
      return [weakHelp helpButtonScreenRect];
    };

    if (!self.playheadPoller) {
      self.playheadPoller =
          [[KKPlayheadPoller alloc] initWithAPIManager:self.apiManager
                                          actionTarget:self
                                           renderCache:self.renderCache];
    }
    [self.playheadPoller setInspectorView:view];
    // The render tick may have established timing before the inspector
    // view existed (poller nil then, ensureRunning was a no-op nil-send).
    // Kick it now so the scrubber appears without needing a user scrub.
    if (self.renderCache.effectDurSec > 0.0)
      [self.playheadPoller ensureRunning];
    return view;
  }
  typedef NSView *(*ViewIMP)(id, SEL, UInt32);
  ViewIMP imp = (ViewIMP)[KKPlugin instanceMethodForSelector:_cmd];
  return imp(self, _cmd, parameterID);
}

- (NSArray<KKHelpGuide *> *)helpGuides {
  // The Introduction + Advanced Timing entries (copy, gating, completion
  // wiring) are identical across plugins, so the kit builds them. Shader only
  // supplies the canvas-reference gate (the final Basic step's viewer cutout
  // needs an OSC draw tick) and the live inspector.
  __weak typeof(self) weak = self;
  return [KKTimingGuide
      standardHelpGuidesForInspectorProvider:^KKTimelineInspectorView * {
        __strong typeof(weak) strong = weak;
        return strong.inspectorView;
      }
      enabledProvider:^BOOL {
        return ShaderHasCanvasReference();
      }];
}

- (NSNotificationName)helpGuideRefreshNotificationName {
  return kShaderOSCPositionNotification;
}

- (nullable NSView *)aiAccessoryView {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // Shared timeline docs now live in the kit framework bundle (so the kit
    // help window can render the same source); register them from there.
    [KKAIKnowledge registerSharedTimelineDocsWithBundle:
                       [NSBundle bundleForClass:[KKOnScreenControl class]]];
    [KKAIKnowledge
        registerBundleDocsWithName:@"Shader"
                            bundle:[NSBundle
                                       bundleForClass:[ShaderPlugin class]]
                      subdirectory:@"AIKnowledge"];
    // Shared on-screen-control docs live in the kit framework (flattened to its
    // Resources root). Filter to just the topics Shader actually uses - it has
    // no rotation OSC, so only the visibility doc.
    [KKAIKnowledge
        registerBundleDocsWithName:@"On-Screen Controls"
                            bundle:[NSBundle
                                       bundleForClass:[KKOnScreenControl class]]
                      subdirectory:nil
                      onlyTopicIDs:@[ @"visibility" ]];
  });

  NSString *productContext = RLoc(
      @"Shader, a Final Cut Pro generator that runs a Shadertoy-style GLSL "
      @"shader to build animated backgrounds. The look is driven by the shader "
      @"source (the \"Shader\" code lane); shared controls (Speed, Seed, "
      @"Grain) "
      @"are animated with the shared Keyframeless timeline (Basic and Advanced "
      @"timing, easing). Always refer to yourself as Shader. Detailed feature "
      @"information is in the reference docs below.",
      @"AI assistant product context for Shader plugin.");

  NSArray<NSArray<NSString *> *> *examples = @[
    @[
      RLoc(@"Warm sunset gradient", @"AI example chip: warm sunset gradient."),
      RLoc(@"Make a warm sunset mesh gradient.",
           @"AI example value: warm sunset gradient.")
    ],
    @[
      RLoc(@"Calm drifting wisps", @"AI example chip: calm drifting wisps."),
      RLoc(@"Use the Wisp style, slow and calm, in cool blues.",
           @"AI example value: calm drifting wisps.")
    ],
    @[
      RLoc(@"Keep one colour", @"AI example chip: keep one colour."),
      RLoc(@"How do I keep one colour and reroll the rest?",
           @"AI example value: keep one colour.")
    ],
    @[
      RLoc(@"What's Basic vs Advanced?",
           @"AI example chip: Basic vs Advanced timing question."),
      RLoc(@"What's the difference between Basic and Advanced timing?",
           @"AI example value: Basic vs Advanced timing question.")
    ],
  ];

  NSString *placeholder = RLoc(@"Ask a question or describe an animation…",
                               @"AI prompt field placeholder for Shader.");

  // Wire the "Keyframeless AI update available" banner: the popover fires this
  // when it opens, we run the standalone-helper update check (its own installer
  // + version, read by KKUpdateChecker) and push the result into the popover.
  // This is the one spot that links both KeyframelessKit and KeyframelessAI.
  [KKAIUpdate setCheckHandler:^{
    [[KKUpdateChecker shared] checkAIUpdateWithCompletion:^(BOOL avail) {
      KKUpdateChecker *checker = [KKUpdateChecker shared];
      [KKAIUpdate setAvailableVersion:checker.aiAvailableVersion
                             notesURL:checker.aiNotesURL.absoluteString];
    }];
  }];

  __weak typeof(self) weakSelf = self;
  return [KKAIBannerHost
      makePluginButtonWithProductContext:productContext
                            examplePairs:examples
                             placeholder:placeholder
                                   onRun:^(NSString *prompt) {
                                     __strong typeof(weakSelf) strong =
                                         weakSelf;
                                     if (!strong)
                                       return;
                                     [strong _runAIPrompt:prompt
                                           productContext:productContext];
                                   }];
}

- (void)_runAIPrompt:(NSString *)prompt
      productContext:(NSString *)productContext {
  [KKAIDraft setRouting:YES];
  [KKAIDraft setError:nil];

  // Read current timeline + clip duration inside an action scope.
  id<FxCustomParameterActionAPI_v4> readAct =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!readAct) {
    [KKAIDraft setRouting:NO];
    [KKAIDraft setError:@"Couldn't open the FCP action scope."];
    return;
  }
  [readAct startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSString *currentJSON =
      KKTimelineAICurrentJSON(getAPI, [ShaderPlugin availableLanes]);
  NSString *uiJson = KKReadCustomParamString(getAPI, kParamUIState);
  NSDictionary *uiState =
      (uiJson.length
           ? [NSJSONSerialization
                 JSONObjectWithData:[uiJson
                                        dataUsingEncoding:NSUTF8StringEncoding]
                            options:0
                              error:nil]
           : nil)
          ?: @{};
  NSInteger activeTab = [uiState[@"activeTab"] integerValue];
  NSString *currentMode = (activeTab == 1) ? @"Advanced" : @"Basic";
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  CMTime clipDur = kCMTimeZero;
  if (timingAPI)
    [timingAPI durationTimeForEffect:&clipDur];
  double clipDurSec = CMTimeGetSeconds(clipDur);
  if (clipDurSec <= 0 || isnan(clipDurSec))
    clipDurSec = 5.0;
  [readAct endAction:self];

  NSString *schema = ShaderAILaneSchemaText();

  __weak typeof(self) weakSelf = self;
  // Custom-only plugin: no Type/palette styling fast-path anymore, so the
  // prompt routes through the standard per-lane / Q&A pipeline.
  [KKAIPluginAgent
              runWithPrompt:prompt
             productContext:productContext
             laneSchemaText:schema
        currentTimelineJSON:currentJSON
        clipDurationSeconds:clipDurSec
       currentInspectorMode:currentMode
      supportsLayerCreation:NO
                 completion:^(KKAIPluginResult *result, NSError *err) {
                   dispatch_async(dispatch_get_main_queue(), ^{
                     __strong typeof(weakSelf) strong = weakSelf;
                     if (!strong)
                       return;
                     [KKAIDraft setRouting:NO];
                     if (err) {
                       KKLogError(@"AI[err] %@", err.localizedDescription);
                       [KKAIDraft setError:err.localizedDescription];
                       return;
                     }
                     if (!result) {
                       KKLogError(@"AI[err] empty result");
                       [KKAIDraft setError:@"Empty AI response."];
                       return;
                     }
                     if (result.kind == KKAIPluginResultKindAnswer) {
                       [KKAIDraft setAnswer:result.answer];
                       return;
                     }
                     // The merge also snaps final keyposes to the last
                     // renderable frame (FCP's last frame is one frame before
                     // the clip end, so a keypose at 1.0 is never reached) -
                     // clipDur from the prompt, frameDur from the process
                     // cache.
                     NSString *merged = KKTimelineAIMergeMutationJSON(
                         currentJSON, result.mutationJSON, clipDurSec,
                         KKProcessFrameDurationSeconds());
                     if (!merged) {
                       KKLogError(@"AI[err] merge returned nil");
                       [KKAIDraft
                           setError:
                               @"AI returned an invalid timeline mutation."];
                       return;
                     }
                     id<FxCustomParameterActionAPI_v4> writeAct =
                         [strong.apiManager
                             apiForProtocol:@protocol(
                                                FxCustomParameterActionAPI_v4)];
                     if (!writeAct) {
                       [KKAIDraft
                           setError:@"Couldn't open the FCP action scope to "
                                    @"apply the mutation."];
                       return;
                     }
                     [writeAct startAction:strong];
                     id<FxParameterSettingAPI_v5> setAPI = [strong.apiManager
                         apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
                     KKWriteCustomParamString(setAPI, merged,
                                              kKKParamTimelineData);

                     // If the new timeline isn't representable in Basic, force
                     // the inspector to Advanced so the user sees the actual
                     // structure. Keeping the activeTab on Basic when the data
                     // is Advanced-only shows the compatibility banner instead
                     // of the new animation.
                     KKTimeline *resultTimeline =
                         [KKTimeline timelineFromJSON:merged];
                     double mergeFrameDur = KKProcessFrameDurationSeconds();
                     double aiEndFrac =
                         (clipDurSec > 0.0 && mergeFrameDur > 0.0 &&
                          mergeFrameDur < clipDurSec)
                             ? (clipDurSec - mergeFrameDur) / clipDurSec
                             : 1.0;
                     if (resultTimeline && !KKTimelineIsBasicCompatible(
                                               resultTimeline, aiEndFrac)) {
                       [strong patchUIStateKey:@"activeTab"
                                         value:@(1)
                                       paramID:kParamUIState];
                     }
                     [writeAct endAction:strong];
                     [KKAIDraft setAnswer:nil];
                     [KKAIDraft clearPrompt];
                   });
                 }];
}

- (nullable NSString *)helpHeaderTitle {
  return RLoc(@"Shader", @"Help section title (plugin name).");
}

- (nullable NSImage *)helpHeaderIcon {
  return [NSImage imageWithSystemSymbolName:@"square.dotted"
                   accessibilityDescription:nil];
}

- (NSArray<KKHelpSection *> *)helpSections {
  // Quick reference: short overview + parameter list (single-sourced from
  // mesh.md), then an on-screen-control shortcuts table.
  KKHelpSection *overview = [self
      helpSectionFromKnowledgeTopic:@"mesh"
                              title:RLoc(@"Shader",
                                         @"Help section title (plugin name).")
                             symbol:@"square.dotted"
                          localizer:^NSString *(NSString *tip) {
                            return RLoc(tip, @"Shader help tip (from "
                                             @"AIKnowledge markdown).");
                          }];

  NSMutableArray<KKHelpShortcut *> *rows =
      [[KKPlugin sharedOnScreenControlShortcuts] mutableCopy];

  KKHelpSection *shortcuts =
      [KKHelpSection sectionWithTitle:RLoc(@"On-screen control shortcuts",
                                           @"Help section title.")
                            tipMarkup:nil
                            shortcuts:rows];
  shortcuts.icon = [NSImage imageWithSystemSymbolName:@"hand.point.up.left"
                             accessibilityDescription:nil];

  return @[ overview, shortcuts ];
}

@end
