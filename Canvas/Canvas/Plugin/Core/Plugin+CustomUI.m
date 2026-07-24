/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasInspectorView.h"
#import "CanvasLayerRender.h" // CanvasReadLayerPaths (fresh, not the snapshot)
#import "CanvasLayerTimeline.h"
#import "CanvasLocalized.h"
#import "CanvasMiniViewerRenderer.h" // per-instance mini-viewer rendezvous paths
#import "CanvasOSCGuide.h" // shared OSC guide bridge (canvas-reference gate)
#import "CanvasPresets.h"
#import "CanvasToolbar.h" // CanvasToolbarToolCursor (arrow guide tool save/force)
#import "Constants.h"
#import "Plugin_Private.h"
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKDataBlob.h>
#import <KeyframelessKit/KKHelpSection.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKOnScreenControl.h>
#import <KeyframelessKit/KKPlugin+InspectorCallbacks.h>
#import <KeyframelessKit/KKPluginHost.h> // KKSetProcessTimelineSnapshot
#import <KeyframelessKit/KKPresets.h>
#import <KeyframelessKit/KKSVGParser.h>
#import <KeyframelessKit/KKTimelineAIMerge.h>
#import <KeyframelessKit/KKTimelineInspectorView+Guide.h>
#import <KeyframelessKit/KKTimingGuide.h>
#import <KeyframelessKit/KKTimeline.h>
#import <KeyframelessKit/KKUpdateChecker.h>
@import KeyframelessAI;

@interface CanvasPlugin (GuideScene)
- (void)_guideBeginDemoScene;
- (void)_guideBeginEmptyScene;
- (void)_guideBeginArrowScene;
- (void)_guideEndDemoScene;
- (void)_guideSaveSceneAndSelectionWithGet:(id<FxParameterRetrievalAPI_v6>)get;
@end

// A simple centred rectangle (object space, 0..1, Y-up) the timing guides teach
// on - Canvas is per-layer, so a guide needs a subject the way a single-clip
// plugin always has its clip. Stroke-only + bright so it reads in the viewer.
static KKBezierPath *_CanvasGuideDemoShape(void) {
  KKBezierPath *p = [[KKBezierPath alloc] init];
  p.name = CLoc(@"Guide Shape", @"Name of the temporary demo layer a timing "
                                @"guide teaches on.");
  p.isImage = NO;
  p.isGroup = NO;
  const float lo = 0.3f, hi = 0.7f;
  [p insertAtIndex:0 position:simd_make_float2(lo, lo)];
  [p insertAtIndex:1 position:simd_make_float2(hi, lo)];
  [p insertAtIndex:2 position:simd_make_float2(hi, hi)];
  [p insertAtIndex:3 position:simd_make_float2(lo, hi)];
  p.closed = YES;
  p.strokeEnabled = YES;
  p.strokeWidth = 16.0f;
  p.strokeR = 0.30f;
  p.strokeG = 0.55f;
  p.strokeB = 1.0f;
  p.opacity = 1.0f;
  return p;
}

// The coordinate-space description for Canvas's cross-layer transform lanes.
// Forms the first half of the PROPERTY CATALOG handed to the targeted-routing
// resolve pass (the layer list is supplied separately, per call).
static NSString *_CanvasAITransformSchemaText(void) {
  NSMutableString *s = [NSMutableString string];
  [s appendString:@"Every layer shares these transform lanes (numeric "
                  @"components):\n\n"];
  [s appendString:
          @"- \"Position\": [x, y]. Normalised clip space, 0..1, 0.5 = "
          @"centre.\n"
          @"    x: 0 = left edge, 1 = right edge.\n"
          @"    y: 0 = bottom, 1 = top (Y points UP).\n"
          @"    Off-frame values (< 0 or > 1) are allowed, so a layer can "
          @"start or end fully outside the frame. Default: [0.5, 0.5].\n"
          @"\n"
          @"- \"Scale\": [x, y], whole percentages of the layer's own size. "
          @"100 = original size. Floored at 0, no upper limit, never negative "
          @"(use Rotation to flip). Default: [100, 100].\n"
          @"\n"
          @"- \"Rotation\": [x, y, z], in DEGREES. z = the in-plane spin "
          @"(clockwise positive) - the usual rotation; x and y tilt in 3D. "
          @"Values accumulate past 360 (720 = two turns). Default: [0, 0, 0].\n"
          @"\n"
          @"- \"Opacity\": one component, whole percentage 0..100. 100 = fully "
          @"opaque, 0 = invisible. Default: 100.\n"
          @"\n"
          @"- \"Anchor\": [x, y], the pivot Rotation and Scale swing around, "
          @"in "
          @"the same normalised space as Position relative to the layer "
          @"([0.5, 0.5] = centre). Default: [0.5, 0.5]. Only change it when "
          @"the "
          @"user wants rotation/scale to pivot off-centre.\n"];
  return s;
}

// The non-transform properties the AI can also set or animate (the lanes are
// already in the AI timeline; this just describes their value spaces + how to
// set a constant). Appended after the transform schema.
static NSString *_CanvasAIPropertySchemaText(void) {
  return @"Other per-layer properties (numbers, same tagged-label scheme). To "
         @"set one as a CONSTANT (no animation), emit a single keypose at time "
         @"0; to animate it, emit two or more keyposes.\n"
         @"- \"Enabled\" (stroke on/off), \"Fill Enabled\", \"Sketch "
         @"Enabled\": "
         @"1 = on, 0 = off.\n"
         @"- \"Stroke Width\": one number, in pixels.\n"
         @"- \"Stroke Solid\" / \"Fill Solid\": the colour, [r, g, b, a] each "
         @"0..1 in sRGB (e.g. #f0ff00 = [0.941, 1.0, 0.0, 1.0]). An explicit "
         @"hex "
         @"the user gives ALWAYS wins. For a NAMED colour use these (convert "
         @"the "
         @"hex to [r,g,b,a] 0..1): red #e23b3b, orange #ff8c00, yellow "
         @"#ffd400, "
         @"green #2ecc40, teal #00b3a4, blue #2563eb, purple #9c27b0 (a "
         @"red+blue "
         @"violet - NOT plain blue), pink #ff5fa2, brown #8b5a2b, white "
         @"#ffffff, "
         @"black #111111, grey #888888. For a solid colour also set the "
         @"matching "
         @"\"Stroke Mode\" / \"Fill Mode\" to 0 (0 = Solid, 1 = Gradient; with "
         @"a "
         @"Dynamic option present 0 = Dynamic, 1 = Solid, 2 = Gradient).\n"
         @"- \"Draw On Start\" / \"Draw On End\": the visible portion of the "
         @"stroke, as a PERCENTAGE 0..100 (Start default 0, End default 100 = "
         @"fully drawn). To draw a line on, animate ONLY \"Draw On End\" from "
         @"0 "
         @"to 100; leave \"Draw On Start\" at 0 (do not animate it). \"Draw On "
         @"Offset\" (0..100) slides the revealed window.\n"
         @"- \"Fill Amount\": image tint strength, 0..100.\n"
         @"- \"Marching Ants Speed\": dash scroll, cycles/sec.\n"
         @"Only emit operations for properties the user asked to change.";
}

// sRGB component (0..1) -> linear, matching the stroke/fill colour space the
// renderer stores (KKSVGParser uses the same curve). The AI is asked for sRGB.
static double _CanvasSRGBToLinear(double c) {
  if (c <= 0.0)
    return 0.0;
  if (c >= 1.0)
    return 1.0;
  return (c <= 0.04045) ? (c / 12.92) : pow((c + 0.055) / 1.055, 2.4);
}

// The exact set of (tagged) lane labels the AI's mutation touched, so only
// those are written back - the rest of the AI timeline (every other
// layer/property, seeded as a constant) must not be persisted.
static NSSet<NSString *> *_CanvasMutationLaneLabels(NSString *mutationJSON) {
  NSMutableSet<NSString *> *labels = [NSMutableSet set];
  NSData *d = [mutationJSON dataUsingEncoding:NSUTF8StringEncoding];
  if (!d)
    return labels;
  NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:d
                                                      options:0
                                                        error:nil];
  if (![obj isKindOfClass:[NSDictionary class]])
    return labels;
  NSArray *ops = obj[@"operations"];
  if (![ops isKindOfClass:[NSArray class]])
    return labels;
  for (id op in ops) {
    NSString *lane =
        [op isKindOfClass:[NSDictionary class]] ? op[@"lane"] : nil;
    if ([lane isKindOfClass:[NSString class]] && lane.length)
      [labels addObject:lane];
  }
  return labels;
}

