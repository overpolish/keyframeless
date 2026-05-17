/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKTimingStage.h>
#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface RoundedInspectorView : NSView

@property(nonatomic, copy, nullable) void (^onLoopToggled)(BOOL enabled);
@property(nonatomic, copy, nullable) void (^onTabChanged)(NSInteger tab);
@property(nonatomic, copy, nullable) void (^onTimelineMutated)
    (KKTimeline *updated);

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                       loopEnabled:(BOOL)loopEnabled
                         activeTab:(NSInteger)activeTab
                    availableLanes:(NSArray<KKLane *> *)availableLanes
                          timeline:(KKTimeline *)timeline
    NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@property(nonatomic, readonly) KKTimelineLanesView *basicLanesView;

- (void)setLoopEnabled:(BOOL)enabled;
- (void)setActiveTab:(NSInteger)tab;
- (void)applyTimeline:(KKTimeline *)timeline;

// The guide entry points (restartIntroGuide / restartOSCGuide /
// restartFullWalkthroughGuide / oscGuideActive) live on the
// RoundedInspectorView (Guides) category — import
// "RoundedInspectorView+Guides.h" to call them.

/// Returns the screen rect of THIS effect instance's FCP header row (from its
/// own logo banner), so the OSC guide's final step anchors to the correct
/// effect with multiple instances. Set by the plugin; nil → floating tip.
@property(nonatomic, copy, nullable) NSRect (^effectHeaderRectProvider)(void);

/// When YES, the OSC guide's drag step only advances once the value actually
/// reaches the target; when NO (default) any drag/release advances. Lets
/// different interactive guides enforce completion. Set before restartOSCGuide.
@property(nonatomic) BOOL oscGuideRequireTargetHit;

/// Invoked when a guide is fully completed (reached its final step), NOT on
/// skip/dismiss. Set per-guide in its onStart; used to persist "completed".
@property(nonatomic, copy, nullable) void (^onGuideCompleted)(void);

@end

NS_ASSUME_NONNULL_END
