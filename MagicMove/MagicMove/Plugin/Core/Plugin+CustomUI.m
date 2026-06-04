/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "MagicMoveLocalized.h"
#import "MagicMoveMiniCanvasRenderer.h"
#import "OSC.h"
#import "Plugin_Private.h"
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KeyframelessKit.h>
@import KeyframelessAI;

/// MagicMove draws Position + Rotation on-screen controls, so it opts into the
/// inspector's "On-Screen Controls" visibility row (other plugins default off).
@interface MagicMoveInspectorView : KKTimelineInspectorView
@end

@implementation MagicMoveInspectorView
- (BOOL)showsOSCVisibilityRow {
  return YES;
}
@end

/// Plain-text coordinate-space description for the AI agent's value-resolution
/// pass - the only context that LLM call sees alongside the user's prompt. Just
/// lanes and their numeric ranges; no timing words.
static NSString *_MagicMoveAILaneSchemaText(void) {
  NSMutableString *s = [NSMutableString string];
  [s appendString:@"Lane labels and coordinate spaces:\n\n"];
  [s appendString:
          @"- \"Position\": two numeric components [x, y].\n"
          @"    Normalised clip space, 0..1, where 0.5 = centre of the frame.\n"
          @"    x: 0 = left edge, 1 = right edge.\n"
          @"    y: 0 = bottom, 1 = top (Y points UP).\n"
          @"    Off-frame values (< 0 or > 1) are allowed, so the clip can "
          @"start or end fully outside the frame.\n"
          @"    Default value: [0.5, 0.5] (centred).\n"
          @"\n"
          @"- \"Scale\": two numeric components [x, y], whole percentages of "
          @"the clip's own size.\n"
          @"    100 = original size. Floored at 0, no upper limit. Never "
          @"negative (use Rotation to flip).\n"
          @"    Default value: [100, 100].\n"
          @"\n"
          @"- \"Rotation\": three numeric components [x, y, z], in DEGREES.\n"
          @"    z = the in-plane spin (clockwise positive) - this is the usual "
          @"rotation. x and y tilt the clip in 3D.\n"
          @"    Values accumulate past 360 (720 = two full turns).\n"
          @"    Default value: [0, 0, 0].\n"
          @"\n"
          @"- \"Opacity\": one numeric component, whole percentage 0..100.\n"
          @"    100 = fully opaque, 0 = invisible.\n"
          @"    Default value: 100.\n"
          @"\n"
          @"- \"Anchor\": two numeric components [x, y] - the pivot that "
          @"Rotation and Scale swing around.\n"
          @"    Same normalised space as Position relative to the clip: "
          @"[0.5, 0.5] = clip centre, [0, 0] = bottom-left corner, "
          @"[1, 1] = top-right corner.\n"
          @"    Default value: [0.5, 0.5] (centre). Only change it when the "
          @"user wants rotation/scale to pivot off-centre.\n"];
  return s;
}

@implementation MagicMovePlugin (CustomUI)

- (BOOL)usesMotionBlur {
  return YES;
}

- (KKClipWrappingMode)clipWrappingMode {
  return KKClipWrappingModeCompound;
}