// The plain lane labels worth showing the AI: the cross-layer transforms plus
// the commonly directed stroke/fill/sketch properties. Rarely AI-targeted
// detail (dashes, markers, line cap/join, gradients, fill style metrics, sketch
// seed/bowing) is omitted to keep the prompt small; an already-ANIMATED lane is
// always included regardless, so existing animations stay retimeable.
static BOOL _CanvasAIRelevantLabel(NSString *plain) {
  static NSSet<NSString *> *set;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    set = [NSSet setWithObjects:@"Scale", @"Position", @"Rotation", @"Anchor",
                                @"Opacity", @"Enabled", @"Stroke Width",
                                @"Stroke Mode", @"Stroke Solid",
                                @"Draw On Start", @"Draw On End",
                                @"Draw On Offset", @"Marching Ants Speed",
                                @"Stroke Style", @"Fill Enabled", @"Fill Mode",
                                @"Fill Solid", @"Fill Amount",
                                @"Sketch Enabled", @"Sketch Roughness", nil];
  });
  return [set containsObject:plain];
}

// Turn the resolve pass's Canvas-format operations
//   {"operations":[{"layer":"<name|selected|all>","lane":"<plain>",
//                   "keyposes":[{"t":<seconds>,"v":[..]}]}]}
// into the standard tagged-label mutation the merge + apply consume:
//   {"operations":[{"lane":"<plain>\x1f<layerID>",
//                   "keyposes":[{"time":<fraction>,"values":[..]}]}]}
// Resolves the layer NAME to its id(s) in code (the model never sees ids),
// expands "all"/"selected", and converts seconds -> clip fraction. Colour sRGB
// -> linear and single-keypose-as-constant are handled later in the apply, as
// for any mutation. Returns nil when nothing usable resolves.
// Easing name from the resolve pass -> KKIntervalCurve index. Default EaseInOut
// (3), matching the timeline's own default (smooth, not linear).
static NSInteger _CanvasCurveInt(id raw) {
  NSString *c =
      [raw isKindOfClass:[NSString class]] ? [raw lowercaseString] : @"";
  if ([c isEqualToString:@"linear"])
    return 0;
  if ([c isEqualToString:@"easein"] || [c isEqualToString:@"in"])
    return 1;
  if ([c isEqualToString:@"easeout"] || [c isEqualToString:@"out"])
    return 2;
  if ([c isEqualToString:@"elastic"])
    return 4;
  if ([c isEqualToString:@"bounce"])
    return 5;
  return 3; // easeInOut (default / "ease" / "smooth" / unknown)
}

