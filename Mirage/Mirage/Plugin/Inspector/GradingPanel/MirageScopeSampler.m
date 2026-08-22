/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageScopeSampler.h"

#import <KeyframelessKit/KKLog.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>

// Cap the pixels actually inspected. The preview is small, but it is sized to
// the popover's display resolution, so this keeps the cost flat if that grows.
static const NSUInteger kMaxSamples = 40000;
/// Oklab a/b that puts the cast marker at the rim. A cast is a small residual,
/// so it needs its own much tighter scale than the cloud to be visible at all.
/// Sized from measurement: a cast strong enough to be obviously wrong reads
/// about 0.055.
static const double kCastFullScale = 0.08;

/// Scope reads are driven while AppKit is inside its mouse-tracking run loop.
/// The main dispatch queue can be deferred by that nested loop; common-mode
/// blocks cannot, so readback and delivery keep pace with the drag.
static void MirageScopePerformOnMainRunLoop(void (^block)(void)) {
  if (!block)
    return;
  CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, block);
  CFRunLoopWakeUp(CFRunLoopGetMain());
}

@implementation MirageScopeReading
@end

/// Half-width of the sampled patch, in pixels. A single pixel would be at the
/// mercy of sensor noise and compression blocks, so a small neighbourhood is
/// averaged.
static const NSInteger kPickPatchRadius = 4;

@implementation MirageScopeSampler {
  id<MTLCommandQueue> _queue;
  id<MTLTexture> _readback;
  __weak id<MTLDevice> _queueDevice;
  MPSImageLanczosScale *_downscaler;
  /// The walk over the readback, off the main thread. Serial: one measurement
  /// is in flight at a time, and the order they were asked in is the order the
  /// panel should hear about them.
  dispatch_queue_t _analysisQueue;
  /// Whether an async measurement owns the readback right now. Read and written
  /// on the MAIN thread only - the background hop never touches it, it just
  /// hands the reading back for the main thread to clear it.
  BOOL _readInFlight;
}

- (instancetype)init {
  if ((self = [super init])) {
    _pickUV = NSMakePoint(-1.0, -1.0);
    _probeUV = NSMakePoint(-1.0, -1.0);
    _visibleUVRect = NSMakeRect(0.0, 0.0, 1.0, 1.0);
    _maximumSampleCount = kMaxSamples;
  }
  return self;
}

/// Which of the byte layouts this file understands `texture` is in, or NO for
/// one it does not. A format this does not understand must be refused rather
/// than reinterpreted, which would report a confidently wrong reading.
static BOOL MirageScopeChannelOrder(id<MTLTexture> texture, NSUInteger *outR,
                                    NSUInteger *outB) {
  BOOL bgra = texture.pixelFormat == MTLPixelFormatBGRA8Unorm ||
              texture.pixelFormat == MTLPixelFormatBGRA8Unorm_sRGB;
  BOOL rgba = texture.pixelFormat == MTLPixelFormatRGBA8Unorm ||
              texture.pixelFormat == MTLPixelFormatRGBA8Unorm_sRGB;
  if (!bgra && !rgba)
    return NO;
  if (outR)
    *outR = bgra ? 2 : 0;
  if (outB)
    *outB = bgra ? 0 : 2;
  return YES;
}

