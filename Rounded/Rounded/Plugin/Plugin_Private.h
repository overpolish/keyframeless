/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "Plugin.h"
#import "RoundedInspectorView.h"
#import <KeyframelessKit/KeyframelessKit.h>

@interface RoundedPlugin ()
@property(nonatomic, weak, nullable) RoundedInspectorView *inspectorView;
@property(nonatomic, retain, nullable) KKMiniCanvasFeed *miniCanvasFeed;
@property(nonatomic) BOOL miniDragUndoStarted;
/// Last clip duration (seconds) pushed live into the inspector from the
/// render tick; guards against re-pushing an unchanged value every frame.
@property(nonatomic) double lastPushedClipDuration;
/// Last playhead fraction (0–1) pushed live into the inspector scrubber;
/// guards against re-dispatching an unchanged value every render tick.
@property(nonatomic) double lastPushedPlayheadFrac;
/// Self-terminating main-queue poll that samples currentTime for the
/// scrubber. Needed because render ticks stop ~1s before the clip end (FCP
/// pre-render buffer) — the poll keeps following currentTime through the
/// buffered tail until it stalls (paused/ended), then invalidates itself.
@property(nonatomic, retain, nullable) NSTimer *playheadTimer;
@property(nonatomic) double playheadPollLast;     // last currentTime sampled
@property(nonatomic) NSInteger playheadPollStall; // consecutive no-change
@property(nonatomic) BOOL lastPushedPlaying; // play/pause button color state
/// Loop-back: mirror of the UI-state "loopEnabled" toggle, cached from the
/// render path so the main-queue poll can read it. When YES and the
/// playhead reaches the clip end, wrap it back to the start.
@property(nonatomic) BOOL loopEnabledCached;
/// CACurrentMediaTime() of the last loop wrap — cooldown so the
/// pause→seek→resume sequence isn't re-triggered while FCP processes it.
@property(nonatomic) NSTimeInterval lastLoopWrapTime;
/// Effect start + duration (seconds) cached from the render path, where
/// FxTimingAPI resolves. -scheduleInputs: reads these because FxTimingAPI
/// returns 0 in that context.
@property(nonatomic) double cachedEffectStartSec;
@property(nonatomic) double cachedEffectDurSec;
/// Timeline-time of the clip start (seconds) and native frame duration,
/// cached from the render path. The scrubber/loop-back playhead move is
/// host-aware: FCP's movePlayheadToTime: wants timeline-time
/// (cachedTimelineStartSec + frac·dur); Motion wants effect-time
/// (cachedEffectStartSec + frac·dur).
@property(nonatomic) double cachedTimelineStartSec;
@property(nonatomic) double cachedFrameDurSec;
/// Set in -scheduleInputs: from the boundary request file. When YES the feed
/// publishes ONLY the boundary tile (sourceImages[1]) and skips ticks that
/// didn't deliver it, so the preview never flickers to the scrub frame.
@property(nonatomic) BOOL boundaryFeedActive;
/// Requested boundary time (seconds), cached from -scheduleInputs: so the
/// render tick can compare it against each delivered tile's mediaTime.
@property(nonatomic) double lastBoundaryReqSec;
/// Returns a copy of `timeline` with every lane's lastKnownClipDuration set
/// to the current effect duration (seconds), so the Basic ruler/hover have a
/// duration without extra plumbing (it then persists via the next blob
/// write). Must be called within an FxCustomParameterActionAPI action scope
/// so FxTimingAPI resolves; returns the input unchanged if unavailable.
- (nullable KKTimeline *)timelineStampedWithClipDuration:
    (nullable KKTimeline *)timeline;
@end

NS_ASSUME_NONNULL_BEGIN

@interface RoundedPlugin (Parameters)
- (BOOL)addParametersWithError:(NSError **)error;
@end

@interface RoundedPlugin (CustomUI)
- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED;
@end

typedef struct {
  double radius;
  double cropW; // 0..1 fraction of image width
  double cropH; // 0..1 fraction of image height
  double cropX; // center offset, -0.5..0.5 (+ = right)
  double cropY; // center offset, -0.5..0.5 (+ = up)
} RoundedPluginState;

@interface RoundedPlugin (Render)
- (BOOL)pluginState:(NSData *_Nullable *_Nonnull)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error;
/// Computes the per-frame rounded params at `time`. Used by both the
/// normal render path (via pluginState:atTime:) and the motion blur
/// sub-frame sample loop.
- (BOOL)roundedParams:(RoundedPluginState *)outParams
               atTime:(CMTime)time
                error:(NSError **)error;
- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError *_Nullable *)outError;
/// Start the self-terminating currentTime → scrubber poll if not already
/// running. Main queue only (manages an NSTimer on the main runloop).
- (void)_ensurePlayheadPolling;
@end

NS_ASSUME_NONNULL_END
