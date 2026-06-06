/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "RoundedInspectorView.h"

#import "RoundedInspectorView+Guides.h"
#import "RoundedInspectorView_Private.h"
#import "RoundedMiniCanvasRenderer.h"
#import <KeyframelessKit/KKTimelineInspectorView+Guide.h>
#import <KeyframelessKit/KKTimingGuide.h>

static NSString *const kRoundedIntroSeenKey = @"RoundedIntroSeen";

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
    // The kit's restart/autostart machinery pulls a fresh config from here.
    __weak typeof(self) weak = self;
    self.timingGuideConfigProvider = ^KKTimingGuideConfig * {
      __strong typeof(weak) s = weak;
      return s ? [s _timingGuideConfig] : nil;
    };
  }
  return self;
}

- (BOOL)showsOSCVisibilityRow {
  return YES;
}

- (void)applyTimeline:(KKTimeline *)timeline {
  [super applyTimeline:timeline];
  _miniCanvasRenderer.timeline = timeline;
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (!self.isDetachedCopy)
    [self autostartIntroGuideOnceWithSeenKey:kRoundedIntroSeenKey];
}

- (instancetype)beginDetachedCopy {
  return [super beginDetachedCopy];
}

@end
