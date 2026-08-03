/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageThumbnailRenderer.h"
#import "MirageMiniViewerRenderer.h"
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KeyframelessKit.h>
#import <Metal/Metal.h>
#import <simd/simd.h>

// A bundled reference frame for iChannel0 (a real photo: faces, saturated
// colour, fine texture, brick/textile detail) so a filter that samples /
// distorts its input previews on genuine detail instead of a flat gradient - a
// smooth gradient hides displacement / chroma-shift / glitch entirely. Decoded
// into sRGB-encoded 8-bit BGRA, the same gamma-encoded convention as the
// gradient fallback (iChannel0 is sampled as gamma-encoded). Returns nil if the
// asset is missing / undecodable, so the caller falls back to the gradient.
static id<MTLTexture> MiragePreviewSourceTexture(id<MTLDevice> device) {
  NSBundle *bundle =
      [NSBundle bundleForClass:NSClassFromString(@"MiragePlugin")];
  NSURL *url = [bundle URLForResource:@"PreviewSource" withExtension:@"jpg"];
  if (!url)
    return nil;
  NSImage *img = [[NSImage alloc] initWithContentsOfURL:url];
  CGImageRef cg = [img CGImageForProposedRect:NULL context:nil hints:nil];
  if (!cg)
    return nil;
  NSUInteger w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
  if (w == 0 || h == 0)
    return nil;
  uint8_t *bytes = (uint8_t *)calloc(w * h * 4, 1);
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  // Top-row-first (flip the default bottom-left CG origin) so the photo reads
  // upright through the render + readback flip. If a thumbnail comes out
  // upside down, drop the translate/scale pair below.
  CGContextRef ctx = CGBitmapContextCreate(
      bytes, w, h, 8, w * 4, cs,
      (uint32_t)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
  CGColorSpaceRelease(cs);
  if (!ctx) {
    free(bytes);
    return nil;
  }
  CGContextTranslateCTM(ctx, 0, h);
  CGContextScaleCTM(ctx, 1, -1);
  CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
  CGContextRelease(ctx);

  MTLTextureDescriptor *d = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:w
                                  height:h
                               mipmapped:NO];
  d.usage = MTLTextureUsageShaderRead;
  d.storageMode = MTLStorageModeShared;
  id<MTLTexture> tex = [device newTextureWithDescriptor:d];
  if (tex)
    [tex replaceRegion:MTLRegionMake2D(0, 0, w, h)
           mipmapLevel:0
             withBytes:bytes
           bytesPerRow:w * 4];
  free(bytes);
  return tex;
}

