/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKWatermark.h"
#import "KKLicense.h"
#import "KKLog.h"
#import "KKMetalDeviceCache.h"
#import "KKShaderTypes.h"
#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#import <FxPlug/FxPlugSDK.h>
#import <os/lock.h>

static NSString *const kKKWatermarkPipelineID = @"KKWatermark";
static NSString *const kKKWatermarkText = @"KEYFRAMELESS TRIAL";
static const CGFloat kKKWatermarkAngle = -30.0 * M_PI / 180.0;
static const float kKKWatermarkOpacity = 0.28f;

/// Draws the diagonal tiled watermark text into a premultiplied RGBA8 bitmap
/// and uploads it as a Metal texture. Size-dependent, so proxy/thumbnail
/// renders get proportionally sized text.
static id<MTLTexture> KKWatermarkTexture(id<MTLDevice> device, NSUInteger width,
                                         NSUInteger height) {
  CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(
      NULL, width, height, 8, width * 4, colorSpace,
      (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(colorSpace);
  if (!ctx)
    return nil;

  CGFloat fontSize = MAX(18.0, (CGFloat)width * 0.032);
  NSFont *font = [NSFont boldSystemFontOfSize:fontSize];
  NSDictionary *attrs = @{
    NSFontAttributeName : font,
    NSForegroundColorAttributeName : [NSColor whiteColor],
  };
  NSAttributedString *text =
      [[NSAttributedString alloc] initWithString:kKKWatermarkText
                                      attributes:attrs];
  CTLineRef line = CTLineCreateWithAttributedString(
      (__bridge CFAttributedStringRef)text);
  CGRect lineBounds = CTLineGetBoundsWithOptions(line, 0);

  CGContextSetShadowWithColor(
      ctx, CGSizeMake(0, -fontSize * 0.06), fontSize * 0.10,
      [[NSColor colorWithWhite:0 alpha:0.9] CGColor]);

  // Rotate around the frame center, then stamp the line on a grid wide
  // enough to cover the rotated frame's diagonal.
  CGContextTranslateCTM(ctx, width / 2.0, height / 2.0);
  CGContextRotateCTM(ctx, kKKWatermarkAngle);
  CGFloat diag = hypot((CGFloat)width, (CGFloat)height) / 2.0 + fontSize;
  CGFloat stepX = lineBounds.size.width + fontSize * 3.0;
  CGFloat stepY = fontSize * 5.0;
  NSInteger row = 0;
  for (CGFloat y = -diag; y <= diag; y += stepY, row++) {
    CGFloat phase = (row % 2) ? stepX / 2.0 : 0.0;
    for (CGFloat x = -diag - phase; x <= diag; x += stepX) {
      CGContextSetTextPosition(ctx, x, y);
      CTLineDraw(line, ctx);
    }
  }
  CFRelease(line);

  MTLTextureDescriptor *desc = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                   width:width
                                  height:height
                               mipmapped:NO];
  desc.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
  [texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
             mipmapLevel:0
               withBytes:CGBitmapContextGetData(ctx)
             bytesPerRow:CGBitmapContextGetBytesPerRow(ctx)];
  CGContextRelease(ctx);
  return texture;
}

/// Per-process texture cache (immutable contents; keyed by device + size so
/// proxy and full-res renders each keep one texture).
static id<MTLTexture> KKWatermarkCachedTexture(id<MTLDevice> device,
                                               NSUInteger width,
                                               NSUInteger height) {
  static NSMutableDictionary<NSString *, id<MTLTexture>> *cache;
  static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
  NSString *key = [NSString
      stringWithFormat:@"%llu_%lux%lu", device.registryID, (unsigned long)width,
                       (unsigned long)height];
  os_unfair_lock_lock(&lock);
  if (!cache)
    cache = [NSMutableDictionary dictionary];
  id<MTLTexture> texture = cache[key];
  os_unfair_lock_unlock(&lock);
  if (texture)
    return texture;

  texture = KKWatermarkTexture(device, width, height);
  if (!texture)
    return nil;
  os_unfair_lock_lock(&lock);
  if (cache.count > 8)
    [cache removeAllObjects];
  cache[key] = texture;
  os_unfair_lock_unlock(&lock);
  return texture;
}

/// `patternW/H` is the size the pattern is authored at (the full image), and
/// `uv*` the sub-rect of it this texture covers. Passing the texture's own size
/// with the unit rect draws the whole pattern.
static void KKWatermarkEncode(NSString *productID,
                              id<MTLCommandBuffer> commandBuffer,
                              id<MTLTexture> destTexture, NSUInteger patternW,
                              NSUInteger patternH, float uvL, float uvR,
                              float uvB, float uvT) {
  if (KKLicenseIsActivated(productID))
    return;
  if (!commandBuffer || !destTexture)
    return;

  id<MTLDevice> device = commandBuffer.device;
  id<MTLTexture> watermark =
      KKWatermarkCachedTexture(device, patternW, patternH);
  if (!watermark)
    return;

  KKMetalDeviceCache *deviceCache = [KKMetalDeviceCache sharedCache];
  id<MTLRenderPipelineState> pipeline = [deviceCache
      buildAndRegisterPipelineStateForPluginID:kKKWatermarkPipelineID
                                    registryID:device.registryID
                                   pixelFormat:destTexture.pixelFormat
                                      bundleID:[NSBundle
                                                   bundleForClass:
                                                       [KKMetalDeviceCache
                                                           class]]
                                                   .bundleIdentifier
                                  vertexShader:@"KKVertexShader"
                                fragmentShader:@"KKTextureOpacityFragment"
                                     blendMode:KKBlendModePremultipliedAlpha];
  if (!pipeline) {
    KKLogWarn(@"KKWatermark: no pipeline; skipping watermark");
    return;
  }

  MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = destTexture;
  pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> encoder =
      [commandBuffer renderCommandEncoderWithDescriptor:pass];
  if (!encoder)
    return;

  float halfW = destTexture.width / 2.0f;
  float halfH = destTexture.height / 2.0f;
  // FCP's destination surface is bottom-up, so v is NOT flipped here (the
  // usual CG-top-to-v0 flip would render the text upside down) and uvB is the
  // pattern row at the tile's BOTTOM edge.
  KKVertex2D vertices[4] = {
      {{-halfW, -halfH}, {uvL, uvB}},
      {{halfW, -halfH}, {uvR, uvB}},
      {{-halfW, halfH}, {uvL, uvT}},
      {{halfW, halfH}, {uvR, uvT}},
  };
  vector_uint2 viewport = {(uint)destTexture.width, (uint)destTexture.height};
  float opacity = kKKWatermarkOpacity;

  [encoder setRenderPipelineState:pipeline];
  [encoder setVertexBytes:vertices
                   length:sizeof(vertices)
                  atIndex:KKVertexInputIndex_Vertices];
  [encoder setVertexBytes:&viewport
                   length:sizeof(viewport)
                  atIndex:KKVertexInputIndex_ViewportSize];
  [encoder setFragmentTexture:watermark atIndex:KKTextureIndex_InputImage];
  [encoder setFragmentBytes:&opacity length:sizeof(opacity) atIndex:0];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
              vertexStart:0
              vertexCount:4];
  [encoder endEncoding];
}

