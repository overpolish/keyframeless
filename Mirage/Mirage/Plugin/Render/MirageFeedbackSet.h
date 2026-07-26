/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/// A fresh RGBA16F feedback/checkpoint buffer texture (render target +
/// sampled).
id<MTLTexture> _Nullable MirageNewBufferTexture(id<MTLDevice> device,
                                                NSUInteger w, NSUInteger h);

/// Persistent per-resolution feedback state: two ping-pong sets of 4 buffer
/// textures. A buffer that reads itself / a later buffer samples the PREVIOUS
/// frame's set; `prevIdx` names it. Reset when the resolution changes.
///
/// The ivars are @public: the multi-pass render loop indexes `tex[set][buffer]`
/// directly per pass, and routing that through 4 accessors would obscure it.
@interface MirageFeedbackSet : NSObject {
@public
  id<MTLTexture> tex[2][4];
  int prevIdx;
  NSUInteger w, h;
  NSInteger lastFrame; // frame index currently held in the `prevIdx` set
  BOOL hasState;       // NO until the first frame has been simulated
  // Periodic snapshots: frame index -> NSArray of 4 texture copies (NSNull =
  // absent buffer). A seek restores the nearest checkpoint <= F, then re-sims
  // to F, so a deep seek is exact + bounded instead of a fixed window from
  // clear.
  NSMutableDictionary<NSNumber *, NSArray *> *checkpoints;
  // LRU stamp, bumped on every lookup. Monotonic within the store rather than
  // process-global (no mutable statics in an XPC plugin).
  uint64_t touch;
}

/// The set `store` holds for `key`, created on first use. Reset to empty when
/// its buffer resolution differs from `w`x`h` (the old textures are the wrong
/// size and its history is meaningless at the new scale).
///
/// The store is capped: a set is per OUTPUT resolution, and a plugin instance
/// meets several over its life (viewer zoom steps, playback half-res, export,
/// library preview). Each one holds 8 live textures plus up to 24 checkpoints
/// of 4, so an uncapped store grows without bound for as long as the instance
/// lives. Least-recently-used sets are dropped past the cap; the set being
/// looked up is always kept.
+ (instancetype)setInStore:(NSMutableDictionary *)store
                    forKey:(NSString *)key
                     width:(NSUInteger)w
                    height:(NSUInteger)h;

/// Nearest checkpoint frame <= F held by this set, or -1.
- (NSInteger)nearestCheckpointAtMost:(NSInteger)F;

/// Snapshot the newest (prevIdx) buffers into a checkpoint at `frame`, evicting
/// the oldest when over the cap.
- (void)snapshotFrame:(NSInteger)frame
               device:(id<MTLDevice>)device
                queue:(nullable id<MTLCommandQueue>)queue;

/// Restore checkpoint `frame` into the prevIdx slot (the "previous frame" the
/// next re-sim step reads).
- (void)restoreFrame:(NSInteger)frame
              device:(id<MTLDevice>)device
               queue:(nullable id<MTLCommandQueue>)queue;

@end

NS_ASSUME_NONNULL_END
