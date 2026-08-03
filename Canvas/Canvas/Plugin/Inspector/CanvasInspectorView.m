/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasInspectorView.h"
#import "CanvasInspectorView+ArrowGuide.h"
#import "CanvasLayerListController.h"
#import "CanvasLayerTimeline.h"
#import "CanvasLocalized.h" // CLoc (guide step messages)
#import "CanvasMiniViewerRenderer.h"
#import "CanvasOSCGuide.h" // shared OSC guide bridge (viewer rect + canvas ref)
#import "CanvasPresets.h"
#import "CanvasThumbnailBake.h" // link-picker poster bake
#import "CanvasToolbar.h" // CanvasToolbarToolPen (arrow guide pen-tool step)
#import <KeyframelessKit/KKLinkBus.h>
#import <KeyframelessKit/KKMiniViewerFeed.h>
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKJoyrideController.h>    // KKJoyrideStep / controller
#import <KeyframelessKit/KKJoyrideDragStep.h>      // slider drag-to-zero step
#import <KeyframelessKit/KKJoyrideGuideHost.h>     // shared guide host
#import <KeyframelessKit/KKJoyrideLanesBinder.h>   // step binding
#import <KeyframelessKit/KKJoyrideTrigger.h>       // advance triggers
#import <KeyframelessKit/KKMiniViewerView.h> // mini toolbar guide methods
#import <KeyframelessKit/KKTimelineBasicView+Guide.h> // In-phase toggle rect
#import <KeyframelessKit/KKTimelineInspectorView+Guide.h> // timingGuideHost
#import <KeyframelessKit/KKTimelineLanesView+Guide.h>     // basicGraph

// NSUserDefaults flag: the first-apply intro guide has been shown once.
static NSString *const kCanvasIntroSeenKey = @"CanvasIntroSeen";

@interface CanvasInspectorView ()
/// Canvas's timing-guide data, built on -makeTimingGuideConfig. The inspector
/// bridges (play, tabs, constants, scrub, ...) come pre-wired from the kit;
/// only the per-plugin data (the lane it teaches + seed/target values) is
/// filled here. Installed as -timingGuideConfigProvider in -viewDidMoveToWindow
/// so the kit's restart machinery pulls a fresh config per guide run.
- (KKTimingGuideConfig *)_timingGuideConfig;
@end