+ (NSArray<KKLane *> *)availableLanes {
  KKLane *position = [KKLane laneWithLabel:@"Position"];
  position.valueType = KKLaneValueTypeGeneric;
  // Position is allowed off-canvas, so no min/max - empty = unconstrained.
  position.componentMin = @[];
  position.componentMax = @[];
  position.componentUnits = @[ @"px", @"px" ];
  position.componentLabels = @[ @"X", @"Y" ];
  // 2D spatial path: keyposes can be smooth (curved). Lights the per-keypose
  // corner/smooth toggle in the value popover and curves the motion path.
  position.spatialCurvable = YES;
  [position insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0.5, @0.5 ]]];

  KKLane *rotation = [KKLane laneWithLabel:@"Rotation"];
  rotation.valueType = KKLaneValueTypeAngle;
  // Knobs cover one revolution visually but model values accumulate past
  // 360° (FCP behaviour - 2 full turns = 720°). Empty min/max = unconstrained.
  rotation.componentMin = @[];
  rotation.componentMax = @[];
  rotation.componentUnits = @[ @"°", @"°", @"°" ];
  rotation.componentLabels = @[ @"X", @"Y", @"Z" ];
  // Standard 3D-axis tint convention (Motion / Blender / Maya): X=red,
  // Y=green, Z=blue. Slightly desaturated so they don't shout against the
  // inspector background.
  rotation.componentLabelColors = @[
    [NSColor colorWithSRGBRed:0.95 green:0.35 blue:0.35 alpha:1.0],
    [NSColor colorWithSRGBRed:0.40 green:0.85 blue:0.45 alpha:1.0],
    [NSColor colorWithSRGBRed:0.40 green:0.60 blue:0.95 alpha:1.0],
  ];
  [rotation insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                            values:@[ @0.0, @0.0, @0.0 ]]];

  KKLane *scale = [KKLane laneWithLabel:@"Scale"];
  scale.valueType = KKLaneValueTypeFloat;
  // Percentage of the clip's own size; 100 = identity. Floor at 0 (no flip),
  // no upper cap (empty max = unconstrained), same as Position's open fields.
  scale.componentMin = @[ @0.0, @0.0 ];
  scale.componentMax = @[];
  scale.componentUnits = @[ @"%", @"%" ];
  scale.componentLabels = @[ @"X", @"Y" ];
  scale.integerValued = YES; // whole percentages only

  // Aspect lock: link glyph in the value popover, on by default (most apps
  // constrain proportions out of the box). Preserves the current X:Y ratio.
  scale.aspectLinkable = YES;
  scale.aspectLinked = YES;
  [scale insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                         values:@[ @100.0, @100.0 ]]];

  KKLane *opacity = [KKLane laneWithLabel:@"Opacity"];
  opacity.valueType = KKLaneValueTypeFloat;
  // Percentage like FCP's opacity control; 100 = fully opaque. Hard 0-100
  // bounds (unlike Scale's open top) - there's no meaningful overshoot.
  opacity.componentMin = @[ @0.0 ];
  opacity.componentMax = @[ @100.0 ];
  opacity.componentUnits = @[ @"%" ];
  opacity.integerValued = YES; // whole percentages only
  [opacity insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @100.0 ]]];

  KKLane *anchor = [KKLane laneWithLabel:@"Anchor"];
  anchor.valueType = KKLaneValueTypeGeneric;
  // The pivot rotation and scale swing around, in the same normalized object
  // space as Position (0.5,0.5 = clip center). No min/max - the anchor can sit
  // off the clip just like Position can go off-canvas.
  anchor.componentMin = @[];
  anchor.componentMax = @[];
  anchor.componentUnits = @[ @"px", @"px" ];
  anchor.componentLabels = @[ @"X", @"Y" ];
  [anchor insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0.5, @0.5 ]]];

  return @[ position, scale, rotation, opacity, anchor ];
}

+ (NSArray<NSArray<NSString *> *> *)oscCompounds {
  return @[
    @[ @"Position" ],
    @[ @"Path" ],
    @[ @"Scale" ],
    @[ @"Rotation", @"Rotation.X", @"Rotation.Y", @"Rotation.Z" ],
    @[ @"Anchor" ],
  ];
}

+ (NSArray<NSString *> *)oscElementKeys {
  NSMutableArray<NSString *> *flat = [NSMutableArray array];
  for (NSArray<NSString *> *c in [self oscCompounds])
    [flat addObjectsFromArray:c];
  return flat;
}

