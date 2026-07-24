/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import "MirageAISchema.h"
#import "MirageDirectives.h"
#import "MirageInspectorView+Guides.h"
#import "MirageInspectorView.h"
#import "MirageLaneCatalog.h"
#import "MirageLocalized.h"
#import "MirageMiniViewerRenderer.h" // per-instance mini-viewer rendezvous paths
#import "MirageOSCBlockRuntime.h" // // @osc custom-handling blocks (checklist)
#import "MirageOSCSnapshot.h" // OSC timeline snapshot + frame-duration setters
#import "MiragePresets.h"     // MirageBuiltinPresets (built-in look presets)
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKColorLanes.h>
#import <KeyframelessKit/KKDataBlob.h>
#import <KeyframelessKit/KKGLSLSyntax.h> // KKExprCatalogMarkdown (AI reference)
#import <KeyframelessKit/KKHelpSection.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKPlugin+InspectorCallbacks.h>
#import <KeyframelessKit/KKPresets.h>
#import <KeyframelessKit/KKTimelineAIMerge.h>
#import <KeyframelessKit/KKTimelineInspectorView+Guide.h> // guide help-button provider
#import <KeyframelessKit/KKTimingCompat.h>
#import <KeyframelessKit/KKTimeline.h>
#import <KeyframelessKit/KKUpdateChecker.h>
@import KeyframelessAI;

// Apply-an-AI-result helpers, one per result kind. Each owns its FCP action
// scope and, on success, lights the green "done" sparkle. Parsing/mutating a
// timeline needs no scope - only the param write does - so the shared writer
// takes the finished JSON and just opens the scope around the write.

// Open an action scope on `plugin`, write `json` to the timeline-data param,
// close it, and light the done sparkle. Sets the AI error and returns NO if the
// scope can't be opened.
static BOOL MirageAIWriteTimelineJSON(MiragePlugin *plugin, NSString *json,
                                      NSString *scopeError) {
  BOOL scoped = KKPerformUndoable(
      plugin.apiManager, plugin, nil,
      ^(id<FxParameterRetrievalAPI_v6> getAPI,
        id<FxParameterSettingAPI_v5> setAPI, CMTime actionTime) {
        if (json.length)
          KKWriteCustomParamString(setAPI, json, kKKParamTimelineData);
      });
  if (!scoped) {
    [KKAIDraft setError:scopeError];
    return NO;
  }
  [KKAIDraft setAnswer:nil];
  [KKAIDraft setCompleted:YES]; // green done sparkle
  [KKAIDraft clearPrompt];
  return YES;
}

// Code authoring: set the AI-written GLSL on the "Mirage" code lane (creating
// it if the persisted timeline has none) and write back; applyTimeline
// re-transpiles and rebuilds the controls (same path a manual code commit
// takes).
static void MirageAIApplyShaderSource(MiragePlugin *plugin, NSString *newSrc,
                                      NSString *timelineBlob) {
  if (!newSrc.length) {
    KKLogError(@"AI[err] empty shader source");
    [KKAIDraft setError:@"AI returned an empty shader."];
    return;
  }
  KKTimeline *tl = timelineBlob.length
                       ? [KKTimeline timelineFromJSON:timelineBlob]
                       : [KKTimeline timeline];
  if (!tl)
    tl = [KKTimeline timeline];
  KKLane *shaderLane = nil;
  for (KKLane *l in tl.lanes)
    if ([l.key isEqualToString:kMirageCodeLaneLabel]) {
      shaderLane = l;
      break;
    }
  if (!shaderLane) {
    shaderLane = [KKLane laneWithKey:kMirageCodeLaneLabel label:kMirageCodeLaneLabel];
    shaderLane.valueType = KKLaneValueTypeCode;
    shaderLane.animatable = NO;
    shaderLane.enabled = NO;
    tl.lanes = [tl.lanes arrayByAddingObject:shaderLane];
  }
  shaderLane.codeString = newSrc;
  MirageAIWriteTimelineJSON(
      plugin, [KKTimeline jsonFromTimeline:tl],
      @"Couldn't open the FCP action scope to apply the shader.");
}