static NSString *_CanvasStandardMutationFromResolve(
    NSString *opsJSON, NSArray<KKBezierPath *> *paths, double clipDurSec,
    NSString *selectedLayerID) {
  NSData *d = [opsJSON dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *obj =
      d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
  NSArray *ops =
      [obj isKindOfClass:[NSDictionary class]] ? obj[@"operations"] : nil;
  if (![ops isKindOfClass:[NSArray class]])
    return nil;

  NSMutableDictionary<NSString *, NSString *> *byName =
      [NSMutableDictionary dictionary];
  NSMutableArray<NSString *> *allIDs = [NSMutableArray array];
  for (KKBezierPath *p in paths) {
    if (!p.layerID.length)
      continue;
    [allIDs addObject:p.layerID];
    if (p.name.length)
      byName[p.name.lowercaseString] = p.layerID;
  }
  NSString *selID =
      selectedLayerID.length ? selectedLayerID : (allIDs.firstObject ?: @"");
  double dur = (clipDurSec > 0.0 && !isnan(clipDurSec)) ? clipDurSec : 5.0;

  NSMutableArray *stdOps = [NSMutableArray array];
  for (id op in ops) {
    if (![op isKindOfClass:[NSDictionary class]])
      continue;
    NSString *plain = op[@"lane"];
    if (![plain isKindOfClass:[NSString class]] || !plain.length)
      continue;
    NSString *spec = [op[@"layer"] isKindOfClass:[NSString class]]
                         ? [op[@"layer"] lowercaseString]
                         : @"";
    NSArray<NSString *> *targets;
    if ([spec isEqualToString:@"all"])
      targets = allIDs;
    else if (spec.length == 0 || [spec isEqualToString:@"selected"])
      targets = selID.length ? @[ selID ] : @[];
    else {
      NSString *lid = byName[spec];
      targets = lid ? @[ lid ] : (selID.length ? @[ selID ] : @[]);
    }
    NSArray *kps = op[@"keyposes"];
    if (![kps isKindOfClass:[NSArray class]] || kps.count == 0)
      continue;
    NSMutableArray<NSMutableDictionary *> *stdKps = [NSMutableArray array];
    for (id kp in kps) {
      if (![kp isKindOfClass:[NSDictionary class]])
        continue;
      NSArray *v = kp[@"v"];
      if (![v isKindOfClass:[NSArray class]])
        continue;
      double frac = dur > 0.0 ? [kp[@"t"] doubleValue] / dur : 0.0;
      frac = fmax(0.0, fmin(1.0, frac));
      [stdKps addObject:[@{@"time" : @(frac), @"values" : v} mutableCopy]];
    }
    if (stdKps.count == 0)
      continue;
    // Easing rides on the interval LEAVING each keypose, so every keypose but
    // the last gets an `outgoing` curve (smooth by default).
    NSInteger curve = _CanvasCurveInt(op[@"curve"]);
    for (NSUInteger i = 0; i + 1 < stdKps.count; i++)
      stdKps[i][@"outgoing"] = @{@"curve" : @(curve)};
    for (NSString *lid in targets) {
      NSString *tagged = [NSString stringWithFormat:@"%@\x1f%@", plain, lid];
      [stdOps addObject:@{@"lane" : tagged, @"keyposes" : stdKps}];
    }
  }
  if (stdOps.count == 0)
    return nil;
  NSData *outD =
      [NSJSONSerialization dataWithJSONObject:@{@"operations" : stdOps}
                                      options:0
                                        error:nil];
  return outD ? [[NSString alloc] initWithData:outD
                                      encoding:NSUTF8StringEncoding]
              : nil;
}

// Turn an AI-generated SVG document into ready-to-insert Canvas layers: parse
// it (the parser keeps the SVG's stroke/fill + width), order it top-to-bottom,
// wrap multiple shapes in a group, and assign each a fresh layerID + a name.
// Mirrors the Finder-drop SVG import path. Returns nil when nothing parses.
static NSMutableArray<KKBezierPath *> *_CanvasLayersFromSVG(NSString *svg,
                                                            NSString *name) {
  if (!svg.length)
    return nil;
  NSArray<KKBezierPath *> *imported = [KKSVGParser pathsFromSVGString:svg
                                                          canvasWidth:1920.0f
                                                         canvasHeight:1080.0f];
  if (imported.count == 0)
    return nil;
  // SVG paints back-to-front; the layer list is top-to-bottom (front first).
  imported = [[imported reverseObjectEnumerator] allObjects];

  // Safety net: a weak local model sometimes emits a hairline stroke-width
  // relative to its viewBox (imports as ~1-2 canonical px). Floor a visible
  // stroke so an AI annotation never lands invisibly thin. (Finder-drag SVG
  // import keeps full fidelity - this is the AI-create path only.)
  for (KKBezierPath *p in imported)
    if (p.strokeEnabled && p.strokeWidth > 0.0f && p.strokeWidth < 8.0f)
      p.strokeWidth = 8.0f;

  NSMutableArray<KKBezierPath *> *out = [NSMutableArray array];
  if (imported.count == 1) {
    KKBezierPath *single = imported.firstObject;
    single.name = name;
    single.parentGroupID = nil;
    single.layerID = [[NSUUID UUID] UUIDString];
    [out addObject:single];
    return out;
  }
  // Several shapes: wrap them in a group, like a multi-element SVG import.
  KKBezierPath *group = [[KKBezierPath alloc] init];
  group.isGroup = YES;
  group.groupID = [[NSUUID UUID] UUIDString];
  group.layerID = [[NSUUID UUID] UUIDString];
  group.name = name;
  group.strokeEnabled = NO;
  group.fillEnabled = NO;
  [out addObject:group];
  for (NSUInteger i = 0; i < imported.count; i++) {
    KKBezierPath *child = imported[i];
    child.parentGroupID = group.groupID;
    child.layerID = [[NSUUID UUID] UUIDString];
    if (!child.name.length)
      child.name =
          [NSString stringWithFormat:@"%@ %lu", name, (unsigned long)(i + 1)];
    [out addObject:child];
  }
  return out;
}

@implementation CanvasPlugin (CustomUI)

- (void)canvasApplyOSCForLayer:(NSString *)layerID
                          keys:(NSArray<NSString *> *)keys {
  KKPluginInstanceState *ist = KKInstanceStateForAPI(self.apiManager);
  if (!ist)
    return;
  // Resolve the layer up front: its kind picks the default OSC seed AND scopes
  // the checklist below (a vector path has point editing; an image / group only
  // has the transform gizmo).
  // Read the layer stack FRESH from the param (not the published snapshot): on
  // a path-op undo both kParamLayerData + kParamUIState change, and this can
  // run (from the UIState handler) before the blob snapshot is republished -
  // the stale snapshot wouldn't contain the restored operand, so it'd resolve
  // to nil and fall back to the image-like gizmo defaults until a reselect.
  KKBezierPath *layer = nil;
  for (KKBezierPath *p in CanvasReadLayerPaths(self.apiManager, self))
    if ([p.layerID isEqualToString:(layerID ?: @"")]) {
      layer = p;
      break;
    }
  BOOL vector = layer && !layer.isImage && !layer.isGroup &&
                (layer.strokeEnabled || layer.fillEnabled);

  NSDictionary *els = ist.oscElementsByOwner[layerID ?: @""];
  if (![els isKindOfClass:[NSDictionary class]])
    els = [CanvasPlugin
        defaultOSCElementsForVector:vector]; // new / unseen layer -> default
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
  // Scope the OSC checklist's path-only elements ("Points", "Corners") to
  // vector-path layers: images / groups drop them so they don't list controls
  // they can't use. The checklist + its states read this live property (see
  // kkWire), so the next open rebuilds against the scoped set.
  NSMutableArray<NSArray<NSString *> *> *scoped = [NSMutableArray array];
  for (NSArray<NSString *> *c in [CanvasPlugin oscCompounds])
    if (vector ||
        (![c containsObject:@"Points"] && ![c containsObject:@"Corners"]))
      [scoped addObject:c];
  ((KKTimelineInspectorView *)self.inspectorView).oscVisibilityCompounds =
      scoped;
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
    __block KKTimeline *timeline = nil;
    __block NSDictionary *uiState = nil;
    CanvasInspectorView *view = (CanvasInspectorView *)[self
        kkCreateInspectorViewWithUIStateParamID:kParamUIState
        renderNudgeParamID:kParamRenderNudge
        dragUndoLabel:KKUndoLabelAdjust(@"Canvas")
        detachedWindowSize:CGSizeMake(720.0, 460.0)
        builtinPresets:CanvasBuiltinPresets()
        inScope:^(KKInspectorCreateContext *ctx,
                  id<FxParameterRetrievalAPI_v6> getAPI) {
          // Per-layer timelines: the kit inspector EDITS the SELECTED layer's
          // own animationJSON with PLAIN labels (so the Animated dropdown /
          // Constants / Keypose work unchanged). The all-layers overview is
          // drawn separately as read-only context. (NOT the global
          // kKKParamTimelineData; the persisted timeline is unused here.)
          // Selection is the topmost layer until panel-driven selection lands.
          NSString *layerB64 = KKReadCustomParamString(getAPI, kParamLayerData);
          NSMutableArray<KKBezierPath *> *layerPaths =
              layerB64.length
                  ? [KKBezierPath
                        pathsFromBlob:[[NSData alloc]
                                          initWithBase64EncodedString:layerB64
                                                              options:0]]
                  : [NSMutableArray array];
          KKTimeline *layerTL = CanvasLayerTimelineForPath(
              CanvasSelectedLayerForPaths(layerPaths, nil),
              [CanvasPlugin availableLanes]);
          timeline = [self timelineStampedWithClipDuration:layerTL];
          uiState = ctx.persistedState.uiState;
          // Publish the full UIState JSON for the viewer OSC (it can't read
          // the custom param) - it reads view-prefs like "autoSelect" and uses
          // it as the base to merge a new selection into on a hit-test click.
          CanvasSetUIStateSnapshot(
              KKReadCustomParamString(getAPI, kParamUIState));
        }
        buildView:^KKTimelineInspectorView *(KKInspectorCreateContext *ctx) {
          KKInspectorPersistedState *st = ctx.persistedState;
          CanvasInspectorView *v = [[CanvasInspectorView alloc]
              initWithAPIManager:self.apiManager
                     loopEnabled:st.loopEnabled
           maintainTimingEnabled:st.maintainTimingEnabled
                       activeTab:st.activeTab
                  availableLanes:[CanvasPlugin availableLanes]
                        timeline:timeline];
          // Per-instance rendezvous paths (keyed by the instance UUID) so two
          // stacked Canvas clips read/write distinct /tmp files instead of
          // the clip below showing the top clip's source in its mini-viewer.
          v.miniViewerDescriptorPath =
              CanvasMiniViewerDescriptorPathForUUID(ctx.instanceUUID);
          v.miniViewerRequestPath =
              CanvasMiniViewerRequestPathForUUID(ctx.instanceUUID);
          return v;
        }];
    if (!view)
      return nil;

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
      // Swallow the guide host's single async timeline-restore write: Canvas
      // restores the whole demo scene itself in -_guideEndDemoScene, so letting
      // this write through would apply the stale saved timeline to the restored
      // selection (clobbering it / wiping the topmost layer when nothing was
      // selected). One-shot - the very next mutation is the kit's restore.
      if (s.guideSuppressMutate) {
        s.guideSuppressMutate = NO;
        return;
      }
      KKPerformUndoable(
          s.apiManager, s, nil,
          ^(id<FxParameterRetrievalAPI_v6> get,
            id<FxParameterSettingAPI_v5> set, CMTime actionTime) {
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
          // Republish the process snapshot so the viewer OSC recomputes visibility
          // on the drawOSC the param write forces - moving a lane into/out of
          // Animated flips its OSC's keypose-gated visibility, but the OSC reads
          // the snapshot (not the param), so without this it keeps the pre-toggle
          // visibility until the next selection/edit republishes it.
          KKTimeline *stamped = [s timelineStampedWithClipDuration:updated];
          KKSetProcessTimelineSnapshot(stamped ?: updated);
      });
      // After a guide's seed lands on the demo layer, refresh the Advanced
      // graph from the new blob: the seed flows through here into the SELECTED
      // layer's currentTimeline (which the Basic graph reads), but the Advanced
      // graph shows the MERGED graphTimeline rebuilt from the blob - so without
      // this the Advanced / Mini-Viewer / OSC guides' keypose lookups find
      // nothing. One-shot per guide (the seed is the first mutation after
      // staging).
      if (s.guideNeedsGraphRefresh && s.guideSceneActive) {
        s.guideNeedsGraphRefresh = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
          [(CanvasInspectorView *)s.inspectorView reloadLayerList];
        });
      }
    };

    // Keypose edits in either graph mutate the ALL-LAYERS graph timeline; split
    // it back per layer (by layerKey) and write each layer's animationJSON.
    view.basicLanesView.onGraphTimelineMutated = ^(KKTimeline *merged) {
      __strong CanvasPlugin *s = weakSelf;
      if (!s)
        return;
      KKPerformUndoable(
          s.apiManager, s, nil,
          ^(id<FxParameterRetrievalAPI_v6> get,
            id<FxParameterSettingAPI_v5> set, CMTime actionTime) {
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
      });
    };

    // Let the intro guide's closing step spotlight this effect's Help button
    // (owned by the plugin's logo banner, resolved live).
    __weak typeof(self) weakHelp = self;
    view.guideHelpButtonScreenRectProvider = ^NSRect {
      return [weakHelp helpButtonScreenRect];
    };

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
    // this is the missing half (it also gives opt-click-in-mini hide/show).
    // handlesHidden + hiddenHandleLabels stay owned by
    // -syncMiniHandleVisibility (so lock ORs in without fighting the kit's
    // async master set); kkRefresh below keeps nil for the same reason.
    [self kkWireOSCVisibilityForView:view
                            renderer:(KKMiniViewerRenderer *)
                                         view.miniViewerDelegate
                           compounds:oscCompounds
                             paramID:kParamUIState];
    NSArray<NSString *> *oscKeys =
        [CanvasPlugin kkOSCElementKeysForCompounds:oscCompounds];
    // Force OSCs visible while a timing guide runs (so its Position handle is
    // on screen), then restore the user's OSC setting on guide end. Canvas
    // defaults the master OFF, so without this the OSC guide would teach
    // controls that aren't drawn. The render nudge makes the viewer redraw on
    // force/restore. TEMPORARILY SKIPPED for leak isolation: if the leak stops
    // with OSC forcing off, the forced viewer-OSC rendering during the guide's
    // playback is the cause. Flip to NO to re-enable.
    static const BOOL kSkipOSCForcingForLeakTest = NO;
    if (!kSkipOSCForcingForLeakTest)
      [self kkInstallGuideOSCForcingOnHost:[view timingGuideHost]
                                      view:view
                               elementKeys:oscKeys
                              nudgeParamID:kParamRenderNudge];
    // Demo-scene staging: each timing guide saves the user's scene + drops in a
    // single demo shape to teach on (Canvas is per-layer, so without a subject
    // the guides are empty), restoring the scene when the guide ends. -begin
    // runs from the inspector's restart override (before the kit seeds);
    // -end is chained onto the OSC-forcing run-did-end hook above.
    view.onGuideSceneBegin = ^{
      __strong CanvasPlugin *s = weakSelf;
      [s _guideBeginDemoScene];
    };
    // Presets guide stages an EMPTY scene instead; same run-did-end restore.
    view.onGuidePresetsSceneBegin = ^{
      __strong CanvasPlugin *s = weakSelf;
      [s _guideBeginEmptyScene];
    };
    // Arrow guide stages an empty scene + activates the Pen tool so the user
    // can draw the demo path; same run-did-end restore.
    view.onGuideArrowSceneBegin = ^{
      __strong CanvasPlugin *s = weakSelf;
      [s _guideBeginArrowScene];
    };
    KKJoyrideGuideHost *guideHost = [view timingGuideHost];
    // Hide the Help window for the duration of ANY guide so it's never in the
    // way, and reopen it when the guide ends. Chain (not clobber) the hooks the
    // OSC-forcing install set above.
    void (^priorRunWillStart)(void) = guideHost.onRunWillStart;
    guideHost.onRunWillStart = ^{
      if (priorRunWillStart)
        priorRunWillStart();
      __strong CanvasPlugin *s = weakSelf;
      if (!s)
        return;
      s.guideRunGeneration = s.guideRunGeneration + 1;
      [s closeRemoteWindowIfSupported];
    };
    void (^priorRunDidEnd)(void) = guideHost.onRunDidEnd;
    guideHost.onRunDidEnd = ^{
      if (priorRunDidEnd)
        priorRunDidEnd();
      __strong CanvasPlugin *s = weakSelf;
      if (!s)
        return;
      [s _guideEndDemoScene];
      // Reopen the Help window next tick, unless another guide started in the
      // meantime (a restart bumps the generation), which would flicker it.
      NSInteger gen = s.guideRunGeneration;
      dispatch_async(dispatch_get_main_queue(), ^{
        __strong CanvasPlugin *s2 = weakSelf;
        if (s2 && s2.guideRunGeneration == gen)
          [s2 openHelpRemoteWindow];
      });
    };
    NSMutableDictionary *visState =
        [uiState mutableCopy] ?: [NSMutableDictionary dictionary];
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
    // 1 instead of the layer that was selected when the project was saved. Do
    // it BEFORE canvasApplyOSCForLayer so the OSC visibility set is the
    // restored layer's. restoreSelectedLayerID self-guards no-ops; the
    // persist-on-select block isn't wired yet (so no churn), but flag
    // restoringSelection anyway.
    NSString *savedSel = visState[@"selectedLayerID"];
    NSArray<NSString *> *savedSelIDs =
        [visState[@"selectedLayerIDs"] isKindOfClass:[NSArray class]]
            ? visState[@"selectedLayerIDs"]
            : nil;
    if (([savedSel isKindOfClass:[NSString class]] && savedSel.length) ||
        savedSelIDs.count) {
      self.restoringSelection = YES;
      [view restoreSelectedLayerIDs:savedSelIDs primary:savedSel];
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
      // Index into the LIVE (per-layer scoped) compounds, not the full set, so
      // the checklist's row indices map to the right element after Points is
      // dropped for an image / group.
      NSArray<NSArray<NSString *> *> *cmp =
          ((KKTimelineInspectorView *)s.inspectorView).oscVisibilityCompounds;
      if (compoundIdx < 0 || compoundIdx >= (NSInteger)cmp.count ||
          segIdx < 0 || segIdx >= (NSInteger)cmp[compoundIdx].count)
        return;
      [s canvasToggleOSCElement:cmp[compoundIdx][segIdx]
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
    view.onSelectedLayerChanged =
        ^(NSString *resolvedLayerID, NSArray<NSString *> *selectedLayerIDs) {
          __strong CanvasPlugin *s = weakOSC;
          [s canvasApplyOSCForLayer:resolvedLayerID keys:oscKeys];
          // Persist the selection so it lands on the undo stack (like standard
          // editors: changing the active layer is itself undoable). Skip while
          // restoring from an undo/redo, else we'd push a duplicate entry. The
          // primary id and the full multi-selection set go in ONE action
          // (patchUIStateKeys) so they're a single undo entry. The
          // kParamUIState write also forces the render round-trip that redraws
          // the viewer OSC, so no separate kParamRenderNudge is needed (it
          // would only add a phantom undo entry - the "takes two cmd-Z"
          // problem).
          if (!s.restoringSelection)
            [s patchUIStateKeys:@{
              @"selectedLayerID" : (resolvedLayerID ?: @""),
              @"selectedLayerIDs" : (selectedLayerIDs ?: @[])
            }
                        paramID:kParamUIState];
        };

    // "Auto-select layers" toggle: seed the checkbox from the persisted state
    // (OFF when absent) and persist flips to kParamUIState. The write triggers
    // parameterChanged, which re-publishes the UIState snapshot the viewer OSC
    // reads.
    [view setAutoSelect:(visState[@"autoSelect"]
                             ? [visState[@"autoSelect"] boolValue]
                             : YES)]; // default ON
    // Seed the mini's grid + toolbar state on cold load too (pluginState only
    // fires on a change, so without this the mini grid / toolbar position would
    // sit at defaults until the user interacts).
    [view setGridEnabled:[visState[@"gridEnabled"] boolValue]
                adaptive:(visState[@"gridAdaptive"]
                              ? [visState[@"gridAdaptive"] boolValue]
                              : YES)spacing
                        :(visState[@"gridSpacing"]
                              ? [visState[@"gridSpacing"] integerValue]
                              : 10)snap:[visState[@"gridSnap"] boolValue]];
    NSArray *seedTbPos = visState[@"miniToolbarPos"];
    CGPoint seedTbNorm =
        ([seedTbPos isKindOfClass:[NSArray class]] && seedTbPos.count == 2)
            ? CGPointMake([seedTbPos[0] doubleValue],
                          [seedTbPos[1] doubleValue])
            : CGPointMake(-1, -1);
    [view setToolbarTool:(visState[@"tool"] ? [visState[@"tool"] integerValue]
                                            : 0)
                 normPos:seedTbNorm];
    view.onAutoSelectChanged = ^(BOOL on) {
      __strong CanvasPlugin *s = weakOSC;
      [s patchUIStateKey:@"autoSelect" value:@(on) paramID:kParamUIState];
    };
    // Mini-viewer toolbar toggles / drag persist their kParamUIState key the
    // same way; the write round-trips to refresh both the viewer OSC + the
    // mini.
    view.onUIStatePatch = ^(NSString *key, id value) {
      __strong CanvasPlugin *s = weakOSC;
      [s patchUIStateKey:key value:value paramID:kParamUIState];
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

// Save the user's scene + selection and swap in a single demo shape for a
// timing guide to teach on. Runs synchronously from the inspector's restart
// override, BEFORE the kit captures the current timeline + applies its seed -
// so the seed (Position/Scale) lands on the demo shape. Restored in
// -_guideEndDemoScene when the guide ends.
- (void)_guideBeginDemoScene {
  // TEMPORARILY STRIPPED for leak isolation: don't stage a demo shape, so the
  // guide runs on the user's own selected layer. If the leak stops with this,
  // the demo-scene swap (param writes / fresh layerID per run) is the cause.
  // Re-enable by flipping this to NO.
  static const BOOL kStripDemoSceneForLeakTest = NO;
  if (kStripDemoSceneForLeakTest)
    return;
  if (self.guideSceneActive)
    return; // already staged (defensive)
  CanvasInspectorView *view = (CanvasInspectorView *)self.inspectorView;
  id<FxCustomParameterActionAPI_v4> act =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!view || !act) {
    KKLogWarn(@"Canvas guide: can't stage demo scene (view/action API nil)");
    return;
  }
  // The demo shape is needed after the scope too (its layerID keys the
  // per-layer OSC seed + selection below).
  KKBezierPath *demo = _CanvasGuideDemoShape();
  __block NSString *demoB64 = nil;
  KKPerformUndoable(
      self.apiManager, self, nil,
      ^(id<FxParameterRetrievalAPI_v6> get, id<FxParameterSettingAPI_v5> set,
        CMTime actionTime) {
        // Save the whole layer blob + the persisted selection so we can
        // restore them.
        [self _guideSaveSceneAndSelectionWithGet:get];
        // Replace the scene with just the demo shape (a clean stage, like
        // other plugins seeding the clip).
        NSData *blob = [KKBezierPath blobFromPaths:@[ demo ]];
        demoB64 = [blob base64EncodedStringWithOptions:0];
        KKWriteCustomParamString(set, demoB64, kParamLayerData);
      });
  self.guideSceneActive = YES;
  self.guideNeedsGraphRefresh = YES;
  // Seed the demo layer's PER-LAYER OSC visibility to Position-only. Canvas
  // keys OSC visibility per layer (oscElementsByOwner[layerID]); an unseen
  // vector path defaults to its Points handles, so without this the timing
  // guides (which all teach Position) would draw Points instead. Must be set
  // BEFORE the select below - canvasApplyOSCForLayer: reads this map on
  // selection. In-memory only (the demo layer is removed on guide end, so its
  // entry is transient).
  KKPluginInstanceState *ist = KKInstanceStateForAPI(self.apiManager);
  NSArray<NSString *> *oscKeys =
      [CanvasPlugin kkOSCElementKeysForCompounds:[CanvasPlugin oscCompounds]];
  NSMutableDictionary<NSString *, NSNumber *> *els =
      [NSMutableDictionary dictionaryWithCapacity:oscKeys.count];
  for (NSString *k in oscKeys)
    els[k] = @([k isEqualToString:@"Position"]);
  NSMutableDictionary *byLayer = [(ist.oscElementsByOwner ?: @{}) mutableCopy];
  byLayer[demo.layerID] = els;
  ist.oscElementsByOwner = byLayer;
  // Publish the demo blob to the OSC's snapshot (it can't read the param) and
  // refresh the inspector's layer list + select the demo so the seed targets
  // it.
  CanvasSetLayerBlobSnapshot(demoB64);
  [view reloadLayerList];
  [view restoreSelectedLayerID:demo.layerID];
  KKLogInfo(@"Canvas guide: staged demo scene (saved %lu chars of layer blob)",
            (unsigned long)self.guideSavedLayerB64.length);
}

// Save the current layer blob + persisted selection (so -_guideEndDemoScene can
// restore them). Shared by the demo-shape and empty seeds. Must run inside an
// action scope (the caller's), so `get` resolves.
- (void)_guideSaveSceneAndSelectionWithGet:(id<FxParameterRetrievalAPI_v6>)get {
  self.guideSavedLayerB64 =
      KKReadCustomParamString(get, kParamLayerData) ?: @"";
  self.guideSavedSelPrimary = nil;
  self.guideSavedSelIDs = nil;
  NSString *uiStr = KKReadCustomParamString(get, kParamUIState);
  if (uiStr.length) {
    NSDictionary *ui = [NSJSONSerialization
        JSONObjectWithData:[uiStr dataUsingEncoding:NSUTF8StringEncoding]
                   options:0
                     error:nil];
    if ([ui isKindOfClass:[NSDictionary class]]) {
      NSString *prim = ui[@"selectedLayerID"];
      self.guideSavedSelPrimary = prim.length ? prim : nil;
      NSArray *ids = ui[@"selectedLayerIDs"];
      if ([ids isKindOfClass:[NSArray class]])
        self.guideSavedSelIDs = ids;
    }
  }
}

// Stage an EMPTY scene for the Presets guide (a preset is applied onto a clean
// canvas, so a demo shape would just be in the way). Saves the user's scene
// like
// -_guideBeginDemoScene; the shared run-did-end hook restores it. Same
// guideSceneActive bookkeeping, so the restore path is identical.
- (void)_guideBeginEmptyScene {
  if (self.guideSceneActive)
    return;
  CanvasInspectorView *view = (CanvasInspectorView *)self.inspectorView;
  id<FxCustomParameterActionAPI_v4> act =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!view || !act) {
    KKLogWarn(@"Canvas guide: can't stage empty scene (view/action API nil)");
    return;
  }
  KKPerformUndoable(
      self.apiManager, self, nil,
      ^(id<FxParameterRetrievalAPI_v6> get, id<FxParameterSettingAPI_v5> set,
        CMTime actionTime) {
        [self _guideSaveSceneAndSelectionWithGet:get];
        KKWriteCustomParamString(set, @"", kParamLayerData);
      });
  self.guideSceneActive = YES;
  self.guideNeedsGraphRefresh = YES;
  CanvasSetLayerBlobSnapshot(nil);
  [view reloadLayerList];
  KKLogInfo(@"Canvas guide: staged empty scene (saved %lu chars of layer blob)",
            (unsigned long)self.guideSavedLayerB64.length);
}

// The "Animating an Arrow" guide draws its own subject, so it stages the same
// empty scene as Presets, then forces the Cursor tool so the guided "switch to
// Pen" step has a real change to make. The user's prior tool is saved and
// restored on guide end (-_guideEndDemoScene). The user switches to Pen
// themselves as a step, so they learn where it lives.
- (void)_guideBeginArrowScene {
  [self _guideBeginEmptyScene];
  if (!self.guideSceneActive)
    return; // staging failed (logged in -_guideBeginEmptyScene)
  id<FxCustomParameterActionAPI_v4> act =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!act)
    return;
  __block NSInteger tool = CanvasToolbarToolCursor;
  KKPerformUndoable(
      self.apiManager, self, nil,
      ^(id<FxParameterRetrievalAPI_v6> get, id<FxParameterSettingAPI_v5> set,
        CMTime actionTime) {
        NSString *uiStr = KKReadCustomParamString(get, kParamUIState);
        if (uiStr.length) {
          NSDictionary *ui = [NSJSONSerialization
              JSONObjectWithData:[uiStr dataUsingEncoding:NSUTF8StringEncoding]
                         options:0
                           error:nil];
          if ([ui isKindOfClass:[NSDictionary class]] && ui[@"tool"])
            tool = [ui[@"tool"] integerValue];
        }
      });
  self.guideSavedTool = tool;
  // Force Cursor (patchUIStateKey opens its own action scope + merges the key).
  [self patchUIStateKey:@"tool"
                  value:@(CanvasToolbarToolCursor)
                paramID:kParamUIState];
}