@implementation CanvasInspectorView {
  CanvasMiniViewerRenderer *_miniViewerRenderer;
  CanvasLayerListController *_layerListController;
  NSArray<KKLane *> *_availableLanes;
  // Signature of the displayed lane set; a change means the layer STRUCTURE
  // changed (layer added/removed/renamed), so re-feed the merged timeline. A
  // value-only edit (keypose drag) keeps the same signature, so we skip the
  // re-feed and don't reset the in-progress edit.
  NSString *_laneStructureSignature;
  NSString *_selectedLayerID; // layer the inspector edits (nil = topmost)
  BOOL _dragging;             // a graph keypose drag is in progress
  id<PROAPIAccessing>
      _apiManager; // for per-instance OSC-visibility state reads
  NSInteger _thumbBakeGeneration; // coalesces thumbnail bakes (see Mirage)
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                       loopEnabled:(BOOL)loopEnabled
             maintainTimingEnabled:(BOOL)maintainTimingEnabled
                         activeTab:(NSInteger)activeTab
                    availableLanes:(NSArray<KKLane *> *)availableLanes
                          timeline:(KKTimeline *)timeline {
  self = [super initWithAPIManager:apiManager
                       loopEnabled:loopEnabled
             maintainTimingEnabled:maintainTimingEnabled
                         activeTab:activeTab
                    availableLanes:availableLanes
                          timeline:timeline];
  if (self) {
    _apiManager = apiManager;
    _availableLanes = [availableLanes copy];
    _laneStructureSignature = [self _laneSignatureForTimeline:timeline];
    _miniViewerRenderer = [[CanvasMiniViewerRenderer alloc] init];
    _miniViewerRenderer.timeline = timeline;
    _miniViewerRenderer.laneTemplates = availableLanes;
    // Per-instance UUID for the cross-process anchor-selection sync (createView
    // mints it before building this view, so it resolves here). The same
    // identity gates the live-drag ref override (a `${uuid...}` expression
    // ref only resolves locally when it targets THIS clip).
    _miniViewerRenderer.instanceUUID = KKInstanceUUIDForAPI(apiManager);
    _miniViewerRenderer.linkSelfUUID = _miniViewerRenderer.instanceUUID;
    [self _retainMiniClipDurationFromTimeline:timeline];
    // Cold-boot seed for the viewer Position OSC (it reads the snapshot, not
    // the param). applyTimeline republishes on selection / edits.
    KKSetProcessTimelineSnapshot(timeline);
    // Position handle + motion-path overlay for the selected layer (the popover
    // mini edits that layer's Position lane). Motion-path / smooth-toggle edits
    // persist the whole layer timeline through onTimelineMutated (read at call
    // time - it's set after init in Plugin+CustomUI); a plain Position-handle
    // drag persists through the popover's own keypose write.
    _miniViewerRenderer.handlesHidden = NO;
    __weak typeof(self) weakInit = self;
    _miniViewerRenderer.onTimelinePersist = ^(KKTimeline *tl) {
      typeof(self) s = weakInit;
      if (s.onTimelineMutated)
        s.onTimelineMutated(tl);
    };
    // Auto-select in the mini-viewer: a body click picks the layer under the
    // cursor (gated by autoSelectEnabled, mirrored from the persisted toggle).
    _miniViewerRenderer.onSelectLayer = ^(NSString *layerID) {
      [weakInit _selectAndHighlightLayer:layerID];
    };
    // Mini Shift / Cmd-click multi-select: mirror the full set onto the panel
    // rows first (so _selectLayer derives the same set), then drive the primary
    // edit target + persist.
    _miniViewerRenderer.onSelectLayers =
        ^(NSArray<NSString *> *layerIDs, NSString *primaryLayerID) {
          typeof(self) s = weakInit;
          [s->_layerListController setSelectionLayerIDs:layerIDs];
          // An empty set is a real deselect (mini click on empty canvas) - go
          // to the no-layer state, not the topmost-fallback _selectLayer:nil
          // gives.
          if (layerIDs.count == 0)
            [s _selectNoLayer];
          else
            [s _selectLayer:(primaryLayerID.length ? primaryLayerID
                                                   : layerIDs.firstObject)];
        };
    // Mini toolbar -> persist the shared/per-surface kParamUIState keys.
    _miniViewerRenderer.onPatchUIState = ^(NSString *key, id value) {
      typeof(self) s = weakInit;
      if (s.onUIStatePatch)
        s.onUIStatePatch(key, value);
    };
    // Mini pen tool -> commit the drawn vector layer(s) to kParamLayerData (one
    // undo each), refresh the viewer-OSC blob snapshot + panel, and select the
    // new layer on create.
    _miniViewerRenderer.onPersistLayers =
        ^(NSArray<KKBezierPath *> *paths, NSString *selectID) {
          typeof(self) s = weakInit;
          if (!s)
            return;
          // Don't adopt a just-drawn path as the selection if it can't be acted
          // on in the open popover (a new constant path has no keypose, so a
          // keypose popover must stay on its owner - otherwise the new path is
          // persisted as the selection and ping-pongs with the keypose
          // re-drive).
          BOOL adopt =
              selectID.length &&
              [s->_layerListController isLayerSelectableInOpenPopover:selectID];
          // Write the blob AND (when adopting) the new selection in ONE action.
          // Two separate actions (blob, then a patchUIState selection write)
          // made path-op commits take TWO cmd-Z, and the undo reverted the
          // selection against the still-mutated blob - so the restored layerID
          // no longer existed and resolved to the wrong layer. One action
          // reverts both together; the kParamUIState round-trip then drives the
          // in-memory selection (highlight + timeline) against the reverted
          // blob.
          [s->_layerListController writePaths:paths
                            selectingLayerIDs:(adopt ? @[ selectID ] : nil)];
          [s _syncLayersToRenderer];
        };
    // Delete: persist the new stack AND clear the selection in ONE action (one
    // undo restores both). The cleared kParamUIState round-trips back through
    // parameterChanged -> restoreSelectedLayerIDs(@[]) -> _selectNoLayer, so no
    // separate selection write is needed here (that would be a 2nd undo step).
    _miniViewerRenderer.onDeleteLayers = ^(NSArray<KKBezierPath *> *paths) {
      typeof(self) s = weakInit;
      if (!s)
        return;
      [s->_layerListController writePaths:paths
            clearingSelectionInSameAction:YES];
      [s _syncLayersToRenderer];
    };
    self.miniViewerDelegate = _miniViewerRenderer;
    // Let the popover mini take key focus on click so a bare Delete is handled
    // there (delete the selected layer) instead of falling through to FCP
    // (which would delete the whole effect). Focus is held only while in the
    // mini; clicking back into FCP releases it, so host shortcuts keep working.
    self.miniGrabsKeyFocusOnClick = YES;
    self.miniViewerDescriptorPath = CanvasMiniViewerDescriptorPath;
    self.miniViewerRequestPath = CanvasMiniViewerRequestPath;

    // Layers panel: appears to the left of value/constants popovers (kit posts
    // scoped open/close notifications; the panel registers keep-alive so
    // interacting with it doesn't dismiss the popover).
    _layerListController =
        [[CanvasLayerListController alloc] initWithLanesView:self.basicLanesView
                                                  apiManager:apiManager];
    __weak typeof(self) weak = self;
    _layerListController.onPrimaryLayerSelected = ^(NSString *layerID) {
      typeof(self) s = weak;
      // A nil primary with an EMPTY panel selection is a real deselect (e.g.
      // ungrouping a group that was the only selection) - go to the no-layer
      // state, not the topmost-fallback _selectLayer:nil would give.
      if (!layerID.length &&
          [s->_layerListController currentSelectionLayerIDs].count == 0)
        [s _selectNoLayer];
      else
        [s _selectLayer:layerID];
    };
    _layerListController.onAutoSelectToggled = ^(BOOL on) {
      typeof(self) s = weak;
      if (s.onAutoSelectChanged)
        s.onAutoSelectChanged(on);
    };
    // Hovering a row highlights that layer (amber) on the adjacent mini-viewer,
    // so it's clear which layer it is without toggling its visibility.
    // In-process (mini only); the main viewer's OSC lives in another process
    // and would need a transient param round-trip, which isn't worth the
    // undo/perf cost.
    _layerListController.onLayerHovered = ^(NSString *layerID) {
      typeof(self) s = weak;
      s->_miniViewerRenderer.hoveredLayerID = layerID;
    };
    // Mirror the popover's non-selectable gating onto the MINI preview (same
    // rule as the layer rows). The MAIN VIEWER gates itself by the playhead in
    // the OSC (a layer is clickable there if it has a constant or a keypose at
    // the playhead), so it needs nothing pushed here.
    _layerListController.onNonSelectableLayersChanged =
        ^(NSSet<NSString *> *s) {
          typeof(self) ss = weak;
          ss->_miniViewerRenderer.nonSelectableLayerIDs = s;
        };
    // The marquee / body-drag use a stricter set in the constants popover (see
    // the controller): move-lane-animated layers can't be moved via constants.
    _layerListController.onMarqueeNonSelectableLayersChanged =
        ^(NSSet<NSString *> *s) {
          typeof(self) ss = weak;
          ss->_miniViewerRenderer.marqueeNonSelectableLayerIDs = s;
        };
    // A keypose popover scoped itself to a layer (clicked a keypose in that
    // layer's lane) -> make it the SELECTED layer, not just a highlight, so the
    // viewer OSC / mini / Constants all follow the layer being edited. Without
    // a real selection change the viewer OSC kept reading the
    // previously-selected layer (it reads the process-snapshot timeline, which
    // only applyTimeline republishes). _selectLayer no-ops the popover retarget
    // (the graph already scoped itself before firing this), so there's no loop;
    // also move the list highlight since this didn't originate from a panel
    // click.
    self.basicLanesView.onKeyposeLayerActivated = ^(NSString *layerKey) {
      __strong typeof(weak) s = weak;
      if (!s || layerKey.length == 0 ||
          [layerKey isEqualToString:s->_selectedLayerID])
        return; // already on the keypose owner - avoid churn / loops
      [s _selectAndHighlightLayer:layerKey];
    };
    // Opening Constants: if the selected layer has no constants, land on the
    // first layer that does (the popover shows the selected owner's constants).
    self.onConstantsWillShow = ^{
      [weak _ensureConstantsLayerSelected];
    };
    // Annotation presets: a content preset (payloadKind "canvasLayers") inserts
    // its pre-built layer(s) into the stack rather than applying a timeline.
    self.onApplyPresetPayload = ^(NSString *kind, NSString *json, BOOL atPlayhead) {
      [weak _applyCanvasLayerPresetPayload:kind json:json];
    };
    _layerListController.templateLaneCount = availableLanes.count;
    // Canvas's property list is short (Scale, Position), so the Animated
    // popover - and the layer panel beside it, which matches its height - would
    // be cramped. Give it a floor ~30pt above the natural compact height so the
    // layer list is comfortable to use.
    self.basicLanesView.minimumManagePopoverHeight = 160.0;
    [self _syncLayersToRenderer];
    [self _feedGraph];
  }
  return self;
}

// Insert an annotation preset's pre-built layer(s) on TOP of the stack (array
// index 0 = front), with fresh layer IDs so re-applying the same preset never
// collides, then select them - all in one undo (writePaths:selectingLayerIDs:).
- (void)_applyCanvasLayerPresetPayload:(NSString *)kind json:(NSString *)json {
  BOOL aspectX = [kind isEqualToString:kCanvasPresetPayloadKindAspectX];
  if (!aspectX && ![kind isEqualToString:kCanvasPresetPayloadKind])
    return;
  if (json.length == 0)
    return;
  NSData *blob = [[NSData alloc] initWithBase64EncodedString:json options:0];
  NSMutableArray<KKBezierPath *> *preset =
      blob.length ? [KKBezierPath pathsFromBlob:blob] : nil;
  if (preset.count == 0)
    return;
  // Aspect-sensitive geometry (the checkmark) is authored square; compress X
  // about the canvas centre by the live aspect (outH/outW) so 45-degree art stays
  // square on any canvas shape. Falls back to 16:9 if the output size is unknown.
  if (aspectX) {
    float ow = 0.0f, oh = 0.0f;
    float f = (CanvasOutputSize(&ow, &oh) && ow > 0.0f) ? (oh / ow)
                                                        : (9.0f / 16.0f);
    for (KKBezierPath *p in preset) {
      NSUInteger n = p.count;
      if (n == 0)
        continue;
      simd_float2 *pts = malloc(sizeof(simd_float2) * n);
      for (NSUInteger i = 0; i < n; i++) {
        KKBezierPoint bp = [p pointAtIndex:i];
        pts[i] = simd_make_float2(0.5f + (bp.x - 0.5f) * f, bp.y);
      }
      [p setLinearPositions:pts count:n closed:p.closed];
      free(pts);
    }
  }
  NSMutableArray<NSString *> *newIDs =
      [NSMutableArray arrayWithCapacity:preset.count];
  for (KKBezierPath *p in preset) {
    p.layerID = [[NSUUID UUID] UUIDString];
    [newIDs addObject:p.layerID];
  }
  NSArray<KKBezierPath *> *existing =
      [_layerListController currentLayerPaths] ?: @[];
  NSMutableArray<KKBezierPath *> *merged = [preset mutableCopy];
  [merged addObjectsFromArray:existing];
  [_layerListController writePaths:merged selectingLayerIDs:newIDs];
  [self _syncLayersToRenderer];
}

// The effective selection set for a primary layer about to be edited: the
// panel's current multi-selection when it contains this primary (a panel
// multi-click); otherwise this is a single select (keypose-lane / mini
// auto-select), so the set is just the primary (empty when there's no layer).
- (NSArray<NSString *> *)_effectiveSelectionForPrimary:(KKBezierPath *)sel {
  NSArray<NSString *> *selSet = [_layerListController currentSelectionLayerIDs];
  if (!sel.layerID.length)
    return @[];
  if (![selSet containsObject:sel.layerID])
    return @[ sel.layerID ];
  return selSet;
}

// When 2+ layers are selected the single-owner inspector timeline shows the
// PRIMARY layer's params, but editing a value would only touch that one layer
// (misleading). Lock every lane so the Constants popover + Advanced graph
// render read-only until a single layer is selected again. Per-field
// propagation (stroke width, colours) can relax this for those fields when they
// return.
- (void)_applyMultiSelectLock:(KKTimeline *)timeline count:(NSUInteger)count {
  if (count <= 1)
    return;
  for (KKLane *l in timeline.lanes)
    l.locked = YES;
}

// Switch which layer the Animated dropdown + Constants act on. This drives the
// SINGLE-OWNER timeline only; the graph (graphTimeline) shows every layer and
// is unaffected by selection.
- (void)_selectLayer:(NSString *)layerID {
  _selectedLayerID = [layerID copy];
  NSArray<KKBezierPath *> *paths = [_layerListController currentLayerPaths];
  KKBezierPath *sel = CanvasSelectedLayerForPaths(paths, _selectedLayerID);
  NSArray<NSString *> *selSet = [self _effectiveSelectionForPrimary:sel];
  KKTimeline *layerTL = CanvasLayerTimelineForPath(sel, _availableLanes);
  [self _applyMultiSelectLock:layerTL count:selSet.count];
  _laneStructureSignature = [self _laneSignatureForTimeline:layerTL];
  [self applyTimeline:layerTL];
  // The mini composites the live (popover) timeline for this layer, so its
  // Position handle previews before the edit persists. Use the RESOLVED layer
  // id (nil _selectedLayerID = topmost) so the override matches a real layer.
  _miniViewerRenderer.selectedLayerID = sel.layerID;
  // Mini handles follow OSC visibility + this layer's lock.
  [self syncMiniHandleVisibility];
  _layerListController.selectedLayerID = _selectedLayerID;
  // Re-point an already-open keypose popover at this layer FIRST: retarget
  // guards against a no-op when the graph's active layer already equals the new
  // one, so it must run before activeLayerKey is updated (no-op if no popover
  // open). Then set activeLayerKey so the NEXT fresh open scopes here too.
  [self.basicLanesView retargetKeyposePopoverToLayerKey:layerID];
  self.basicLanesView.activeLayerKey = layerID;
  // Re-scope an open "Applies to" (gap / modulation) popover to this layer's
  // timeline (now applied above), mirroring the keypose-popover retarget.
  [self.basicLanesView reopenOpenAppliesToPopover];
  // Keep the controller's stored highlight set in step with the live selection,
  // so a later lazily-built popover companion restores THIS selection rather
  // than a stale one (e.g. after ungroup the freed layer stays selected on
  // reopen).
  [_layerListController setSelectionLayerIDs:selSet];
  // Mirror the full selection onto the mini so its toolbar's path-op buttons
  // follow (it needs the whole set, not just the primary).
  _miniViewerRenderer.selectedLayerIDs = selSet;
  if (_onSelectedLayerChanged)
    _onSelectedLayerChanged(sel.layerID, selSet);
}

// Select a layer AND move the list highlight. Used when the selection
// originates somewhere other than a panel row click (a keypose-lane click, a
// mini-viewer auto-select) - those don't set the row highlight themselves,
// unlike onPrimaryLayerSelected which fires from the row click that already
// highlights.
- (void)_selectAndHighlightLayer:(NSString *)layerID {
  [self _selectLayer:layerID];
  [_layerListController highlightLayerID:layerID];
}

- (void)setAutoSelect:(BOOL)autoSelect {
  _layerListController.autoSelect = autoSelect;
  _miniViewerRenderer.autoSelectEnabled = autoSelect;
}

- (void)setGridEnabled:(BOOL)enabled
              adaptive:(BOOL)adaptive
               spacing:(NSInteger)spacing
                  snap:(BOOL)snap {
  _miniViewerRenderer.gridEnabled = enabled;
  _miniViewerRenderer.gridAdaptive = adaptive;
  _miniViewerRenderer.gridSpacing = spacing;
  _miniViewerRenderer.gridSnap = snap;
}

- (void)setToolbarTool:(NSInteger)tool normPos:(CGPoint)normPos {
  _miniViewerRenderer.toolbarTool = tool;
  _miniViewerRenderer.toolbarNormPos = normPos;
  [self _arrowGuideAdvanceIfPenSelected:tool];
}

- (void)restoreSelectedLayerID:(NSString *)layerID {
  [self restoreSelectedLayerIDs:(layerID.length ? @[ layerID ] : @[])
                        primary:layerID];
}

// Clear the whole selection to a real no-layer state: no highlighted rows, the
// mini shows nothing, and the lanes fall back to the locked no-layer timeline.
- (void)_selectNoLayer {
  _selectedLayerID = nil;
  [_layerListController setSelectionLayerIDs:@[]];
  _miniViewerRenderer.selectedLayerID = nil;
  _miniViewerRenderer.selectedLayerIDs = @[];
  KKTimeline *tl = CanvasLayerTimelineForPath(nil, _availableLanes);
  _laneStructureSignature = [self _laneSignatureForTimeline:tl];
  [self applyTimeline:tl];
  [self syncMiniHandleVisibility];
  if (_onSelectedLayerChanged)
    _onSelectedLayerChanged(nil, @[]);
}

- (void)restoreSelectedLayerIDs:(NSArray<NSString *> *)layerIDs
                        primary:(NSString *)primary {
  NSArray<NSString *> *selIDs =
      [layerIDs isKindOfClass:[NSArray class]] ? layerIDs : @[];
  // No-op guard: skip when the list already shows exactly this set + primary,
  // so unrelated UIState writes (OSC toggles, grid, etc.) don't churn the
  // timeline.
  NSSet *curSet =
      [NSSet setWithArray:[_layerListController currentSelectionLayerIDs]];
  NSSet *wantSet = [NSSet setWithArray:selIDs];
  BOOL samePrimary = (primary.length == 0)
                         ? (_selectedLayerID.length == 0)
                         : [primary isEqualToString:_selectedLayerID];
  if ([curSet isEqualToSet:wantSet] && samePrimary)
    return;
  // Push the FULL selection to the layer list so EVERY selected row highlights
  // (incl. images) - _selectLayer then reads it back for the mini's set.
  [_layerListController setSelectionLayerIDs:selIDs];
  if (selIDs.count == 0) {
    [self _selectNoLayer];
    return;
  }
  [self _selectLayer:(primary.length ? primary : selIDs.firstObject)];
}

- (NSString *)resolvedSelectedLayerID {
  KKBezierPath *sel = CanvasSelectedLayerForPaths(
      [_layerListController currentLayerPaths], _selectedLayerID);
  return sel.layerID;
}

// Constants edits the selected layer's constant params; if that layer has none
// (fully animated), switch to the first layer that does so the popover isn't
// empty. Leaves the selection alone when it already has constants.
- (void)_ensureConstantsLayerSelected {
  // Multi-select shows the primary's constants READ-ONLY (lanes locked); don't
  // reassign to a different layer here - that would collapse the
  // multi-selection.
  if ([_layerListController currentSelectionLayerIDs].count > 1)
    return;
  NSArray<KKBezierPath *> *paths = [_layerListController currentLayerPaths];
  KKBezierPath *sel = CanvasSelectedLayerForPaths(paths, _selectedLayerID);
  if (CanvasLayerHasConstant(sel, _availableLanes))
    return; // open as-is
  for (KKBezierPath *p in paths)
    if (CanvasLayerHasConstant(p, _availableLanes)) {
      [self _selectLayer:p.layerID];
      [_layerListController highlightLayerID:p.layerID];
      return;
    }
}

// Feed the all-layers graph timeline (every layer's animated lanes) + the layer
// stack order so both graphs show every layer in layer-list order, regardless
// of selection.
- (void)_feedGraph {
  NSArray<KKBezierPath *> *paths = [_layerListController currentLayerPaths];
  KKTimeline *merged = CanvasMergedTimeline(paths, _availableLanes);
  // Some layer still has a constant (un-animated) param? Keep the Constants
  // button reachable even when the selected layer is fully animated. Set this
  // BEFORE graphTimeline: the setter runs a refresh that reads
  // ownerConstantsAvailable to decide the "All" dropdown summary, so a stale
  // value would mis-label a partially-animated project as "All".
  self.basicLanesView.ownerConstantsAvailable =
      CanvasAnyLayerHasConstant(paths, _availableLanes);
  self.basicLanesView.graphTimeline = merged;
  NSMutableArray<NSString *> *order =
      [NSMutableArray arrayWithCapacity:paths.count];
  for (KKBezierPath *p in paths)
    if (p.layerID.length)
      [order addObject:p.layerID];
  self.basicLanesView.layerOrder = order;
  // Animated dropdown lists every animated layer's name (layer-stack order), so
  // it reflects the whole project, not just the selected owner.
  NSMutableArray<NSString *> *titles = [NSMutableArray array];
  NSMutableSet<NSString *> *seen = [NSMutableSet set];
  for (KKLane *l in merged.lanes) {
    NSString *nm = l.layerLabel;
    if (nm.length && ![seen containsObject:nm]) {
      [seen addObject:nm];
      [titles addObject:nm];
    }
  }
  self.basicLanesView.dropdownLayerTitles = titles;
  // Respect a real no-selection state: don't fall back to the topmost layer
  // (CanvasSelectedLayerForPaths does on nil), which would resurrect the mini's
  // selection + gizmo right after a deselect (e.g. ungrouping a group-only
  // selection - this graph rebuild runs from the blob reload).
  KKBezierPath *sel = _selectedLayerID.length
                          ? CanvasSelectedLayerForPaths(paths, _selectedLayerID)
                          : nil;
  _miniViewerRenderer.selectedLayerID = sel.layerID;
  [self syncMiniHandleVisibility]; // OSC visibility + lock
  _layerListController.selectedLayerID = sel.layerID;
  // The kit re-evaluates the Constants button only in applyTimeline (a
  // selection/edit). _feedGraph also runs on cold boot + reload
  // (parameterChanged load), where it just updated ownerConstantsAvailable - so
  // refresh the button here too, else it stays hidden until the first layer
  // selection even when a layer has constants.
  self.constantsButton.hidden = !self.basicLanesView.hasUnoptedLanes;
}

- (void)dealloc {
  [_layerListController invalidate];
}

// Push the current layer stack to the mini-viewer renderer so its preview
// composites the same layers the main render does. The renderer re-runs on the
// next published source frame (no explicit redraw needed - editing a layer
// re-renders the clip).
- (void)_syncLayersToRenderer {
  NSArray<KKBezierPath *> *paths = [_layerListController currentLayerPaths];
  _miniViewerRenderer.layers = paths;
  // Publish the blob for the viewer OSC's write path (it can't read
  // kParamLayerData itself - see CanvasLayerBlobSnapshot).
  NSData *blob = [KKBezierPath blobFromPaths:paths];
  CanvasSetLayerBlobSnapshot(blob ? [blob base64EncodedStringWithOptions:0]
                                  : nil);
}

// Show the inspector's OSC-visibility row (the global "show controls" toggle +
// the Position/Path pills). The base defaults NO; Canvas has a viewer Transform
// OSC, so opt in.
- (BOOL)showsOSCVisibilityRow {
  return YES;
}

// Canvas renders each layer through KKTransformVertexShader, so it can emit a
// per-layer velocity buffer for the Fast (reconstruction) motion-blur technique.
- (BOOL)motionBlurSupportsFastTechnique {
  return YES;
}

// Canvas defaults to Fast, where Samples is unused; if the user switches to the
// Accurate path, its per-layer content is heavy, so default to a low count.
- (NSInteger)motionBlurDefaultSamples {
  return 6;
}

// The popover mini handles follow the SAME OSC visibility as the viewer OSC
// (global toggle + per-element hidden set, read from per-instance state),
// plus the selected layer's lock (locked => no handles). Canvas owns this so it
// can OR in lock without fighting the kit's async master refresh; the inspector
// toggle/pills write the instance state (nil renderer in kkWire/kkRefresh), and
// this pushes it onto the mini renderer.
- (void)syncMiniHandleVisibility {
  KKPluginInstanceState *st = KKInstanceStateForAPI(_apiManager);
  BOOL master = st ? st.oscMasterVisible : YES;
  _miniViewerRenderer.hiddenHandleLabels = st.hiddenOSCElements ?: [NSSet set];
  KKBezierPath *sel = CanvasSelectedLayerForPaths(
      [_layerListController currentLayerPaths], _selectedLayerID);
  // Master-off is a peekable hide (Opt reveals); lock is a hard, non-peekable,
  // non-interactive gate - keep them on separate flags so Opt can't peek a
  // locked layer's handles into existence.
  _miniViewerRenderer.handlesHidden = !master;
  _miniViewerRenderer.handlesLocked = sel.locked;
}

- (void)_retainMiniClipDurationFromTimeline:(KKTimeline *)timeline {
  // Keep the largest clip duration the timeline has ever reported (a later
  // gesture rebuild drops the lanes' lastKnownClipDuration); the mini uses it
  // to place the marching-ants phase at the previewed frame.
  for (KKLane *l in timeline.lanes)
    if (l.lastKnownClipDuration > _miniViewerRenderer.clipDurationSeconds)
      _miniViewerRenderer.clipDurationSeconds = l.lastKnownClipDuration;
}

// A freshly-built per-layer timeline (CanvasLayerTimelineForPath) has no
// lastKnownClipDuration on its lanes, so KKLaneVisibleAtFraction would fall
// back to a blind 0.05 (5% of clip) keypose-proximity epsilon - making the
// viewer Position OSC appear ~9 frames off the keypose instead of within one
// frame. Stamp the seeded clip duration before publishing so the epsilon is one
// frame.
- (void)_publishViewerSnapshot:(KKTimeline *)timeline {
  double dur = self.clipDurationSeconds;
  if (dur > 0.0)
    for (KKLane *l in timeline.lanes)
      l.lastKnownClipDuration = dur;
  KKSetProcessTimelineSnapshot(timeline);
}

- (void)applyTimeline:(KKTimeline *)timeline {
  [super applyTimeline:timeline];
  _miniViewerRenderer.timeline = timeline;
  [self _retainMiniClipDurationFromTimeline:timeline];
  // Publish the SELECTED layer's timeline as the process snapshot so the viewer
  // Position OSC (same process) reads this layer. Its lanes carry layerKey, so
  // an OSC drag knows which layer's animationJSON to write. (drawOSC can't read
  // the param - FxParameterRetrievalAPI is nil there - so the snapshot is its
  // only source.) Groups publish like layers: their pivot lives in the stored
  // Anchor lane now, so no Position re-anchor shift is needed.
  [self _publishViewerSnapshot:timeline];
  // Refresh this clip's reference-menu thumbnails when its look changes.
  [self _scheduleThumbnailBake];
}

// Coalesced one-shot bake (the Mirage pattern): bump the generation, fire
// ~0.8s later only if still the latest, so appear + an edit burst collapse to
// one bake and the mini feed has had a moment to publish a frame.
- (void)_scheduleThumbnailBake {
  if (self.isDetachedCopy)
    return;
  NSInteger gen = ++_thumbBakeGeneration;
  __weak typeof(self) weak = self;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        __strong typeof(weak) s = weak;
        if (s && s->_thumbBakeGeneration == gen)
          [s _bakeLinkThumbnails];
      });
}