/// Average the patch around `uv`, returning NO when the point is outside the
/// frame or the patch lands on no pixels at all. `outLinear` and `outCoded`
/// each take three components and either may be NULL: the two picks want
/// different encodings of the same pixels, and reading the neighbourhood twice
/// to serve them would be the same loop with one line changed.
static BOOL MirageAveragePatch(const uint8_t *bytes, NSUInteger w, NSUInteger h,
                               NSUInteger bytesPerRow, NSUInteger rIdx,
                               NSUInteger bIdx, NSPoint uv, double *outLinear,
                               double *outCoded) {
  if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0)
    return NO;
  NSInteger cx = (NSInteger)(uv.x * (double)(w - 1) + 0.5);
  NSInteger cy = (NSInteger)(uv.y * (double)(h - 1) + 0.5);
  double lin[3] = {0.0, 0.0, 0.0}, coded[3] = {0.0, 0.0, 0.0};
  NSUInteger patch = 0;
  for (NSInteger y = cy - kPickPatchRadius; y <= cy + kPickPatchRadius; y++) {
    if (y < 0 || y >= (NSInteger)h)
      continue;
    const uint8_t *row = bytes + (NSUInteger)y * bytesPerRow;
    for (NSInteger x = cx - kPickPatchRadius; x <= cx + kPickPatchRadius; x++) {
      if (x < 0 || x >= (NSInteger)w)
        continue;
      const uint8_t *px = row + (NSUInteger)x * 4;
      double c[3] = {px[rIdx] / 255.0, px[1] / 255.0, px[bIdx] / 255.0};
      for (int i = 0; i < 3; i++) {
        coded[i] += c[i];
        lin[i] += MirageSrgbToLinear(c[i]);
      }
      patch++;
    }
  }
  if (!patch)
    return NO;
  for (int i = 0; i < 3; i++) {
    if (outLinear)
      outLinear[i] = lin[i] / patch;
    if (outCoded)
      outCoded[i] = coded[i] / patch;
  }
  return YES;
}

/// The four accumulation arrays a measurement fills, and whether the
/// visible-region pair is really there.
typedef struct {
  double *tone;
  double *chroma;
  double *toneVisible;
  double *chromaVisible;
  BOOL scoped;
} MirageScopeBinSet;

static void MirageScopeBinsFree(MirageScopeBinSet *set) {
  free(set->tone);
  free(set->chroma);
  free(set->toneVisible);
  free(set->chromaVisible);
}

/// Allocate the bins, returning NO only when the whole-frame pair could not be
/// had - with nothing to measure into there is no reading to give.
///
/// Scoped means BOTH visible sets exist, and it is decided from the pointers
/// rather than from `wantScoped`. A half-scoped state - one set allocated, or
/// the flag saying yes while an allocation said no - is then not representable,
/// which is what keeps every later reader honest without re-checking.
static BOOL MirageScopeBinsAlloc(MirageScopeBinSet *out, NSUInteger binCount,
                                 NSUInteger chromaCount, BOOL wantScoped) {
  *out = (MirageScopeBinSet){0};
  out->tone = calloc(binCount, sizeof(double));
  out->chroma = calloc(chromaCount, sizeof(double));
  if (wantScoped) {
    out->toneVisible = calloc(binCount, sizeof(double));
    out->chromaVisible = calloc(chromaCount, sizeof(double));
  }
  if (!out->tone || !out->chroma) {
    MirageScopeBinsFree(out);
    *out = (MirageScopeBinSet){0};
    return NO;
  }
  out->scoped = out->toneVisible != NULL && out->chromaVisible != NULL;
  if (wantScoped && !out->scoped) {
    free(out->toneVisible);
    free(out->chromaVisible);
    out->toneVisible = NULL;
    out->chromaVisible = NULL;
  }
  return YES;
}

/// Walk the readback on `stride` in both axes, accumulating every visited pixel
/// in linear light. u/v are bottom-origin, like the texture and like
/// MirageAveragePatch's own mapping.
static void MirageScopeAccumulateStrided(MirageScopeAccumulator *acc,
                                         const uint8_t *bytes, NSUInteger w,
                                         NSUInteger h, NSUInteger bytesPerRow,
                                         NSUInteger stride, NSUInteger rIdx,
                                         NSUInteger bIdx) {
  double denomX = w > 1 ? (double)(w - 1) : 1.0;
  double denomY = h > 1 ? (double)(h - 1) : 1.0;
  for (NSUInteger y = 0; y < h; y += stride) {
    const uint8_t *row = bytes + y * bytesPerRow;
    double v = (double)y / denomY;
    for (NSUInteger x = 0; x < w; x += stride) {
      const uint8_t *px = row + x * 4;
      MirageScopeAccumulatePixel(acc, MirageSrgbToLinear(px[rIdx] / 255.0),
                                 MirageSrgbToLinear(px[1] / 255.0),
                                 MirageSrgbToLinear(px[bIdx] / 255.0),
                                 (double)x / denomX, v);
    }
  }
}