// Restore the user's scene + selection after a timing guide ends. Chained onto
// the guide host's run-did-end hook (fires on completion OR skip).
- (void)_guideEndDemoScene {
  if (!self.guideSceneActive)
    return;
  self.guideSceneActive = NO;
  CanvasInspectorView *view = (CanvasInspectorView *)self.inspectorView;
  id<FxCustomParameterActionAPI_v4> act =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!view || !act) {
    KKLogWarn(@"Canvas guide: can't restore demo scene (view/action API nil)");
    return;
  }
  // Swallow the guide host's one async timeline-restore write (it would apply
  // the stale pre-guide timeline to the restored selection).
  self.guideSuppressMutate = YES;
  NSString *savedB64 = self.guideSavedLayerB64 ?: @"";
  KKPerformUndoable(
      self.apiManager, self, nil,
      ^(id<FxParameterRetrievalAPI_v6> get, id<FxParameterSettingAPI_v5> set,
        CMTime actionTime) {
        KKWriteCustomParamString(set, savedB64, kParamLayerData);
      });
  CanvasSetLayerBlobSnapshot(savedB64.length ? savedB64 : nil);
  [view reloadLayerList];
  [view restoreSelectedLayerIDs:(self.guideSavedSelIDs ?: @[])
                        primary:self.guideSavedSelPrimary];
  self.guideSavedLayerB64 = nil;
  self.guideSavedSelPrimary = nil;
  self.guideSavedSelIDs = nil;
  // Restore the tool the Arrow guide forced to Cursor (0 = no Arrow guide ran).
  if (self.guideSavedTool != 0) {
    [self patchUIStateKey:@"tool"
                    value:@(self.guideSavedTool)
                  paramID:kParamUIState];
    self.guideSavedTool = 0;
  }
  KKLogInfo(@"Canvas guide: restored user scene");
}