// A synthetic source for iChannel0: a smooth colour gradient with a soft radial
// so a shader that samples / distorts its input has something to show. Fallback
// when the bundled reference frame is unavailable.
static id<MTLTexture> MirageTestPatternTexture(id<MTLDevice> device,
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

static NSData *MirageJPEGFromTexture(id<MTLTexture> tex) {
  NSUInteger w = tex.width, h = tex.height, bpr = w * 4;
  uint8_t *bytes = (uint8_t *)malloc(h * bpr);
  [tex getBytes:bytes
      bytesPerRow:bpr
       fromRegion:MTLRegionMake2D(0, 0, w, h)
      mipmapLevel:0];
  // BGRA -> RGBA for NSBitmapImageRep, and force alpha opaque. JPEG has no
  // alpha, so a transparent region would otherwise flatten over WHITE. The
  // output is premultiplied, so pinning alpha=255 reads the RGB as an
  // over-BLACK composite - empty pixels come out black, matching the
  // mini-viewer's background.
  for (NSUInteger i = 0; i < w * h; i++) {
    uint8_t b = bytes[i * 4], r = bytes[i * 4 + 2];
    bytes[i * 4] = r;
    bytes[i * 4 + 2] = b;
    bytes[i * 4 + 3] = 255;
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
  // JPEG, not PNG. Mirage previews are smooth gradients - the worst case for
  // PNG's lossless run-length coding, which leaves them near 80KB. They're
  // opaque composites over an opaque test source, so alpha is moot, and JPEG at
  // 0.8 lands them near 10KB with no visible loss at thumbnail size.
  return [rep representationUsingType:NSBitmapImageFileTypeJPEG
                           properties:@{
                             NSImageCompressionFactor : @0.8
                           }];
}

// Re-render the effect fresh into a `w`x`h` JPEG at the renderer's CURRENT
// uniform state. `providedSource` is the iChannel0 texture (this clip's real
// footage from the mini feed); nil falls back to the bundled reference frame
// (test pattern as a last resort - fine for generators, which ignore
// iChannel0).
static NSData *MirageThumbReRender(KKMiniViewerRenderer *renderer, NSUInteger w,
                                   NSUInteger h,
                                   id<MTLTexture> providedSource) {
  id<MTLDevice> device =
      providedSource.device ?: MTLCreateSystemDefaultDevice();
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
  id<MTLTexture> source = providedSource;
  if (!source)
    source = MiragePreviewSourceTexture(device);
  if (!source)
    source = MirageTestPatternTexture(device, w, h);
  if (!dest || !source)
    return nil;
  id<MTLCommandQueue> queue = [device newCommandQueue];
  id<MTLCommandBuffer> cb = [queue commandBuffer];
  if (![renderer encodeEffectFromSource:source into:dest commandBuffer:cb])
    return nil;
  [cb commit];
  [cb waitUntilCompleted];
  return MirageJPEGFromTexture(dest);
}

NSData *MirageRenderThumbnailJPEG(KKMiniViewerRenderer *renderer, NSUInteger w,
                                  NSUInteger h) {
  if (!renderer || w == 0 || h == 0)
    return nil;

  // Primary path: capture the already-rendered FINAL frame the mini-viewer is
  // displaying, rather than re-running the shader. That frame is the true
  // composited result on real footage / audio / "To" well, so transitions,
  // picture-in-picture layouts and audio visualisers thumbnail correctly.
  // Blit-scale it (keeping its aspect) into a shared target we can read back.
  // ...except on a trial, where that frame carries the baked watermark. A
  // template a trial user authors must not ship a watermarked card, so re-run
  // the effect on the SAME real footage instead - the watermark lives above
  // -encodeEffectFromSource:, so this comes out clean.
  if (!KKLicenseIsActivated(KKLicenseProductMirage))
    return MirageThumbReRender(renderer, w, h, renderer.canvas.sourceTexture);

  id<MTLTexture> finalFrame = renderer.canvas.processedTexture;
  if (finalFrame && [renderer isKindOfClass:[MirageMiniViewerRenderer class]]) {
    id<MTLDevice> cd = finalFrame.device;
    NSUInteger fw = MAX((NSUInteger)1, finalFrame.width);
    NSUInteger fh = MAX((NSUInteger)1, finalFrame.height);
    NSUInteger tw = w;
    NSUInteger th =
        MAX((NSUInteger)1, (NSUInteger)llround((double)w * (double)fh / fw));
    MTLTextureDescriptor *cdd = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:tw
                                    height:th
                                 mipmapped:NO];
    cdd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    cdd.storageMode = MTLStorageModeShared;
    id<MTLTexture> cdest = [cd newTextureWithDescriptor:cdd];
    if (cdest) {
      id<MTLCommandQueue> cq = [cd newCommandQueue];
      id<MTLCommandBuffer> ccb = [cq commandBuffer];
      [(MirageMiniViewerRenderer *)renderer blitFrom:finalFrame
                                                into:cdest
                                       commandBuffer:ccb];
      [ccb commit];
      [ccb waitUntilCompleted];
      return MirageJPEGFromTexture(cdest);
    }
  }

  // Fallback (no rendered frame yet, e.g. authoring off a clip): re-render on a
  // bundled reference frame at the renderer's live state.
  return MirageThumbReRender(renderer, w, h, nil);
}

NSData *MirageRenderThumbnailJPEGFromSource(KKMiniViewerRenderer *renderer,
                                            NSUInteger w, NSUInteger h,
                                            id<MTLTexture> source) {
  if (!renderer || w == 0 || h == 0)
    return nil;
  // Deterministic poster on the clip's REAL source: pin the renderer to
  // fraction 0.5 (iTime <- editFraction, iProgress <- playheadFraction, link
  // refs <- clipStart+0.5*dur), re-render on `source` (this clip's footage from
  // the mini feed; nil = bundled reference for generators), then restore the
  // live values. Runs synchronously on the main thread, so the live preview is
  // untouched.
  double savedEdit = renderer.editFraction;
  double savedLink = renderer.linkTimelineSec;
  double dur = renderer.clipDurationSeconds;
  double start = renderer.clipTimelineStartSec;
  BOOL isShader = [renderer isKindOfClass:[MirageMiniViewerRenderer class]];
  double savedPlay =
      isShader ? ((MirageMiniViewerRenderer *)renderer).playheadFraction : 0.0;

  renderer.editFraction = 0.5;
  if (isShader)
    ((MirageMiniViewerRenderer *)renderer).playheadFraction = 0.5;
  if (dur > 0.0 && start >= 0.0)
    renderer.linkTimelineSec = start + 0.5 * dur;

  NSData *jpeg = MirageThumbReRender(renderer, w, h, source);

  renderer.editFraction = savedEdit;
  renderer.linkTimelineSec = savedLink;
  if (isShader)
    ((MirageMiniViewerRenderer *)renderer).playheadFraction = savedPlay;
  return jpeg;
}
