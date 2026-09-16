/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>

NS_ASSUME_NONNULL_BEGIN

@class MagicMovePlugin;

/// Inspector views poll: the host has no callback for playhead movement.
@protocol MMInspectorRefreshable <NSObject>
/// Read host state and update the view. The caller owns the action scope, so
/// implementations must not open or close one, and must not write parameters.
- (void)refreshInspectorValuesInAction:(id<FxCustomParameterActionAPI_v4>)action;
@end

/// One refresh clock per plugin instance. Every registered view is refreshed
/// from a single host action per tick, rather than each view opening its own:
/// with two effects selected that is one action per tick instead of twelve.
///
/// Registrations are weak and the timer only runs while views are registered.
/// It runs in the default run loop mode, because opening a host action inside
/// an AppKit tracking loop is what the menu paths deliberately avoid.
@interface MMInspectorClock : NSObject
- (instancetype)initWithManager:(id<PROAPIAccessing>)manager;
- (void)addView:(id<MMInspectorRefreshable>)view;
- (void)removeView:(id<MMInspectorRefreshable>)view;
/// Refresh every registered view now, in one action. Used on attachment so a
/// freshly shown row does not wait for the next tick.
- (void)refreshNow;
@end

NS_ASSUME_NONNULL_END
