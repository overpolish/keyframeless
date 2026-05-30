/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKMiniCanvasFeed.h>
#import <KeyframelessKit/KKMotionBlur.h>
#import <KeyframelessKit/KKTimingLane.h>
#import <KeyframelessKit/KKTimingStage.h>

@class KKTimelineInspectorView;
@class KKMiniCanvasRenderer;
@protocol PROAPIAccessing;

NS_ASSUME_NONNULL_BEGIN

/// Reads the keypose-popover request JSON (written by the inspector's
/// mini-canvas popover) and returns the requested clip-fractions list when
/// `active` is true. Returns nil otherwise. Falls back to single-element
/// `[frac]` for legacy single-fraction payloads.
NSArray<NSNumber *> *_Nullable KKReadBoundaryRequestFracs(NSString *path);

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
@interface KKV3RenderCache : NSObject
@property(nonatomic) double effectStartSec;
@property(nonatomic) double effectDurSec;
@property(nonatomic) double timelineStartSec; // FCP movePlayhead base
@property(nonatomic) double frameDurSec;
@property(nonatomic) double lastPushedClipDuration;
@property(nonatomic) BOOL loopEnabled;
/// Multi-slot mini-canvas feed bookkeeping populated by
/// KKBuildV3SourceRequests; read by the render-output side to pair
/// delivered tiles to slots.
@property(nonatomic) BOOL boundaryFeedActive;
@property(nonatomic) double lastBoundaryReqSec;
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *boundaryReqSecs;
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *boundaryReqFracs;
@end

/// Handles a kKKParamTimelineData parameterChanged: reads the blob inside
/// an action scope, optionally stamps clip duration, publishes to the
/// process snapshot, sets renderer.timeline, and dispatches applyTimeline:
/// to the inspector view on the main queue.
void KKHandleTimelineParamChanged(
    id<PROAPIAccessing> apiManager, UInt32 timelineParamID,
    NSObject *actionTarget,
    KKTimeline *_Nullable (^_Nullable timelineStamper)(KKTimeline *_Nullable),
    KKMiniCanvasRenderer *_Nullable miniCanvasRenderer,
    KKTimelineInspectorView *_Nullable inspectorView);

/// Builds the FxImageTileRequest list for one render: current frame +
/// motion-blur sub-frames + boundary-preview frames. Caches the boundary
/// state into `cache` so the render-output side can pair delivered tiles
/// to slots. `mbState.enabled == NO` produces no MB sub-frames.
///
/// `requestBuilder` returns an FxImageTileRequest for the given CMTime.
/// Passed as a block to keep FxPlug out of KeyframelessKit's link surface
/// (workflow-extension targets use this framework too). Each plugin's
/// `scheduleInputs:` wraps `[[FxImageTileRequest alloc] initWith…]` in a
/// one-line block.
NSArray *KKBuildV3SourceRequests(CMTime renderTime, KKMotionBlurState mbState,
                                 NSString *_Nullable boundaryRequestPath,
                                 KKV3RenderCache *cache,
                                 id _Nonnull (^requestBuilder)(CMTime t));

/// Refreshes the render-tick cached values from FxTimingAPI and pushes
/// clip-duration + frame-duration to the inspector view (on main) when
/// they change. Also seeds the process frame-duration. Call once per
/// pluginState tick. Returns YES on success (durSec > 0).
BOOL KKRefreshV3RenderCache(id<PROAPIAccessing> apiManager,
                            KKTimelineInspectorView *_Nullable inspectorView,
                            KKV3RenderCache *cache);

NS_ASSUME_NONNULL_END
