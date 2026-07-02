/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

@protocol FxTimingAPI_v4;
@class FxImageTile;
@class FxImageTileRequest;
@class KKTimeline;

NS_ASSUME_NONNULL_BEGIN

/// When motion blur should actually fire on a given frame. Stored in the
/// custom-UI blob as `"mode"`; absent / 0 = transitions-only (the default).
typedef NS_ENUM(int32_t, KKMotionBlurMode) {
  /// Blur only while the shutter window overlaps a real keypose transition
  /// (endpoints differ). Modulation jitter during a hold is ignored - the
  /// cheapest mode and the default.
  KKMotionBlurModeTransitionsOnly = 0,
  /// Blur whenever any animated value moves across the shutter window -
  /// transitions AND modulation (wiggle / oscillate / handheld).
  KKMotionBlurModeValueChanging = 1,
  /// Blur every frame regardless of whether anything animates. Required for
  /// real content (source-frame) blur when params are static but footage moves.
  KKMotionBlurModeAlways = 2,
};

/// How the blur is computed. Stored in the custom-UI blob as `"technique"`;
/// absent = Fast. The user-facing pill is just Fast vs Accurate; the old
/// when-to-fire modes are derived from this (Fast skips still layers
/// automatically, Accurate blurs every frame for footage smear).
typedef NS_ENUM(int32_t, KKMotionBlurTechnique) {
  /// Per-layer velocity-buffer reconstruction (KKMotionBlurReconstruct). Fixed
  /// cost independent of blur length; blurs the plugin's own animated
  /// transforms. Requires the plugin to emit a velocity buffer (opt-in via
  /// `-motionBlurSupportsFastTechnique`). The default.
  KKMotionBlurTechniqueFast = 0,
  /// Sample-and-accumulate (re-render N sub-frame samples). Universal - blurs
  /// moving footage too - and the correctness fallback for extreme in-shutter
  /// rotation. Costs N renders; `sampleCount` applies.
  KKMotionBlurTechniqueAccurate = 1,
};

/// Snapshot of motion-blur params resolved during `pluginState:atTime:`,
/// where FxParameterRetrievalAPI_v6 is available. Plugins concatenate this
/// into their own pluginState NSData so render - which has no paramAPI -
/// can use the values.
typedef struct {
  bool enabled;
  int sampleCount; // 2..KK_MOTION_BLUR_MAX_SAMPLES, undefined when disabled
  double shutterSec;
  KKMotionBlurMode mode;           // when to fire; derived from technique
  KKMotionBlurTechnique technique; // how to blur; 0 = Fast (reconstruction)
} KKMotionBlurState;

/// Sample-and-accumulate motion blur shared across plugins.
///
/// Unlike the standalone MotionBlur effect (which post-processes the
/// upstream input via FCP's scheduleInputs), this variant blurs the
/// *plugin's own* render: the host plugin hands `renderBlock` over and
/// KKMotionBlur invokes it N times at staggered sub-frame times, each
/// into a pooled offscreen texture, then averages them into `dest`.
///
/// The plugin is responsible for re-evaluating its own time-dependent
/// state (KKTiming queries, transforms, etc.) at the `subTime` it is
/// handed - KKMotionBlur knows nothing about what is being drawn.
@interface KKMotionBlur : NSObject

/// Snapshots motion-blur state from a custom-UI JSON blob
/// (`{"enabled":bool,"shutterAngle":0–360,"samples":2–128,"mode":0–2}`) instead
/// of the native 9924–9929 params. shutterAngle maps to the shutter window;
/// samples is the explicit sample count; mode is when to fire (see
/// `KKMotionBlurMode`, absent = transitions-only). Empty / nil / disabled JSON
/// returns a disabled state.
+ (KKMotionBlurState)snapshotStateFromJSON:(nullable NSString *)json
                                 timingAPI:(id<FxTimingAPI_v4>)timingAPI
                                    atTime:(CMTime)time;

/// Decides whether a frame should actually blur, given the mode and the clip
/// fractions the shutter window spans (`fracStart`/`fracEnd`, order-agnostic).
///
/// - `Always` → YES.
/// - `ValueChanging` → YES if any lane's resolved value (modulation included)
///   differs across the window.
/// - `TransitionsOnly` → YES if the window overlaps a keypose interval whose
///   endpoints differ (a real transition); modulation-only holds are ignored.
///
/// Returns YES when `timeline` is nil (can't gate - don't suppress a wanted
/// blur). Plugins call this from `pluginState:atTime:` and clear
/// `state.enabled` for the frame when it returns NO.
+ (BOOL)frameShouldBlurForMode:(KKMotionBlurMode)mode
                      timeline:(nullable KKTimeline *)timeline
                     fracStart:(double)fracStart
                       fracEnd:(double)fracEnd;

