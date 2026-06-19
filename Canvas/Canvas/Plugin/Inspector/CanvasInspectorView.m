/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasInspectorView.h"
#import "CanvasLayerListController.h"
#import "CanvasLayerTimeline.h"
#import "CanvasMiniViewerRenderer.h"
#import <KeyframelessKit/KKBezierPath.h>

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
    self.miniViewerDelegate = _miniViewerRenderer;
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
      [weak _selectLayer:layerID];
    };
    _layerListController.onAutoSelectToggled = ^(BOOL on) {
      typeof(self) s = weak;
      if (s.onAutoSelectChanged)
        s.onAutoSelectChanged(on);
    };
    // Mirror the popover's non-selectable gating onto the MINI preview (same
    // rule as the layer rows). The MAIN VIEWER gates itself by the playhead in
    // the OSC (a layer is clickable there if it has a constant or a keypose at
    // the playhead), so it needs nothing pushed here.
    _layerListController.onNonSelectableLayersChanged = ^(NSSet<NSString *> *s) {
      typeof(self) ss = weak;
      ss->_miniViewerRenderer.nonSelectableLayerIDs = s;
    };
    // A keypose popover scoped itself to a layer (clicked a keypose in that
    // layer's lane) -> make it the SELECTED layer, not just a highlight, so the
    // viewer OSC / mini / Constants all follow the layer being edited. Without a
    // real selection change the viewer OSC kept reading the previously-selected
    // layer (it reads the process-snapshot timeline, which only applyTimeline
    // republishes). _selectLayer no-ops the popover retarget (the graph already
    // scoped itself before firing this), so there's no loop; also move the list
    // highlight since this didn't originate from a panel click.
    self.basicLanesView.onKeyposeLayerActivated = ^(NSString *layerKey) {
      [weak _selectAndHighlightLayer:layerKey];
    };
    // Opening Constants: if the selected layer has no constants, land on the
    // first layer that does (the popover shows the selected owner's constants).
    self.onConstantsWillShow = ^{
      [weak _ensureConstantsLayerSelected];
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

// Switch which layer the Animated dropdown + Constants act on. This drives the
// SINGLE-OWNER timeline only; the graph (graphTimeline) shows every layer and
// is unaffected by selection.
- (void)_selectLayer:(NSString *)layerID {
  _selectedLayerID = [layerID copy];
  NSArray<KKBezierPath *> *paths = [_layerListController currentLayerPaths];
  KKBezierPath *sel = CanvasSelectedLayerForPaths(paths, _selectedLayerID);
  KKTimeline *layerTL = CanvasLayerTimelineForPath(sel, _availableLanes);
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
  // Let the plugin swap the active OSC-visibility set to this layer's.
  if (_onSelectedLayerChanged)
    _onSelectedLayerChanged(sel.layerID);
}

// Select a layer AND move the list highlight. Used when the selection originates
// somewhere other than a panel row click (a keypose-lane click, a mini-viewer
// auto-select) - those don't set the row highlight themselves, unlike
// onPrimaryLayerSelected which fires from the row click that already highlights.
- (void)_selectAndHighlightLayer:(NSString *)layerID {
  [self _selectLayer:layerID];
  [_layerListController highlightLayerID:layerID];
}

- (void)setAutoSelect:(BOOL)autoSelect {
  _layerListController.autoSelect = autoSelect;
  _miniViewerRenderer.autoSelectEnabled = autoSelect;
}

- (void)restoreSelectedLayerID:(NSString *)layerID {
  NSArray<KKBezierPath *> *paths = [_layerListController currentLayerPaths];
  // nil/empty target = topmost layer (the baseline before any selection
  // persisted, so undoing past the first selection lands back there).
  KKBezierPath *target =
      CanvasSelectedLayerForPaths(paths, layerID.length ? layerID : nil);
  KKBezierPath *current = CanvasSelectedLayerForPaths(paths, _selectedLayerID);
  if (target == current ||
      (target.layerID && [target.layerID isEqualToString:current.layerID]))
    return; // already there - don't churn the UI on unrelated UIState changes
  [self _selectLayer:layerID.length ? layerID : nil];
  // A panel click already shows its highlight; an undo/redo-driven restore
  // doesn't, so move it explicitly to the (resolved) layer.
  [_layerListController highlightLayerID:target.layerID];
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
  KKBezierPath *sel = CanvasSelectedLayerForPaths(paths, _selectedLayerID);
  _miniViewerRenderer.selectedLayerID = sel.layerID;
  [self syncMiniHandleVisibility]; // OSC visibility + lock
  _layerListController.selectedLayerID = sel.layerID;
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
// OSC, so opt in (matches MagicMove/Rounded).
- (BOOL)showsOSCVisibilityRow {
  return YES;
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

- (void)applyTimeline:(KKTimeline *)timeline {
  [super applyTimeline:timeline];
  _miniViewerRenderer.timeline = timeline;
  // Publish the SELECTED layer's timeline as the process snapshot so the viewer
  // Position OSC (same process) reads this layer. Its lanes carry layerKey, so
  // an OSC drag knows which layer's animationJSON to write. (drawOSC can't read
  // the param - FxParameterRetrievalAPI is nil there - so the snapshot is its
  // only source.)
  KKSetProcessTimelineSnapshot(timeline);
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
  KKBezierPath *sel = CanvasSelectedLayerForPaths(paths, _selectedLayerID);
  KKTimeline *layerTL = CanvasLayerTimelineForPath(sel, _availableLanes);
  // Always refresh the viewer OSC's process snapshot with the selected layer's
  // CURRENT keyposes - even mid-drag. The snapshot only feeds the viewer
  // control's draw + visibility (which must track a just-added/moved keypose, so
  // its lead-in/out hold visibility recomputes against the new first/last
  // keypose times); it doesn't reset any inspector-side popover/mini edit. The
  // gated applyTimeline below also sets it, but is skipped on a value-only
  // change during a drag - which is exactly when the snapshot went stale.
  KKSetProcessTimelineSnapshot(layerTL);
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
    [parts addObject:[NSString stringWithFormat:@"%@|%@|%d", l.label ?: @"",
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

@end