/// Where the cast marker sits for a patch averaged in linear light: its Oklab
/// a/b error against `declaration`, scaled to the rim and clamped to the
/// circle.
static NSPoint MirageScopeCastMarker(const double linear[3],
                                     MirageMemoryColor declaration) {
  double pa = 0.0, pbb = 0.0;
  MirageLinearToOklabAB(linear[0], linear[1], linear[2], &pa, &pbb);
  // Neutral measures the patch against the origin. A declaration measures it
  // against the region that colour belongs in, and the error is what is left
  // over once the nearest correct version of it is subtracted - so a patch
  // already in the region reports exactly nothing.
  //
  // Signed the same way round as the grey cast on purpose: the cross sits where
  // the excess colour is, and the gesture stays "drag the puck the other way".
  if (declaration != MirageMemoryColorNeutral) {
    double na = 0.0, nb = 0.0;
    MirageMemoryColorNearest(MirageMemoryColorRegionFor(declaration), pa, pbb,
                             &na, &nb);
    pa -= na;
    pbb -= nb;
  }
  double mx = pa / kCastFullScale, my = pbb / kCastFullScale;
  double len = hypot(mx, my);
  if (len > 1.0) {
    mx /= len;
    my /= len;
  }
  return NSMakePoint(mx, my);
}

// A shared-storage copy is unavoidable: the mini's processed texture is
// MTLStorageModePrivate, so the CPU cannot read it directly. Kept and reused
// between measurements rather than reallocated per tick.
- (BOOL)_ensureReadbackForTexture:(id<MTLTexture>)texture
                           device:(id<MTLDevice>)device {
  if (_queueDevice != device || !_queue) {
    _queue = [device newCommandQueue];
    _queueDevice = device;
    _readback = nil;
    _downscaler = [[MPSImageLanczosScale alloc] initWithDevice:device];
  }
  if (!_queue)
    return NO;
  NSUInteger maxSamples = MAX((NSUInteger)1, self.maximumSampleCount);
  double scale = texture.width * texture.height > maxSamples
                     ? sqrt((double)maxSamples /
                            ((double)texture.width * (double)texture.height))
                     : 1.0;
  NSUInteger targetW = MAX((NSUInteger)1,
                           (NSUInteger)floor((double)texture.width * scale));
  NSUInteger targetH = MAX((NSUInteger)1,
                           (NSUInteger)floor((double)texture.height * scale));
  if (_readback && _readback.width == targetW &&
      _readback.height == targetH &&
      _readback.pixelFormat == texture.pixelFormat)
    return YES;
  MTLTextureDescriptor *td = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:texture.pixelFormat
                                   width:targetW
                                  height:targetH
                               mipmapped:NO];
  td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
  td.storageMode = MTLStorageModeShared;
  _readback = [device newTextureWithDescriptor:td];
  return _readback != nil;
}

/// Encode the full-size copy or GPU downsample into the reusable shared
/// texture. Downsampling BEFORE readback is the latency win: the previous path
/// copied every preview pixel to the CPU and only then skipped most of them.
- (void)_encodeTexture:(id<MTLTexture>)texture
       toReadbackUsing:(id<MTLCommandBuffer>)cb {
  if (_readback.width == texture.width && _readback.height == texture.height) {
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:texture
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(texture.width, texture.height, 1)
                toTexture:_readback
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    return;
  }
  [_downscaler encodeToCommandBuffer:cb
                       sourceTexture:texture
                  destinationTexture:_readback];
}

/// Blit `texture` into the shared-storage copy and hand back its bytes, or nil
/// for a texture this file cannot read. `bytesPerRow` is always `width * 4`.
- (NSData *)_readbackBytesForTexture:(id<MTLTexture>)texture
                              device:(id<MTLDevice>)device {
  if (![self _ensureReadbackForTexture:texture device:device])
    return nil;
  id<MTLCommandBuffer> cb = [_queue commandBuffer];
  [self _encodeTexture:texture toReadbackUsing:cb];
  [cb commit];
  [cb waitUntilCompleted];

  NSUInteger w = _readback.width, h = _readback.height;
  NSMutableData *data = [NSMutableData dataWithLength:w * 4 * h];
  if (!data)
    return nil;
  [_readback getBytes:data.mutableBytes
          bytesPerRow:w * 4
           fromRegion:MTLRegionMake2D(0, 0, w, h)
          mipmapLevel:0];
  return data;
}