- (NSArray<KKHelpGuide *> *)helpGuides {
  // The Introduction / Advanced Timing / Mini Viewer / On-Screen Controls /
  // Presets walkthroughs are identical across plugins - the kit builds them
  // from the live inspector. Gated on the OSC's canvas reference (set once the
  // user focuses the effect on a clip and moves over the viewer), like every
  // other plugin: the guides cut out the FCP viewer / boundary popover, which
  // only resolve once the OSC bridge has a draw tick, so they show the
  // "disabled until you focus the effect" subtitle until then.
  __weak typeof(self) weak = self;
  BOOL (^enabled)(void) = ^BOOL {
    return CanvasSharedOSCGuideBridge().hasCanvasReference;
  };
  NSMutableArray<KKHelpGuide *> *guides = [[KKTimingGuide
      standardHelpGuidesForInspectorProvider:^KKTimelineInspectorView * {
        __strong typeof(weak) strong = weak;
        return strong.inspectorView;
      }
                             enabledProvider:enabled] mutableCopy];

  // Canvas-specific end-to-end walkthrough: draw a path, give it an arrow
  // marker, and animate it drawing on. Gated on the same OSC-canvas reference
  // as the others (it spotlights the viewer).
  __block __weak KKHelpGuide *weakArrow = nil;
  KKHelpGuide *arrow = [KKHelpGuide
      guideWithTitle:CLoc(@"Animating an Arrow",
                          @"Help guide title: arrow workflow walkthrough.")
            subtitle:
                CLoc(@"Draw a path, add an arrow, and animate it drawing on",
                     @"Help guide subtitle: Animating an Arrow.")
             onStart:^{
               __strong typeof(weak) s = weak;
               CanvasInspectorView *iv = (CanvasInspectorView *)s.inspectorView;
               if (!iv)
                 return;
               KKHelpGuide *live = weakArrow;
               iv.onGuideCompleted = ^{
                 [live markCompleted];
               };
               [iv runArrowGuide];
             }];
  weakArrow = arrow;
  arrow.identifier = @"canvas.arrow";
  arrow.enabledProvider = enabled;
  arrow.disabledSubtitle = CLoc(
      @"Guides are disabled. Click the effect's header on a clip to select "
      @"it, then move your mouse over the viewer to enable them.",
      @"Help guide disabled subtitle (no OSC canvas reference yet).");
  [guides addObject:arrow];
  return guides;
}