// Bake the effect-level poster plus one isolated poster per (non-group) layer,
// all keyed by the instance UUID so the expression picker can show them at the
// clip AND layer menu levels. writeThumbnailJPEG skips byte-identical writes.
- (void)_bakeLinkThumbnails {
  NSString *uuid = KKInstanceUUIDForAPI(_apiManager);
  if (uuid.length == 0)
    return; // instance UUID not created yet (lazy); a later bake catches it
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  if (!device)
    return;
  id<MTLTexture> src = KKMiniViewerFeedLoadPrimarySource(
      CanvasMiniViewerDescriptorPathForUUID(uuid), device);
  NSData *jpeg =
      CanvasRenderThumbnailJPEG(_miniViewerRenderer, 320, 180, src, nil);
  if (jpeg.length)
    [KKLinkBus writeThumbnailJPEG:jpeg forUUID:uuid];
  for (KKBezierPath *p in _miniViewerRenderer.layers) {
    if (p.layerID.length == 0)
      continue;
    NSData *layerJPEG = CanvasRenderThumbnailJPEG(_miniViewerRenderer, 320,
                                                  180, src, p.layerID);
    if (layerJPEG.length)
      [KKLinkBus writeThumbnailJPEG:layerJPEG
                            forUUID:uuid
                            layerID:p.layerID];
  }
}

