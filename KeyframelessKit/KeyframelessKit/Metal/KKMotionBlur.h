/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

@protocol FxParameterRetrievalAPI_v6;
@protocol FxTimingAPI_v4;
@class FxImageTile;

NS_ASSUME_NONNULL_BEGIN

/// Snapshot of motion-blur params resolved during `pluginState:atTime:`,
/// where FxParameterRetrievalAPI_v6 is available. Plugins concatenate this
/// into their own pluginState NSData so render — which has no paramAPI —
/// can use the values.
typedef struct {
  bool enabled;
  bool transitionsOnly; // when true, plugin should clear `enabled` for
                        // frames where no timing lane is in a Transition
                        // segment, so hold portions skip the blur path
  int sampleCount; // 2..KK_MOTION_BLUR_MAX_SAMPLES, undefined when disabled
  double shutterSec;
  // Per-sample render-target downscale. Sample textures are allocated at
  // (destW * subframeScale, destH * subframeScale); the accumulation pass
  // bilinear-upsamples back to full dest. Default 0.5 — invisible on
  // motion-blurred output and ~4× cheaper per sample. Plugins whose render
  // pipeline assumes full-res sampleDest dims (Glow's composite viewport,
  // etc.) can set this to 1.0 to opt out.
  float subframeScale;
  // When true and FCP requests a non-HIGH quality render (scrubbing /
  // playback), `applyToDestinationImage:` overrides `subframeScale` to a
  // very low value so frames land fast. Has no effect on HIGH-quality
  // renders (paused inspector, export).
  bool adaptiveQuality;
  // FCP-reported quality level at snapshot time. HIGH = export (and
  // paused-with-Best-render-pref); MEDIUM/LOW = everything else. Used
  // only as an export filter — paused-at-Normal-pref is also non-HIGH.
  bool qualityIsHigh;
  // Timeline frame duration in seconds, captured from FxTimingAPI at
  // snapshot. Apply uses this to compute a frame-rate-aware "is FCP
  // currently rendering at playback cadence" check.
  double frameDurationSec;
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
/// handed — KKMotionBlur knows nothing about what is being drawn.
@interface KKMotionBlur : NSObject

/// Snapshots the motion-blur params at `time`. Call from
/// `pluginState:atTime:` (where paramAPI is available) and embed the
/// returned struct in your pluginState NSData; pass it back to
/// `applyToDestinationImage:state:...` from your render path.
+ (KKMotionBlurState)snapshotStateWithParameterAPI:
                         (id<FxParameterRetrievalAPI_v6>)paramAPI
                                         timingAPI:(id<FxTimingAPI_v4>)timingAPI
                                            atTime:(CMTime)time
                                           quality:(NSUInteger)quality;

/// Acquires a pooled intermediate ("scratch") texture inside a render
/// block. Use for any plugin-private textures the render block needs as
/// passes feed each other (Glow's blur pyramid, etc.) so they survive the
/// life of the shared command buffer without per-frame allocation churn.
///
/// Pool entries are keyed by (`key`, `sampleIndex`, `registryID`,
/// `width`, `height`, `format`) — pick a key unique to the texture's
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