- (nullable NSImage *)helpHeaderIcon {
  return [NSImage imageWithSystemSymbolName:@"pencil.and.outline"
                   accessibilityDescription:nil];
}

// Lets the Help window poll the guides' enabled state live (1s timer + this
// notification on the enable edge): without it the disabled-guides warning is
// evaluated once when the window opens and never updates - so it would clear on
// first focus and never reappear when the effect is deselected again.
- (nullable NSNotificationName)helpGuideRefreshNotificationName {
  return CanvasSharedOSCGuideBridge().guidePositionNotificationName;
}

// One help section per AIKnowledge topic, single-sourced from the markdown so
// the help window and the AI read the same text. `symbol` is the section icon.
- (KKHelpSection *)_canvasHelpSectionForTopic:(NSString *)topic
                                        title:(NSString *)title
                                       symbol:(NSString *)symbol {
  return
      [self helpSectionFromKnowledgeTopic:topic
                                    title:title
                                   symbol:symbol
                                localizer:^NSString *(NSString *tip) {
                                  return CLoc(tip, @"Canvas help tip (from "
                                                   @"AIKnowledge markdown).");
                                }];
}

- (NSArray<KKHelpSection *> *)helpSections {
  // A short overview, then one section per property group (Core / Transform /
  // Stroke / Fill / Sketch - mirroring the inspector's lane groups), each
  // single-sourced from its AIKnowledge markdown, then the shortcuts table.
  KKHelpSection *overview = [self
      _canvasHelpSectionForTopic:@"canvas"
                           title:CLoc(@"Canvas",
                                      @"Help section title (plugin name).")
                          symbol:@"pencil.and.outline"];
  KKHelpSection *core =
      [self _canvasHelpSectionForTopic:@"core"
                                 title:CLoc(@"Core",
                                            @"Help section title (geometry).")
                                symbol:@"point.topleft.down.to.point."
                                       @"bottomright.curvepath"];
  KKHelpSection *transform = [self
      _canvasHelpSectionForTopic:@"transform"
                           title:CLoc(@"Transform",
                                      @"Help section title (transform).")
                          symbol:@"arrow.up.and.down.and.arrow.left.and.right"];
  KKHelpSection *stroke =
      [self _canvasHelpSectionForTopic:@"stroke"
                                 title:CLoc(@"Stroke",
                                            @"Help section title (stroke).")
                                symbol:@"scribble"];
  KKHelpSection *fill = [self
      _canvasHelpSectionForTopic:@"fill"
                           title:CLoc(@"Fill", @"Help section title (fill).")
                          symbol:@"drop.fill"];
  KKHelpSection *sketch =
      [self _canvasHelpSectionForTopic:@"sketch"
                                 title:CLoc(@"Sketch",
                                            @"Help section title (sketch).")
                                symbol:@"pencil.and.scribble"];
  KKHelpSection *grid = [self
      _canvasHelpSectionForTopic:@"grid"
                           title:CLoc(@"Grid", @"Help section title (grid).")
                          symbol:@"grid"];

  // Glyph-only keys carry nothing to translate (pure <kbd> symbols), so they
  // stay literal - only the description is localized. Mirrors the kit's
  // sharedOnScreenControlShortcuts ("<kbd>⌘ 0</kbd>" is a plain literal there).
  KKHelpShortcut * (^g)(NSString *, NSString *) =
      ^KKHelpShortcut *(NSString *keys, NSString *desc) {
        return [KKHelpShortcut
            shortcutWithKeysMarkup:keys
                        descMarkup:CLoc(desc, @"Canvas keyboard shortcut.")];
      };
  // Keys that contain words (a gesture phrase) localize both sides.
  KKHelpShortcut * (^kbd)(NSString *, NSString *) =
      ^KKHelpShortcut *(NSString *keys, NSString *desc) {
        return [KKHelpShortcut
            shortcutWithKeysMarkup:CLoc(keys, @"Canvas keyboard shortcut keys.")
                        descMarkup:CLoc(desc, @"Canvas keyboard shortcut.")];
      };
  NSMutableArray<KKHelpShortcut *> *rows = [@[
    g(@"<kbd>⌃ V</kbd> / <kbd>⌃ X</kbd> / <kbd>⌃ B</kbd> / <kbd>⌃ G</kbd>",
      @"Cursor / pen / rectangle / ellipse tool"),
    g(@"<kbd>⌫</kbd>",
      @"Delete the selected layers, or anchors of an edited path"),
    g(@"<kbd>⌘ G</kbd>", @"Group the selected layers"),
    g(@"<kbd>⌘ D</kbd>", @"Duplicate the selected layers"),
    g(@"<kbd>⌘ ]</kbd> / <kbd>⌘ [</kbd>",
      @"Bring the selected layers forward / send them backward"),
    g(@"<kbd>⌘ Z</kbd> / <kbd>⇧ ⌘ Z</kbd>", @"Undo / redo"),
    g(@"<kbd>↩</kbd> / <kbd>⎋</kbd>",
      @"Finish / cancel the path you're drawing with the pen"),
    kbd(@"Double-click a point", @"Toggle a smooth curve or a sharp corner"),
    kbd(@"<kbd>⇧</kbd> + drag a point or handle",
        @"Lock the move to horizontal / vertical"),
    kbd(@"<kbd>⌘</kbd> + drag a point or handle",
        @"Snap a point to align with others, or a handle to 45°"),
    kbd(@"<kbd>⌃</kbd> + drag a handle", @"Break the curve handle's symmetry"),
    kbd(@"Drag the Position handle", @"Move the selected layer on the canvas"),
    kbd(@"Drag the Scale box", @"Resize the selected layer"),
    kbd(@"Drag a Rotation ring", @"Spin the selected layer"),
  ] mutableCopy];
  [rows addObjectsFromArray:[KKPlugin sharedOnScreenControlShortcuts]];

  KKHelpSection *shortcuts =
      [KKHelpSection sectionWithTitle:CLoc(@"Shortcuts", @"Help section title.")
                            tipMarkup:nil
                            shortcuts:rows];
  shortcuts.icon = [NSImage imageWithSystemSymbolName:@"keyboard"
                             accessibilityDescription:nil];

  return @[ overview, core, transform, stroke, fill, sketch, grid, shortcuts ];
}

