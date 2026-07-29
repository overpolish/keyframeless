/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPlugin+MiniViewerFeed.h"

#import "KKLog.h"
#import "KKMetalDeviceCache.h"
#import "KKMiniViewerFeed.h"
#import "KKPluginHost.h" // KKRenderCache
#import <FxPlug/FxPlugSDK.h>
#import <QuartzCore/QuartzCore.h>

@implementation KKPlugin (MiniViewerFeed)

- (void)
    kkPublishMiniViewerFeedForDestination:(FxImageTile *)destinationImage
                             sourceImages:(NSArray<FxImageTile *> *)sourceImages
                           descriptorPath:(NSString *)descriptorPath
                          boundaryReqSecs:(NSArray<NSNumber *> *)boundaryReqSecs
                         boundaryReqFracs:
                             (NSArray<NSNumber *> *)boundaryReqFracs
                          multiSlotActive:(BOOL)multiSlotActive
                        changesOutputSize:(BOOL)changesOutputSize
                             linearFloat:(BOOL)linearFloat
                               defaultTag:(double)defaultTag
                              renderCache:(KKRenderCache *)renderCache {
  if (sourceImages.count == 0 || !destinationImage.ioSurface)
    return;

  // (Re)create the feed when the descriptor path changes. A per-instance path
  // resolves its UUID late (recreates once it's known); a static path creates
  // the feed once and never recreates.
  if (!self.miniViewerFeed ||
      ![self.miniViewerFeedPath isEqualToString:descriptorPath]) {
    self.miniViewerFeed =
        [[KKMiniViewerFeed alloc] initWithDescriptorPath:descriptorPath];
    self.miniViewerFeedPath = descriptorPath;
  }
  self.miniViewerFeed.linearFloat = linearFloat;

  // Build (slot index, tile) pairs to publish this tick.
  NSMutableArray *pairs = [NSMutableArray array];
  if (multiSlotActive && boundaryReqSecs.count > 0) {
    // Greedy assignment: each REQUESTED time claims its closest unclaimed
    // delivered tile by mediaTime. FCP doesn't honor request order and serves
    // stale boundary tiles while it re-schedules, so match by time, not index.
    static const double kMaxDt = 0.5;
    NSMutableArray<NSNumber *> *availTileIdx = [NSMutableArray array];
    for (NSUInteger i = 0; i < sourceImages.count; i++)
      if (sourceImages[i].ioSurface)
        [availTileIdx addObject:@(i)];
    if (self.miniViewerFeed.slotCount != boundaryReqSecs.count) {
      self.miniViewerFeed.slotCount = boundaryReqSecs.count;
      [self.miniViewerFeed publishDescriptor];
    }
    for (NSUInteger slot = 0; slot < boundaryReqSecs.count; slot++) {
      double want = boundaryReqSecs[slot].doubleValue;
      NSInteger bestPos = -1;
      double bestDt = kMaxDt;
      for (NSUInteger p = 0; p < availTileIdx.count; p++) {
        NSUInteger ti = availTileIdx[p].unsignedIntegerValue;
        double mt = CMTimeGetSeconds(sourceImages[ti].mediaTime);
        double dt = fabs(mt - want);
        if (dt < bestDt) {
          bestDt = dt;
          bestPos = (NSInteger)p;
        }
      }
      if (bestPos >= 0) {
        NSUInteger ti = availTileIdx[bestPos].unsignedIntegerValue;
        [pairs addObject:@[ @(slot), sourceImages[ti] ]];
        [availTileIdx removeObjectAtIndex:bestPos];
      }
    }
  } else {
    if (self.miniViewerFeed.slotCount != 1)
      self.miniViewerFeed.slotCount = 1;
    [pairs addObject:@[ @0, sourceImages[0] ]];
  }

  for (NSArray *pair in pairs) {
    NSUInteger slotIdx = [pair[0] unsignedIntegerValue];
    FxImageTile *feedTile = pair[1];
    FxRect sTile = feedTile.tilePixelBounds;
    FxRect sImg = feedTile.imagePixelBounds;
    // Sub-tile (parent Scale > 100%) would publish a squashed sub-region.
    BOOL fullFrame = (sTile.left == sImg.left && sTile.right == sImg.right &&
                      sTile.top == sImg.top && sTile.bottom == sImg.bottom);
    if (!fullFrame)
      continue;
    int sW = sImg.right - sImg.left, sH = sImg.top - sImg.bottom;
    // Size gate: FCP re-runs this instance for the tiny project-library /
    // browser thumbnail (~112x64, ~same aspect as the timeline), which the
    // aspect gate below can't catch. Publishing it would size the mini-viewer's
    // media + OSC/crop to the thumbnail and draw it upscaled/blurry. Track the
    // largest source seen and skip any frame materially smaller in either
    // dimension (< 1/4 - allows half/quarter-res proxy renders, rejects the
    // thumbnail). Covers the changesOutputSize path too (it skips the aspect
    // gate). Mirrors the generator's largest-size-seen guard.
    CGSize maxSrc = self.miniViewerFeed.largestSourceSizeSeen;
    if (maxSrc.width > 0 && maxSrc.height > 0 &&
        (sW < maxSrc.width / 4.0 || sH < maxSrc.height / 4.0))
      continue;
    if ((double)sW * sH > (double)maxSrc.width * maxSrc.height)
      self.miniViewerFeed.largestSourceSizeSeen = CGSizeMake(sW, sH);
    // FCP's project-library preview re-runs the effect into a browser-thumb
    // destination while passing the same source → aspect ping-pong. Gate on
    // dest aspect matching the source within a generous tolerance. SKIP this
    // gate for bounds-expanding effects (changesOutputSize): their dest aspect
    // legitimately differs from the source, so the gate would drop every frame
    // and the feed would never publish (IOSurfaceLookup failures downstream).
    if (!changesOutputSize) {
      FxRect dImg = destinationImage.imagePixelBounds;
      int dW = dImg.right - dImg.left, dH = dImg.top - dImg.bottom;
      double sAsp = (sH > 0) ? fabs((double)sW / (double)sH) : 0;
      double dAsp = (dH > 0) ? fabs((double)dW / (double)dH) : 0;
      if (sAsp > 0 && dAsp > 0 && fabs(sAsp - dAsp) > 0.05)
        continue;
    }
    double tag = (slotIdx < boundaryReqFracs.count)
                     ? boundaryReqFracs[slotIdx].doubleValue
                     : defaultTag;
    // Publish where the PLAYHEAD is, alongside the frame's own tag. FCP renders
    // a constant ~0.27s (16-20 frames at 60fps) ahead of the playhead, so a
    // live-playback consumer that evaluates the effect at `tag` runs the whole
    // animation that far early - visible as a keypose starting part-way in.
    // Delaying the pixels would need ~20 buffered surfaces; instead the consumer
    // draws the delivered frame but evaluates the EFFECT here. Stale sample or
    // not playing publishes -1 = unknown, and the consumer falls back to `tag`.
    //
    // Gating the publish on this instead was tried and reverted: a CONSTANT lead
    // means every frame is early, so holding frames without a buffer is just
    // dropping them, and the preview fell to the escape-hatch cadence.
    if (slotIdx == 0 && renderCache) {
      static const double kSampleFreshSec = 0.30;
      // The raw sample updates at ~15Hz against a 60Hz tag stream, so publishing
      // it directly stepped the animation 4 frames at a time. Publish
      // `tag - lead` instead: the lead is near-constant, so a smoothed estimate
      // of it subtracted from the smooth per-frame tag gives both the right
      // moment and a per-frame-smooth fraction.
      static const double kLeadSmoothing = 0.05; // ~20 samples to settle
      double nowMach = CACurrentMediaTime();
      double sampleWall = renderCache.playheadSampleWall;
      BOOL usable = renderCache.playheadPlaying && sampleWall > 0.0 &&
                    (nowMach - sampleWall) < kSampleFreshSec;
      // Only REFINE the lead on a usable sample, but keep applying the last one
      // regardless. The poller doesn't report `playing` until ~0.2s after
      // playback actually starts, and discarding the lead over that gap made the
      // preview fall back to the raw (0.25s-early) tag and then snap back once
      // it re-seeded - visible as a flicker of the wrong animation phase at the
      // start. The lead is a property of FCP's render pipeline, not of this
      // moment, so it carries across runs. Safe to publish while stopped too:
      // the consumer only reads it while live playback is active.
      if (usable) {
        double rawLead = tag - renderCache.playheadFrac;
        // A scrub or loop-wrap can momentarily make this meaningless; a negative
        // or absurd lead contributes nothing rather than poisoning the average.
        if (rawLead < 0.0 || rawLead > 0.5)
          rawLead = 0.0;
        double lead = self.miniViewerPlayheadLead;
        lead = (lead < 0.0) ? rawLead
                            : lead + kLeadSmoothing * (rawLead - lead);
        self.miniViewerPlayheadLead = lead;
      }
      double lead = self.miniViewerPlayheadLead;
      // Never measured (first playback of this instance) - fall back to the tag.
      self.miniViewerFeed.playheadFrac =
          (lead < 0.0) ? -1.0 : MAX(0.0, MIN(1.0, tag - lead));
    }

    KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
    MTLPixelFormat pf =
        [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
    uint64_t rid = destinationImage.deviceRegistryID;
    id<MTLCommandQueue> q = [cache commandQueueWithRegistryID:rid
                                                  pixelFormat:pf];
    id<MTLDevice> dev = [cache deviceWithRegistryID:rid];
    if (!q || !dev)
      continue;
    id<MTLTexture> srcTex = [feedTile metalTextureForDevice:dev];
    if (!srcTex) {
      [cache returnCommandQueueToCache:q];
      continue;
    }
    [self.miniViewerFeed updateSlot:slotIdx
                  withSourceTexture:srcTex
                                tag:tag
                             device:dev
                       commandQueue:q];
    [cache returnCommandQueueToCache:q];
  }
}

- (void)kkPublishMiniViewerChannel1ForDestination:
            (FxImageTile *)destinationImage
                                     sourceImages:
                                         (NSArray<FxImageTile *> *)sourceImages
                                  wellParameterID:(UInt32)wellParameterID {
  if (!self.miniViewerFeed)
    return; // the slot publish creates the feed; nothing to attach to yet
  FxImageTile *wellTile =
      KKImageTileForParameterID(sourceImages, wellParameterID);
  if (!wellTile || !wellTile.ioSurface)
    return; // well empty / unfilled - leave the last published one alone

  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  MTLPixelFormat pf =
      [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
  uint64_t rid = destinationImage.deviceRegistryID;
  id<MTLCommandQueue> q = [cache commandQueueWithRegistryID:rid pixelFormat:pf];
  id<MTLDevice> dev = [cache deviceWithRegistryID:rid];
  if (!q || !dev)
    return;
  id<MTLTexture> tex = [wellTile metalTextureForDevice:dev];
  if (tex)
    [self.miniViewerFeed updateChannel1WithSourceTexture:tex
                                                  device:dev
                                            commandQueue:q];
  [cache returnCommandQueueToCache:q];
}

@end
