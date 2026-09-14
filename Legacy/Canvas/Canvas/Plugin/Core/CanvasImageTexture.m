/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasImageTexture.h"
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKLog.h>

id<MTLTexture> CanvasImageTextureForPath(
    NSString *path, id<MTLDevice> device,
    NSMutableDictionary<NSString *, id<MTLTexture>> *cache) {
  if (path.length == 0 || !device)
    return nil;

  id<MTLTexture> cached = cache[path];
  if (cached && cached.device == device)
    return cached;

  NSImage *nsImage = [[NSImage alloc] initWithContentsOfFile:path];
  CGImageRef cg = [nsImage CGImageForProposedRect:NULL context:nil hints:nil];
  if (!cg) {
    KKLogWarn(@"Canvas: failed to decode image at %@", path);
    return nil;
  }

  size_t w = CGImageGetWidth(cg);
  size_t h = CGImageGetHeight(cg);
  if (w == 0 || h == 0)
    return nil;

  // Render into a known RGBA8 premultiplied-sRGB buffer. The CTM is flipped so
  // memory row 0 is the TOP of the image (Metal v=0 is the first row), giving
  // an upright texture for a standard top-left UV quad.
  size_t bytesPerRow = w * 4;
  NSMutableData *buf = [NSMutableData dataWithLength:bytesPerRow * h];
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(
      buf.mutableBytes, w, h, 8, bytesPerRow, cs,
      (CGBitmapInfo)((uint32_t)kCGImageAlphaPremultipliedLast |
                     (uint32_t)kCGBitmapByteOrder32Big));
  CGColorSpaceRelease(cs);
  if (!ctx)
    return nil;
  CGContextTranslateCTM(ctx, 0, h);
  CGContextScaleCTM(ctx, 1, -1);
  CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
  CGContextRelease(ctx);

  MTLTextureDescriptor *desc = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB
                                   width:w
                                  height:h
                               mipmapped:NO];
  desc.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> tex = [device newTextureWithDescriptor:desc];
  if (!tex)
    return nil;
  [tex replaceRegion:MTLRegionMake2D(0, 0, w, h)
         mipmapLevel:0
           withBytes:buf.bytes
         bytesPerRow:bytesPerRow];

  cache[path] = tex;
  return tex;
}
