/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "ShaderThumbnailRenderer.h"
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KeyframelessKit.h>
#import <Metal/Metal.h>
#import <simd/simd.h>

// A synthetic source for iChannel0: a smooth colour gradient with a soft radial
// so a shader that samples / distorts its input has something to show.
static id<MTLTexture> ShaderTestPatternTexture(id<MTLDevice> device,
                                               NSUInteger w, NSUInteger h) {
  MTLTextureDescriptor *d = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:w
                                  height:h
                               mipmapped:NO];
  d.usage = MTLTextureUsageShaderRead;
  d.storageMode = MTLStorageModeShared;
  id<MTLTexture> tex = [device newTextureWithDescriptor:d];
  if (!tex)
    return nil;
  uint8_t *bytes = (uint8_t *)malloc(w * h * 4);
  for (NSUInteger y = 0; y < h; y++) {
    for (NSUInteger x = 0; x < w; x++) {
      double u = (double)x / (double)MAX((NSUInteger)1, w - 1);
      double v = (double)y / (double)MAX((NSUInteger)1, h - 1);
      double du = u - 0.5, dv = v - 0.5;
      double rad = 1.0 - MIN(1.0, sqrt(du * du + dv * dv) * 1.6);
      double r = u * 0.9 + 0.1 * rad;
      double g = v * 0.9 + 0.1 * rad;
      double b = (0.5 + 0.5 * sin(u * 6.2831 + v * 3.14)) * 0.8 + 0.2 * rad;
      uint8_t *p = &bytes[(y * w + x) * 4];
      p[0] = (uint8_t)(MIN(1.0, b) * 255.0); // B
      p[1] = (uint8_t)(MIN(1.0, g) * 255.0); // G
      p[2] = (uint8_t)(MIN(1.0, r) * 255.0); // R
      p[3] = 255;
    }
  }
  [tex replaceRegion:MTLRegionMake2D(0, 0, w, h)
         mipmapLevel:0
           withBytes:bytes
         bytesPerRow:w * 4];
  free(bytes);
  return tex;
}

static NSData *ShaderPNGFromTexture(id<MTLTexture> tex) {
  NSUInteger w = tex.width, h = tex.height, bpr = w * 4;
  uint8_t *bytes = (uint8_t *)malloc(h * bpr);
  [tex getBytes:bytes
      bytesPerRow:bpr
       fromRegion:MTLRegionMake2D(0, 0, w, h)
      mipmapLevel:0];
  // BGRA -> RGBA for NSBitmapImageRep.
  for (NSUInteger i = 0; i < w * h; i++) {
    uint8_t b = bytes[i * 4], r = bytes[i * 4 + 2];
    bytes[i * 4] = r;
    bytes[i * 4 + 2] = b;
  }
  NSBitmapImageRep *rep =
      [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                              pixelsWide:w
                                              pixelsHigh:h
                                           bitsPerSample:8
                                         samplesPerPixel:4
                                                hasAlpha:YES
                                                isPlanar:NO
                                          colorSpaceName:NSDeviceRGBColorSpace
                                             bytesPerRow:bpr
                                            bitsPerPixel:32];
  // Flip vertically. The shader renders y-up (the fragCoord convention; the
  // flipY in kkExtra.z stays off because FCP's destination is itself
  // reverse-Y), while NSBitmapImageRep wants row 0 at the TOP. The
  // mini-viewer's on-screen path absorbs that in its draw transform - a raw
  // readback like this one has to do it here, or every thumbnail comes out
  // upside down.
  uint8_t *dst = rep.bitmapData;
  for (NSUInteger y = 0; y < h; y++)
    memcpy(dst + y * bpr, bytes + (h - 1 - y) * bpr, bpr);
  free(bytes);
  return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

NSData *ShaderRenderThumbnailPNG(KKMiniViewerRenderer *renderer, NSUInteger w,
                                 NSUInteger h) {
  if (!renderer || w == 0 || h == 0)
    return nil;
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  if (!device)
    return nil;

  MTLTextureDescriptor *dd = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:w
                                  height:h
                               mipmapped:NO];
  dd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  dd.storageMode = MTLStorageModeShared;
  id<MTLTexture> dest = [device newTextureWithDescriptor:dd];
  id<MTLTexture> source = ShaderTestPatternTexture(device, w, h);
  if (!dest || !source)
    return nil;

  id<MTLCommandQueue> queue = [device newCommandQueue];
  id<MTLCommandBuffer> cb = [queue commandBuffer];
  if (![renderer encodeEffectFromSource:source into:dest commandBuffer:cb])
    return nil;
  [cb commit];
  [cb waitUntilCompleted];
  return ShaderPNGFromTexture(dest);
}
