/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKMiniViewerFeed.h>
#import <KeyframelessKit/KKMotionBlur.h>
#import <KeyframelessKit/KKTimeline.h>

@class KKTimelineInspectorView;
@class KKMiniViewerRenderer;
@protocol PROAPIAccessing;

NS_ASSUME_NONNULL_BEGIN

/// Reads the keypose-popover request JSON (written by the inspector's
/// mini-viewer popover) and returns the requested clip-fractions list when
/// `active` is true. Returns nil otherwise. Falls back to single-element
/// `[frac]` for legacy single-fraction payloads.
NSArray<NSNumber *> *_Nullable KKReadBoundaryRequestFracs(NSString *path);
BOOL KKReadMiniViewerFeedActive(NSString *path);

/// Process-global timeline snapshot. One plugin instance per XPC process,
/// so a single static slot suffices to hand the current timeline to OSC
/// math (which can't see the FxPlug param APIs from its draw tick).
/// Retain semantics; safe to set with nil.
void KKSetProcessTimelineSnapshot(KKTimeline *_Nullable timeline);
KKTimeline *_Nullable KKProcessTimelineSnapshot(void);

/// Frame-duration shared with OSC math so its keypose-snap epsilon is
/// one frame across any project framerate. Zero is ignored.
void KKSetProcessFrameDurationSeconds(double frameDurSec);
double KKProcessFrameDurationSeconds(void);

/// Cross-tick state every v3 plugin threads between scheduleInputs,
/// pluginState, parameterChanged, and the playhead poll. Held as a
/// retained property on the plugin's private interface.
@interface KKRenderCache : NSObject
@property(nonatomic) double effectStartSec;
@property(nonatomic) double effectDurSec;
@property(nonatomic) double timelineStartSec; // FCP movePlayhead base
/// The effect's OWN start mapped into project seconds
/// (`timelineTime:fromInputTime:(effectStart)`) - clip fraction 0 in absolute
/// timeline time, which is the span every link-bus publish is tagged with.
/// Distinct from `timelineStartSec`, which maps the SOURCE in-point.
/// Refreshed every tick by KKRefreshRenderCache, so anything on the render
/// path that needs it reads it here instead of re-entering the host for an
/// answer this tick already has.
@property(nonatomic) double clipProjectStartSec;
/// Raw source-media in-point (startTimeOfInputToFilter), in source seconds.
/// Head-trimming a clip advances this; tail-trimming leaves it. Used by the
/// "Maintain Timing" remap to anchor keyposes to absolute media time.
@property(nonatomic) double sourceInSec;
@property(nonatomic) double frameDurSec;
/// Latest playhead sample, written by KKPlayheadPoller on MAIN and read from
/// the RENDER threads by the mini-viewer feed gate. One writer, one reader,
/// no set-then-read protocol between them - the reader only ever takes the
/// most recent sample - so this is the "store the cached value" shape, not a
/// shared transient flag. `atomic` (no `nonatomic`) so the accessors are safe
/// to cross that boundary. `playheadSampleWall` is CACurrentMediaTime at the
/// sample; <= 0 means never sampled, and a stale value disables the gate.
@property(atomic) double playheadFrac;
@property(atomic) double playheadSampleWall;
@property(atomic) BOOL playheadPlaying;
@property(nonatomic) double lastPushedClipDuration;
@property(nonatomic) double lastPushedClipProjectStart;
@property(nonatomic) BOOL loopEnabled;
/// "Maintain Timing" (timelock): when YES and `anchorDurSec` > 0, the render
/// remaps the clip fraction so keyposes hold their absolute media position
/// across trims/grows/splits instead of rescaling with the clip. These three
/// are populated each tick from the UI-state blob.
@property(nonatomic) BOOL maintainTimingEnabled;
@property(nonatomic) double anchorSrcInSec; // source in-point when lock engaged
@property(nonatomic) double anchorDurSec;   // clip duration when lock engaged
// Debounce state for the bake: a trim drags the source range across many ticks;
// the render-remap shows a live preview throughout, and the destructive blob
// rewrite is deferred until the range settles (one commit per trim, not per
// frame). `bakeGeneration` bumps on every change; a delayed commit runs only if
// its captured generation is still current.
@property(nonatomic) double bakeLastSeenSrcInSec;
@property(nonatomic) double bakeLastSeenDurSec;
@property(nonatomic) NSInteger bakeGeneration;
/// Multi-slot mini-viewer feed bookkeeping populated by
/// KKBuildSourceRequests; read by the render-output side to pair
/// delivered tiles to slots.
@property(nonatomic) BOOL boundaryFeedActive;
@property(nonatomic) BOOL miniViewerFeedActive;
@property(nonatomic) double lastBoundaryReqSec;
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *boundaryReqSecs;
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *boundaryReqFracs;
/// Clip fraction (0..1) for an absolute render-time in seconds, from the cached
/// effect start/duration. The mini-viewer feed tags each published source frame
/// with this so a live-playback consumer evaluates the effect at exactly that
/// frame's own playhead time - the transform stays locked to the footage the
/// feed delivered, instead of a separately-polled playhead that drifts behind
/// it. 0 when the duration is unset.
- (double)clipFractionAtSeconds:(double)sec;
@end