- (void)applyOSCElementsFromUIState:(NSDictionary *)uiState {
  [self kkApplyOSCVisibilityFromState:uiState
                          elementKeys:[MagicMovePlugin oscElementKeys]
                             renderer:self.miniCanvasRenderer];
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID != kParamInspectorUI) {
    typedef NSView *(*ViewIMP)(id, SEL, UInt32);
    ViewIMP imp = (ViewIMP)[KKPlugin instanceMethodForSelector:_cmd];
    return imp(self, _cmd, parameterID);
  }

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];

  KKInspectorPersistedState *st =
      [self kkReadInspectorPersistedStateWithGetAPI:getAPI
                                     uiStateParamID:kParamUIState];
  BOOL loopEnabled = st.loopEnabled;
  NSInteger activeTab = st.activeTab;
  BOOL oscMasterVisible = st.oscMasterVisible;
  KKMiniCanvasRenderMode renderMode = (KKMiniCanvasRenderMode)st.renderMode;
  BOOL motionBlurEnabled = st.motionBlurEnabled;
  double motionBlurShutterAngle = st.motionBlurShutterAngle;
  NSInteger motionBlurSamples = st.motionBlurSamples;
  NSInteger motionBlurMode = st.motionBlurMode;
  NSDictionary *uiState = st.uiState;
  KKTimeline *timeline = [self timelineStampedWithClipDuration:st.timeline];

  // Cold-boot seed for the OSC. Without this the first drawOSC tick after FCP
  // relaunch reads nil → handle snaps to (0.5, 0.5) regardless of saved state.
  KKSetProcessTimelineSnapshot(timeline);
  // Per-instance OSC visibility lives in KKPluginInstanceState (the OSC reads
  // it via the shared kKKParamInstanceID UUID, NOT a process singleton, so two
  // instances on one clip stay independent). Ensure mints the UUID here, inside
  // the action scope where the setting API resolves.
  KKPluginInstanceState *instState =
      KKInstanceStateEnsureForAPI(self.apiManager);
  instState.oscMasterVisible = oscMasterVisible;

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
      KKSetProcessFrameDurationSeconds(seedFrameDurSec);
  }

  [actionAPI endAction:self];

  NSArray<KKLane *> *available = [MagicMovePlugin availableLanes];
  KKTimelineInspectorView *view =
      [[MagicMoveInspectorView alloc] initWithAPIManager:self.apiManager
                                             loopEnabled:loopEnabled
                                               activeTab:activeTab
                                          availableLanes:available
                                                timeline:timeline];

  if (!self.miniCanvasRenderer) {
    self.miniCanvasRenderer = [[MagicMoveMiniCanvasRenderer alloc] init];
  }
  self.miniCanvasRenderer.timeline = timeline;
  self.miniCanvasRenderer.handlesHidden = !oscMasterVisible;
  [self applyOSCElementsFromUIState:uiState];
  // Wire the master tick + per-element pills + mini-canvas opt-click in one
  // call (shared glue in KKPlugin (OSCVisibility)).
  [self kkWireOSCVisibilityForView:view
                          renderer:self.miniCanvasRenderer
                         compounds:[MagicMovePlugin oscCompounds]
                           paramID:kParamUIState];
  view.miniCanvasDelegate = self.miniCanvasRenderer;
  // Per-instance rendezvous paths (keyed by the instance UUID minted above) so
  // two stacked MagicMove clips read/write distinct /tmp files instead of the
  // top clip flickering the one below it.
  NSString *instUUID = KKInstanceUUIDForAPI(self.apiManager);
  view.miniCanvasDescriptorPath =
      MagicMoveMiniCanvasDescriptorPathForUUID(instUUID);
  view.miniCanvasRequestPath = MagicMoveMiniCanvasRequestPathForUUID(instUUID);
  if (seedClipDurSec > 0)
    [view setClipDurationSeconds:seedClipDurSec];
  if (seedFrameDurSec > 0)
    [view setFrameDurationSeconds:seedFrameDurSec];
  [view setMotionBlurEnabled:motionBlurEnabled];
  [view setMotionBlurShutterAngle:motionBlurShutterAngle
                          samples:motionBlurSamples];
  [view setMotionBlurMode:(KKMotionBlurMode)motionBlurMode];
  [view setRenderMode:renderMode];
  [view setOSCVisible:oscMasterVisible];

  [self kkWireStandardInspectorCallbacksForView:view
                                 uiStateParamID:kParamUIState
                             renderNudgeParamID:kParamRenderNudge
                                  dragUndoLabel:@"Adjust Magic Move"
                             detachedWindowSize:CGSizeMake(720.0, 460.0)];
  // Mini-canvas motion-path edits (anchor / handle drag) persist the whole
  // blob through the same writer as inspector timeline mutations.
  self.miniCanvasRenderer.onTimelinePersist = view.onTimelineMutated;

  // Rotate-with-motion: per-interval toggle on the Position lane's gap
  // popovers (curve + hold-modulation, Advanced + Basic). Persisted under
  // the interval's userProperties dict. Disabled (and ignored) when the
  // gap has no actual motion - linear curves with no modulation produce no
  // tangent to rotate along.
  view.gapPopoverExtraRows = ^NSArray<NSView *> *(
      KKGapPopoverPhase phase, NSString *laneLabel, KKInterval *rep,
      KKGapIntervalReader read, KKGapIntervalMutator mutate) {
    if (![laneLabel isEqualToString:@"Position"])
      return @[];
    KKCheckboxRowView *row = [[KKCheckboxRowView alloc]
        initWithTitle:MMLoc(@"Rotate with motion",
                            @"Gap popover toggle: align rotation to the "
                            @"position-curve tangent during this gap.")
        tooltip:nil
        binding:^BOOL {
          KKInterval *live = read();
          return [live userBoolForKey:@"rotateWithMotion" default:NO];
        }
        disabledBinding:^BOOL {
          // Rotate-with-motion only needs the position to MOVE - the lean is
          // driven by acceleration, so a modulated gap's wobble drives it just
          // as well as a path tangent. Disable only when the gap is genuinely
          // static:
          // - Hold-modulation gaps wobble only if they actually have
          // modulation;
          //   a plain static hold does not move, so disable that.
          // - Transition gaps move unless they holdsFlat (Basic per-property
          //   phase-off) with no modulation to wobble them.
          KKInterval *live = read();
          BOOL hasModulation = (live.modulation != KKIntervalModulationNone);
          if (phase == KKGapPopoverPhaseHoldModulation)
            return !hasModulation;
          return live.holdsFlat && !hasModulation;
        }
        onToggle:^(BOOL isOn) {
          mutate(^(KKInterval *iv) {
            [iv setUserBool:isOn forKey:@"rotateWithMotion"];
          });
        }];
    return @[ row ];
  };

  self.inspectorView = view;
  if (!self.playheadPoller) {
    self.playheadPoller =
        [[KKPlayheadPoller alloc] initWithAPIManager:self.apiManager
                                        actionTarget:self
                                         renderCache:self.renderCache];
  }
  [self.playheadPoller setInspectorView:view];
  // The render tick may have already established timing before the
  // inspector view existed (poller was nil then, so ensureRunning was a
  // no-op nil-send). Kick it now so the scrubber appears without needing
  // the user to scrub.
  if (self.renderCache.effectDurSec > 0.0)
    [self.playheadPoller ensureRunning];
  return view;
}