- (NSArray<NSNumber *> *)probeTexture:(id<MTLTexture>)texture
                               device:(id<MTLDevice>)device
                                 atUV:(NSPoint)uv {
  if (!texture || !device || texture.width == 0 || texture.height == 0)
    return nil;
  NSUInteger rIdx = 0, bIdx = 2;
  if (!MirageScopeChannelOrder(texture, &rIdx, &bIdx)) {
    KKLogWarn(@"[Pick] unsupported source format %lu, nothing to sample",
              (unsigned long)texture.pixelFormat);
    return nil;
  }
  NSData *data = [self _readbackBytesForTexture:texture device:device];
  if (!data)
    return nil;
  double coded[3] = {0.0, 0.0, 0.0};
  if (!MirageAveragePatch(data.bytes, _readback.width, _readback.height,
                          _readback.width * 4, rIdx, bIdx, uv, NULL, coded))
    return nil;
  return @[ @(coded[0]), @(coded[1]), @(coded[2]) ];
}

/// Everything a measurement needs beyond the pixels, taken from the sampler at
/// the moment it is asked.
///
/// Snapshotted into a struct rather than read off `self` inside the walk,
/// because the walk can be happening on another thread by then: the properties
/// belong to the main thread, and a pick moved mid-measurement must describe
/// the NEXT reading, not silently change what this one was measuring.
typedef struct {
  NSUInteger binCount;
  double minStop;
  double maxStop;
  NSRect region;
  NSPoint pickUV;
  NSPoint probeUV;
  MirageMemoryColor declaration;
  NSUInteger rIdx;
  NSUInteger bIdx;
} MirageScopeReadParams;

static MirageScopeReadParams
MirageScopeParamsFor(MirageScopeSampler *sampler, NSUInteger binCount,
                     double minStop, double maxStop, NSUInteger rIdx,
                     NSUInteger bIdx) {
  MirageScopeReadParams p = {0};
  p.binCount = binCount;
  p.minStop = minStop;
  p.maxStop = maxStop;
  // Sanitised here, not trusted from the property: a caller can set it before
  // the preview has been laid out, and a rect that is not a region has to read
  // as the whole frame rather than as a very small zoom.
  p.region = MirageScopeSanitisedVisibleRect(sampler.visibleUVRect);
  p.pickUV = sampler.pickUV;
  p.probeUV = sampler.probeUV;
  p.declaration = sampler.pickDeclaration;
  p.rIdx = rIdx;
  p.bIdx = bIdx;
  return p;
}

