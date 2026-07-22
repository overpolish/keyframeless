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
