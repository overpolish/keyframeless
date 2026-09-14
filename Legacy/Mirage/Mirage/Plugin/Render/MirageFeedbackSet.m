/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageFeedbackSet.h"

id<MTLTexture> MirageNewBufferTexture(id<MTLDevice> device, NSUInteger w,
                                      NSUInteger h) {
  MTLTextureDescriptor *td = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                   width:w
                                  height:h
                               mipmapped:NO];
  td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  td.storageMode = MTLStorageModePrivate;
  return [device newTextureWithDescriptor:td];
}

// Frames kept as checkpoints before the oldest is evicted.
static const NSInteger kMaxCheckpoints = 24;

// Output resolutions kept before the least-recently-used set is dropped. Three
// covers the resolutions a plugin instance genuinely alternates between (the
// viewer, a reduced playback pass, an export or preview); a fourth is a
// resolution it has moved on from. Evicting one costs a feedback shader its
// history, so it re-sims from clear the next time that resolution appears -
// which is why this is an LRU cap and not "keep only the current one".
static const NSInteger kMaxResolutionSets = 3;

@implementation MirageFeedbackSet

+ (instancetype)setInStore:(NSMutableDictionary *)store
                    forKey:(NSString *)key
                     width:(NSUInteger)w
                    height:(NSUInteger)h {
  MirageFeedbackSet *fb = store[key];
  if (!fb) {
    fb = [MirageFeedbackSet new];
    store[key] = fb;
  }
  if (fb->w != w || fb->h != h) {
    for (int s = 0; s < 2; s++)
      for (int c = 0; c < 4; c++)
        fb->tex[s][c] = nil;
    [fb->checkpoints removeAllObjects];
    fb->prevIdx = 0;
    fb->hasState = NO;
    fb->w = w;
    fb->h = h;
  }
  // Stamp this set as the most recently used, then drop the coldest ones over
  // the cap. The stamp is the store's own high-water mark + 1 rather than a
  // process-global counter, so there is no mutable static to go wrong across
  // XPC instances.
  uint64_t high = 0;
  for (MirageFeedbackSet *other in store.allValues)
    if (other->touch > high)
      high = other->touch;
  fb->touch = high + 1;
  while ((NSInteger)store.count > kMaxResolutionSets) {
    NSString *coldestKey = nil;
    uint64_t coldest = UINT64_MAX;
    for (NSString *k in store) {
      MirageFeedbackSet *s = store[k];
      if (s->touch < coldest) {
        coldest = s->touch;
        coldestKey = k;
      }
    }
    if (!coldestKey)
      break;
    [store removeObjectForKey:coldestKey];
  }
  return fb;
}

- (NSInteger)nearestCheckpointAtMost:(NSInteger)F {
  NSInteger best = -1;
  for (NSNumber *k in checkpoints)
    if (k.integerValue <= F && k.integerValue > best)
      best = k.integerValue;
  return best;
}

- (void)snapshotFrame:(NSInteger)frame
               device:(id<MTLDevice>)device
                queue:(id<MTLCommandQueue>)queue {
  if (!queue)
    return;
  int from = prevIdx;
  NSMutableArray *snap = [NSMutableArray arrayWithCapacity:4];
  id<MTLCommandBuffer> cb = [queue commandBuffer];
  id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
  for (int k = 0; k < 4; k++) {
    id<MTLTexture> src = tex[from][k];
    if (!src) {
      [snap addObject:[NSNull null]];
      continue;
    }
    id<MTLTexture> copy = MirageNewBufferTexture(device, w, h);
    if (copy)
      [bl copyFromTexture:src toTexture:copy];
    [snap addObject:copy ?: (id)[NSNull null]];
  }
  [bl endEncoding];
  [cb commit];
  [cb waitUntilCompleted];
  if (!checkpoints)
    checkpoints = [NSMutableDictionary dictionary];
  checkpoints[@(frame)] = snap;
  while ((NSInteger)checkpoints.count > kMaxCheckpoints) {
    NSNumber *oldest = [[checkpoints.allKeys
        sortedArrayUsingSelector:@selector(compare:)] firstObject];
    [checkpoints removeObjectForKey:oldest];
  }
}

- (void)restoreFrame:(NSInteger)frame
              device:(id<MTLDevice>)device
               queue:(id<MTLCommandQueue>)queue {
  NSArray *snap = checkpoints[@(frame)];
  if (!snap || !queue)
    return;
  int into = prevIdx;
  id<MTLCommandBuffer> cb = [queue commandBuffer];
  id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
  for (int k = 0; k < 4; k++) {
    id t = snap[k];
    if (t == [NSNull null]) {
      tex[into][k] = nil;
      continue;
    }
    id<MTLTexture> dst = tex[into][k];
    if (!dst) {
      dst = MirageNewBufferTexture(device, w, h);
      tex[into][k] = dst;
    }
    if (dst)
      [bl copyFromTexture:(id<MTLTexture>)t toTexture:dst];
  }
  [bl endEncoding];
  [cb commit];
  [cb waitUntilCompleted];
}

@end
