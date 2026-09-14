/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasThumbnailBake.h"

#import "CanvasLayerTree.h" // CanvasLayerPathWithAncestors
#import "CanvasMiniViewerRenderer_Internal.h"
#import <AppKit/AppKit.h>

// An opaque black stand-in source when the feed has no frame yet (the clip has
// never rendered in this session), so the layers still bake over the same
// background the mini shows for a missing source.
static id<MTLTexture> CanvasThumbBlackSource(id<MTLDevice> device) {
  MTLTextureDescriptor *d = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:16
                                  height:16
                               mipmapped:NO];
  d.usage = MTLTextureUsageShaderRead;
  d.storageMode = MTLStorageModeShared;
  id<MTLTexture> tex = [device newTextureWithDescriptor:d];
  if (!tex)
    return nil;
  uint8_t bytes[16 * 16 * 4];
  for (NSUInteger i = 0; i < sizeof(bytes); i += 4) {
    bytes[i] = bytes[i + 1] = bytes[i + 2] = 0;
    bytes[i + 3] = 255;
  }
  [tex replaceRegion:MTLRegionMake2D(0, 0, 16, 16)
         mipmapLevel:0
           withBytes:bytes
         bytesPerRow:16 * 4];
  return tex;
}

// BGRA texture -> JPEG, alpha pinned opaque (JPEG has no alpha; the output is
// premultiplied so empty pixels flatten to black, matching the mini's
// background). Rows are copied REVERSED: the composite draws in the mini's
// y-up canvas convention, so a straight readback comes out upside down.
static NSData *CanvasThumbJPEGFromTexture(id<MTLTexture> tex) {
  NSUInteger w = tex.width, h = tex.height, bpr = w * 4;
  uint8_t *bytes = (uint8_t *)malloc(h * bpr);
  if (!bytes)
    return nil;
  [tex getBytes:bytes
      bytesPerRow:bpr
       fromRegion:MTLRegionMake2D(0, 0, w, h)
      mipmapLevel:0];
  for (NSUInteger i = 0; i < w * h; i++) {
    uint8_t *p = &bytes[i * 4];
    uint8_t b = p[0];
    p[0] = p[2];
    p[2] = b;
    p[3] = 255;
  }
  NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
      initWithBitmapDataPlanes:NULL
                    pixelsWide:(NSInteger)w
                    pixelsHigh:(NSInteger)h
                 bitsPerSample:8
               samplesPerPixel:4
                      hasAlpha:YES
                      isPlanar:NO
                colorSpaceName:NSDeviceRGBColorSpace
                   bytesPerRow:(NSInteger)bpr
                  bitsPerPixel:32];
  if (rep)
    for (NSUInteger y = 0; y < h; y++)
      memcpy(rep.bitmapData + y * bpr, bytes + (h - 1 - y) * bpr, bpr);
  free(bytes);
  if (!rep)
    return nil;
  return [rep representationUsingType:NSBitmapImageFileTypeJPEG
                           properties:@{
                             NSImageCompressionFactor : @(0.85)
                           }];
}

NSData *CanvasRenderThumbnailJPEG(CanvasMiniViewerRenderer *renderer,
                                  NSUInteger w, NSUInteger h,
                                  id<MTLTexture> source,
                                  NSString *onlyLayerID) {
  if (!renderer || w == 0 || h == 0)
    return nil;
  id<MTLDevice> device = source.device ?: MTLCreateSystemDefaultDevice();
  if (!device)
    return nil;
  if (!source)
    source = CanvasThumbBlackSource(device);
  if (!source)
    return nil;

  MTLTextureDescriptor *dd = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:w
                                  height:h
                               mipmapped:NO];
  dd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  dd.storageMode = MTLStorageModeShared;
  id<MTLTexture> dest = [device newTextureWithDescriptor:dd];
  if (!dest)
    return nil;

  // Pin the poster to fraction 0.5 and (optionally) isolate one layer; the
  // live values are restored after the synchronous encode, so the on-screen
  // preview never sees them.
  double savedEdit = renderer.editFraction;
  NSArray<KKBezierPath *> *savedLayers = renderer.layers;
  float savedStrokeScale = renderer.strokeScaleOverride;
  KKBezierPath *unhidden = nil;
  renderer.editFraction = 0.5;
  // Stroke widths are authored in canonical (full-output) px; this bake's
  // dest is far smaller, so scale them down proportionally - the same
  // correction the main render applies for FCP browser thumbnails. The black
  // fallback source (16px) is not the canonical frame, so leave 1.0 there.
  if (source.width >= 64)
    renderer.strokeScaleOverride = (float)w / (float)source.width;
  if (onlyLayerID.length) {
    NSUInteger targetIdx = NSNotFound;
    for (NSUInteger i = 0; i < savedLayers.count; i++)
      if ([savedLayers[i].layerID isEqualToString:onlyLayerID]) {
        targetIdx = i;
        break;
      }
    if (targetIdx == NSNotFound) {
      renderer.editFraction = savedEdit;
      renderer.strokeScaleOverride = savedStrokeScale;
      return nil;
    }
    KKBezierPath *target = savedLayers[targetIdx];
    if (target.hidden) {
      target.hidden = NO; // show the layer being pictured
      unhidden = target;
    }
    if (target.isGroup) {
      // A group's portrait is its members: ancestors + the group row + every
      // nested descendant, in stack order, so the group transform composes
      // and members keep their z-order. Individually-hidden members stay
      // hidden - the thumbnail shows what the group shows.
      NSMutableIndexSet *keep = [NSMutableIndexSet indexSet];
      [keep addIndexes:CanvasLayerAncestorIndices(targetIdx, savedLayers)];
      [keep addIndex:targetIdx];
      [keep addIndexes:CanvasLayerDescendantIndices(targetIdx, savedLayers)];
      NSMutableArray<KKBezierPath *> *sub =
          [NSMutableArray arrayWithCapacity:keep.count];
      [keep enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
        [sub addObject:savedLayers[i]];
      }];
      renderer.layers = sub;
    } else {
      renderer.layers = CanvasLayerPathWithAncestors(target, savedLayers);
    }
  }

  NSData *jpeg = nil;
  id<MTLCommandQueue> queue = [device newCommandQueue];
  id<MTLCommandBuffer> cb = [queue commandBuffer];
  if (cb && [renderer encodeEffectFromSource:source into:dest
                               commandBuffer:cb]) {
    [cb commit];
    [cb waitUntilCompleted];
    jpeg = CanvasThumbJPEGFromTexture(dest);
  }

  renderer.editFraction = savedEdit;
  renderer.layers = savedLayers;
  renderer.strokeScaleOverride = savedStrokeScale;
  if (unhidden)
    unhidden.hidden = YES;
  return jpeg;
}
