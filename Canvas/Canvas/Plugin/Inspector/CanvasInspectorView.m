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
  }
  return self;
}

- (void)dealloc {
  [_layerListController invalidate];
}

- (void)applyTimeline:(KKTimeline *)timeline {
  [super applyTimeline:timeline];
  _miniViewerRenderer.timeline = timeline;
}

- (void)reloadLayerList {
  [_layerListController reload];
}

- (void)setLayerParamActionTarget:(id)target {
  _layerListController.paramActionTarget = target;
}

@end
