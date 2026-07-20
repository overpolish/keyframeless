/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMiniViewerFeed.h"

#import "KKLog.h"
#import <IOSurface/IOSurface.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>

// Long-edge cap for the preview surface. _computeDst never upscales, so a
// ≤2048 source is cached at native res (crisp when zoomed); larger sources
// (4K+) are bounded here to keep each persistent IOSurface ~9MB and the
// throttled (≤10fps) MPS pass cheap.
static const NSUInteger kTargetLongEdge = 2048;

// Minimum wall-clock gap between surface updates per slot. The mini viewer
// only needs a recent frame, not every render tick - this keeps the render
// path from paying an MPS pass on every frame during playback.
// Cap to ~60 fps. Was 0.1s (10 fps) which felt laggy during interactive
// editing - the last drag tick within the 100 ms window would get dropped
// and the mini viewer would stay stale until the next render frame fired.
static const NSTimeInterval kMinUpdateInterval = 1.0 / 60.0;

// One IOSurface + texture + bookkeeping per filmstrip frame. Slot 0 is the
// single-slot default; onion-skin enlarges the array.
@interface _KKMiniFeedSlot : NSObject
@property(nonatomic) IOSurfaceRef surface;
@property(nonatomic, strong) id<MTLTexture> surfaceTexture;
@property(nonatomic) NSUInteger srcW;
@property(nonatomic) NSUInteger srcH;
@property(nonatomic) NSUInteger dstW;
@property(nonatomic) NSUInteger dstH;
@property(nonatomic) uint64_t generation;
@property(nonatomic) double tag; // opaque (callers store the slot's frac)
@property(nonatomic) NSTimeInterval lastUpdate;
@end

@implementation _KKMiniFeedSlot
- (void)dealloc {
  if (_surface)
    CFRelease(_surface);
}
@end

@implementation KKMiniViewerFeed {
  NSString *_descriptorPath;
  NSMutableArray<_KKMiniFeedSlot *> *_slots;
  // A SECOND texture, not a second time. Deliberately outside `_slots`: those
  // mean "the same source at different times" (onion-skin / filmstrip) and
  // their count moves with the boundary preview, so an index into them would
  // shift under a consumer's feet. Published as its own descriptor key, absent
  // when nil, so feeds that never set it are byte-identical to before.
  _KKMiniFeedSlot *_channel1;
  MPSImageBilinearScale *_scaler;
}

- (instancetype)initWithDescriptorPath:(NSString *)descriptorPath {
  self = [super init];
  if (self) {
    _descriptorPath = [descriptorPath copy];
    _slots = [NSMutableArray array];
    [_slots addObject:[[_KKMiniFeedSlot alloc] init]];
  }
  return self;
}

- (NSUInteger)slotCount {
  @synchronized(self) {
    return _slots.count;
  }
}

- (void)setSlotCount:(NSUInteger)slotCount {
  if (slotCount < 1)
    slotCount = 1;
  @synchronized(self) {
    if (_slots.count == slotCount)
      return;
    while (_slots.count < slotCount)
      [_slots addObject:[[_KKMiniFeedSlot alloc] init]];
    while (_slots.count > slotCount)
      [_slots removeLastObject];
  }
}

- (void)_computeDstForSrcW:(NSUInteger)sw
                         h:(NSUInteger)sh
                      slot:(_KKMiniFeedSlot *)slot {
  NSUInteger longEdge = MAX(sw, sh);
  double scale =
      longEdge > 0 ? (double)kTargetLongEdge / (double)longEdge : 1.0;
  if (scale > 1.0)
    scale = 1.0; // never upscale a small source
  NSUInteger w = (NSUInteger)lround((double)sw * scale);
  NSUInteger h = (NSUInteger)lround((double)sh * scale);
  slot.dstW = MAX(w & ~1u, 2u); // keep even
  slot.dstH = MAX(h & ~1u, 2u);
}

