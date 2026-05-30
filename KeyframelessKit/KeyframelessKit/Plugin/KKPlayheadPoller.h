/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

@class KKTimelineInspectorView;
@class KKV3RenderCache;
@protocol PROAPIAccessing;

NS_ASSUME_NONNULL_BEGIN

/// Self-terminating main-queue NSTimer that follows
/// FxCustomParameterActionAPI_v4.currentTime, pushes scrubber + playing
/// state to the inspector view, and wraps the playhead at clip end when
/// the cached loop flag is YES. Render ticks stop ~1s before the clip end
/// (FCP pre-render buffer); the poll catches the buffered tail.
///
/// Plugin owns one as a retained property. Configure it once after init
/// (apiManager, actionTarget, inspectorView, renderCache), then call
/// `-ensureRunning` from the render path whenever cached duration > 0.
@interface KKPlayheadPoller : NSObject
- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                      actionTarget:(NSObject *)actionTarget
                       renderCache:(KKV3RenderCache *)renderCache;
/// Refresh on each createViewForParameterID: in case the inspector view
/// was re-created. Weak ref; safe to set with nil.
- (void)setInspectorView:(nullable KKTimelineInspectorView *)inspectorView;
- (void)ensureRunning;
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END
