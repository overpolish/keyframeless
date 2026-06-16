/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasInspectorView.h"
#import "CanvasLayerListController.h"
#import "CanvasLayerTimeline.h"
#import "CanvasMiniViewerRenderer.h"

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
    _availableLanes = [availableLanes copy];
    _laneStructureSignature = [self _laneSignatureForTimeline:timeline];
    _miniViewerRenderer = [[CanvasMiniViewerRenderer alloc] init];
    _miniViewerRenderer.timeline = timeline;
    // No on-screen controls yet (increment 1): the preview is a clean
    // passthrough frame with no handles drawn or hit-tested.
    _miniViewerRenderer.handlesHidden = YES;
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
    // A keypose popover scoped itself to a layer (clicked pill) -> mirror that
    // into the layer list's highlight.
    self.basicLanesView.onKeyposeLayerActivated = ^(NSString *layerKey) {
      typeof(self) s = weak;
      [s->_layerListController highlightLayerID:layerKey];
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
  _layerListController.selectedLayerID = _selectedLayerID;
  // Re-point an already-open keypose popover at this layer FIRST: retarget
  // guards against a no-op when the graph's active layer already equals the new
  // one, so it must run before activeLayerKey is updated (no-op if no popover
  // open). Then set activeLayerKey so the NEXT fresh open scopes here too.
  [self.basicLanesView retargetKeyposePopoverToLayerKey:layerID];
  self.basicLanesView.activeLayerKey = layerID;
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
  self.basicLanesView.graphTimeline = merged;
  NSMutableArray<NSString *> *order =
      [NSMutableArray arrayWithCapacity:paths.count];
  for (KKBezierPath *p in paths)
    if (p.layerID.length)
      [order addObject:p.layerID];
  self.basicLanesView.layerOrder = order;
  // Some layer still has a constant (un-animated) param? Keep the Constants
  // button reachable even when the selected layer is fully animated.
  self.basicLanesView.ownerConstantsAvailable =
      CanvasAnyLayerHasConstant(paths, _availableLanes);
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
  _miniViewerRenderer.layers = [_layerListController currentLayerPaths];
}

- (void)applyTimeline:(KKTimeline *)timeline {
  [super applyTimeline:timeline];
  _miniViewerRenderer.timeline = timeline;
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
  // Always rebuild the all-layers graph (any layer may have gained/lost an
  // animated lane).
  [self _feedGraph];
  NSString *sig = [self _laneSignatureForTimeline:layerTL];
  if ([sig isEqualToString:_laneStructureSignature])
    return;
  _laneStructureSignature = sig;
  [self applyTimeline:layerTL];
}

// Order-sensitive signature of the lane set (unique tagged labels + layer
// labels), so a rename or reorder also counts as a structure change.
- (NSString *)_laneSignatureForTimeline:(KKTimeline *)timeline {
  NSMutableArray<NSString *> *parts =
      [NSMutableArray arrayWithCapacity:timeline.lanes.count];
  for (KKLane *l in timeline.lanes)
    [parts addObject:[NSString stringWithFormat:@"%@|%@", l.label ?: @"",
                                                l.layerLabel ?: @""]];
  return [parts componentsJoinedByString:@"\n"];
}

- (void)setLayerParamActionTarget:(id)target {
  _layerListController.paramActionTarget = target;
  // The target is the host-recognized plugin for action scopes; now that it's
  // set, do an authoritative read to seed the preview's layers.
  [self _syncLayersToRenderer];
}

@end