// Track a live keypose drag so reloadLayerList knows the per-frame write echoes
// from one (which it must not let reset the in-progress edit) apart from a real
// external change like cmd-Z (which must refresh the rendered popover + mini).
// The host sets onDragBegin/End for undo grouping; we wrap to also flip the
// flag.
- (void)setOnDragBegin:(void (^)(void))onDragBegin {
  __weak typeof(self) weak = self;
  [super setOnDragBegin:^{
    typeof(self) s = weak;
    if (s)
      s->_dragging = YES;
    if (onDragBegin)
      onDragBegin();
  }];
}

- (void)setOnDragEnd:(void (^)(void))onDragEnd {
  __weak typeof(self) weak = self;
  [super setOnDragEnd:^{
    typeof(self) s = weak;
    if (s)
      s->_dragging = NO;
    if (onDragEnd)
      onDragEnd();
  }];
}

- (void)reloadLayerList {
  [_layerListController reload];
  [self _syncLayersToRenderer];
  [self _refeedTimelineIfStructureChanged];
}

// Rebuild the merged (all-layers) timeline from the current layer stack and
// re-feed it ONLY when the lane structure changed (layer added/removed/renamed)
// - so adding a layer shows its group, without resetting an in-progress keypose
// drag (those fire reloadLayerList too but keep the same lane set).
- (void)_refeedTimelineIfStructureChanged {
  NSArray<KKBezierPath *> *paths = [_layerListController currentLayerPaths];
  // Respect a real no-selection state - don't fall back to the topmost layer
  // (CanvasSelectedLayerForPaths does on nil), which would re-apply that
  // layer's timeline after a deselect and leave the open popover editing it
  // (this runs from the blob reload after ungroup).
  KKBezierPath *sel = _selectedLayerID.length
                          ? CanvasSelectedLayerForPaths(paths, _selectedLayerID)
                          : nil;
  KKTimeline *layerTL = CanvasLayerTimelineForPath(sel, _availableLanes);
  [self _applyMultiSelectLock:layerTL
                        count:[_layerListController currentSelectionLayerIDs]
                                  .count];
  // Always refresh the viewer OSC's process snapshot with the selected layer's
  // CURRENT keyposes - even mid-drag. The snapshot only feeds the viewer
  // control's draw + visibility (which must track a just-added/moved keypose,
  // so its lead-in/out hold visibility recomputes against the new first/last
  // keypose times); it doesn't reset any inspector-side popover/mini edit. The
  // gated applyTimeline below also sets it, but is skipped on a value-only
  // change during a drag - which is exactly when the snapshot went stale.
  [self _publishViewerSnapshot:layerTL];
  // Always rebuild the all-layers graph (any layer may have gained/lost an
  // animated lane).
  [self _feedGraph];
  NSString *sig = [self _laneSignatureForTimeline:layerTL];
  BOOL structureChanged = ![sig isEqualToString:_laneStructureSignature];
  _laneStructureSignature = sig;
  // applyTimeline refreshes the mini + any open popover (via the kit's
  // _refresh). Run it on a structure change always; on a value-only change run
  // it too UNLESS a drag is live - so cmd-Z / redo / external edits update the
  // rendered popover value + preview, while an in-progress drag (whose
  // per-frame echoes keep the same structure) isn't reset out from under the
  // user.
  if (structureChanged || !_dragging)
    [self applyTimeline:layerTL];
}