- (NSArray<KKHelpSection *> *)helpSections {
  KKHelpSection *magicMove = [KKHelpSection
      sectionWithTitle:@"Magic Move"
             tipMarkup:@[
               (@"<accent>Position</accent>, <accent>Scale</accent>, and "
                @"<accent>Rotation</accent> all animate from the clip's "
                @"natural state to the values set here - drive each one on "
                @"canvas via the <symbol arcade.stick.console.fill /> "
                @"on-screen control."),
               (@"<accent>Opacity</accent> animates the same way, from a "
                @"slider in the inspector."),
               (@"<accent>Anchor Point</accent> sets the pivot rotations "
                @"and scale swing around."),
               (@"Toggle <accent>Rotate with Motion</accent> in the gap "
                @"popover to align the clip's heading with its motion path."),
               (@"When the Position lane has multiple keyposes a bezier "
                @"<accent>path</accent> draws between them on canvas - "
                @"reshape it by dragging anchors or their handles."),
               (@"Stacking with <accent>Crop</accent> or similar spatial "
                @"effects? Place them <accent>below</accent> Magic Move in "
                @"the inspector so they apply to the clip first, then move "
                @"with it - otherwise they anchor to the canvas and clip "
                @"around the moved content."),
             ]
             shortcuts:@[
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>Shift</kbd> + drag"
                               descMarkup:@"Constrain motion to X or Y axis"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌃</kbd> + drag"
                                           descMarkup:@"Disable snapping"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>⌥</kbd>"
                               descMarkup:@"Reveal X and Y rotation rings"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>Shift</kbd> + scale"
                               descMarkup:@"Lock scale to X or Y axis"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"Double-click scale ring"
                                           descMarkup:@"Reset to 1:1"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"Double-click path anchor"
                               descMarkup:@"Toggle between smooth and corner"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌥</kbd> + click "
                                                      @"path anchor"
                                           descMarkup:@"Delete the anchor"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌥</kbd> + click "
                                                      @"path curve"
                                           descMarkup:@"Insert a new anchor "
                                                      @"at the nearest spot"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌥</kbd> + drag "
                                                      @"handle"
                                           descMarkup:@"Break handle "
                                                      @"symmetry (move "
                                                      @"independently)"],
             ]];
  magicMove.icon =
      [NSImage imageWithSystemSymbolName:@"circle.dotted.and.circle"
                accessibilityDescription:nil];
  return @[ magicMove ];
}