/// Handles a kKKParamTimelineData parameterChanged: reads the blob inside the
/// host callback (without opening a nested action), optionally stamps duration,
/// publishes to the
/// process snapshot, sets renderer.timeline, and dispatches applyTimeline:
/// to the inspector view on the main queue.
void KKHandleTimelineParamChanged(
    id<PROAPIAccessing> apiManager, UInt32 timelineParamID,
    KKTimeline *_Nullable (^_Nullable timelineStamper)(KKTimeline *_Nullable),
    KKMiniViewerRenderer *_Nullable miniViewerRenderer,
    KKTimelineInspectorView *_Nullable inspectorView);

/// Builds the FxImageTileRequest list for one render: the current frame +
/// boundary-preview frames. Caches the boundary state into `cache` so the
/// render-output side can pair delivered tiles to slots.
///
/// Motion blur does NOT request sub-frame source frames here: every built-in
/// plugin blurs its OWN animation (per-sample params / transforms, or velocity
/// reconstruction) over a single source frame, so requesting N sub-frame
/// sources would only re-render the upstream effect N times for no benefit
/// (footage smear needs Frame Blending / Optical Flow to differ at all). An
/// effect that genuinely wants footage content-smear calls `+[KKMotionBlur
/// appendSourceRequestsForState:...]` explicitly.
///
/// `requestBuilder` returns an FxImageTileRequest for the given CMTime.
/// Passed as a block to keep FxPlug out of KeyframelessKit's link surface
/// (workflow-extension targets use this framework too). Each plugin's
/// `scheduleInputs:` wraps `[[FxImageTileRequest alloc] initWith…]` in a
/// one-line block.
NSArray *KKBuildSourceRequests(CMTime renderTime,
                               NSString *_Nullable boundaryRequestPath,
                               KKRenderCache *cache,
                               id _Nonnull (^requestBuilder)(CMTime t));

/// Applies the "Maintain Timing" remap to a clip fraction (0–1 of the current
/// trimmed clip). Returns `clipFrac` unchanged when the lock is off or no
/// anchor is established. Otherwise maps the frame's absolute media time
/// (`sourceInSec + clipFrac * effectDurSec`) back to the authored fraction
/// against the anchor `(anchorSrcInSec, anchorDurSec)`, clamped to [0,1] so
/// keyposes pushed past the clip edge hold at the endpoint. Pass the cache by
/// value-of-fields; reads `maintainTimingEnabled`, `sourceInSec`,
/// `effectDurSec`, `anchorSrcInSec`, `anchorDurSec`.
double KKMaintainTimingRemappedFraction(double clipFrac, KKRenderCache *cache);

/// Populates the render-tick loop + maintain-timing fields from a parsed
/// UI-state dictionary (the `kParamUIState` blob). Plugins call this from the
/// per-tick param read instead of hand-copying `loopEnabled`.
void KKRenderCacheApplyUIState(KKRenderCache *cache,
                               NSDictionary *_Nullable uiState);

/// Refreshes the render-tick cached values from FxTimingAPI and pushes
/// clip-duration + frame-duration to the inspector view (on main) when
/// they change. Also seeds the process frame-duration. Call once per
/// pluginState tick. Returns YES on success (durSec > 0).
BOOL KKRefreshRenderCache(id<PROAPIAccessing> apiManager,
                          KKTimelineInspectorView *_Nullable inspectorView,
                          KKRenderCache *cache);

NS_ASSUME_NONNULL_END