// Order-sensitive signature of the lane set (unique tagged labels + layer
// labels + locked state), so a rename, reorder, OR lock-toggle counts as a
// change and forces applyTimeline - without locked here a pure lock-toggle
// (which doesn't touch labels) left _timeline stale, so the Constants popover's
// rows (sourced from _timeline) didn't pick up the read-only state.
- (NSString *)_laneSignatureForTimeline:(KKTimeline *)timeline {
  NSMutableArray<NSString *> *parts =
      [NSMutableArray arrayWithCapacity:timeline.lanes.count];
  for (KKLane *l in timeline.lanes)
    [parts addObject:[NSString stringWithFormat:@"%@|%@|%@|%d", l.key ?: @"",
                                                l.label ?: @"",
                                                l.layerLabel ?: @"",
                                                l.locked ? 1 : 0]];
  return [parts componentsJoinedByString:@"\n"];
}

- (void)setLayerParamActionTarget:(id)target {
  _layerListController.paramActionTarget = target;
  // The target is the host-recognized plugin for action scopes; now that it's
  // set, do an authoritative read to seed the preview's layers.
  [self _syncLayersToRenderer];
}

// Install the timing-guide config provider once the view is live. Without it
// the kit's restart machinery (restartBasicTimingGuide / Advanced / MiniViewer
// / OSC) early-returns, so the Help-window guides do nothing - which is why
// only the self-contained Presets guide ran before.
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.isDetachedCopy)
    return;
  if (!self.timingGuideConfigProvider) {
    __weak typeof(self) weak = self;
    self.timingGuideConfigProvider = ^KKTimingGuideConfig * {
      __strong typeof(weak) s = weak;
      return s ? [s _timingGuideConfig] : nil;
    };
  }
  // First-apply intro: springs the Basic walkthrough once the effect is
  // selected and its on-screen controls are drawn (the same gate as the Help
  // window's "guides disabled" warning), so a first-time user is shown the
  // basics instead of having to discover the guides themselves.
  [self autostartIntroGuideOnceWithSeenKey:kCanvasIntroSeenKey];
  // Bake thumbnails on plain selection too (applyTimeline only fires on a
  // param change).
  [self _scheduleThumbnailBake];
}

