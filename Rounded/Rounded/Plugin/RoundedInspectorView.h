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

- (void)setLoopEnabled:(BOOL)enabled;
- (void)setActiveTab:(NSInteger)tab;
- (void)applyTimeline:(KKTimeline *)timeline;

@end

NS_ASSUME_NONNULL_END