- (nullable NSView *)aiAccessoryView {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    [KKAIKnowledge registerSharedTimelineDocs];
    [KKAIKnowledge
        registerBundleDocsWithName:@"Magic Move"
                            bundle:[NSBundle
                                       bundleForClass:[MagicMovePlugin class]]
                      subdirectory:@"AIKnowledge"];
    // Shared on-screen-control docs live in the kit framework (flattened to its
    // Resources root). Magic Move uses the rotation gizmo + the visibility
    // system, so expose just those two topics.
    [KKAIKnowledge
        registerBundleDocsWithName:@"On-Screen Controls"
                            bundle:[NSBundle
                                       bundleForClass:[KKOnScreenControl class]]
                      subdirectory:nil
                      onlyTopicIDs:@[ @"visibility", @"rotation" ]];
  });

  NSString *productContext = MMLoc(
      @"Magic Move, a Final Cut Pro plugin that animates a clip's position, "
      @"scale, rotation, and opacity around an adjustable anchor point, using "
      @"the shared Keyframeless timeline system (Basic and Advanced timing, "
      @"easing, motion blur). Always refer to yourself as Magic Move. Detailed "
      @"feature information is in the reference docs below.",
      @"AI assistant product context for Magic Move plugin.");

  NSArray<NSArray<NSString *> *> *examples = @[
    @[
      MMLoc(@"Slide in from the left",
            @"AI example chip: slide in from the left."),
      MMLoc(@"Animate the clip sliding in from off the left edge to the "
            @"centre over the first second.",
            @"AI example value: slide in from the left.")
    ],
    @[
      MMLoc(@"Spin once", @"AI example chip: spin once."),
      MMLoc(@"Spin the clip one full turn over the whole duration.",
            @"AI example value: spin once.")
    ],
    @[
      MMLoc(@"Pop in with a bounce", @"AI example chip: pop in with a bounce."),
      MMLoc(@"Scale the clip from 0% up to 100% with a bounce at the start.",
            @"AI example value: pop in with a bounce.")
    ],
    @[
      MMLoc(@"What does the anchor point do?",
            @"AI example chip: anchor point question."),
      MMLoc(@"What does the anchor point do?",
            @"AI example value: anchor point question.")
    ],
  ];

  NSString *placeholder = MMLoc(@"Ask a question or describe an animation…",
                                @"AI prompt field placeholder for Magic Move.");

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
      KKTimelineAICurrentJSON(getAPI, [MagicMovePlugin availableLanes]);
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

  NSString *schema = _MagicMoveAILaneSchemaText();

  __weak typeof(self) weakSelf = self;
  [KKAIPluginAgent
             runWithPrompt:prompt
            productContext:productContext
            laneSchemaText:schema
       currentTimelineJSON:currentJSON
       clipDurationSeconds:clipDurSec
      currentInspectorMode:currentMode
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
                    // clipDur from the prompt, frameDur from the process cache.
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
                    // If the result isn't Basic-representable, force the
                    // inspector to Advanced so the user sees the real structure
                    // instead of the compatibility banner.
                    KKTimeline *resultTimeline =
                        [KKTimeline timelineFromJSON:merged];
                    if (resultTimeline &&
                        !KKTimelineIsBasicCompatible(resultTimeline)) {
                      [strong patchUIStateKey:@"activeTab"
                                        value:@(1)
                                      paramID:kParamUIState];
                    }
                    [writeAct endAction:strong];
                    [KKAIDraft setAnswer:nil];
                    [KKAIDraft clearPrompt];
                    // Light the green "done" sparkle so a fire-and-look-away
                    // run still has a confirmation waiting on return. Cleared
                    // when the user next opens the popover or types.
                    [KKAIDraft setCompleted:YES];
                  });
                }];
}

@end