// Expression authoring: for each {lane, expression} op set that lane's
// linkExpression (creating the lane if absent; friendly ${Clip.Param} refs
// translated to the stored ${uuid.label} form via the current manifests), then
// write back so applyTimeline re-derives the driven values.
static void MirageAIApplyExpressionOps(MiragePlugin *plugin, NSString *opsJSON,
                                       NSString *timelineBlob) {
  NSData *opsData = [opsJSON dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *opsObj = opsData
                             ? [NSJSONSerialization JSONObjectWithData:opsData
                                                               options:0
                                                                 error:nil]
                             : nil;
  NSArray *ops =
      [opsObj isKindOfClass:[NSDictionary class]] ? opsObj[@"operations"] : nil;
  if (![ops isKindOfClass:[NSArray class]] || ops.count == 0) {
    [KKAIDraft setError:@"AI returned no expression."];
    return;
  }
  KKTimeline *tl = timelineBlob.length
                       ? [KKTimeline timelineFromJSON:timelineBlob]
                       : [KKTimeline timeline];
  if (!tl)
    tl = [KKTimeline timeline];
  NSArray<KKLinkManifest *> *manifests = [KKLinkBus allManifests];
  NSMutableArray<KKLane *> *lanes = [tl.lanes mutableCopy];
  for (NSDictionary *op in ops) {
    if (![op isKindOfClass:[NSDictionary class]])
      continue;
    NSString *label = op[@"lane"];
    NSString *expr = op[@"expression"];
    if (![label isKindOfClass:[NSString class]] || label.length == 0 ||
        ![expr isKindOfClass:[NSString class]] || expr.length == 0)
      continue;
    NSString *stored = KKLinkStoredExpressionFromDisplay(expr, manifests);
    KKLane *target = nil;
    for (KKLane *l in lanes)
      if ([l.key isEqualToString:label]) {
        target = l;
        break;
      }
    if (!target) {
      target = [KKLane laneWithKey:label label:label];
      [lanes addObject:target];
    }
    target.linkExpression = stored;
  }
  tl.lanes = lanes;
  MirageAIWriteTimelineJSON(
      plugin, [KKTimeline jsonFromTimeline:tl],
      @"Couldn't open the FCP action scope to apply the expression.");
}

// Keypose mutation: merge into the current timeline (snapping final keyposes to
// the last renderable frame), write back, and - when the result isn't Basic-
// representable - switch the inspector to Advanced so the user sees the real
// structure instead of the compatibility banner.
static void MirageAIApplyMutation(MiragePlugin *plugin, NSString *currentJSON,
                                  NSString *mutationJSON, double clipDurSec) {
  NSString *merged = KKTimelineAIMergeMutationJSON(
      currentJSON, mutationJSON, clipDurSec, KKProcessFrameDurationSeconds());
  if (!merged) {
    KKLogError(@"AI[err] merge returned nil");
    [KKAIDraft setError:@"AI returned an invalid timeline mutation."];
    return;
  }
  BOOL scoped = KKPerformUndoable(
      plugin.apiManager, plugin, nil,
      ^(id<FxParameterRetrievalAPI_v6> getAPI,
        id<FxParameterSettingAPI_v5> setAPI, CMTime actionTime) {
        KKWriteCustomParamString(setAPI, merged, kKKParamTimelineData);
        KKTimeline *resultTimeline = [KKTimeline timelineFromJSON:merged];
        double mergeFrameDur = KKProcessFrameDurationSeconds();
        double aiEndFrac = (clipDurSec > 0.0 && mergeFrameDur > 0.0 &&
                            mergeFrameDur < clipDurSec)
                               ? (clipDurSec - mergeFrameDur) / clipDurSec
                               : 1.0;
        if (resultTimeline &&
            !KKTimelineIsBasicCompatible(resultTimeline, aiEndFrac))
          [plugin patchUIStateKey:@"activeTab" value:@(1) paramID:kParamUIState];
      });
  if (!scoped) {
    [KKAIDraft setError:@"Couldn't open the FCP action scope to apply the "
                        @"mutation."];
    return;
  }
  [KKAIDraft setAnswer:nil];
  [KKAIDraft setCompleted:YES]; // green done sparkle
  [KKAIDraft clearPrompt];
}

@implementation MiragePlugin (CustomUI)

- (BOOL)usesMotionBlur {
  return YES;
}

+ (NSArray<KKLane *> *)availableLanes {
  return MirageBuildAvailableLanes();
}

// Source-aware lane set: the Core lanes plus whatever dynamic lanes the given
// shader source declares (e.g. the `// #color` Colours group).
+ (NSArray<KKLane *> *)availableLanesForShaderSource:(NSString *)source {
  return [self availableLanesForShaderSource:source audioTickets:nil];
}

+ (NSArray<KKLane *> *)
    availableLanesForShaderSource:(NSString *)source
                     audioTickets:(NSDictionary<NSString *, id> *)tickets {
  return MirageBuildAvailableLanesForSource(
      source.length ? source : MirageCustomDefaultShaderSource(), tickets);
}

// The current shader source from a timeline's "Mirage" code lane (the baked
// default when absent/empty), for deriving the source-aware lane set.
+ (NSString *)shaderSourceFromTimeline:(KKTimeline *)timeline {
  for (KKLane *l in timeline.lanes)
    if ([l.key isEqualToString:kMirageCodeLaneLabel] && l.codeString.length)
      return l.codeString;
  return MirageCustomDefaultShaderSource();
}

+ (NSArray<NSArray<NSString *> *> *)oscCompounds {
  // Static fallback: the real set is per-shader (oscCompoundsForShaderSource:).
  return @[];
}

// The OSC element set the current shader declares, for the visibility popover /
// settings cog. Each `osc`-annotated lane is one compound (single element for a
// point handle; a rotation gizmo is one compound of its master + per-axis
// rings).
+ (NSArray<NSArray<NSString *> *> *)oscCompoundsForShaderSource:
    (NSString *)source {
  // The runtimes are the single source of truth: every inline `osc=` directive
  // arrives as SUGAR (a synthesized block) alongside the authored `// @osc`
  // blocks, in checklist order matching the viewer's oscElementKeys.
  NSMutableArray<NSArray<NSString *> *> *out = [NSMutableArray array];
  if (!source.length)
    return out;
  for (MirageOSCBlockRuntime *b in
       [MirageOSCBlockRuntime runtimesForSource:source lanes:@[]]) {
    if ([b.primitive isEqualToString:@"position"]) {
      // A position also owns a motion-PATH element, toggleable independently
      // of its handle (a separate Position + Path).
      [out addObject:@[ b.binds ]];
      [out addObject:@[ [b.binds stringByAppendingString:@" Path"] ]];
      continue;
    }
    if ([b.primitive isEqualToString:@"rotate"]) {
      // ONE compound of the gizmo's master + per-axis rings (keyed on its LANE
      // label), so the checklist shows a "Rotation" group with X/Y/Z children.
      NSMutableArray<NSString *> *group =
          [NSMutableArray arrayWithObject:b.binds];
      NSString *lower = b.axes.lowercaseString;
      BOOL any = NO;
      const char *canon = "XYZ";
      for (int a = 0; a < 3; a++)
        if ([lower containsString:[[NSString stringWithFormat:@"%c", canon[a]]
                                      lowercaseString]]) {
          [group addObject:[b.binds stringByAppendingFormat:@".%c", canon[a]]];
          any = YES;
        }
      if (!any)
        [group addObject:[b.binds stringByAppendingString:@".Z"]];
      [out addObject:group];
      continue;
    }
    [out addObject:@[ b.name ]];
  }
  return out;
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == kParamInspectorUI) {
    __block KKTimeline *timeline = nil;
    __block NSString *shaderSrc = nil;
    __block NSArray<KKLane *> *available = nil;
    __block BOOL oscMasterVisible = YES;
    __block NSDictionary *uiState = nil;
    __block KKMiniViewerRenderMode renderMode = 0;
    MirageInspectorView *view = (MirageInspectorView *)[self
        kkCreateInspectorViewWithUIStateParamID:kParamUIState
        renderNudgeParamID:kParamRenderNudge
        dragUndoLabel:KKUndoLabelAdjust(@"Mirage")
        detachedWindowSize:CGSizeMake(720.0, 460.0)
        builtinPresets:MirageBuiltinPresets()
        inScope:^(KKInspectorCreateContext *ctx,
                  id<FxParameterRetrievalAPI_v6> getAPI) {
          KKInspectorPersistedState *st = ctx.persistedState;
          oscMasterVisible = st.oscMasterVisible;
          uiState = st.uiState;
          renderMode = (KKMiniViewerRenderMode)st.renderMode;
          timeline = [self timelineStampedWithClipDuration:st.timeline];
          // Cold-boot seed for the OSC. Without this, the first drawOSC tick
          // after FCP relaunch sees an empty snapshot -> falls through to "no
          // lane = constant", Origin reads default 0.5,0.5 -> the handle sits
          // at frame centre regardless of saved state. parameterChanged
          // eventually catches up, but only after a redraw nudge.
          MirageSetTimelineSnapshot(timeline);
          if (ctx.seedFrameDurSec > 0)
            MirageSetFrameDurationSeconds(ctx.seedFrameDurSec);
          // Seed the per-instance OSC master tick while the state is scoped.
          ctx.instanceState.oscMasterVisible = st.oscMasterVisible;
        }
        buildView:^KKTimelineInspectorView *(KKInspectorCreateContext *ctx) {
          // Catches bindings this instance made before tickets existed, and
          // any made while its inspector was closed. Opens its own scope, so
          // it runs after the template's scope rather than inside it.
          [self syncAudioTicketsForTimeline:timeline];
          // Source-aware: derive the lane set (incl. the dynamic Colours
          // group) from the current shader source, so a shader's `// #color`
          // directive surfaces its swatches + palette generator.
          shaderSrc = [MiragePlugin shaderSourceFromTimeline:timeline];
          available =
              [MiragePlugin availableLanesForShaderSource:shaderSrc
                                             audioTickets:self.audioTickets];
          KKInspectorPersistedState *st = ctx.persistedState;
          MirageInspectorView *v = [[MirageInspectorView alloc]
              initWithAPIManager:self.apiManager
                     loopEnabled:st.loopEnabled
           maintainTimingEnabled:st.maintainTimingEnabled
                       activeTab:st.activeTab
                  availableLanes:available
                        timeline:timeline];
          // Per-instance rendezvous paths (keyed by the instance UUID) so two
          // stacked Mirage clips read/write distinct /tmp files instead of
          // the clip below showing the top clip's source in its mini-viewer.
          v.miniViewerDescriptorPath =
              MirageMiniViewerDescriptorPathForUUID(ctx.instanceUUID);
          v.miniViewerRequestPath =
              MirageMiniViewerRequestPathForUUID(ctx.instanceUUID);
          // Live source-derived lanes: when the shader code commits
          // (debounced), the inspector re-derives the lane set from the new
          // source. Cached tickets, not a fresh read: this fires from a
          // code-commit callback, outside any action scope, where the param
          // APIs return nil.
          __weak __typeof(self) weakLaneSelf = self;
          v.availableLanesProvider = ^NSArray<KKLane *> *(NSString *code) {
            return [MiragePlugin
                availableLanesForShaderSource:code
                                 audioTickets:weakLaneSelf.audioTickets];
          };
          return v;
        }];
    if (!view)
      return nil;

        // On-screen-control visibility: master tick + per-element pills (Origin,
    // Path) + opt-click-hide + opt-reveal. The element key is the lane label
    // (KKPositionOSC / the mini controller key their visibility on it). Shared
    // glue in KKPlugin (OSCVisibility); the renderer is the mini-viewer
    // delegate.
    KKMiniViewerRenderer *oscRenderer =
        (KKMiniViewerRenderer *)view.miniViewerDelegate;
    // The Scale mini box reads the plugin's lane templates for the aspect-link
    // default of an untouched (not-yet-in-timeline) constant Scale.
    if ([oscRenderer isKindOfClass:[MirageMiniViewerRenderer class]])
      ((MirageMiniViewerRenderer *)oscRenderer).laneTemplates = available;
    NSArray<NSArray<NSString *> *> *oscCompounds =
        [MiragePlugin oscCompoundsForShaderSource:shaderSrc];
    oscRenderer.handlesHidden = !oscMasterVisible;
    [self kkApplyOSCVisibilityFromState:uiState
                            elementKeys:[KKPlugin kkOSCElementKeysForCompounds:
                                                      oscCompounds]
                               renderer:oscRenderer];
    [self kkWireOSCVisibilityForView:view
                            renderer:oscRenderer
                           compounds:oscCompounds
                             paramID:kParamUIState];
    // The OSC element set is source-derived (each `osc` directive is a
    // compound), so a code edit that adds/removes an OSC or changes a rotate's
    // axis set must re-wire the visibility checklist - otherwise the dropdown
    // keeps the old axes/handles. Re-derive the compounds on every code commit
    // and re-wire (the wire re-captures the compounds so the toggle indexing
    // stays aligned).
    __weak __typeof(self) weakSelf = self;
    __weak KKTimelineInspectorView *weakView = view;
    __weak KKMiniViewerRenderer *weakOscRenderer = oscRenderer;
    view.onCodeCommitted = ^(NSString *code) {
      __strong __typeof(weakSelf) strongSelf = weakSelf;
      KKTimelineInspectorView *v = weakView;
      KKMiniViewerRenderer *r = weakOscRenderer;
      if (!strongSelf || !v || !r)
        return;
      NSArray<NSArray<NSString *> *> *freshCompounds =
          [MiragePlugin oscCompoundsForShaderSource:code];
      [strongSelf kkWireOSCVisibilityForView:v
                                    renderer:r
                                   compounds:freshCompounds
                                     paramID:kParamUIState];
    };
    [view setOSCVisible:oscMasterVisible];
    [view setRenderMode:renderMode];

    // Force OSCs visible while a guide runs (so its mini-viewer + viewer
    // handles are usable), then restore the user's OSC setting on guide end.
    [self kkInstallGuideOSCForcingOnHost:[(MirageInspectorView *)
                                                 view timingGuideHost]
                                    view:view
                             elementKeys:[KKPlugin kkOSCElementKeysForCompounds:
                                                       oscCompounds]
                            nudgeParamID:kParamRenderNudge];

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
  // wiring) are identical across plugins, so the kit builds them. Mirage only
  // supplies the canvas-reference gate (the final Basic step's viewer cutout
  // needs an OSC draw tick) and the live inspector.
  __weak typeof(self) weak = self;
  return [KKTimingGuide
      standardHelpGuidesForInspectorProvider:^KKTimelineInspectorView * {
        __strong typeof(weak) strong = weak;
        return strong.inspectorView;
      }
      enabledProvider:^BOOL {
        return MirageHasCanvasReference();
      }];
}

- (NSNotificationName)helpGuideRefreshNotificationName {
  return kMirageOSCPositionNotification;
}

- (nullable NSView *)aiAccessoryView {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // Shared timeline docs now live in the kit framework bundle (so the kit
    // help window can render the same source); register them from there.
    [KKAIKnowledge registerSharedTimelineDocsWithBundle:
                       [NSBundle bundleForClass:[KKOnScreenControl class]]];
    [KKAIKnowledge
        registerBundleDocsWithName:@"Mirage"
                            bundle:[NSBundle
                                       bundleForClass:[MiragePlugin class]]
                      subdirectory:@"AIKnowledge"];
    // Shared on-screen-control docs live in the kit framework (flattened to its
    // Resources root). Mirage's own OSCs are directive-driven (see the
    // directives doc), not the standard lane-bound Rotation/Scale controls
    // those kit docs describe, so pull in only the shared visibility behaviour.
    [KKAIKnowledge
        registerBundleDocsWithName:@"On-Screen Controls"
                            bundle:[NSBundle
                                       bundleForClass:[KKOnScreenControl class]]
                      subdirectory:nil
                      onlyTopicIDs:@[ @"visibility" ]];
    // Audio-reactive shaders. The docs live in the kit (Sonar publishes the
    // data, Mirage consumes it - neither owns it), so the workflow extension
    // and every future consumer read the same source. Both topics, not just the
    // directive: a user asking how to drive a shader from audio needs to know
    // Sonar exists and that they have to publish first.
    [KKAIKnowledge
        registerBundleDocsWithName:@"Audio-Reactive"
                            bundle:[NSBundle
                                       bundleForClass:[KKOnScreenControl class]]
                      subdirectory:nil
                      onlyTopicIDs:@[
                        @"audio-sonar", @"audio-shader-directive"
                      ]];
    // The expression function/variable reference, GENERATED from the editor's
    // own KKExprCatalog so the AI's vocabulary can never drift from the
    // autocomplete (the expressions.md prose teaches concepts; this is the
    // exhaustive list). The expression + shader-code agents pull ALL knowledge
    // entries, so it always travels with them.
    [KKAIKnowledge registerInlineDocWithName:@"Expression Reference"
                                     topicID:@"expression-functions"
                                     summary:@"Every expression variable and "
                                             @"function with its signature."
                                     content:KKExprCatalogMarkdown()];
  });

  NSString *productContext = RLoc(
      @"Mirage, a Final Cut Pro effect that runs a Shadertoy-style GLSL shader "
      @"live on a clip. The look is defined by the shader source (the "
      @"\"Mirage\" "
      @"code lane), which you can write or edit for the user; the clip is "
      @"available to the shader as iChannel0. Uniforms annotated with // # "
      @"directives become inspector + on-screen controls, and every control "
      @"animates on the shared Keyframeless timeline (Basic and Advanced "
      @"timing, "
      @"easing). Always refer to yourself as Mirage. Detailed feature "
      @"information is in the reference docs below.",
      @"AI assistant product context for Mirage plugin.");

  NSArray<NSArray<NSString *> *> *examples = @[
    @[
      RLoc(@"Plasma background", @"AI example chip: generator shader."),
      RLoc(@"Write a shader for a colourful flowing plasma background.",
           @"AI example value: generator shader.")
    ],
    @[
      RLoc(@"Wavy distortion", @"AI example chip: filter shader."),
      RLoc(@"Write a shader that distorts the clip with a wavy ripple.",
           @"AI example value: filter shader.")
    ],
    @[
      RLoc(@"Add a control", @"AI example chip: add a directive control."),
      RLoc(@"Add a slider to control the amount.",
           @"AI example value: add a directive control.")
    ],
    @[
      RLoc(@"How do controls work?", @"AI example chip: directives question."),
      RLoc(@"How do I turn a uniform into an on-screen control?",
           @"AI example value: directives question.")
    ],
  ];

  NSString *placeholder = RLoc(@"Ask a question or describe a shader…",
                               @"AI prompt field placeholder for Mirage.");

  // Wire the "Keyframeless AI update available" banner: the popover fires this
  // when it opens, we run the standalone-helper update check (its own installer
  // + version, read by KKUpdateChecker) and push the result into the popover.
  // This is the one spot that links both KeyframelessKit and KeyframelessAI.
  __weak typeof(self) weakSelf = self;
  return [KKAIBannerHost
      makeStandardPluginButtonWithProductContext:productContext
                                    examplePairs:examples
                                     placeholder:placeholder
                                checkForAIUpdate:^(void (^report)(
                                    NSString *version, NSString *notesURL)) {
                                  [[KKUpdateChecker shared]
                                      checkAIUpdateWithCompletion:^(BOOL avail) {
                                        KKUpdateChecker *c =
                                            [KKUpdateChecker shared];
                                        report(c.aiAvailableVersion,
                                               c.aiNotesURL.absoluteString);
                                      }];
                                }
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
  __block NSString *currentJSON = nil;
  __block NSString *availableSources = nil;
  __block NSString *timelineBlob = nil;
  __block NSString *aiShaderSrc = @"";
  __block NSString *currentMode = @"Basic";
  __block double clipDurSec = 5.0;
  BOOL scoped = KKPerformUndoable(
      self.apiManager, self, nil,
      ^(id<FxParameterRetrievalAPI_v6> getAPI,
        id<FxParameterSettingAPI_v5> setAPI, CMTime actionTime) {
        currentJSON = KKTimelineAICurrentJSON(getAPI, [MiragePlugin availableLanes]);
        // Other clips this one can reference in a cross-clip ${Clip.Param} expression
        // (excluding itself), for the AI's expression route.
        NSString *selfLinkUUID = KKInstanceUUIDForAPI(self.apiManager);
        availableSources = KKLinkAvailableSourcesJSON(
            selfLinkUUID, KKLinkDocumentIDForAPI(self.apiManager));
        // Raw timeline blob (carries the "Mirage" code lane the AI may rewrite) and
        // the current shader source. Pass "" when it's the untouched default so a
        // from-scratch ask starts clean; a customised shader is passed so the AI
        // edits it in place ("add a slider", "make the ripples bigger").
        timelineBlob = KKReadCustomParamString(getAPI, kKKParamTimelineData);
        NSString *rawShaderSrc = @"";
        KKTimeline *readTimeline =
            timelineBlob.length ? [KKTimeline timelineFromJSON:timelineBlob] : nil;
        for (KKLane *l in readTimeline.lanes)
          if ([l.key isEqualToString:kMirageCodeLaneLabel] && l.codeString.length) {
            rawShaderSrc = l.codeString;
            break;
          }
        aiShaderSrc =
            [rawShaderSrc isEqualToString:MirageCustomDefaultShaderSource()]
                ? @""
                : rawShaderSrc;
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
        currentMode = (activeTab == 1) ? @"Advanced" : @"Basic";
        id<FxTimingAPI_v4> timingAPI =
            [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
        CMTime clipDur = kCMTimeZero;
        if (timingAPI)
          [timingAPI durationTimeForEffect:&clipDur];
        clipDurSec = CMTimeGetSeconds(clipDur);
        if (clipDurSec <= 0 || isnan(clipDurSec))
          clipDurSec = 5.0;
  });
  if (!scoped) {
    [KKAIDraft setRouting:NO];
    [KKAIDraft setError:@"Couldn't open the FCP action scope."];
    return;
  }

  NSString *schema = MirageAILaneSchemaText();

  __weak typeof(self) weakSelf = self;
  // Custom-only plugin: the look is the GLSL source, so the code-authoring
  // entry point adds the "code" route (write / edit the shader) on top of the
  // standard per-lane / Q&A pipeline.
  [KKAIPluginAgent
      runCodeAuthoringWithPrompt:prompt
                  productContext:productContext
                  laneSchemaText:schema
             currentTimelineJSON:currentJSON
             clipDurationSeconds:clipDurSec
            currentInspectorMode:currentMode
             currentShaderSource:aiShaderSrc
                availableSources:availableSources
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
                          switch (result.kind) {
                          case KKAIPluginResultKindAnswer:
                            [KKAIDraft setAnswer:result.answer];
                            break;
                          case KKAIPluginResultKindAuthorCode:
                            MirageAIApplyShaderSource(
                                strong, result.shaderSource, timelineBlob);
                            break;
                          case KKAIPluginResultKindAuthorExpression:
                            MirageAIApplyExpressionOps(
                                strong, result.expressionOps, timelineBlob);
                            break;
                          default: // .mutation
                            MirageAIApplyMutation(strong, currentJSON,
                                                  result.mutationJSON,
                                                  clipDurSec);
                            break;
                          }
                        });
                      }];
}