void KKWatermarkEncodeIfUnlicensed(NSString *productID,
                                   id<MTLCommandBuffer> commandBuffer,
                                   id<MTLTexture> destTexture, BOOL topDown) {
  if (!destTexture)
    return;
  KKWatermarkEncode(productID, commandBuffer, destTexture, destTexture.width,
                    destTexture.height, 0.0f, 1.0f, topDown ? 1.0f : 0.0f,
                    topDown ? 0.0f : 1.0f);
}

void KKWatermarkEncodeIfUnlicensedForTile(NSString *productID,
                                          id<MTLCommandBuffer> commandBuffer,
                                          id<MTLTexture> destTexture,
                                          FxImageTile *destinationImage) {
  if (!destinationImage) {
    KKWatermarkEncodeIfUnlicensed(productID, commandBuffer, destTexture, NO);
    return;
  }
  // FCP splits a frame into tiles for expensive renders (and hands a sub-tile
  // when parent Scale > 100%). Sizing the pattern to the TILE stamped a
  // complete watermark into each one - two tiles read as two watermarks. Author
  // it against the full image and let each tile draw its own slice.
  FxRect tile = destinationImage.tilePixelBounds;
  FxRect img = destinationImage.imagePixelBounds;
  float imgW = (float)(img.right - img.left);
  float imgH = (float)(img.top - img.bottom);
  if (imgW <= 0.0f || imgH <= 0.0f) {
    KKWatermarkEncodeIfUnlicensed(productID, commandBuffer, destTexture, NO);
    return;
  }
  KKWatermarkEncode(productID, commandBuffer, destTexture, (NSUInteger)imgW,
                    (NSUInteger)imgH, (float)(tile.left - img.left) / imgW,
                    (float)(tile.right - img.left) / imgW,
                    (float)(tile.bottom - img.bottom) / imgH,
                    (float)(tile.top - img.bottom) / imgH);
}

void KKWatermarkApplyIfUnlicensed(NSString *productID,
                                  FxImageTile *destinationImage) {
  if (KKLicenseIsActivated(productID))
    return;
  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  id<MTLDevice> device =
      [cache deviceWithRegistryID:destinationImage.deviceRegistryID];
  id<MTLTexture> destTex = [destinationImage metalTextureForDevice:device];
  if (!device || !destTex)
    return;
  id<MTLCommandQueue> queue = [cache
      commandQueueWithRegistryID:destinationImage.deviceRegistryID
                     pixelFormat:[KKMetalDeviceCache
                                     pixelFormatForImageTile:destinationImage]];
  if (!queue)
    return;
  id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
  KKWatermarkEncodeIfUnlicensedForTile(productID, commandBuffer, destTex,
                                       destinationImage);
  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];
  [cache returnCommandQueueToCache:queue];
}