/// The measurement itself: bins in, reading out, nothing of the sampler's
/// touched. Pure, so it is safe to run wherever the caller can afford it.
static MirageScopeReading *
MirageScopeReadingFromBytes(NSData *data, NSUInteger w, NSUInteger h,
                            MirageScopeReadParams p) {
  NSUInteger binCount = p.binCount;
  NSUInteger rIdx = p.rIdx, bIdx = p.bIdx;
  NSUInteger bytesPerRow = w * 4;
  // Stride both axes so the sample stays spread across the frame. Sampling the
  // first N rows would measure the sky and call it the image.
  NSUInteger total = w * h;
  NSUInteger stride = total > kMaxSamples
                          ? (NSUInteger)ceil(sqrt((double)total / kMaxSamples))
                          : 1;
  const uint8_t *bytes = data.bytes;
  NSRect region = p.region;
  NSUInteger chromaCount = kChromaAngleBins * kChromaRadiusBins;
  BOOL wantScoped = !MirageScopeRectIsFullFrame(region);
  MirageScopeBinSet binSet;
  if (!MirageScopeBinsAlloc(&binSet, binCount, chromaCount, wantScoped))
    return nil;
  if (wantScoped && !binSet.scoped)
    KKLogWarn(@"[Grading] the visible-region bins could not be allocated, "
              @"measuring the whole frame");
  MirageScopeAccumulator acc = {
      .toneBins = binSet.tone,
      .toneVisibleBins = binSet.toneVisible,
      .binCount = binCount,
      .minStop = p.minStop,
      .maxStop = p.maxStop,
      .chromaBins = binSet.chroma,
      .chromaVisibleBins = binSet.chromaVisible,
      .angleBins = kChromaAngleBins,
      .radiusBins = kChromaRadiusBins,
      .visibleRect = region,
  };
  // ONE pass. The pixel that lands in the visible rect increments its bin in
  // both sets as it is read, so the zoomed scope costs the same single readback
  // the unzoomed one does.
  MirageScopeAccumulateStrided(&acc, bytes, w, h, bytesPerRow, stride, rIdx,
                               bIdx);

  NSArray<NSNumber *> *out = MirageScopeBoxBins(binSet.tone, binCount);
  NSArray<NSNumber *> *chromaOut =
      MirageScopeBoxBins(binSet.chroma, chromaCount);
  NSArray<NSNumber *> *outVis =
      MirageScopeBoxBins(binSet.toneVisible, binCount);
  NSArray<NSNumber *> *chromaVisOut =
      MirageScopeBoxBins(binSet.chromaVisible, chromaCount);
  NSUInteger counted = acc.counted, over = acc.over;
  BOOL scoped = binSet.scoped;
  // A zoom so tight that the stride steps over the whole region leaves nothing
  // to draw. The full-frame set is still honest, so the reading falls back to
  // it rather than showing an empty bright layer over a ghost.
  if (scoped && acc.visibleCounted == 0) {
    scoped = NO;
    outVis = nil;
    chromaVisOut = nil;
  }
  MirageScopeBinsFree(&binSet);

  MirageScopeReading *reading = [MirageScopeReading new];
  reading.toneBins = out;
  reading.chromaBins = chromaOut;
  reading.chromaAngleBins = kChromaAngleBins;
  reading.chromaRadiusBins = kChromaRadiusBins;
  reading.toneBinsVisible = outVis;
  reading.chromaBinsVisible = chromaVisOut;
  reading.regionScoped = scoped;

  // The picked reference: average a small patch so noise and compression
  // blocking do not decide the reading.
  double picked[3] = {0.0, 0.0, 0.0};
  if (MirageAveragePatch(bytes, w, h, bytesPerRow, rIdx, bIdx, p.pickUV, picked,
                         NULL)) {
    reading.chromaCast = MirageScopeCastMarker(picked, p.declaration);
    // Everything on the circle reads the SAME region. A cross measured from a
    // patch the zoomed preview no longer shows would sit on a cloud binned from
    // pixels it has nothing to do with, and one circle would be saying two
    // things at once. Withdrawing it is the honest answer - the reference has
    // scrolled out of the picture - and castAvailable already means exactly
    // that.
    reading.castAvailable = !scoped || MirageScopeUVInRect(p.pickUV, region);
  }

  double probed[3] = {0.0, 0.0, 0.0};
  if (MirageAveragePatch(bytes, w, h, bytesPerRow, rIdx, bIdx, p.probeUV, NULL,
                         probed))
    reading.probedRGB = @[ @(probed[0]), @(probed[1]), @(probed[2]) ];

  reading.sampleCount = counted;
  reading.overRange = counted ? (double)over / (double)counted : 0.0;
  return reading;
}

/// The two checks every measurement starts with, answered once: whether there
/// is anything readable here at all, and in which byte order.
- (BOOL)_canMeasure:(id<MTLTexture>)texture
             device:(id<MTLDevice>)device
           binCount:(NSUInteger)binCount
            minStop:(double)minStop
            maxStop:(double)maxStop
               rIdx:(NSUInteger *)rIdx
               bIdx:(NSUInteger *)bIdx {
  if (!texture || !device || binCount == 0 || maxStop <= minStop)
    return NO;
  if (texture.width == 0 || texture.height == 0)
    return NO;
  // Only the display-coded 8-bit formats the mini viewer produces.
  if (!MirageScopeChannelOrder(texture, rIdx, bIdx)) {
    KKLogWarn(@"[Grading] unsupported preview format %lu, no measurement",
              (unsigned long)texture.pixelFormat);
    return NO;
  }
  return YES;
}

