/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "MeshColorSpace.h"
#import "MeshInspectorView+Guides.h"
#import "MeshInspectorView.h"
#import "MeshLocalized.h"
#import "MeshMiniViewerRenderer.h" // per-instance mini-viewer rendezvous paths
#import "MeshOSCRadiusMath.h"
#import "Plugin_Private.h"
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKColorLanes.h>
#import <KeyframelessKit/KKDataBlob.h>
#import <KeyframelessKit/KKHelpSection.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKPlugin+InspectorCallbacks.h>
#import <KeyframelessKit/KKTimelineAIMerge.h>
#import <KeyframelessKit/KKTimelineInspectorView+Guide.h> // guide help-button provider
#import <KeyframelessKit/KKTimingCompat.h>
#import <KeyframelessKit/KKTimingStage.h>
@import KeyframelessAI;

/// Plain-text coordinate-space description used by the AI agent's value
/// resolution pass. Kept tight on purpose: this is the only context the
/// values-pass LLM call sees, alongside the user's prompt. No timing words,
/// no in/out, no Basic/Advanced - just lanes and their numeric ranges.
static NSString *_MeshAILaneSchemaText(void) {
  return @"Lane labels and value spaces. This is an animated mesh gradient "
         @"generator: colour spots drift on procedural paths and are blended "
         @"by distance, warped by distortion + swirl, with a film-grain "
         @"finish.\n\n"
         @"- \"Distortion\": single value, percent 0..100. Organic noise warp "
         @"of the whole field (0 = calm/smooth, higher = more churning "
         @"folds). Default 80.\n"
         @"- \"Swirl\": single value, percent 0..100. Vortex twist around the "
         @"centre (0 = none, higher = more spiral). Default 10.\n"
         @"- \"Speed\": single value, 0..3 multiplier of the animation rate "
         @"(1 = normal, 0 = frozen, 2 = twice as fast). Animatable. "
         @"Default 1.\n"
         @"- \"Seed\": single integer, the animation start-frame / layout "
         @"variation (any value; re-roll for a different look). NOT "
         @"animatable - one constant for the clip. Default 0.\n"
         @"- \"Grain Mixer\": single value, percent 0..100. Grain distortion "
         @"at the colour-spot edges (0 = clean edges, higher = grainier "
         @"blend). Default 0.\n"
         @"- \"Grain\": single value, percent 0..100. Post film-grain overlay "
         @"(0 = clean, higher = more grain). Default 6.\n"
         @"- \"Color 1\", \"Color 2\", ... : the gradient's colour spots, each "
         @"[r, g, b, a] in sRGB 0..1. The shader places and animates the "
         @"spots, so only the colours are set (no positions). There are "
         @"several; set as many as the user asks for. Defaults are a "
         @"purple / pink / blue / teal palette.\n"
         @"- \"Type\": the gradient style. A structural choice (NOT animated), "
         @"stored as an index: 0 = Mesh (the only real option today; "
         @"index 1 is a disabled placeholder). Default 0.\n";
}

@implementation MeshPlugin (CustomUI)

- (BOOL)usesMotionBlur {
  return YES;
}

