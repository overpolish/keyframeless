/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasInspectorView.h"
#import "CanvasLayerListController.h"
#import "CanvasMiniViewerRenderer.h"

@implementation CanvasInspectorView {
  CanvasMiniViewerRenderer *_miniViewerRenderer;
  CanvasLayerListController *_layerListController;
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
    [self _syncLayersToRenderer];
  }
  return self;
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
}

- (void)setLayerParamActionTarget:(id)target {
  _layerListController.paramActionTarget = target;
  // The target is the host-recognized plugin for action scopes; now that it's
  // set, do an authoritative read to seed the preview's layers.
  [self _syncLayersToRenderer];
}

@end