- (nullable NSString *)helpHeaderTitle {
  return RLoc(@"Mirage", @"Help section title (plugin name).");
}

- (nullable NSImage *)helpHeaderIcon {
  return [NSImage imageWithSystemSymbolName:@"square.dotted"
                   accessibilityDescription:nil];
}

- (NSArray<KKHelpSection *> *)helpSections {
  // Single-sourced from the AIKnowledge markdown - the same docs the AI reads -
  // so help and AI never drift. Three user-facing topics (the per-directive /
  // audio deep docs stay AI-only), then an on-screen-control shortcut table.
  // topicID is the .md filename stem in the bundle's AIKnowledge subdir.
  NSString * (^loc)(NSString *) = ^NSString *(NSString *tip) {
    return RLoc(tip, @"Mirage help tip (from AIKnowledge markdown).");
  };
  KKHelpSection *overview = [self
      helpSectionFromKnowledgeTopic:@"shader"
                              title:RLoc(@"Mirage", @"Help section: overview.")
                             symbol:@"square.dotted"
                          localizer:loc];
  KKHelpSection *writing = [self
      helpSectionFromKnowledgeTopic:@"custom-shader"
                              title:RLoc(@"Writing a shader",
                                         @"Help section: the shader language.")
                             symbol:@"chevron.left.forwardslash.chevron.right"
                          localizer:loc];
  KKHelpSection *directives =
      [self helpSectionFromKnowledgeTopic:@"directives"
                                    title:RLoc(@"Controls (directives)",
                                               @"Help section: directives.")
                                   symbol:@"slider.horizontal.3"
                                localizer:loc];

  NSMutableArray<KKHelpShortcut *> *rows =
      [[KKPlugin sharedOnScreenControlShortcuts] mutableCopy];
  KKHelpSection *shortcuts =
      [KKHelpSection sectionWithTitle:RLoc(@"On-screen control shortcuts",
                                           @"Help section title.")
                            tipMarkup:nil
                            shortcuts:rows];
  shortcuts.icon = [NSImage imageWithSystemSymbolName:@"hand.point.up.left"
                             accessibilityDescription:nil];

  return @[ overview, writing, directives, shortcuts ];
}

@end