- (nullable NSView *)aiAccessoryView {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // Shared timeline docs live in the kit framework bundle (so the kit help
    // window renders the same source); register them from there.
    [KKAIKnowledge registerSharedTimelineDocsWithBundle:
                       [NSBundle bundleForClass:[KKOnScreenControl class]]];
    [KKAIKnowledge
        registerBundleDocsWithName:@"Canvas"
                            bundle:[NSBundle
                                       bundleForClass:[CanvasPlugin class]]
                      subdirectory:@"AIKnowledge"];
    // Shared on-screen-control docs live in the kit framework. Canvas uses the
    // Position handle / motion path, the Rotation gizmo, and the visibility
    // system, so expose those topics.
    [KKAIKnowledge
        registerBundleDocsWithName:@"On-Screen Controls"
                            bundle:[NSBundle
                                       bundleForClass:[KKOnScreenControl class]]
                      subdirectory:nil
                      onlyTopicIDs:@[
                        @"visibility", @"rotation", @"position"
                      ]];
    // Color (Solid / Gradient) is a shared property whose doc lives in the kit
    // framework. Canvas uses it for the stroke + fill colour, so opt in.
    [KKAIKnowledge
        registerBundleDocsWithName:@"Color"
                            bundle:[NSBundle
                                       bundleForClass:[KKOnScreenControl class]]
                      subdirectory:nil
                      onlyTopicIDs:@[ @"color" ]];
  });

  NSString *productContext = CLoc(
      @"Canvas, a Final Cut Pro plugin for drawing and animating a stack of "
      @"layers (vector shapes, imported images and SVGs, and groups) over a "
      @"clip, using the shared Keyframeless timeline system (Basic and "
      @"Advanced timing, easing, motion blur). Every layer can animate its "
      @"transform (position, scale, rotation, anchor, opacity); vector layers "
      @"can also animate stroke, fill, sketch and draw-on. Always refer to "
      @"yourself as Canvas. Detailed feature information is in the reference "
      @"docs below.",
      @"AI assistant product context for Canvas plugin.");

  NSArray<NSArray<NSString *> *> *examples = @[
    @[
      CLoc(@"Slide the top layer in", @"AI example chip: slide a layer in."),
      CLoc(@"Animate the topmost layer sliding in from off the left edge to "
           @"its place over the first second.",
           @"AI example value: slide a layer in.")
    ],
    @[
      CLoc(@"Draw on the stroke", @"AI example chip: draw on the stroke."),
      CLoc(@"Reveal the stroke of the selected path by animating its draw-on "
           @"from nothing to fully drawn across the clip.",
           @"AI example value: draw on the stroke.")
    ],
    @[
      CLoc(@"Fade everything in", @"AI example chip: fade everything in."),
      CLoc(@"Fade every layer's opacity up from 0 to 100 over the first half "
           @"second.",
           @"AI example value: fade everything in.")
    ],
    @[
      CLoc(@"What's Basic vs Advanced?",
           @"AI example chip: Basic vs Advanced timing question."),
      CLoc(@"What's the difference between Basic and Advanced timing?",
           @"AI example value: Basic vs Advanced timing question.")
    ],
  ];

  NSString *placeholder = CLoc(@"Ask a question or describe an animation…",
                               @"AI prompt field placeholder for Canvas.");

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
                                           productContext:productContext
                                              allowCreate:YES];
                                   }];
}

