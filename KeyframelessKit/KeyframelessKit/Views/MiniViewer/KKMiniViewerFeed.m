/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMiniViewerFeed.h"

#import "KKLog.h"
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>

// Long-edge cap for the preview surface. _computeDst never upscales, so a
// ≤2048 source is cached at native res (crisp when zoomed); larger sources
// (4K+) are bounded here to keep each persistent IOSurface bounded (~9MB for
// BGRA8 or ~18MB for RGBA16F) and the throttled MPS pass cheap.
static const NSUInteger kTargetLongEdge = 2048;

// Minimum wall-clock gap between surface updates per slot. The mini viewer
// only needs a recent frame, not every render tick - this keeps the render
// path from paying an MPS pass on every frame during playback.
// Cap to ~60 fps. Was 0.1s (10 fps) which felt laggy during interactive
// editing - the last drag tick within the 100 ms window would get dropped
// and the mini viewer would stay stale until the next render frame fired.
static const NSTimeInterval kMinUpdateInterval = 1.0 / 60.0;

// Trailing-edge delay for the coalesced republish. Half a 60fps frame: long
// enough that every surface update completing within one render tick folds into
// one write, short enough to stay far inside the consumer's poll period (~16ms
// live, ~66ms idle) so the descriptor is never the stale link.
static const NSTimeInterval kPublishCoalesceInterval = 1.0 / 120.0;

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

static NSString *KKMiniFeedFormatName(_KKMiniFeedSlot *slot) {
  return slot.surfaceTexture.pixelFormat == MTLPixelFormatRGBA16Float
             ? @"rgba16Float"
             : @"bgra8";
}

// How one surface is described to a consumer. Every published entry - slot,
// channel 1, aux - carries exactly these keys, so a consumer resolves any of
// them the same way.
static NSDictionary *KKMiniFeedSlotEntry(_KKMiniFeedSlot *slot) {
  return @{
    @"ioSurfaceID" : @((uint32_t)IOSurfaceGetID(slot.surface)),
    @"width" : @(slot.dstW),
    @"height" : @(slot.dstH),
    @"generation" : @(slot.generation),
    @"pixelFormat" : KKMiniFeedFormatName(slot),
  };
}

@implementation KKMiniViewerFeed {
  NSString *_descriptorPath;
  NSMutableArray<_KKMiniFeedSlot *> *_slots;
  // A SECOND texture, not a second time. Deliberately outside `_slots`: those
  // mean "the same source at different times" (onion-skin / filmstrip) and
  // their count moves with the boundary preview, so an index into them would
  // shift under a consumer's feet. Published as its own descriptor key, absent
  // when nil, so feeds that never set it are byte-identical to before.
  _KKMiniFeedSlot *_channel1;
  // Auxiliary textures: extra whole frames a consumer indexes POSITIONALLY,
  // outside both existing shapes (slots = one source at many times, channel 1 =
  // a single fixed second source). Published as its own `aux` array, absent
  // when empty, so a feed that never fills it is unchanged.
  NSMutableArray<_KKMiniFeedSlot *> *_auxSlots;
  MPSImageBilinearScale *_scaler;
  // Republish coalescing (see -_schedulePublishLocked).
  BOOL _publishDirty;
  BOOL _publishScheduled;
}