- (BOOL)_ensureSurfaceForSlot:(_KKMiniFeedSlot *)slot
                       device:(id<MTLDevice>)device
                         srcW:(NSUInteger)sw
                         srcH:(NSUInteger)sh {
  if (slot.surfaceTexture && sw == slot.srcW && sh == slot.srcH)
    return YES;

  [self _computeDstForSrcW:sw h:sh slot:slot];

  slot.surfaceTexture = nil;
  if (slot.surface) {
    CFRelease(slot.surface);
    slot.surface = NULL;
  }

  size_t bpr = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, slot.dstW * 4);
  NSDictionary *props = @{
    (id)kIOSurfaceWidth : @(slot.dstW),
    (id)kIOSurfaceHeight : @(slot.dstH),
    (id)kIOSurfaceBytesPerElement : @4,
    (id)kIOSurfaceBytesPerRow : @(bpr),
    (id)kIOSurfacePixelFormat : @((uint32_t)'BGRA'),
  };
  slot.surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
  if (!slot.surface) {
    KKLogError(@"KKMiniViewerFeed: IOSurfaceCreate failed (%lux%lu)",
               (unsigned long)slot.dstW, (unsigned long)slot.dstH);
    return NO;
  }

  // FCP hands us a linear-light source. Writing through an _sRGB-typed
  // texture makes MPS gamma-encode on store, so the 8-bit surface holds
  // display-encoded values - KKMiniViewerView reads them as plain BGRA8 and
  // shows them straight, matching the brightness FCP displays.
  MTLTextureDescriptor *td = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
                                   width:slot.dstW
                                  height:slot.dstH
                               mipmapped:NO];
  td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite |
             MTLTextureUsageRenderTarget;
  td.storageMode = MTLStorageModeShared;
  slot.surfaceTexture = [device newTextureWithDescriptor:td
                                               iosurface:slot.surface
                                                   plane:0];
  if (!slot.surfaceTexture) {
    KKLogError(@"KKMiniViewerFeed: newTextureWithDescriptor:iosurface: "
               @"returned nil");
    CFRelease(slot.surface);
    slot.surface = NULL;
    return NO;
  }

  slot.srcW = sw;
  slot.srcH = sh;
  return YES;
}

// The channel-1 entry, or nil when nothing has published one.
- (NSDictionary *)_channel1EntryLocked {
  if (!_channel1 || !_channel1.surface)
    return nil;
  return @{
    @"ioSurfaceID" : @((uint32_t)IOSurfaceGetID(_channel1.surface)),
    @"width" : @(_channel1.dstW),
    @"height" : @(_channel1.dstH),
    @"generation" : @(_channel1.generation),
  };
}

- (void)_publishLocked {
  NSMutableArray *slotEntries = [NSMutableArray array];
  for (_KKMiniFeedSlot *s in _slots) {
    if (!s.surface)
      continue;
    [slotEntries addObject:@{
      @"ioSurfaceID" : @((uint32_t)IOSurfaceGetID(s.surface)),
      @"width" : @(s.dstW),
      @"height" : @(s.dstH),
      @"generation" : @(s.generation),
      @"tag" : @(s.tag),
    }];
  }
  if (slotEntries.count == 0) {
    // Generator: no source frames, but publish the output media size so a
    // consumer resolves `sourceMediaSize` (px-scaled value fields need it). The
    // consumer synthesizes one source-less slot from the empty array and draws
    // it via its own generate path.
    if (_mediaSize.width > 0 && _mediaSize.height > 0) {
      NSMutableDictionary *dimsOnly = [@{
        @"srcWidth" : @(_mediaSize.width),
        @"srcHeight" : @(_mediaSize.height),
        @"ts" : @([NSDate timeIntervalSinceReferenceDate]),
        @"slots" : @[],
      } mutableCopy];
      NSDictionary *ch1 = [self _channel1EntryLocked];
      if (ch1)
        dimsOnly[@"channel1"] = ch1;
      NSData *json = [NSJSONSerialization dataWithJSONObject:dimsOnly
                                                     options:0
                                                       error:nil];
      if (![json writeToFile:_descriptorPath atomically:YES])
        KKLogWarn(@"KKMiniViewerFeed: failed to write %@", _descriptorPath);
    }
    return;
  }

  // Top-level keys at slot 0 stay for the single-slot fast path (so existing
  // consumers that don't know about `slots` keep working). New consumers
  // walk the `slots` array.
  _KKMiniFeedSlot *first = _slots.firstObject;
  NSMutableDictionary *desc = [@{
    @"ioSurfaceID" : @((uint32_t)IOSurfaceGetID(first.surface)),
    @"width" : @(first.dstW),
    @"height" : @(first.dstH),
    @"srcWidth" : @(first.srcW),
    @"srcHeight" : @(first.srcH),
    @"generation" : @(first.generation),
    @"ts" : @([NSDate timeIntervalSinceReferenceDate]),
    @"slots" : slotEntries,
  } mutableCopy];
  NSDictionary *ch1 = [self _channel1EntryLocked];
  if (ch1)
    desc[@"channel1"] = ch1;
  NSData *json = [NSJSONSerialization dataWithJSONObject:desc
                                                 options:0
                                                   error:nil];
  if (![json writeToFile:_descriptorPath atomically:YES])
    KKLogWarn(@"KKMiniViewerFeed: failed to write %@", _descriptorPath);
}

- (void)publishDescriptor {
  @synchronized(self) {
    [self _publishLocked];
  }
}

