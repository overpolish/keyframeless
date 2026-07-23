/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "GlowInspectorView.h"

#import "GlowInspectorView+Guides.h"
#import "GlowInspectorView_Private.h"
#import "GlowMiniViewerRenderer.h"
#import <KeyframelessKit/KKTimelineInspectorView+Guide.h> // intro autostart

// NSUserDefaults flag: the first-apply intro guide has been shown once.
static NSString *const kGlowIntroSeenKey = @"GlowIntroSeen";

@implementation GlowInspectorView

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
    _miniViewerRenderer = [[GlowMiniViewerRenderer alloc] init];
    _miniViewerRenderer.timeline = timeline;
    self.miniViewerDelegate = _miniViewerRenderer;
    self.miniViewerDescriptorPath = GlowMiniViewerDescriptorPath;
    self.miniViewerRequestPath = GlowMiniViewerRequestPath;
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

// First-apply intro: springs the Basic walkthrough once the effect is selected
// and its on-screen control is drawn (the same gate the other plugins use), so
// a first-time user is shown the basics rather than having to find the guides.
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (!self.isDetachedCopy)
    [self autostartIntroGuideOnceWithSeenKey:kGlowIntroSeenKey];
}

@end