- (instancetype)initWithDescriptorPath:(NSString *)descriptorPath {
  self = [super init];
  if (self) {
    _descriptorPath = [descriptorPath copy];
    _playheadFrac = -1.0; // unknown until a playing render tick sets it
    _slots = [NSMutableArray array];
    [_slots addObject:[[_KKMiniFeedSlot alloc] init]];
    _auxSlots = [NSMutableArray array];
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

- (NSUInteger)auxTextureCount {
  @synchronized(self) {
    return _auxSlots.count;
  }
}

- (void)setAuxTextureCount:(NSUInteger)auxTextureCount {
  @synchronized(self) {
    if (_auxSlots.count == auxTextureCount)
      return;
    while (_auxSlots.count < auxTextureCount)
      [_auxSlots addObject:[[_KKMiniFeedSlot alloc] init]];
    while (_auxSlots.count > auxTextureCount)
      [_auxSlots removeLastObject];
    KKLogDebug(@"[MiniFeed] aux count -> %lu",
               (unsigned long)_auxSlots.count);
  }
}

- (CGSize)primarySourceSize {
  @synchronized(self) {
    _KKMiniFeedSlot *first = _slots.firstObject;
    return CGSizeMake((CGFloat)first.srcW, (CGFloat)first.srcH);
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

// The backing surface for one preview slot, at the element size and pixel format
// the linear-float / display-encoded choice implies. Returns NULL (and logs) when
// the surface could not be made.
static IOSurfaceRef KKMiniFeedCreateSurface(NSUInteger w, NSUInteger h,
                                            BOOL linearFloat) {
  size_t bytesPerElement = linearFloat ? 8 : 4;
  OSType surfaceFormat =
      linearFloat ? kCVPixelFormatType_64RGBAHalf : (OSType)'BGRA';
  size_t bpr =
      IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, w * bytesPerElement);
  NSDictionary *props = @{
    (id)kIOSurfaceWidth : @(w),
    (id)kIOSurfaceHeight : @(h),
    (id)kIOSurfaceBytesPerElement : @(bytesPerElement),
    (id)kIOSurfaceBytesPerRow : @(bpr),
    (id)kIOSurfacePixelFormat : @((uint32_t)surfaceFormat),
  };
  IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
  if (!surface)
    KKLogError(@"KKMiniViewerFeed: IOSurfaceCreate failed (%lux%lu)",
               (unsigned long)w, (unsigned long)h);
  return surface;
}

- (BOOL)_ensureSurfaceForSlot:(_KKMiniFeedSlot *)slot
                       device:(id<MTLDevice>)device
                         srcW:(NSUInteger)sw
                         srcH:(NSUInteger)sh {
  MTLPixelFormat expectedFormat =
      self.linearFloat ? MTLPixelFormatRGBA16Float
                       : MTLPixelFormatBGRA8Unorm_sRGB;
  if (slot.surfaceTexture && slot.surfaceTexture.pixelFormat == expectedFormat &&
      sw == slot.srcW && sh == slot.srcH)
    return YES;

  [self _computeDstForSrcW:sw h:sh slot:slot];

  slot.surfaceTexture = nil;
  if (slot.surface) {
    CFRelease(slot.surface);
    slot.surface = NULL;
  }

  slot.surface =
      KKMiniFeedCreateSurface(slot.dstW, slot.dstH, self.linearFloat);
  if (!slot.surface)
    return NO;

  // The default feed display-encodes FCP's linear source through an sRGB-typed
  // BGRA8 target. Technical color transforms instead retain the linear float
  // values, including HDR values above one and wide-gamut negative components.
  MTLTextureDescriptor *td = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:expectedFormat
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
  return KKMiniFeedSlotEntry(_channel1);
}

// The `aux` array, or nil when there is nothing to publish. All-or-nothing: a
// half-filled array would shift a positional consumer onto the wrong entries,
// and a consumer that sees no `aux` has a defined fallback, so publishing a
// partial one is strictly worse than publishing none.
- (NSArray *)_auxEntriesLocked {
  if (_auxSlots.count == 0)
    return nil;
  NSMutableArray *entries = [NSMutableArray arrayWithCapacity:_auxSlots.count];
  for (_KKMiniFeedSlot *s in _auxSlots) {
    if (!s.surface)
      return nil;
    [entries addObject:KKMiniFeedSlotEntry(s)];
  }
  return entries;
}

// Attach the optional second-texture keys, serialize and write. Both publish
// shapes - the generator's dimensions-only document and the full one - carry the
// same `channel1` / `aux` entries, absent when nothing has published them.
- (void)_writeDescriptorLocked:(NSMutableDictionary *)desc {
  NSDictionary *ch1 = [self _channel1EntryLocked];
  if (ch1)
    desc[@"channel1"] = ch1;
  NSArray *aux = [self _auxEntriesLocked];
  if (aux)
    desc[@"aux"] = aux;
  NSData *json = [NSJSONSerialization dataWithJSONObject:desc
                                                 options:0
                                                   error:nil];
  BOOL wrote = [json writeToFile:_descriptorPath atomically:YES];
  if (!wrote)
    KKLogWarn(@"KKMiniViewerFeed: failed to write %@", _descriptorPath);
}

- (void)_publishLocked {
  NSMutableArray *slotEntries = [NSMutableArray array];
  for (_KKMiniFeedSlot *s in _slots) {
    if (!s.surface)
      continue;
    NSMutableDictionary *entry = [KKMiniFeedSlotEntry(s) mutableCopy];
    entry[@"tag"] = @(s.tag);
    [slotEntries addObject:entry];
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
      [self _writeDescriptorLocked:dimsOnly];
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
    @"pixelFormat" : KKMiniFeedFormatName(first),
    @"ts" : @([NSDate timeIntervalSinceReferenceDate]),
    @"playheadFrac" : @(_playheadFrac),
    @"slots" : slotEntries,
  } mutableCopy];
  [self _writeDescriptorLocked:desc];
}

- (void)publishDescriptor {
  @synchronized(self) {
    [self _publishLocked];
  }
}

// Coalesce the post-update republish. The descriptor is a WHOLE-FEED snapshot,
// so N surface updates completing inside one render tick used to serialise and
// atomically write N copies of the same document - source plus one per aux
// texture, measured at ~2.7 writes per tick and ~160 temp-file+rename pairs a
// second across two instances during playback. One trailing write per burst
// carries exactly the same information.
//
// Trailing edge, not leading: the LAST update in a burst is the one whose
// generations the consumer needs, and a leading-edge throttle would drop it and
// leave the mini a frame behind whenever playback stopped. The dirty flag makes
// the coalesce lossless - any update that lands while a write is pending is
// covered by that pending write. Caller holds the lock.
- (void)_schedulePublishLocked {
  _publishDirty = YES;
  if (_publishScheduled)
    return;
  _publishScheduled = YES;
  __weak typeof(self) weakSelf = self;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(kPublishCoalesceInterval * NSEC_PER_SEC)),
      dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        KKMiniViewerFeed *strong = weakSelf;
        if (!strong)
          return;
        @synchronized(strong) {
          strong->_publishScheduled = NO;
          if (!strong->_publishDirty)
            return;
          strong->_publishDirty = NO;
          [strong _publishLocked];
        }
      });
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
      [self _schedulePublishLocked];
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