- (void)_encodeUpdateForSlot:(_KKMiniFeedSlot *)slot
               sourceTexture:(id<MTLTexture>)sourceTexture
                         tag:(double)tag
                      device:(id<MTLDevice>)device
                commandQueue:(id<MTLCommandQueue>)commandQueue {
  NSUInteger sw = sourceTexture.width;
  NSUInteger sh = sourceTexture.height;
  if (sw == 0 || sh == 0)
    return;
  if (![self _ensureSurfaceForSlot:slot device:device srcW:sw srcH:sh])
    return;

  if (!_scaler)
    _scaler = [[MPSImageBilinearScale alloc] initWithDevice:device];

  id<MTLCommandBuffer> cb = [commandQueue commandBuffer];
  cb.label = @"KKMiniViewerFeed";
  [_scaler encodeToCommandBuffer:cb
                   sourceTexture:sourceTexture
              destinationTexture:slot.surfaceTexture];

  slot.generation++;
  slot.tag = tag;
  slot.lastUpdate = [NSDate timeIntervalSinceReferenceDate];
  [cb addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull done) {
    @synchronized(self) {
      [self _publishLocked];
    }
  }];
  [cb commit];
}

- (void)updateWithSourceTexture:(id<MTLTexture>)sourceTexture
                         device:(id<MTLDevice>)device
                   commandQueue:(id<MTLCommandQueue>)commandQueue {
  if (!sourceTexture || !device || !commandQueue)
    return;
  @synchronized(self) {
    _KKMiniFeedSlot *slot = _slots.firstObject;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - slot.lastUpdate < kMinUpdateInterval)
      return;
    [self _encodeUpdateForSlot:slot
                 sourceTexture:sourceTexture
                           tag:slot.tag
                        device:device
                  commandQueue:commandQueue];
  }
}

- (void)updateSlot:(NSUInteger)slotIdx
    withSourceTexture:(id<MTLTexture>)sourceTexture
                  tag:(double)tag
               device:(id<MTLDevice>)device
         commandQueue:(id<MTLCommandQueue>)commandQueue {
  if (!sourceTexture || !device || !commandQueue)
    return;
  @synchronized(self) {
    if (slotIdx >= _slots.count)
      return;
    _KKMiniFeedSlot *slot = _slots[slotIdx];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - slot.lastUpdate < kMinUpdateInterval && slot.tag == tag)
      return;
    [self _encodeUpdateForSlot:slot
                 sourceTexture:sourceTexture
                           tag:tag
                        device:device
                  commandQueue:commandQueue];
  }
}

- (void)updateChannel1WithSourceTexture:(id<MTLTexture>)sourceTexture
                                 device:(id<MTLDevice>)device
                           commandQueue:(id<MTLCommandQueue>)commandQueue {
  if (!sourceTexture || !device || !commandQueue)
    return;
  @synchronized(self) {
    if (!_channel1)
      _channel1 = [[_KKMiniFeedSlot alloc] init];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - _channel1.lastUpdate < kMinUpdateInterval)
      return;
    [self _encodeUpdateForSlot:_channel1
                 sourceTexture:sourceTexture
                           tag:0.0
                        device:device
                  commandQueue:commandQueue];
  }
}

@end

id<MTLTexture> KKMiniViewerFeedLoadPrimarySource(NSString *descriptorPath,
                                                 id<MTLDevice> device) {
  if (descriptorPath.length == 0 || !device)
    return nil;
  NSData *data = [NSData dataWithContentsOfFile:descriptorPath];
  if (!data)
    return nil;
  NSDictionary *desc = [NSJSONSerialization JSONObjectWithData:data
                                                       options:0
                                                         error:nil];
  if (![desc isKindOfClass:NSDictionary.class])
    return nil;
  // Slot 0 (multi-slot descriptors) else the legacy top-level key. A generator
  // feed carries neither (it publishes only media dims), so this returns nil
  // and the caller re-renders on its own reference source instead.
  uint32_t sid = 0;
  NSArray *slots = desc[@"slots"];
  if ([slots isKindOfClass:NSArray.class] && slots.count > 0 &&
      [slots[0] isKindOfClass:NSDictionary.class])
    sid = (uint32_t)[slots[0][@"ioSurfaceID"] unsignedIntValue];
  if (sid == 0)
    sid = (uint32_t)[desc[@"ioSurfaceID"] unsignedIntValue];
  if (sid == 0)
    return nil;
  IOSurfaceRef surf = IOSurfaceLookup((IOSurfaceID)sid);
  if (!surf)
    return nil;
  MTLTextureDescriptor *td = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:IOSurfaceGetWidth(surf)
                                  height:IOSurfaceGetHeight(surf)
                               mipmapped:NO];
  td.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
  td.storageMode = MTLStorageModeShared;
  id<MTLTexture> tex = [device newTextureWithDescriptor:td
                                              iosurface:surf
                                                  plane:0];
  CFRelease(surf); // the texture retains the surface
  return tex;
}
