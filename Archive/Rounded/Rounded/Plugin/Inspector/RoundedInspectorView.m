/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "RoundedInspectorView.h"

#import "RoundedInspectorView+Guides.h"
#import "RoundedInspectorView_Private.h"
#import "RoundedMiniViewerRenderer.h"
#import <KeyframelessKit/KKTimelineInspectorView+Guide.h>
#import <KeyframelessKit/KKTimingGuide.h>

static NSString *const kRoundedIntroSeenKey = @"RoundedIntroSeen";

@implementation RoundedInspectorView

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
    _miniViewerRenderer = [[RoundedMiniViewerRenderer alloc] init];
    _miniViewerRenderer.timeline = timeline;
    self.miniViewerDelegate = _miniViewerRenderer;
    self.miniViewerDescriptorPath = RoundedMiniViewerDescriptorPath;
    self.miniViewerRequestPath = RoundedMiniViewerRequestPath;
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
  _miniViewerRenderer.timeline = timeline;
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