+ (NSArray<KKLane *> *)availableLanes {
  // Lane order (top-to-bottom default): Type, then this gradient type's
  // options, then the colour swatches last (colours are dynamic - users
  // add/remove them). Users can reorder in the inspector.
  NSMutableArray<KKLane *> *lanes = [NSMutableArray array];

  // Mesh Gradient (paper-design port, Apache-2.0): a flat list of colour
  // swatches placed procedurally by the shader, plus scalar controls. Type is
  // the scaffold pill for future gradient types - the kit only renders a pill
  // at 2+ choices, so it carries Mesh Gradient plus a disabled-in-spirit
  // "Coming Soon" placeholder (the render ignores the value). Replace the
  // placeholder with the real second type when it lands.
  KKLane *type = [KKLane laneWithLabel:@"Type"];
  type.valueType = KKLaneValueTypeFloat;
  type.choiceLabels = @[ @"Mesh", @"Coming Soon" ];
  type.componentMin = @[ @0.0 ];
  type.componentMax = @[ @1.0 ];
  type.integerValued = YES;
  type.animatable = NO;
  type.enabled = NO;
  type.categoryKey = @"Core";
  type.categorySymbol = @"circle.dotted";
  [type insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0.0 ]]];
  [lanes addObject:type];

  // Options for the Mesh Gradient, gated to the real type. Distortion = organic
  // noise warp; Swirl = vortex warp; Speed = motion rate; Seed = layout
  // variation; Grain Mixer = grain at the spot edges; Grain = post overlay.
  // %-units store 0..100 (the shader wants 0..1); Speed is a raw multiplier;
  // Seed is a non-animatable integer (start-time offset) with a dice field, and
  // takes any value - the slider range is nominal, the field/dice sets it.
  struct {
    NSString *label;
    double def, min, max;
    NSString *unit; // nil = raw number (no % scaling)
    BOOL animatable;
    BOOL seedField;
  } controls[] = {
      {@"Distortion", KK_MESH_GRAD_DEFAULT_DISTORTION * 100.0, 0.0, 100.0, @"%",
       YES, NO},
      {@"Swirl", KK_MESH_GRAD_DEFAULT_SWIRL * 100.0, 0.0, 100.0, @"%", YES, NO},
      {@"Speed", KK_MESH_GRAD_DEFAULT_SPEED, 0.0, 3.0, nil, YES, NO},
      {@"Seed", KK_MESH_GRAD_DEFAULT_SEED, 0.0, 1000000.0, nil, NO, YES},
      {@"Grain Mixer", KK_MESH_GRAD_DEFAULT_GRAINMIXER * 100.0, 0.0, 100.0,
       @"%", YES, NO},
      {@"Grain", KK_MESH_DEFAULT_GRAIN * 100.0, 0.0, 100.0, @"%", YES, NO},
  };
  for (unsigned s = 0; s < sizeof(controls) / sizeof(controls[0]); s++) {
    KKLane *lane = [KKLane laneWithLabel:controls[s].label];
    lane.valueType = KKLaneValueTypeFloat;
    lane.componentMin = @[ @(controls[s].min) ];
    lane.componentMax = @[ @(controls[s].max) ];
    if (controls[s].unit)
      lane.componentUnits = @[ controls[s].unit ];
    lane.animatable = controls[s].animatable;
    lane.seedField = controls[s].seedField;
    lane.integerValued = controls[s].seedField; // seed is an integer
    lane.enabled = NO;
    lane.categoryKey = @"Core";
    lane.categorySymbol = @"circle.dotted";
    lane.visibleWhenLabel = @"Type";
    lane.visibleWhenValues = @[ @0 ];
    [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                          values:@[ @(controls[s].def) ]]];
    [lanes addObject:lane];
  }

  // Colour swatches LAST (dynamic - users add/remove): one [r, g, b, a] lane
  // each, seeded from the default palette. The shader places the spots, so
  // there are no positions to edit, just the colours.
  for (int i = 0; i < KK_MESH_COLOR_COUNT; i++) {
    KKLane *color = [KKLane laneWithLabel:MeshColorLabel(i)];
    color.valueType = KKLaneValueTypeColor;
    color.componentMin = @[ @0.0, @0.0, @0.0, @0.0 ];
    color.componentMax = @[ @1.0, @1.0, @1.0, @1.0 ];
    color.animatable = YES; // colours can be keyframed
    color.enabled = NO;
    color.categoryKey = @"Colors";
    color.categorySymbol = @"paintpalette";
    color.visibleWhenLabel = @"Type";
    color.visibleWhenValues = @[ @0 ];
    const float *c = kMeshDefaultColorsSRGB[i];
    [color insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                           values:@[
                                             @(c[0]), @(c[1]), @(c[2]), @(c[3])
                                           ]]];
    [lanes addObject:color];
  }

  return lanes;
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
    // constant", radius reads default 20, crop reads [1,1,0,0] → handle is
    // visible at the canvas TR regardless of saved state. parameterChanged
    // eventually catches up, but only after a redraw nudge.
    MeshSetTimelineSnapshot(timeline);

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
        MeshSetFrameDurationSeconds(seedFrameDurSec);
    }

    // Per-instance OSC-visibility state: mint the UUID here (inside the action
    // scope where the setting API resolves) and seed the master tick.
    KKInstanceStateEnsureForAPI(self.apiManager).oscMasterVisible =
        oscMasterVisible;

    [actionAPI endAction:self];

    NSArray<KKLane *> *available = [MeshPlugin availableLanes];
    MeshInspectorView *view =
        [[MeshInspectorView alloc] initWithAPIManager:self.apiManager
                                          loopEnabled:loopEnabled
                                maintainTimingEnabled:st.maintainTimingEnabled
                                            activeTab:activeTab
                                       availableLanes:available
                                             timeline:timeline];
    // Per-instance rendezvous paths (keyed by the instance UUID minted above)
    // so two stacked Mesh clips read/write distinct /tmp files instead of the
    // clip below showing the top clip's source in its mini-viewer.
    NSString *instUUID = KKInstanceUUIDForAPI(self.apiManager);
    view.miniViewerDescriptorPath =
        MeshMiniViewerDescriptorPathForUUID(instUUID);
    view.miniViewerRequestPath = MeshMiniViewerRequestPathForUUID(instUUID);
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

    // On-screen-control visibility: master tick + per-element pills (Radius,
    // Crop) + opt-click-hide + opt-reveal. Shared glue in KKPlugin
    // (OSCVisibility); the renderer is the view's mini-viewer delegate.
    KKMiniViewerRenderer *oscRenderer =
        (KKMiniViewerRenderer *)view.miniViewerDelegate;
    NSArray<NSArray<NSString *> *> *oscCompounds =
        @[ @[ @"Radius" ], @[ @"Crop" ] ];
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
    [self kkInstallGuideOSCForcingOnHost:[(MeshInspectorView *)
                                                 view timingGuideHost]
                                    view:view
                             elementKeys:[KKPlugin kkOSCElementKeysForCompounds:
                                                       oscCompounds]
                            nudgeParamID:kParamRenderNudge];

    [self kkWireStandardInspectorCallbacksForView:view
                                   uiStateParamID:kParamUIState
                               renderNudgeParamID:kParamRenderNudge
                                    dragUndoLabel:@"Adjust Radius"
                               detachedWindowSize:CGSizeMake(720.0, 460.0)];

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
  // wiring) are identical across plugins, so the kit builds them. Mesh only
  // supplies the canvas-reference gate (the final Basic step's viewer cutout
  // needs an OSC draw tick) and the live inspector.
  __weak typeof(self) weak = self;
  return [KKTimingGuide
      standardHelpGuidesForInspectorProvider:^KKTimelineInspectorView * {
        __strong typeof(weak) strong = weak;
        return strong.inspectorView;
      }
      enabledProvider:^BOOL {
        return MeshHasCanvasReference();
      }];
}

