/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "GlowInspectorView.h"
#import "GlowLocalized.h"
#import "GlowOSCRadiusMath.h"
#import "Plugin_Private.h"
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKColorLanes.h>
#import <KeyframelessKit/KKDataBlob.h>
#import <KeyframelessKit/KKHelpSection.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKPlugin+InspectorCallbacks.h>
#import <KeyframelessKit/KKPlugin+OSCVisibility.h>
#import <KeyframelessKit/KKTimelineAIMerge.h>
#import <KeyframelessKit/KKTimelineInspectorView+Guide.h>
#import <KeyframelessKit/KKTimingCompat.h>
#import <KeyframelessKit/KKTimingGuide.h>
#import <KeyframelessKit/KKTimingStage.h>
@import KeyframelessAI;

/// Plain-text coordinate-space description for the AI agent's value-resolution
/// pass. Kept tight: this is the only context that pass sees alongside the
/// prompt. Lanes: the Core group (Radius, Intensity, Falloff, Threshold,
/// Position), the Color group (Mode), and the Noise group (Amount, Spread,
/// Grain Size, Speed, Seed).
static NSString *_GlowAILaneSchemaText(void) {
  return @"Lane labels and value spaces:\n\n"
         @"- \"Radius\": two numeric components [X, Y], aspect-linked. Each is "
         @"the glow blur radius in canonical pixels, range 0..500 (0 = no "
         @"glow, "
         @"500 = a large halo). Default [100, 100]. X and Y are normally kept "
         @"equal; apply a single radius the user asks for to both "
         @"components.\n"
         @"- \"Intensity\": single value, percent 0..300. Glow brightness "
         @"(100 = normal, higher = brighter). Default 100.\n"
         @"- \"Falloff\": single value, percent 0..200. Edge softness "
         @"(0 = softest/widest, higher = tighter edge). Default 0.\n"
         @"- \"Threshold\": single value, percent 0..100. Bloom bright-pass "
         @"cutoff (0 = no bloom, higher blooms bright areas). Default 0.\n"
         @"- \"Position\": two numeric components [X, Y], normalised 0..1 of "
         @"the "
         @"clip ([0.5, 0.5] = centred = the glow sits on the clip). Offsets "
         @"the "
         @"glow: X<0.5 shifts it left, X>0.5 right; Y<0.5 down, Y>0.5 up. May "
         @"be "
         @"animated along a curved path (keyposes can be smooth). Default "
         @"[0.5, 0.5].\n"
         @"- \"Mode\": the glow colour mode. A structural choice (NOT "
         @"animated), "
         @"stored as an index: 0 = Dynamic (the glow takes its colour from the "
         @"underlying source pixels, the default), 1 = Solid, 2 = Gradient. "
         @"Default 0.\n"
         @"- \"Solid\": the glow tint when Mode = Solid, as [r, g, b, a] in "
         @"sRGB 0..1. Only used when Mode = Solid. Default [1, 1, 1, 1] "
         @"(white).\n"
         @"- \"Gradient\": the glow gradient when Mode = Gradient. A composite "
         @"value [type, angleDegrees, <flat [pos, r, g, b, mid] per stop>] "
         @"where "
         @"type 0 = radial, 1 = linear (angle applies only to linear). Only "
         @"used "
         @"when Mode = Gradient. Edited via the inline gradient picker, not "
         @"typed.\n"
         @"- \"Amount\": single value, percent 0..100. How much grain is mixed "
         @"into the glow (0 = clean glow, higher = more grain). Default 0.\n"
         @"- \"Spread\": single value, percent 0..100. How far the grain "
         @"reaches "
         @"into the glow's falloff (low = near the edge, high = through the "
         @"whole glow). Default 0.\n"
         @"- \"Grain Size\": single value, percent 0..100. Size of each grain "
         @"speck (low = fine/tiny, high = coarse/chunky). Default 50.\n"
         @"- \"Speed\": single value, percent 0..100. How fast the grain "
         @"animates over time (0 = static). Default 0.\n"
         @"- \"Seed\": single integer, the random grain-pattern seed. NOT "
         @"animatable - one constant for the clip; re-roll for a different "
         @"pattern. Default 0.\n";
}