- (void)updateAuxTexture:(id<MTLTexture>)sourceTexture
                 atIndex:(NSUInteger)index
                  device:(id<MTLDevice>)device
            commandQueue:(id<MTLCommandQueue>)commandQueue {
  if (!sourceTexture || !device || !commandQueue)
    return;
  @synchronized(self) {
    if (index >= _auxSlots.count)
      return;
    _KKMiniFeedSlot *slot = _auxSlots[index];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - slot.lastUpdate < kMinUpdateInterval)
      return;
    [self _encodeUpdateForSlot:slot
                 sourceTexture:sourceTexture
                           tag:0.0
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
  NSString *format = nil;
  if ([slots isKindOfClass:NSArray.class] && slots.count > 0 &&
      [slots[0] isKindOfClass:NSDictionary.class]) {
    sid = (uint32_t)[slots[0][@"ioSurfaceID"] unsignedIntValue];
    format = slots[0][@"pixelFormat"];
  }
  if (sid == 0) {
    sid = (uint32_t)[desc[@"ioSurfaceID"] unsignedIntValue];
    format = desc[@"pixelFormat"];
  }
  if (sid == 0)
    return nil;
  IOSurfaceRef surf = IOSurfaceLookup((IOSurfaceID)sid);
  if (!surf)
    return nil;
  MTLPixelFormat pixelFormat = [format isEqualToString:@"rgba16Float"]
                                   ? MTLPixelFormatRGBA16Float
                                   : MTLPixelFormatBGRA8Unorm;
  MTLTextureDescriptor *td = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:pixelFormat
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

NSString *KKMiniViewerFeedDescriptorPath(NSString *productSlug,
                                         NSString *uuid) {
  if (!uuid.length)
    return [NSString stringWithFormat:@"/tmp/%@-miniviewer.json", productSlug];
  return [NSString
      stringWithFormat:@"/tmp/%@-miniviewer-%@.json", productSlug, uuid];
}

NSString *KKMiniViewerFeedRequestPath(NSString *productSlug, NSString *uuid) {
  if (!uuid.length)
    return [NSString
        stringWithFormat:@"/tmp/%@-miniviewer-request.json", productSlug];
  return [NSString stringWithFormat:@"/tmp/%@-miniviewer-request-%@.json",
                                    productSlug, uuid];
}