- (NSNotificationName)helpGuideRefreshNotificationName {
  return kMeshOSCPositionNotification;
}

- (nullable NSView *)aiAccessoryView {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // Shared timeline docs now live in the kit framework bundle (so the kit
    // help window can render the same source); register them from there.
    [KKAIKnowledge registerSharedTimelineDocsWithBundle:
                       [NSBundle bundleForClass:[KKOnScreenControl class]]];
    [KKAIKnowledge
        registerBundleDocsWithName:@"Mesh"
                            bundle:[NSBundle bundleForClass:[MeshPlugin class]]
                      subdirectory:@"AIKnowledge"];
    // Shared on-screen-control docs live in the kit framework (flattened to its
    // Resources root). Filter to just the topics Mesh actually uses - it has
    // no rotation OSC, so only the visibility doc.
    [KKAIKnowledge
        registerBundleDocsWithName:@"On-Screen Controls"
                            bundle:[NSBundle
                                       bundleForClass:[KKOnScreenControl class]]
                      subdirectory:nil
                      onlyTopicIDs:@[ @"visibility" ]];
  });

  NSString *productContext = RLoc(
      @"Mesh, a Final Cut Pro plugin that rounds corners, crops with a box, "
      @"and animates with the shared Keyframeless timeline system (Basic and "
      @"Advanced timing, easing, motion blur). Always refer to yourself as "
      @"Mesh. Detailed feature information is in the reference docs below.",
      @"AI assistant product context for Mesh plugin.");

  NSArray<NSArray<NSString *> *> *examples = @[
    @[
      RLoc(@"Animate radius 0→100% with bounce",
           @"AI example chip: animate radius with bounce."),
      RLoc(@"Animate the radius from 0% to 100% over 1 second with bounce.",
           @"AI example value: animate radius with bounce.")
    ],
    @[
      RLoc(@"Crop to top right", @"AI example chip: crop to top right."),
      RLoc(@"Crop to the top right quadrant.",
           @"AI example value: crop to top right.")
    ],
    @[
      RLoc(@"Reveal then hide", @"AI example chip: in/out crop animation."),
      RLoc(@"Animate the crop in from the top right and back out at the "
           @"end, while the radius rounds over the whole clip.",
           @"AI example value: in/out crop animation.")
    ],
    @[
      RLoc(@"What's Basic vs Advanced?",
           @"AI example chip: Basic vs Advanced timing question."),
      RLoc(@"What's the difference between Basic and Advanced timing?",
           @"AI example value: Basic vs Advanced timing question.")
    ],
  ];

  NSString *placeholder = RLoc(@"Ask a question or describe an animation…",
                               @"AI prompt field placeholder for Mesh.");

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
      KKTimelineAICurrentJSON(getAPI, [MeshPlugin availableLanes]);
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

  NSString *schema = _MeshAILaneSchemaText();

  __weak typeof(self) weakSelf = self;
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
  return RLoc(@"Mesh", @"Help section title (plugin name).");
}

