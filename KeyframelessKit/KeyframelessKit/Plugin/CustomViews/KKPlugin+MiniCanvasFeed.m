/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPlugin+MiniCanvasFeed.h"

#import "KKMetalDeviceCache.h"
#import "KKMiniCanvasFeed.h"
#import <FxPlug/FxPlugSDK.h>

@implementation KKPlugin (MiniCanvasFeed)

- (void)
    kkPublishMiniCanvasFeedForDestination:(FxImageTile *)destinationImage
                             sourceImages:(NSArray<FxImageTile *> *)sourceImages
                           descriptorPath:(NSString *)descriptorPath
                          boundaryReqSecs:(NSArray<NSNumber *> *)boundaryReqSecs
                         boundaryReqFracs:
                             (NSArray<NSNumber *> *)boundaryReqFracs
                          multiSlotActive:(BOOL)multiSlotActive
                               defaultTag:(double)defaultTag {
  if (sourceImages.count == 0 || !destinationImage.ioSurface)
    return;

  // (Re)create the feed when the descriptor path changes. A per-instance path
  // resolves its UUID late (recreates once it's known); a static path creates
  // the feed once and never recreates.
  if (!self.miniCanvasFeed ||
      ![self.miniCanvasFeedPath isEqualToString:descriptorPath]) {
    self.miniCanvasFeed =
        [[KKMiniCanvasFeed alloc] initWithDescriptorPath:descriptorPath];
    self.miniCanvasFeedPath = descriptorPath;
  }

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
    if (self.miniCanvasFeed.slotCount != boundaryReqSecs.count) {
      self.miniCanvasFeed.slotCount = boundaryReqSecs.count;
      [self.miniCanvasFeed publishDescriptor];
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
    if (self.miniCanvasFeed.slotCount != 1)
      self.miniCanvasFeed.slotCount = 1;
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
    // FCP's project-library preview re-runs the effect into a browser-thumb
    // destination while passing the same source → aspect ping-pong. Gate on
    // dest aspect matching the source within a generous tolerance.
    FxRect dImg = destinationImage.imagePixelBounds;
    int sW = sImg.right - sImg.left, sH = sImg.top - sImg.bottom;
    int dW = dImg.right - dImg.left, dH = dImg.top - dImg.bottom;
    double sAsp = (sH > 0) ? fabs((double)sW / (double)sH) : 0;
    double dAsp = (dH > 0) ? fabs((double)dW / (double)dH) : 0;
    if (sAsp > 0 && dAsp > 0 && fabs(sAsp - dAsp) > 0.05)
      continue;
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
    double tag = (slotIdx < boundaryReqFracs.count)
                     ? boundaryReqFracs[slotIdx].doubleValue
                     : defaultTag;
    [self.miniCanvasFeed updateSlot:slotIdx
                  withSourceTexture:srcTex
                                tag:tag
                             device:dev
                       commandQueue:q];
    [cache returnCommandQueueToCache:q];
  }
}

@end