// Stage a demo subject before each timing guide seeds. Canvas is per-layer, so
// unlike a single-clip plugin (where the clip is always the subject) a guide
// has nothing to teach on unless a shape exists - so we save the scene and drop
// in a demo shape here, BEFORE the kit's restart captures + applies its seed
// (which then attaches to the demo shape). The scene is restored from the guide
// host's run-did-end hook. We invoke the original kit category implementation
// via the base-class IMP (the subclass override otherwise shadows it).
- (void)_runKitRestartForSelector:(SEL)sel {
  if (self.onGuideSceneBegin)
    self.onGuideSceneBegin();
  IMP base = [KKTimelineInspectorView instanceMethodForSelector:sel];
  ((void (*)(id, SEL))base)(self, sel);
}

- (void)restartBasicTimingGuide {
  [self _runKitRestartForSelector:_cmd];
}

- (void)restartAdvancedTimingGuide {
  [self _runKitRestartForSelector:_cmd];
}

// Canvas-specific end-to-end guide, run directly on the shared host (not a kit
// restart - it's not one of the standard timing walkthroughs). Stages an empty
// scene via the plugin hook, pins Basic, then runs the arrow steps in the
// Constants popover (see -_arrowGuideStepsForGuide:binder:). The run-did-end
// hook (shared with the other guides) restores the user's scene + tool.
- (void)runArrowGuide {
  if (self.isDetachedCopy)
    return;
  if (self.onGuideArrowSceneBegin)
    self.onGuideArrowSceneBegin();
  KKJoyrideGuideHost *host = [self timingGuideHost];
  host.forwardsGestures = YES;
  [self setActiveTab:KKTimelineTabBasic];
  if (self.onScrub)
    self.onScrub(0.0);
  // Save the user's remembered constant tab; the guide forces Core before the
  // "navigate to the Stroke group" step (when the drawn path guarantees a Core
  // category exists) and restores this on completion.
  self.arrowGuideSavedCategory = [self.basicLanesView guideRememberedConstantCategory];
  self.arrowGuideActive = YES;
  // The guide owns the play accent for its duration so FCP's bursty currentTime
  // can't flicker it during the watch-back step (restored on completion).
  self.guideOwnsPlayState = YES;
  __weak typeof(self) weak = self;
  [host runWithSeed:nil
      buildSteps:^NSArray<KKJoyrideStep *> *(KKJoyrideController *guide,
                                             KKJoyrideLanesBinder *binder) {
        __strong typeof(weak) s = weak;
        if (!s)
          return @[];
        // Forward play-button taps to the binder so the watch-back step's
        // binder.playToggleTapped machine fires (else it never advances).
        __weak KKJoyrideLanesBinder *wb = binder;
        s.onPlaybackToggleTapped = ^{
          [wb notifyPlaybackToggleTapped];
        };
        return [s _arrowGuideStepsForGuide:guide binder:binder];
      }
      extraOnComplete:^{
        __strong typeof(weak) s = weak;
        if (!s)
          return;
        s.arrowGuideActive = NO;
        s.onPlaybackToggleTapped = nil;
        s.guideOwnsPlayState = NO;
        // Restore the user's tab - live-switch the popover if it's still open
        // (e.g. the user skipped), else it just updates the reopen memory.
        if (s.arrowGuideSavedCategory.length)
          [s.basicLanesView
              guideSelectConstantCategory:s.arrowGuideSavedCategory];
        s.arrowGuideSavedCategory = nil;
      }];
}