- (nullable NSImage *)helpHeaderIcon {
  return [NSImage imageWithSystemSymbolName:@"square.dotted"
                   accessibilityDescription:nil];
}

- (NSArray<KKHelpSection *> *)helpSections {
  // Quick reference: short overview + parameter list (single-sourced from
  // mesh.md), then an on-screen-control shortcuts table. The per-property
  // deep docs (radius/box-crop.md) stay AI-only.
  KKHelpSection *overview = [self
      helpSectionFromKnowledgeTopic:@"mesh"
                              title:RLoc(@"Mesh",
                                         @"Help section title (plugin name).")
                             symbol:@"square.dotted"
                          localizer:^NSString *(NSString *tip) {
                            return RLoc(tip, @"Mesh help tip (from "
                                             @"AIKnowledge markdown).");
                          }];

  NSMutableArray<KKHelpShortcut *> *rows = [@[
    [KKHelpShortcut
        shortcutWithKeysMarkup:RLoc(@"Drag the Radius handle",
                                    @"Shortcut keys.")
                    descMarkup:RLoc(@"Set the corner rounding on the canvas",
                                    @"Help shortcut.")],
    [KKHelpShortcut
        shortcutWithKeysMarkup:RLoc(@"Drag a Crop edge or corner",
                                    @"Shortcut keys.")
                    descMarkup:RLoc(@"Crop from that side", @"Help shortcut.")],
  ] mutableCopy];
  [rows addObjectsFromArray:[KKPlugin sharedOnScreenControlShortcuts]];

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