/// Acquires a pooled intermediate ("scratch") texture inside a render
/// block. Use for any plugin-private textures the render block needs as
/// passes feed each other (Glow's blur pyramid, etc.) so they survive the
/// life of the shared command buffer without per-frame allocation churn.
///
/// Pool entries are keyed by (`key`, `sampleIndex`, `registryID`,
/// `width`, `height`, `format`) - pick a key unique to the texture's
/// purpose within the plugin (e.g. `@"glow.prep"`). Distinct sample
/// indices return distinct textures, which is what you want when all N
/// samples are queued on the same command buffer.
///
/// Lifetime: the texture is held until `applyToDestinationImage:`
/// completes its `commit + waitUntilCompleted`, then returned to a
/// shared pool. Reused on the next frame's render. Caller must NOT
/// store strong refs beyond the render block.
///
/// Returns nil when called outside an `applyToDestinationImage:`
/// invocation, or if texture allocation fails.
+ (nullable id<MTLTexture>)scratchTextureForKey:(NSString *)key
                                    sampleIndex:(int)sampleIndex
                                          width:(NSUInteger)width
                                         height:(NSUInteger)height
                                         format:(MTLPixelFormat)format
                                          usage:(MTLTextureUsage)usage
                                         device:(id<MTLDevice>)device;

/// Returns the N CMTimes (wrapped as NSValue) that `applyToDestinationImage:`
/// will request from the render block, given the snapshotted state and the
/// frame's render time. Plugins use this from `pluginState:atTime:` to
/// pre-compute their per-sample render parameters (paramAPI is unavailable
/// at render time, so all sample-time evaluation must happen up-front).
+ (NSArray<NSValue *> *)sampleTimesForState:(KKMotionBlurState)state
                                 renderTime:(CMTime)renderTime;

/// Opt into REAL (content) motion blur: appends one source-clip request per
/// sub-frame sample time (skipping `renderTime`, which the plugin already
/// requests) to `requests`. Call from `scheduleInputs:`. FCP then delivers the
/// source at each sub-frame time, and `applyToDestinationImage:` feeds the
/// time-matched frame to each accumulate pass - so the underlying content
/// smears, not just the plugin's parameter animation.
///
/// `builder` creates one request for a given sample time: the plugin owns this
/// because KeyframelessKit doesn't link FxPlug (can't construct
/// `FxImageTileRequest`). Typically a one-liner:
/// `^(CMTime t){ return [[FxImageTileRequest alloc]
///   initWithSource:kFxImageTileRequestSourceEffectClip time:t
///   includeFilters:YES parameterID:0]; }` (autorelease under MRR).
///
/// No-op when blur is disabled, so it's safe to call unconditionally. Each
/// added request is another source frame FCP decodes - heavier, can drop live-
/// playback frames; FCP delivers discrete frames, so content smears smoothly
/// only with Frame Blending / Optical Flow or a shutter spanning >1 frame.
+ (void)appendSourceRequestsForState:(KKMotionBlurState)state
                          renderTime:(CMTime)renderTime
                                  to:(NSMutableArray<FxImageTileRequest *> *)
                                         requests
                             builder:(FxImageTileRequest *_Nullable (^)(
                                         CMTime sampleTime))builder;

/// Renders one frame with motion blur applied. Owns its own command queue
/// and command buffer; commits and waits before returning.
///
/// The render block is invoked N times (once per sample) with `sampleIndex`
/// matching the index into the array returned by `sampleTimesForState:`.
/// The plugin uses `sampleIndex` to look up its precomputed per-sample
/// render data and encode a draw into `sampleDest` on `commandBuffer`.
///
/// Returns NO if `state.enabled` is false (caller should fall back to
/// its normal render path) or on error.
+ (BOOL)applyToDestinationImage:(FxImageTile *)destinationImage
                   sourceImages:(NSArray<FxImageTile *> *)sourceImages
                          state:(KKMotionBlurState)state
                     renderTime:(CMTime)renderTime
                    renderBlock:
                        (BOOL (^)(int sampleIndex, id<MTLTexture> sampleDest,
                                  id<MTLCommandBuffer> commandBuffer,
                                  NSArray<id<MTLTexture>> *inputTextures))
                            renderBlock;

@end

NS_ASSUME_NONNULL_END
