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

// FxPlug may deliver a source at its native raster size while rendering it in
// a smaller project/canonical frame. `units="px"` controls are authored in the
// latter space (the main renderer derives the same ratio in
// MirageRenderScale). Carry that frame size across the mini feed rather than
// asking the inspector to mistake native source pixels for project pixels.
static CGSize KKMiniViewerPixelReferenceSize(FxImageTile *tile) {
  if (!tile)
    return CGSizeZero;
  FxRect bounds = tile.imagePixelBounds;
  CGFloat pixelW = fabs((CGFloat)(bounds.right - bounds.left));
  CGFloat pixelH = fabs((CGFloat)(bounds.top - bounds.bottom));
  FxMatrix44 *inverse = tile.inversePixelTransform;
  if (!inverse || pixelW <= 0.0 || pixelH <= 0.0)
    return CGSizeMake(pixelW, pixelH);
  FxPoint2D lower = [inverse
      transform2DPoint:(FxPoint2D){(float)bounds.left, (float)bounds.bottom}];
  FxPoint2D upper = [inverse
      transform2DPoint:(FxPoint2D){(float)bounds.right, (float)bounds.top}];
  CGFloat canonicalW = fabs((CGFloat)upper.x - (CGFloat)lower.x);
  CGFloat canonicalH = fabs((CGFloat)upper.y - (CGFloat)lower.y);
  if (!isfinite(canonicalW) || !isfinite(canonicalH) || canonicalW <= 0.0 ||
      canonicalH <= 0.0)
    return CGSizeMake(pixelW, pixelH);
  return CGSizeMake(canonicalW, canonicalH);
}

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
                           fullResolution:(BOOL)fullResolution
                               defaultTag:(double)defaultTag
                              renderCache:(KKRenderCache *)renderCache {
  if (sourceImages.count == 0 || !destinationImage.ioSurface)
    return;

  BOOL pixelsActive = !renderCache || renderCache.miniViewerFeedActive;

  // Compact mode deliberately disables the expensive IOSurface feed, but the
  // editor still needs frame dimensions to convert normalized point/multi
  // storage to user-facing pixels. Publish a dimensions-only descriptor. If
  // this feed previously carried surfaces, replace it once so those producer-
  // side references are released; subsequent render ticks only rewrite JSON
  // when one of the dimensions actually changes.
  if (!pixelsActive) {
    FxImageTile *source = sourceImages.firstObject;
    FxRect sourceBounds = source.imagePixelBounds;
    CGSize mediaSize =
        CGSizeMake(fabs((CGFloat)(sourceBounds.right - sourceBounds.left)),
                   fabs((CGFloat)(sourceBounds.top - sourceBounds.bottom)));
    FxRect destinationBounds = destinationImage.imagePixelBounds;
    CGSize renderSize = CGSizeMake(
        fabs((CGFloat)(destinationBounds.right - destinationBounds.left)),
        fabs((CGFloat)(destinationBounds.top - destinationBounds.bottom)));
    CGSize referenceSize = KKMiniViewerPixelReferenceSize(source);

    BOOL pathChanged =
        ![self.miniViewerFeedPath isEqualToString:descriptorPath];
    BOOL carriedPixels = self.miniViewerFeed.primarySourceSize.width > 0.0;
    if (!self.miniViewerFeed || pathChanged || carriedPixels) {
      self.miniViewerFeed =
          [[KKMiniViewerFeed alloc] initWithDescriptorPath:descriptorPath];
      self.miniViewerFeedPath = descriptorPath;
    }
    BOOL metadataChanged =
        !CGSizeEqualToSize(self.miniViewerFeed.mediaSize, mediaSize) ||
        !CGSizeEqualToSize(self.miniViewerFeed.pixelReferenceSize,
                           referenceSize) ||
        !CGSizeEqualToSize(self.miniViewerFeed.renderPixelSize, renderSize);
    if (metadataChanged || carriedPixels || pathChanged) {
      self.miniViewerFeed.mediaSize = mediaSize;
      self.miniViewerFeed.pixelReferenceSize = referenceSize;
      self.miniViewerFeed.renderPixelSize = renderSize;
      [self.miniViewerFeed publishDescriptor];
    }
    return;
  }

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
  self.miniViewerFeed.fullResolution = fullResolution;
  FxRect destinationBounds = destinationImage.imagePixelBounds;
  self.miniViewerFeed.renderPixelSize = CGSizeMake(
      fabs((CGFloat)(destinationBounds.right - destinationBounds.left)),
      fabs((CGFloat)(destinationBounds.top - destinationBounds.bottom)));

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
      } else {
        NSMutableArray<NSNumber *> *had = [NSMutableArray array];
        for (NSNumber *p in availTileIdx)
          [had addObject:@(CMTimeGetSeconds(
                             sourceImages[p.unsignedIntegerValue].mediaTime))];
        KKLogWarn(@"[Boundary] slot %lu want=%.3f NO tile within %.2fs, "
                  @"delivered=%@ (last frame stays on screen)",
                  (unsigned long)slot, want, kMaxDt, had);
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
    if (!fullFrame) {
      KKLogWarn(@"[Boundary] slot %lu DROPPED: sub-tile, not a full frame",
                (unsigned long)slotIdx);
      continue;
    }
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
        (sW < maxSrc.width / 4.0 || sH < maxSrc.height / 4.0)) {
      KKLogWarn(@"[Boundary] slot %lu DROPPED: %dx%d too small vs %.0fx%.0f",
                (unsigned long)slotIdx, sW, sH, maxSrc.width, maxSrc.height);
      continue;
    }
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
      if (sAsp > 0 && dAsp > 0 && fabs(sAsp - dAsp) > 0.05) {
        KKLogWarn(@"[Boundary] slot %lu DROPPED: aspect %.3f vs dest %.3f",
                  (unsigned long)slotIdx, sAsp, dAsp);
        continue;
      }
    }
    double tag = (slotIdx < boundaryReqFracs.count)
                     ? boundaryReqFracs[slotIdx].doubleValue
                     : defaultTag;
    // Publish where the PLAYHEAD is, alongside the frame's own tag. FCP renders
    // a constant ~0.27s (16-20 frames at 60fps) ahead of the playhead, so a
    // live-playback consumer that evaluates the effect at `tag` runs the whole
    // animation that far early - visible as a keypose starting part-way in.
    // Delaying the pixels would need ~20 buffered surfaces; instead the
    // consumer draws the delivered frame but evaluates the EFFECT here. Stale
    // sample or not playing publishes -1 = unknown, and the consumer falls back
    // to `tag`.
    //
    // Gating the publish on this instead was tried and reverted: a CONSTANT
    // lead means every frame is early, so holding frames without a buffer is
    // just dropping them, and the preview fell to the escape-hatch cadence.
    if (slotIdx == 0 && renderCache) {
      static const double kSampleFreshSec = 0.30;
      // The raw sample updates at ~15Hz against a 60Hz tag stream, so
      // publishing it directly stepped the animation 4 frames at a time.
      // Publish `tag - lead` instead: the lead is near-constant, so a smoothed
      // estimate of it subtracted from the smooth per-frame tag gives both the
      // right moment and a per-frame-smooth fraction.
      static const double kLeadSmoothing = 0.05; // ~20 samples to settle
      double nowMach = CACurrentMediaTime();
      double sampleWall = renderCache.playheadSampleWall;
      BOOL usable = renderCache.playheadPlaying && sampleWall > 0.0 &&
                    (nowMach - sampleWall) < kSampleFreshSec;
      // Only REFINE the lead on a usable sample, but keep applying the last one
      // regardless. The poller doesn't report `playing` until ~0.2s after
      // playback actually starts, and discarding the lead over that gap made
      // the preview fall back to the raw (0.25s-early) tag and then snap back
      // once it re-seeded - visible as a flicker of the wrong animation phase
      // at the start. The lead is a property of FCP's render pipeline, not of
      // this moment, so it carries across runs. Safe to publish while stopped
      // too: the consumer only reads it while live playback is active.
      if (usable) {
        double rawLead = tag - renderCache.playheadFrac;
        // A scrub or loop-wrap can momentarily make this meaningless; a
        // negative or absurd lead contributes nothing rather than poisoning the
        // average.
        if (rawLead < 0.0 || rawLead > 0.5)
          rawLead = 0.0;
        double lead = self.miniViewerPlayheadLead;
        lead =
            (lead < 0.0) ? rawLead : lead + kLeadSmoothing * (rawLead - lead);
        self.miniViewerPlayheadLead = lead;
      }
      double lead = self.miniViewerPlayheadLead;
      // Never measured (first playback of this instance) - fall back to the
      // tag.
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
    // A checked-out queue must go back even when the DEVICE lookup is what
    // failed. The pool is fixed size and process-wide, so one bail that skips
    // the return shrinks it permanently for every instance in this process.
    if (!q || !dev) {
      if (q)
        [cache returnCommandQueueToCache:q];
      continue;
    }
    id<MTLTexture> srcTex = [feedTile metalTextureForDevice:dev];
    if (!srcTex) {
      [cache returnCommandQueueToCache:q];
      continue;
    }
    self.miniViewerFeed.pixelReferenceSize =
        KKMiniViewerPixelReferenceSize(feedTile);
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
  // Same fixed-size-pool hazard as the slot publish above: return the queue
  // even when it was the device lookup that failed.
  if (!q || !dev) {
    if (q)
      [cache returnCommandQueueToCache:q];
    return;
  }
  id<MTLTexture> tex = [wellTile metalTextureForDevice:dev];
  if (tex)
    [self.miniViewerFeed updateChannel1WithSourceTexture:tex
                                                  device:dev
                                            commandQueue:q];
  [cache returnCommandQueueToCache:q];
}

