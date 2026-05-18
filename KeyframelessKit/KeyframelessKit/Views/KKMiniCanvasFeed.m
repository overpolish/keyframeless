/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMiniCanvasFeed.h"

#import "KKLog.h"
#import <IOSurface/IOSurface.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>

// Long-edge cap for the preview surface. _computeDst never upscales, so a
// ≤2048 source is cached at native res (crisp when zoomed); larger sources
// (4K+) are bounded here to keep the persistent IOSurface ~9MB and the
// throttled (≤10fps) MPS pass cheap.
static const NSUInteger kTargetLongEdge = 2048;

// Minimum wall-clock gap between surface updates. The mini canvas only needs
// a recent frame, not every render tick — this keeps the render path from
// paying an MPS pass on every frame during playback.
static const NSTimeInterval kMinUpdateInterval = 0.1;

@implementation KKMiniCanvasFeed {
  NSString *_descriptorPath;
  IOSurfaceRef _surface;
  id<MTLTexture> _surfaceTexture;
  MPSImageBilinearScale *_scaler;
  NSUInteger _srcW, _srcH;
  NSUInteger _dstW, _dstH;
  uint64_t _generation;
  NSTimeInterval _lastUpdate;
}

- (instancetype)initWithDescriptorPath:(NSString *)descriptorPath {
  self = [super init];
  if (self)
    _descriptorPath = [descriptorPath copy];
  return self;
}

- (void)dealloc {
  if (_surface)
    CFRelease(_surface);
}

- (void)_computeDstForSrcW:(NSUInteger)sw h:(NSUInteger)sh {
  NSUInteger longEdge = MAX(sw, sh);
  double scale =
      longEdge > 0 ? (double)kTargetLongEdge / (double)longEdge : 1.0;
  if (scale > 1.0)
    scale = 1.0; // never upscale a small source
  NSUInteger w = (NSUInteger)lround((double)sw * scale);
  NSUInteger h = (NSUInteger)lround((double)sh * scale);
  _dstW = MAX(w & ~1u, 2u); // keep even
  _dstH = MAX(h & ~1u, 2u);
}

- (BOOL)_ensureSurfaceForDevice:(id<MTLDevice>)device
                           srcW:(NSUInteger)sw
                           srcH:(NSUInteger)sh {
  if (_surfaceTexture && sw == _srcW && sh == _srcH)
    return YES;

  [self _computeDstForSrcW:sw h:sh];

  _surfaceTexture = nil;
  if (_surface) {
    CFRelease(_surface);
    _surface = NULL;
  }

  size_t bpr = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, _dstW * 4);
  NSDictionary *props = @{
    (id)kIOSurfaceWidth : @(_dstW),
    (id)kIOSurfaceHeight : @(_dstH),
    (id)kIOSurfaceBytesPerElement : @4,
    (id)kIOSurfaceBytesPerRow : @(bpr),
    (id)kIOSurfacePixelFormat : @((uint32_t)'BGRA'),
  };
  _surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
  if (!_surface) {
    KKLogError(@"KKMiniCanvasFeed: IOSurfaceCreate failed (%lux%lu)",
               (unsigned long)_dstW, (unsigned long)_dstH);
    return NO;
  }

  // FCP hands us a linear-light source. Writing through an _sRGB-typed
  // texture makes MPS gamma-encode on store, so the 8-bit surface holds
  // display-encoded values — KKMiniCanvasView reads them as plain BGRA8 and
  // shows them straight, matching the brightness FCP displays.
  MTLTextureDescriptor *td = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
                                   width:_dstW
                                  height:_dstH
                               mipmapped:NO];
  td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite |
             MTLTextureUsageRenderTarget;
  td.storageMode = MTLStorageModeShared;
  _surfaceTexture = [device newTextureWithDescriptor:td
                                           iosurface:_surface
                                               plane:0];
  if (!_surfaceTexture) {
    KKLogError(@"KKMiniCanvasFeed: newTextureWithDescriptor:iosurface: "
               @"returned nil");
    CFRelease(_surface);
    _surface = NULL;
    return NO;
  }

  _srcW = sw;
  _srcH = sh;
  return YES;
}

- (void)_publish {
  NSDictionary *desc = @{
    @"ioSurfaceID" : @((uint32_t)IOSurfaceGetID(_surface)),
    @"width" : @(_dstW),
    @"height" : @(_dstH),
    // Original media size, so a constants popover's crop size label can
    // show real pixel dimensions (the surface is a downscaled preview).
    @"srcWidth" : @(_srcW),
    @"srcHeight" : @(_srcH),
    @"generation" : @(_generation),
    @"ts" : @([NSDate timeIntervalSinceReferenceDate]),
  };
  NSData *json = [NSJSONSerialization dataWithJSONObject:desc
                                                 options:0
                                                   error:nil];
  if (![json writeToFile:_descriptorPath atomically:YES])
    KKLogWarn(@"KKMiniCanvasFeed: failed to write %@", _descriptorPath);
}

- (void)updateWithSourceTexture:(id<MTLTexture>)sourceTexture
                         device:(id<MTLDevice>)device
                   commandQueue:(id<MTLCommandQueue>)commandQueue {
  if (!sourceTexture || !device || !commandQueue)
    return;

  @synchronized(self) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - _lastUpdate < kMinUpdateInterval)
      return;

    NSUInteger sw = sourceTexture.width;
    NSUInteger sh = sourceTexture.height;
    if (sw == 0 || sh == 0)
      return;
    if (![self _ensureSurfaceForDevice:device srcW:sw srcH:sh])
      return;

    if (!_scaler)
      _scaler = [[MPSImageBilinearScale alloc] initWithDevice:device];

    id<MTLCommandBuffer> cb = [commandQueue commandBuffer];
    cb.label = @"KKMiniCanvasFeed";
    [_scaler encodeToCommandBuffer:cb
                     sourceTexture:sourceTexture
                destinationTexture:_surfaceTexture];

    _generation++;
    _lastUpdate = now;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull done) {
      @synchronized(self) {
        if (self->_surface)
          [self _publish];
      }
    }];
    [cb commit];
  }
}

@end