- (void)restartMiniViewerGuide {
  [self _runKitRestartForSelector:_cmd];
}

- (void)restartOSCGuide {
  [self _runKitRestartForSelector:_cmd];
}

// The Presets guide stages an EMPTY scene (vs the timing guides' demo shape) so
// the applied preset lands on a clean canvas. Same base-IMP trick as
// -_runKitRestartForSelector: to invoke the kit's runPresetsGuide past this
// override; the shared guide host's run-did-end hook restores the scene.
- (void)runPresetsGuide {
  if (self.onGuidePresetsSceneBegin)
    self.onGuidePresetsSceneBegin();
  IMP base = [KKTimelineInspectorView instanceMethodForSelector:_cmd];
  ((void (*)(id, SEL))base)(self, _cmd);
}

// Canvas teaches the Position lane (a 2D clip-space point, stored 0..1) -
// it has the clearest mini-viewer point handle - with
// Scale as the second Advanced lane so the per-property timeline + marquee
// multi-select steps have two rows. Both live in Canvas's "Transform" category,
// so the Advanced lane-filter step groups them under the real capsule.
- (KKTimingGuideConfig *)_timingGuideConfig {
  KKTimingGuideConfig *cfg = [self makeTimingGuideConfig];
  cfg.primaryLabel = @"Position";
  cfg.primaryComponentCount = 2;
  cfg.primaryValueType = KKLaneValueTypeGeneric;
  cfg.primarySeedValues = @[ @0.5, @0.5 ];
  cfg.primaryCategoryKey = @"Transform";
  // OSCs to keep visible while a guide runs (the rest are hidden, restored on
  // end). The Position handle is what the guides reference.
  cfg.oscKeepLabels = @[ @"Position" ];
  // Second lane in the Advanced seed so the multi-row / marquee steps have two
  // properties. Scale is a non-featured lane (not in the Position keypose
  // mini-viewer), so seeding it can't disturb the featured Position handles.
  cfg.secondaryLabel = @"Scale";
  cfg.secondaryValueType = KKLaneValueTypeFloat;
  cfg.secondarySeedValues = @[ @100.0, @100.0 ];
  cfg.secondaryCategoryKey = @"Transform";
  // Destination the Basic constants step drags Position to (off-centre from the
  // 0.5,0.5 seed, normalized 0..1).
  cfg.primaryTargetValues = @[ @0.7, @0.35 ];
  // A different spot for the keypose-edit drag so the handle visibly moves.
  cfg.keyposeTargetValues = @[ @0.3, @0.62 ];
  // Mini-viewer guide: four corner positions so the clip visibly moves around
  // the frame across the filmstrip / onion-skin frames.
  cfg.miniViewerSeedValues =
      @[ @[ @0.3, @0.3 ], @[ @0.7, @0.3 ], @[ @0.7, @0.7 ], @[ @0.3, @0.7 ] ];
  // The OSC guide's pill step has the user disable a NON-featured control (so
  // the keypose mini-viewer, which shows only Position, stays populated).
  cfg.oscDisableLabel = @"Scale";
  // The viewer image rect (for the Basic watch-back cutout + the OSC guide's
  // viewer spotlight), read off the shared bridge the OSC tick feeds. Returns
  // NSZeroRect until a draw tick lands, so the guides degrade gracefully.
  cfg.viewerScreenRect = ^NSRect {
    return CanvasSharedOSCGuideBridge().estimatedViewerScreenRect;
  };
  cfg.oscGuideBridge = ^KKOSCGuideBridge * {
    return CanvasSharedOSCGuideBridge();
  };
  return cfg;
}

@end