- (void)kkPublishMiniViewerAuxTexturesForDestination:
            (FxImageTile *)destinationImage
                                            textures:(NSArray *)textures {
  KKMiniViewerFeed *feed = self.miniViewerFeed;
  if (!feed)
    return; // the slot publish creates the feed; nothing to attach to yet
  if (textures.count == 0) {
    if (feed.auxTextureCount != 0) {
      feed.auxTextureCount = 0;
      [feed publishDescriptor];
    }
    return;
  }

  // Same-frame geometry gate. The feed downscales every surface by one
  // long-edge rule, so an aux frame only lines up with slot 0 when it came in
  // at the same source size. FCP re-runs the instance at a browser-thumbnail
  // size, and the slot publish drops those; without this the aux set would keep
  // the thumbnail and a shader sampling a neighbour would read a differently
  // framed image. All-or-nothing: a mixed set is worse than a stale one.
  CGSize primary = feed.primarySourceSize;
  if (primary.width > 0 && primary.height > 0) {
    for (id entry in textures) {
      if (entry == [NSNull null])
        continue;
      id<MTLTexture> t = entry;
      if (t.width != (NSUInteger)primary.width ||
          t.height != (NSUInteger)primary.height) {
        KKLogWarn(@"[MiniFeed] aux DROPPED: %lux%lu vs source %.0fx%.0f",
                  (unsigned long)t.width, (unsigned long)t.height,
                  primary.width, primary.height);
        return;
      }
    }
  }

  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  MTLPixelFormat pf =
      [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
  uint64_t rid = destinationImage.deviceRegistryID;
  id<MTLCommandQueue> q = [cache commandQueueWithRegistryID:rid pixelFormat:pf];
  id<MTLDevice> dev = [cache deviceWithRegistryID:rid];
  if (!q || !dev) {
    if (q)
      [cache returnCommandQueueToCache:q];
    return;
  }
  BOOL countChanged = (feed.auxTextureCount != textures.count);
  feed.auxTextureCount = textures.count;
  for (NSUInteger i = 0; i < textures.count; i++) {
    id entry = textures[i];
    if (entry == [NSNull null])
      continue; // unresolved this tick - keep the last good frame at this index
    [feed updateAuxTexture:entry atIndex:i device:dev commandQueue:q];
  }
  [cache returnCommandQueueToCache:q];
  if (countChanged) {
    id<MTLTexture> first =
        textures.firstObject != [NSNull null] ? textures.firstObject : nil;
    KKLogDebug(@"[MiniFeed] aux pump count=%lu first=%lux%lu",
               (unsigned long)textures.count, (unsigned long)first.width,
               (unsigned long)first.height);
  }
}

@end