@implementation GlowPlugin (CustomUI)

- (BOOL)usesMotionBlur {
  return YES;
}

+ (NSArray<KKLane *> *)availableLanes {
  // M1: a single 2-component aspect-linked Radius lane [X, Y] in canonical
  // pixels, modelled on MagicMove's Scale lane. Later milestones add the
  // remaining lanes (Intensity, Falloff, Noise, Position, Color, ...).
  KKLane *radius = [KKLane laneWithLabel:@"Radius"];
  radius.valueType = KKLaneValueTypeFloat;
  radius.componentMin = @[ @0.0, @0.0 ];
  radius.componentMax = @[ @500.0, @500.0 ];
  // "px" here is a purely cosmetic suffix: radius is stored AND rendered as
  // absolute canonical pixels (the shader's blur sigma). We deliberately do
  // NOT set componentsScaleWithMedia, so the field shows the literal value
  // (e.g. "100 px") with no media transform - unlike Crop/Position which are
  // normalised 0..1 and opt into the pixel display scaling.
  radius.componentUnits = @[ @"px", @"px" ];
  radius.componentLabels = @[ @"X", @"Y" ];
  // Raw px shown with decimals: scrub by 1 px/step, not the 0.01 the auto rule
  // would pick for a 2-decimal field.
  radius.scrubStep = 1.0;
  radius.aspectLinkable = YES;
  radius.aspectLinked = YES;
  // Param-picker category: Radius is the "Core" page; the noise params split
  // off into their own "Noise" page (see the static-values popover pills).
  radius.categoryKey = @"Core";
  radius.categorySymbol = @"circle.dotted";
  [radius
      insertKeypose:[KKKeyPose
                        keyposeAtTime:0.0
                               values:@[ @(kGlowM1Radius), @(kGlowM1Radius) ]]];

  // Intensity (Core, animatable %): glow brightness multiplier. Stored as a
  // whole percent (100 = 1.0); render divides by 100. Range mirrors the old
  // slider (0-300%, default 100%).
  KKLane *intensity = [KKLane laneWithLabel:@"Intensity"];
  intensity.valueType = KKLaneValueTypeFloat;
  intensity.componentMin = @[ @0.0 ];
  intensity.componentMax = @[ @300.0 ];
  intensity.componentUnits = @[ @"%" ];
  intensity.integerValued = YES;
  intensity.categoryKey = @"Core";
  intensity.categorySymbol = @"circle.dotted";
  [intensity
      insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                      values:@[ @(kGlowM1Intensity * 100.0) ]]];

  // Falloff (Core, animatable %): edge softness. The shader uses glowFalloff =
  // 1 + value, so the lane's 0-200% maps to a 1.0-3.0 falloff (higher = tighter
  // edge). Default 0% (= glowFalloff 1.0 = kGlowM1Falloff).
  KKLane *falloff = [KKLane laneWithLabel:@"Falloff"];
  falloff.valueType = KKLaneValueTypeFloat;
  falloff.componentMin = @[ @0.0 ];
  falloff.componentMax = @[ @200.0 ];
  falloff.componentUnits = @[ @"%" ];
  falloff.integerValued = YES;
  falloff.categoryKey = @"Core";
  falloff.categorySymbol = @"circle.dotted";
  [falloff
      insertKeypose:[KKKeyPose
                        keyposeAtTime:0.0
                               values:@[ @((kGlowM1Falloff - 1.0) * 100.0) ]]];

  // Threshold (Core, animatable %): bloom bright-pass cutoff. 0 = no bloom (the
  // bloom render lane is skipped); raising it blooms bright source areas.
  // Stored as a whole percent (0-100); render divides by 100.
  KKLane *threshold = [KKLane laneWithLabel:@"Threshold"];
  threshold.valueType = KKLaneValueTypeFloat;
  threshold.componentMin = @[ @0.0 ];
  threshold.componentMax = @[ @100.0 ];
  threshold.componentUnits = @[ @"%" ];
  threshold.integerValued = YES;
  threshold.categoryKey = @"Core";
  threshold.categorySymbol = @"circle.dotted";
  [threshold
      insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                      values:@[ @(kGlowM1Threshold * 100.0) ]]];

  // Position (Core, 2D spatial): offsets the glow. Stored normalised 0..1
  // (0.5, 0.5 = centred = no offset); render maps it to glow offset = pos-0.5.
  // Generalised via the kit's KKPositionOSC / KKPositionMiniController (same
  // curved-path Position as MagicMove). Off-canvas allowed, so no min/max.
  KKLane *position = [KKLane laneWithLabel:@"Position"];
  position.valueType = KKLaneValueTypeGeneric;
  position.componentMin = @[];
  position.componentMax = @[];
  position.componentUnits = @[ @"px", @"px" ];
  position.componentsScaleWithMedia = YES; // stored 0..1, displayed as pixels
  position.componentLabels = @[ @"X", @"Y" ];
  position.spatialCurvable = YES;
  position.categoryKey = @"Core";
  position.categorySymbol = @"circle.dotted";
  [position insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0.5, @0.5 ]]];

  // Color (its own category): the reusable kit colour group - a Mode pill
  // (Dynamic / Solid / Gradient) gating a solid swatch and a composite gradient
  // (radial/linear + angle + stops), all animatable. The grouping (categoryKey)
  // is ours; the content is the shared KKColorLanes helper.
  NSArray<KKLane *> *colorLanes =
      KKColorLanesMake(nil, /*includesDynamic=*/YES, /*animatable=*/YES);
  for (KKLane *l in colorLanes) {
    l.categoryKey = @"Color";
    l.categorySymbol = @"paintpalette";
  }
  KKLane *colorMode = colorLanes[0];
  KKLane *solidColor = colorLanes[1];
  KKLane *gradient = colorLanes[2];

  // Noise: grain mixed into the glow. Amount + Spread animate; Seed is a
  // value-only random integer (the gap-popover seed control). Render wiring is
  // a later step - these currently display but don't yet affect the glow.
  // Amount + Spread are 0-100% in the UI (whole percentages, like Opacity); the
  // shader takes 0-1, so the render param-eval divides by 100 (step C). Names
  // are short because the "Noise" category already carries the context.
  KKLane *noise = [KKLane laneWithLabel:@"Amount"];
  noise.valueType = KKLaneValueTypeFloat;
  noise.componentMin = @[ @0.0 ];
  noise.componentMax = @[ @100.0 ];
  noise.componentUnits = @[ @"%" ];
  noise.integerValued = YES;
  noise.categoryKey = @"Noise";
  noise.categorySymbol = @"waveform";
  [noise insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                         values:@[ @(kGlowM1Noise * 100.0) ]]];

  KKLane *noiseSpread = [KKLane laneWithLabel:@"Spread"];
  noiseSpread.valueType = KKLaneValueTypeFloat;
  noiseSpread.componentMin = @[ @0.0 ];
  noiseSpread.componentMax = @[ @100.0 ];
  noiseSpread.componentUnits = @[ @"%" ];
  noiseSpread.integerValued = YES;
  noiseSpread.categoryKey = @"Noise";
  noiseSpread.categorySymbol = @"waveform";
  [noiseSpread
      insertKeypose:[KKKeyPose
                        keyposeAtTime:0.0
                               values:@[ @(kGlowM1NoiseOffset * 100.0) ]]];

  // Grain Size (animatable %): higher = larger, chunkier grain (fewer cells).
  // 50% reproduces the historical fixed grain; render maps it via
  // GlowNoiseGrainCells.
  KKLane *noiseGrain = [KKLane laneWithLabel:@"Grain Size"];
  noiseGrain.valueType = KKLaneValueTypeFloat;
  noiseGrain.componentMin = @[ @0.0 ];
  noiseGrain.componentMax = @[ @100.0 ];
  noiseGrain.componentUnits = @[ @"%" ];
  noiseGrain.integerValued = YES;
  noiseGrain.categoryKey = @"Noise";
  noiseGrain.categorySymbol = @"waveform";
  [noiseGrain
      insertKeypose:[KKKeyPose
                        keyposeAtTime:0.0
                               values:@[ @(kGlowM1NoiseGrain * 100.0) ]]];

  // Speed (animatable %): the shader phase = Seed + time * (Speed/100) * 5, so
  // the grain drifts outward over time (the old "animated noise" behaviour).
  KKLane *noiseSpeed = [KKLane laneWithLabel:@"Speed"];
  noiseSpeed.valueType = KKLaneValueTypeFloat;
  noiseSpeed.componentMin = @[ @0.0 ];
  noiseSpeed.componentMax = @[ @100.0 ];
  noiseSpeed.componentUnits = @[ @"%" ];
  noiseSpeed.integerValued = YES;
  noiseSpeed.categoryKey = @"Noise";
  noiseSpeed.categorySymbol = @"waveform";
  [noiseSpeed
      insertKeypose:[KKKeyPose
                        keyposeAtTime:0.0
                               values:@[ @(kGlowM1NoiseSpeed * 100.0) ]]];

  // Seed: the random pattern seed (value-only re-roll field, never a lane). The
  // shader hashes it to a bounded spatial offset, so any value picks a distinct
  // grain pattern - it isn't fed into a hash directly, so there's no
  // float-precision cap to keep it small.
  KKLane *noiseSeed = [KKLane laneWithLabel:@"Seed"];
  noiseSeed.valueType = KKLaneValueTypeFloat;
  noiseSeed.componentMin = @[ @0.0 ];
  noiseSeed.componentMax = @[ @999999.0 ];
  noiseSeed.integerValued = YES;
  noiseSeed.animatable = NO; // value-only random seed, never a lane
  noiseSeed.seedField = YES; // value + re-roll, not a slider
  noiseSeed.categoryKey = @"Noise";
  noiseSeed.categorySymbol = @"waveform";
  [noiseSeed insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                             values:@[ @(kGlowM1NoiseSeed) ]]];

  return @[
    radius, intensity, falloff, threshold, position, colorMode, solidColor,
    gradient, noiseSeed, noise, noiseSpread, noiseGrain, noiseSpeed
  ];
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
    BOOL motionBlurEnabled = st.motionBlurEnabled;
    double motionBlurShutterAngle = st.motionBlurShutterAngle;
    NSInteger motionBlurSamples = st.motionBlurSamples;
    NSInteger motionBlurMode = st.motionBlurMode;
    BOOL oscMasterVisible = st.oscMasterVisible;
    NSDictionary *uiState = st.uiState;
    KKTimeline *timeline = [self timelineStampedWithClipDuration:st.timeline];

    // Cold-boot seed for the OSC. Without this, the first drawOSC tick after a
    // relaunch sees an empty snapshot and the ring reads the default radius.
    // parameterChanged catches up later, but only after a redraw nudge.
    GlowSetTimelineSnapshot(timeline);

    // Frame + clip duration for the keypose-snap epsilon and the basic-view
    // scrubber clamp. FxTimingAPI resolves inside this action scope; we also
    // push them into the view right after construction to avoid the
    // render-push race documented in Rounded.
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
        GlowSetFrameDurationSeconds(seedFrameDurSec);
    }

    // Per-instance state: mint the UUID inside the action scope where the
    // setting API resolves, and seed the OSC master-visibility tick.
    KKInstanceStateEnsureForAPI(self.apiManager).oscMasterVisible =
        oscMasterVisible;

    [actionAPI endAction:self];

    NSArray<KKLane *> *available = [GlowPlugin availableLanes];
    GlowInspectorView *view =
        [[GlowInspectorView alloc] initWithAPIManager:self.apiManager
                                          loopEnabled:loopEnabled
                                            activeTab:activeTab
                                       availableLanes:available
                                             timeline:timeline];
    if (seedClipDurSec > 0)
      [view setClipDurationSeconds:seedClipDurSec];
    if (seedFrameDurSec > 0)
      [view setFrameDurationSeconds:seedFrameDurSec];
    [view setMotionBlurEnabled:motionBlurEnabled];
    [view setMotionBlurShutterAngle:motionBlurShutterAngle
                            samples:motionBlurSamples];
    [view setMotionBlurMode:(KKMotionBlurMode)motionBlurMode];

    // On-screen-control visibility: master tick + the single Radius pill +
    // opt-click-hide + opt-reveal. Shared glue in KKPlugin (OSCVisibility); the
    // renderer is the view's mini-viewer delegate.
    KKMiniViewerRenderer *oscRenderer =
        (KKMiniViewerRenderer *)view.miniViewerDelegate;
    NSArray<NSArray<NSString *> *> *oscCompounds =
        @[ @[ @"Radius" ], @[ @"Position" ], @[ @"Path" ] ];
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

    // Force OSCs visible while a guide runs (so its mini-viewer + viewer
    // handles are usable even if the user hid the Radius ring), then restore
    // the user's master + per-element OSC setting on guide end.
    [self kkInstallGuideOSCForcingOnHost:[(GlowInspectorView *)
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
    // Mini-viewer motion-path edits (Position anchor / tangent drag) persist
    // the whole blob through the same writer as inspector timeline mutations.
    oscRenderer.onTimelinePersist = view.onTimelineMutated;

    self.inspectorView = view;
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

- (NSArray<KKHelpGuide *> *)helpGuides {
  // The Introduction / Advanced Timing / Mini Viewer / On-Screen Controls /
  // Presets walkthroughs are identical across plugins, so the kit builds them
  // from the live inspector. Glow has no OSC guide bridge, so the guides aren't
  // gated on a canvas reference - they're always enabled.
  __weak typeof(self) weak = self;
  return [KKTimingGuide
      standardHelpGuidesForInspectorProvider:^KKTimelineInspectorView * {
        __strong typeof(weak) strong = weak;
        return strong.inspectorView;
      }
      enabledProvider:^BOOL {
        return YES;
      }];
}

- (nullable NSImage *)helpHeaderIcon {
  return [NSImage imageWithSystemSymbolName:@"sparkles"
                   accessibilityDescription:nil];
}

- (NSArray<KKHelpSection *> *)helpSections {
  // Quick reference: short overview + parameter list (single-sourced from
  // glow.md), then an on-screen-control shortcuts table. The per-property deep
  // doc (radius.md) stays AI-only.
  KKHelpSection *overview = [self
      helpSectionFromKnowledgeTopic:@"glow"
                              title:GLoc(@"Glow",
                                         @"Help section title (plugin name).")
                             symbol:@"sparkles"
                          localizer:^NSString *(NSString *tip) {
                            return GLoc(tip, @"Glow help tip (from AIKnowledge "
                                             @"markdown).");
                          }];

  NSMutableArray<KKHelpShortcut *> *rows = [@[
    [KKHelpShortcut
        shortcutWithKeysMarkup:GLoc(@"Drag the Radius ring", @"Shortcut keys.")
                    descMarkup:GLoc(@"Set the glow size on the canvas",
                                    @"Help shortcut.")],
  ] mutableCopy];
  [rows addObjectsFromArray:[KKPlugin sharedOnScreenControlShortcuts]];

  KKHelpSection *shortcuts =
      [KKHelpSection sectionWithTitle:GLoc(@"On-screen control shortcuts",
                                           @"Help section title.")
                            tipMarkup:nil
                            shortcuts:rows];
  shortcuts.icon = [NSImage imageWithSystemSymbolName:@"hand.point.up.left"
                             accessibilityDescription:nil];

  return @[ overview, shortcuts ];
}

- (nullable NSView *)aiAccessoryView {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // Shared timeline docs live in the kit framework bundle (so the kit help
    // window renders the same source); register them from there.
    [KKAIKnowledge registerSharedTimelineDocsWithBundle:
                       [NSBundle bundleForClass:[KKOnScreenControl class]]];
    [KKAIKnowledge
        registerBundleDocsWithName:@"Glow"
                            bundle:[NSBundle bundleForClass:[GlowPlugin class]]
                      subdirectory:@"AIKnowledge"];
    // Shared on-screen-control docs live in the kit framework. Glow has the
    // radius ring (no rotation OSC) plus the shared Position handle / motion
    // path, so filter to those topics.
    [KKAIKnowledge
        registerBundleDocsWithName:@"On-Screen Controls"
                            bundle:[NSBundle
                                       bundleForClass:[KKOnScreenControl class]]
                      subdirectory:nil
                      onlyTopicIDs:@[ @"visibility", @"position" ]];
    // Color (Dynamic/Solid/Gradient) is a shared property whose doc lives in
    // the kit framework. Glow uses it to tint the glow, so opt into the central
    // doc (every adopting plugin registers this same topic - the doc is plugin
    // agnostic).
    [KKAIKnowledge
        registerBundleDocsWithName:@"Color"
                            bundle:[NSBundle
                                       bundleForClass:[KKOnScreenControl class]]
                      subdirectory:nil
                      onlyTopicIDs:@[ @"color" ]];
  });

  NSString *productContext = GLoc(
      @"Glow, a Final Cut Pro plugin that adds a soft animatable glow around a "
      @"clip and animates it with the shared Keyframeless timeline system "
      @"(Basic and Advanced timing, easing, motion blur). Always refer to "
      @"yourself as Glow. Detailed feature information is in the reference "
      @"docs "
      @"below.",
      @"AI assistant product context for Glow plugin.");

  NSArray<NSArray<NSString *> *> *examples = @[
    @[
      GLoc(@"Glow in with bounce", @"AI example chip: animate glow in."),
      GLoc(@"Animate the glow growing from 0 to 200 over 1 second with bounce.",
           @"AI example value: animate glow in.")
    ],
    @[
      GLoc(@"Pulse the glow", @"AI example chip: pulse the glow."),
      GLoc(@"Pulse the glow larger and back a few times across the clip.",
           @"AI example value: pulse the glow.")
    ],
    @[
      GLoc(@"What's Basic vs Advanced?",
           @"AI example chip: Basic vs Advanced timing question."),
      GLoc(@"What's the difference between Basic and Advanced timing?",
           @"AI example value: Basic vs Advanced timing question.")
    ],
  ];

  NSString *placeholder = GLoc(@"Ask a question or describe an animation…",
                               @"AI prompt field placeholder for Glow.");

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
      KKTimelineAICurrentJSON(getAPI, [GlowPlugin availableLanes]);
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

  NSString *schema = _GlowAILaneSchemaText();

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
                      [KKAIDraft setError:@"Couldn't open the FCP action scope "
                                          @"to apply the mutation."];
                      return;
                    }
                    [writeAct startAction:strong];
                    id<FxParameterSettingAPI_v5> setAPI = [strong.apiManager
                        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
                    KKWriteCustomParamString(setAPI, merged,
                                             kKKParamTimelineData);

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

@end