- (MirageScopeReading *)readTexture:(id<MTLTexture>)texture
                             device:(id<MTLDevice>)device
                           binCount:(NSUInteger)binCount
                            minStop:(double)minStop
                            maxStop:(double)maxStop {
  NSUInteger rIdx = 0, bIdx = 2;
  if (![self _canMeasure:texture
                  device:device
                binCount:binCount
                 minStop:minStop
                 maxStop:maxStop
                    rIdx:&rIdx
                    bIdx:&bIdx])
    return nil;
  NSData *data = [self _readbackBytesForTexture:texture device:device];
  if (!data)
    return nil;
  return MirageScopeReadingFromBytes(
      data, _readback.width, _readback.height,
      MirageScopeParamsFor(self, binCount, minStop, maxStop, rIdx, bIdx));
}

- (void)readTextureAsync:(id<MTLTexture>)texture
                  device:(id<MTLDevice>)device
                binCount:(NSUInteger)binCount
                 minStop:(double)minStop
                 maxStop:(double)maxStop
              completion:(void (^)(MirageScopeReading *))completion {
  if (!completion)
    return;
  NSUInteger rIdx = 0, bIdx = 2;
  if (![self _canMeasure:texture
                  device:device
                binCount:binCount
                 minStop:minStop
                 maxStop:maxStop
                    rIdx:&rIdx
                    bIdx:&bIdx]) {
    completion(nil);
    return;
  }
  // One at a time. The readback texture is a single shared copy, so a second
  // measurement started while the first is still being walked would be blitting
  // over the pixels it is reading - and there is nothing to gain from two
  // answers about frames 16ms apart anyway.
  if (_readInFlight) {
    completion(nil);
    return;
  }
  if (![self _ensureReadbackForTexture:texture device:device]) {
    completion(nil);
    return;
  }
  if (!_analysisQueue)
    _analysisQueue = dispatch_queue_create("co.overpolish.mirage.scope",
                                           DISPATCH_QUEUE_SERIAL);
  MirageScopeReadParams params =
      MirageScopeParamsFor(self, binCount, minStop, maxStop, rIdx, bIdx);
  _readInFlight = YES;
  id<MTLCommandBuffer> cb = [_queue commandBuffer];
  [self _encodeTexture:texture toReadbackUsing:cb];
  __weak typeof(self) weak = self;
  [cb addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
    // Back to the main thread for the COPY only: the readback texture is the
    // sampler's, and the sampler belongs to the main thread. The copy is a
    // memcpy of a preview-sized frame; the walk over it is what is worth
    // moving, and that is the hop below.
    MirageScopePerformOnMainRunLoop(^{
      __strong typeof(weak) s = weak;
      if (!s) {
        completion(nil);
        return;
      }
      NSUInteger w = s->_readback.width, h = s->_readback.height;
      NSMutableData *data = [NSMutableData dataWithLength:w * 4 * h];
      if (!data) {
        s->_readInFlight = NO;
        completion(nil);
        return;
      }
      [s->_readback getBytes:data.mutableBytes
                 bytesPerRow:w * 4
                  fromRegion:MTLRegionMake2D(0, 0, w, h)
                 mipmapLevel:0];
      dispatch_async(s->_analysisQueue, ^{
        MirageScopeReading *reading =
            MirageScopeReadingFromBytes(data, w, h, params);
        MirageScopePerformOnMainRunLoop(^{
          __strong typeof(weak) inner = weak;
          if (inner)
            inner->_readInFlight = NO;
          completion(reading);
        });
      });
    });
  }];
  // No wait: the whole point is that the main thread leaves here immediately.
  [cb commit];
}

@end
