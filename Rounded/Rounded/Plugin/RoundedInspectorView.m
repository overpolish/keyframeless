/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "RoundedInspectorView.h"

#import "RoundedInspectorView+Guides.h"
#import "RoundedInspectorView_Private.h"
#import "RoundedMiniCanvasRenderer.h"

@implementation RoundedInspectorView

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                       loopEnabled:(BOOL)loopEnabled
                         activeTab:(NSInteger)activeTab
                    availableLanes:(NSArray<KKLane *> *)availableLanes
                          timeline:(KKTimeline *)timeline {
  self = [super initWithAPIManager:apiManager
                       loopEnabled:loopEnabled
                         activeTab:activeTab
                    availableLanes:availableLanes
                          timeline:timeline];
  if (self) {
    _miniCanvasRenderer = [[RoundedMiniCanvasRenderer alloc] init];
    _miniCanvasRenderer.timeline = timeline;
    self.miniCanvasDelegate = _miniCanvasRenderer;
    self.miniCanvasDescriptorPath = RoundedMiniCanvasDescriptorPath;
    self.miniCanvasRequestPath = RoundedMiniCanvasRequestPath;
    self.managePopoverSpotlightLabel = @"Radius";
  }
  return self;
}

- (void)applyTimeline:(KKTimeline *)timeline {
  [super applyTimeline:timeline];
  _miniCanvasRenderer.timeline = timeline;
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (!self.isDetachedCopy)
    [self _maybeAutostartIntroGuide];
}

- (instancetype)beginDetachedCopy {
  RoundedInspectorView *copy =
      (RoundedInspectorView *)[super beginDetachedCopy];
  if ([copy isKindOfClass:[RoundedInspectorView class]])
    copy.effectHeaderRectProvider = self.effectHeaderRectProvider;
  return copy;
}

- (void)dealloc {
  [_miniCanvasRenderer release];
  [super dealloc];
}

@end
