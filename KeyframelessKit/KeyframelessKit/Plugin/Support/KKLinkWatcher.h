/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

@protocol PROAPIAccessing;

NS_ASSUME_NONNULL_BEGIN

/// Watches the published files a subscriber reads and forces the subscriber to
/// re-render when one changes - because FCP renders clips independently and
/// will NOT re-render a subscriber on a cross-clip source edit, so it would
/// otherwise only refresh on the next scrub/playback (stale frames, "pinging").
///
/// Modelled on KKPlayheadPoller: the plugin owns one, feeds it the current
/// source names each render, and it polls their change-stamps on a main-queue
/// timer. During a sustained source drag it nudges at most ~4/s so the
/// subscriber tracks; a settle-fire lands the exact final value.
///
/// `nudgeParamID` MUST be a hidden STRING param (kKKParamRenderNudgeString,
/// registered by the kit's standard-params helper): string writes are the one
/// param write FCP keeps off the undo stack, and the watcher fires outside
/// any user edit - an undoable nudge stacks stray entries and re-arms itself
/// on every undo of the source edit.
@interface KKLinkWatcher : NSObject

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                      actionTarget:(NSObject *)actionTarget
                      nudgeParamID:(uint32_t)nudgeParamID;

/// Set the source link names to watch. Call each render from the render state.
/// Empty stops the watcher; non-empty (re)arms it. Call on the main queue (it
/// schedules a timer).
- (void)setSourceNames:(NSSet<NSString *> *)names;

- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