- (void)_runAIPrompt:(NSString *)prompt
      productContext:(NSString *)productContext
         allowCreate:(BOOL)allowCreate {
  [KKAIDraft setRouting:YES];
  [KKAIDraft setError:nil];

  NSArray<KKLane *> *templates = [CanvasPlugin availableLanes];
  __block NSArray<KKBezierPath *> *paths = @[];
  __block NSString *currentJSON = nil;
  __block double clipDurSec = 5.0;
  __block NSString *selectedLayerID = nil;
  BOOL scoped = KKPerformUndoable(
      self.apiManager, self, nil,
      ^(id<FxParameterRetrievalAPI_v6> getAPI,
        id<FxParameterSettingAPI_v5> setAPI, CMTime actionTime) {
        NSString *b64 = KKReadCustomParamString(getAPI, kParamLayerData);
        paths = b64.length
                    ? [KKBezierPath
                          pathsFromBlob:[[NSData alloc]
                                            initWithBase64EncodedString:b64
                                                                options:0]]
                    : @[];
        // The all-layers AI timeline: every layer's transform lanes (seeded)
        // plus any lane it already animates, each label tagged
        // "<property>\x1f<layerID>" so a mutation can target a specific layer
        // and the result feeds straight back through
        // CanvasApplyMergedTimelineToPaths.
        currentJSON =
            [KKTimeline jsonFromTimeline:CanvasAITimeline(paths, templates)];
        id<FxTimingAPI_v4> timingAPI =
            [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
        CMTime clipDur = kCMTimeZero;
        if (timingAPI)
          [timingAPI durationTimeForEffect:&clipDur];
        clipDurSec = CMTimeGetSeconds(clipDur);
        if (clipDurSec <= 0 || isnan(clipDurSec))
          clipDurSec = 5.0;
        selectedLayerID =
            ((CanvasInspectorView *)self.inspectorView).resolvedSelectedLayerID;
      });
  if (!scoped) {
    [KKAIDraft setRouting:NO];
    [KKAIDraft setError:@"Couldn't open the FCP action scope."];
    return;
  }

  // Targeted routing: the model gets a compact PROPERTY CATALOG + the layer
  // NAMES (never the whole timeline, never layer ids), then resolves the edit
  // directly. Tiny prompt - fast, especially on local. `currentJSON` (the full
  // timeline) is kept only for the merge in the completion below.
  NSMutableString *propertyCatalog = [NSMutableString string];
  [propertyCatalog appendString:_CanvasAITransformSchemaText()];
  [propertyCatalog appendString:@"\n"];
  [propertyCatalog appendString:_CanvasAIPropertySchemaText()];

  NSMutableString *layerCatalog = [NSMutableString string];
  for (KKBezierPath *p in paths) {
    NSString *type = p.isGroup ? @"group" : (p.isImage ? @"image" : @"shape");
    BOOL sel =
        selectedLayerID.length && [p.layerID isEqualToString:selectedLayerID];
    [layerCatalog appendFormat:@"  - \"%@\" (%@%@)\n",
                               p.name.length ? p.name : @"Layer", type,
                               sel ? @", selected" : @""];
  }
  if (layerCatalog.length == 0)
    [layerCatalog appendString:@"  (no layers yet)\n"];

  NSMutableArray<NSString *> *laneLabels = [NSMutableArray array];
  for (KKLane *t in templates)
    if (t.label && _CanvasAIRelevantLabel(t.label))
      [laneLabels addObject:t.label];

  __weak typeof(self) weakSelf = self;
  [KKAIPluginAgent
      runCanvasTargetedWithPrompt:prompt
                   productContext:productContext
                       laneLabels:laneLabels
                  propertyCatalog:propertyCatalog
                     layerCatalog:layerCatalog
              clipDurationSeconds:clipDurSec
            supportsLayerCreation:allowCreate
                       completion:^(KKAIPluginResult *result, NSError *err) {
                         dispatch_async(dispatch_get_main_queue(), ^{
                           __strong typeof(weakSelf) strong = weakSelf;
                           if (!strong)
                             return;
                           [KKAIDraft setRouting:NO];
                           if (err) {
                             KKLogError(@"AI[err] %@",
                                        err.localizedDescription);
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
                           if (result.kind ==
                               KKAIPluginResultKindCreateLayers) {
                             [strong _canvasCreateLayersFromSVG:result.createSVG
                                                  animatePrompt:
                                                      result.createAnimatePrompt
                                                 productContext:productContext];
                             return;
                           }
                           // The resolve pass returns Canvas-format operations
                           // (layer NAME, plain lane, keyposes in seconds).
                           // Turn them into the standard tagged-label mutation
                           // (resolve names -> layerIDs, seconds -> clip
                           // fractions) that the merge + apply expect.
                           NSString *stdMutation =
                               _CanvasStandardMutationFromResolve(
                                   result.mutationJSON, paths, clipDurSec,
                                   selectedLayerID);
                           if (!stdMutation) {
                             KKLogError(@"AI[err] resolve produced no usable "
                                        @"operations");
                             [KKAIDraft
                                 setError:@"The AI couldn't resolve that to an "
                                          @"editable property."];
                             return;
                           }
                           // Snap each lane's final keypose to the last
                           // renderable frame (FCP's last frame is one before
                           // the out-point).
                           NSString *merged = KKTimelineAIMergeMutationJSON(
                               currentJSON, stdMutation, clipDurSec,
                               KKProcessFrameDurationSeconds());
                           if (!merged) {
                             KKLogError(@"AI[err] merge returned nil");
                             [KKAIDraft setError:@"AI returned an invalid "
                                                 @"timeline mutation."];
                             return;
                           }
                           KKTimeline *mergedTL =
                               [KKTimeline timelineFromJSON:merged];
                           if (!mergedTL) {
                             [KKAIDraft setError:@"AI returned an invalid "
                                                 @"timeline mutation."];
                             return;
                           }
                           // Write back ONLY the lanes the mutation named - the
                           // rest of the AI timeline (every other
                           // layer/property, seeded as a constant) must not be
                           // persisted. A single-keypose change (e.g. "set
                           // stroke to red") is applied as a constant too, not
                           // just multi-keypose animations.
                           NSSet<NSString *> *touched =
                               _CanvasMutationLaneLabels(stdMutation);
                           NSMutableArray<KKLane *> *changed =
                               [NSMutableArray array];
                           BOOL anyAnimated = NO;
                           for (KKLane *l in mergedTL.lanes) {
                             if (![touched containsObject:l.key])
                               continue;
                             // The AI gives colours in sRGB; the renderer
                             // stores linear RGB (alpha untouched). Convert
                             // each keypose's first three components on a
                             // colour lane.
                             if (l.valueType == KKLaneValueTypeColor) {
                               for (KKKeyPose *kp in l.keyposes) {
                                 NSMutableArray<NSNumber *> *v =
                                     [kp.values mutableCopy];
                                 for (NSUInteger i = 0; i < 3 && i < v.count;
                                      i++)
                                   v[i] =
                                       @(_CanvasSRGBToLinear(v[i].doubleValue));
                                 kp.values = v;
                               }
                             }
                             // One keypose = a constant set, not an animation:
                             // mark it constant so it lands in Constants, not
                             // the Animated set. Two or more = a real
                             // animation.
                             l.enabled = (l.keyposes.count > 1);
                             if (l.enabled)
                               anyAnimated = YES;
                             [changed addObject:l];
                           }
                           if (changed.count == 0) {
                             KKLogError(
                                 @"AI[err] mutation named no known lanes");
                             [KKAIDraft
                                 setError:@"AI returned changes for properties "
                                          @"that aren't available here."];
                             return;
                           }
                           mergedTL.lanes = changed;

                           BOOL scoped = KKPerformUndoable(
                               strong.apiManager, strong, nil,
                               ^(id<FxParameterRetrievalAPI_v6> get,
                                 id<FxParameterSettingAPI_v5> setAPI,
                                 CMTime actionTime) {
                               NSString *freshB64 =
                                   KKReadCustomParamString(get, kParamLayerData);
                               NSMutableArray<KKBezierPath *> *cur =
                                   freshB64.length
                                       ? [KKBezierPath
                                             pathsFromBlob:
                                                 [[NSData alloc]
                                                     initWithBase64EncodedString:
                                                         freshB64
                                                                         options:0]]
                                       : [NSMutableArray array];
                               CanvasApplyMergedTimelineToPaths(mergedTL, cur,
                                                                templates);
                               NSData *blob = [KKBezierPath blobFromPaths:cur];
                               KKWriteCustomParamString(
                                   setAPI, [blob base64EncodedStringWithOptions:0],
                                   kParamLayerData);
                               // A cross-layer AI ANIMATION isn't
                               // Basic-representable (Basic shares timings across
                               // layers), so show Advanced so the user sees the
                               // real per-layer structure. A pure constant change
                               // leaves the tab alone.
                               if (anyAnimated)
                                 [strong patchUIStateKey:@"activeTab"
                                                   value:@(1)
                                                 paramID:kParamUIState];
                           });
                           if (!scoped) {
                             [KKAIDraft
                                 setError:@"Couldn't open the FCP action scope "
                                          @"to apply the mutation."];
                             return;
                           }
                           [KKAIDraft setAnswer:nil];
                           [KKAIDraft clearPrompt];
                           [KKAIDraft setCompleted:YES];
                         });
                       }];
}

- (void)_canvasCreateLayersFromSVG:(NSString *)svg
                     animatePrompt:(nullable NSString *)animatePrompt
                    productContext:(NSString *)productContext {
  NSMutableArray<KKBezierPath *> *newLayers =
      _CanvasLayersFromSVG(svg, CLoc(@"Drawing", @"Default name for an "
                                                 @"AI-created Canvas layer."));
  if (newLayers.count == 0) {
    KKLogError(@"AI[err] create returned no parseable SVG layers");
    [KKAIDraft setError:@"The AI couldn't produce a drawable shape."];
    return;
  }

  BOOL scoped = KKPerformUndoable(
      self.apiManager, self, nil,
      ^(id<FxParameterRetrievalAPI_v6> get, id<FxParameterSettingAPI_v5> set,
        CMTime actionTime) {
        NSString *b64 = KKReadCustomParamString(get, kParamLayerData);
        NSMutableArray<KKBezierPath *> *cur =
            b64.length ? [KKBezierPath
                             pathsFromBlob:[[NSData alloc]
                                               initWithBase64EncodedString:b64
                                                                   options:0]]
                       : [NSMutableArray array];
        // New layers go on top (front), matching preset insertion.
        NSMutableArray<KKBezierPath *> *merged = [newLayers mutableCopy];
        [merged addObjectsFromArray:cur];
        NSData *blob = [KKBezierPath blobFromPaths:merged];
        KKWriteCustomParamString(set, [blob base64EncodedStringWithOptions:0],
                                 kParamLayerData);
      });
  if (!scoped) {
    [KKAIDraft
        setError:@"Couldn't open the FCP action scope to add the layer."];
    return;
  }

  // If the user also asked to animate / reveal the shape, run that now that the
  // layer exists - the second pass classifies as a mutation and targets the new
  // layer (it's front-most in the roster). Defer so the param write settles
  // before the next read.
  if (animatePrompt.length) {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      // allowCreate:NO - this pass animates the just-created layer; it must
      // never re-enter creation (a create-flavoured prompt would otherwise draw
      // another shape and loop forever).
      [weakSelf _runAIPrompt:animatePrompt
              productContext:productContext
                 allowCreate:NO];
    });
    return;
  }
  [KKAIDraft setAnswer:nil];
  [KKAIDraft clearPrompt];
  [KKAIDraft setCompleted:YES];
}

@end
