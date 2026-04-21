/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC_Private.h"

@implementation CanvasOSC (DrawPreview)

- (BOOL)shouldShowBooleanPreview:(BOOL)isCursorMode {
  return isCursorMode && self.hoveredPathOp > 0 &&
         ((self.hoveredPathOp == kOSCPathOutline &&
           self.selectedPathIndices.count >= 1) ||
          (self.hoveredPathOp != kOSCPathOutline &&
           self.selectedPathIndices.count >= 2));
}

- (void)computeBooleanPreviewIfNeeded {
  if (self.previewCachedOp == self.hoveredPathOp)
    return;

  NSMutableArray<KKBezierPath *> *operands = [NSMutableArray array];
  [self.selectedPathIndices
      enumerateIndexesWithOptions:NSEnumerationReverse
                       usingBlock:^(NSUInteger idx, BOOL *stop) {
                         if (idx < self.paths.count &&
                             !self.paths[idx].isImage &&
                             !self.paths[idx].isGroup) {
                           [operands addObject:self.paths[idx]];
                         }
                       }];

  if (self.hoveredPathOp == kOSCPathOutline) {
    NSArray<KKBezierPath *> *outlines = KKPathStrokeToOutline(
        operands, (CGFloat)self.imageWidth, (CGFloat)self.imageHeight);
    self.previewResultPath = outlines.firstObject;
  } else if (operands.count >= 2) {
    KKBooleanOp op;
    if (self.hoveredPathOp == kOSCPathUnion)
      op = KKBooleanOpUnion;
    else if (self.hoveredPathOp == kOSCPathSubtract)
      op = KKBooleanOpSubtract;
    else if (self.hoveredPathOp == kOSCPathIntersect)
      op = KKBooleanOpIntersect;
    else
      op = KKBooleanOpXOR;
    self.previewResultPath = KKPathBooleanApply(operands, op);
  } else {
    self.previewResultPath = nil;
  }
  self.previewCachedOp = self.hoveredPathOp;
  self.previewTexture = nil;
}

- (CGMutablePathRef)canvasCGPathForPath:(KKBezierPath *)p {
  CGMutablePathRef cgp = CGPathCreateMutable();
  NSUInteger nc = p.contourCount;
  for (NSUInteger ci = 0; ci < nc; ci++) {
    NSRange r = [p contourRangeAtIndex:ci];
    NSUInteger cStart = r.location;
    NSUInteger cLen = r.length;
    if (cLen < 2)
      continue;
    NSUInteger segCount = p.closed ? cLen : (cLen - 1);
    for (NSUInteger i = 0; i < segCount; i++) {
      NSUInteger idx = cStart + i;
      NSUInteger nextIdx = cStart + ((i + 1) % cLen);
      for (NSUInteger s = 0; s <= 32; s++) {
        float t = (float)s / 32.0f;
        simd_float2 pos = [p evaluatePointAtIndex:idx nextIndex:nextIdx atT:t];
        CGPoint cp = [self canvasPointFromObjectPoint:pos];
        if (i == 0 && s == 0)
          CGPathMoveToPoint(cgp, NULL, cp.x, cp.y);
        else
          CGPathAddLineToPoint(cgp, NULL, cp.x, cp.y);
      }
    }
    if (p.closed)
      CGPathCloseSubpath(cgp);
  }
  return cgp;
}

- (void)renderPreviewTextureForSize:(NSInteger)pixelW
                             height:(NSInteger)pixelH
                   destinationImage:(FxImageTile *)destinationImage {
  if (self.previewTexture)
    return;

  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(
      NULL, pixelW, pixelH, 8, pixelW * 4, cs,
      (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(cs);
  if (!ctx)
    return;

  CGContextSetLineJoin(ctx, kCGLineJoinRound);
  CGContextSetLineCap(ctx, kCGLineCapRound);

  // Red tint: selected paths (will be removed).
  [self.selectedPathIndices
      enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx >= self.paths.count)
          return;
        KKBezierPath *p = self.paths[idx];
        if (p.isImage || p.isGroup || p.count < 2)
          return;
        CGMutablePathRef cgp = [self canvasCGPathForPath:p];
        if (p.closed) {
          CGContextSetRGBFillColor(ctx, 1.0, 0.0, 0.0, 0.45);
          CGContextAddPath(ctx, cgp);
          CGContextFillPath(ctx);
        }
        CGPathRelease(cgp);
      }];

  // Green tint: result path (will remain).
  if (self.previewResultPath && self.previewResultPath.count >= 2) {
    CGMutablePathRef cgp = [self canvasCGPathForPath:self.previewResultPath];
    if (self.previewResultPath.closed) {
      CGContextSetRGBFillColor(ctx, 0.0, 1.0, 0.0, 0.45);
      CGContextAddPath(ctx, cgp);
      CGContextFillPath(ctx);
    }
    CGPathRelease(cgp);
  }

  // Upload to texture.
  KKMetalDeviceCache *pvCache = [KKMetalDeviceCache sharedCache];
  id<MTLDevice> pvDevice =
      [pvCache deviceWithRegistryID:destinationImage.deviceRegistryID];
  MTLTextureDescriptor *desc = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                   width:pixelW
                                  height:pixelH
                               mipmapped:NO];
  desc.usage = MTLTextureUsageShaderRead;
  self.previewTexture = [pvDevice newTextureWithDescriptor:desc];
  [self.previewTexture replaceRegion:MTLRegionMake2D(0, 0, pixelW, pixelH)
                         mipmapLevel:0
                           withBytes:CGBitmapContextGetData(ctx)
                         bytesPerRow:pixelW * 4];
  CGContextRelease(ctx);
}

- (void)drawPreviewTextureWithDestinationImage:(FxImageTile *)destinationImage {
  if (!self.previewTexture)
    return;

  float ioW = [destinationImage.ioSurface width];
  float ioH = [destinationImage.ioSurface height];

  KKMetalDeviceCache *pvCache = [KKMetalDeviceCache sharedCache];
  uint64_t pvRegID = destinationImage.deviceRegistryID;
  MTLPixelFormat pvFmt =
      [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
  id<MTLRenderPipelineState> pvPS = [pvCache
      buildAndRegisterPipelineStateForPluginID:
          @"co.overpolish.keyframeless.Canvas.Preview"
                                    registryID:pvRegID
                                   pixelFormat:pvFmt
                                      bundleID:@"co.overpolish"
                                                ".keyframeless"
                                                ".KeyframelessKit"
                                  vertexShader:@"KKVertexShader"
                                fragmentShader:@"KKLabelFragment"
                                     blendMode:KKBlendModePremultipliedAlpha];
  if (!pvPS)
    return;

  id<MTLCommandQueue> pvQueue = [pvCache commandQueueWithRegistryID:pvRegID
                                                        pixelFormat:pvFmt];
  if (!pvQueue)
    return;

  id<MTLTexture> outTex = [destinationImage
      metalTextureForDevice:[pvCache deviceWithRegistryID:pvRegID]];
  id<MTLCommandBuffer> pvBuf = [pvQueue commandBuffer];
  [pvBuf enqueue];
  MTLRenderPassDescriptor *pvRPD =
      [MTLRenderPassDescriptor renderPassDescriptor];
  pvRPD.colorAttachments[0].texture = outTex;
  pvRPD.colorAttachments[0].loadAction = MTLLoadActionLoad;
  pvRPD.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> pvEnc =
      [pvBuf renderCommandEncoderWithDescriptor:pvRPD];
  MTLViewport pvVP = {0, 0, ioW, ioH, -1.0, 1.0};
  [pvEnc setViewport:pvVP];
  [pvEnc setRenderPipelineState:pvPS];
  simd_uint2 vpSize = {(unsigned int)ioW, (unsigned int)ioH};
  [pvEnc setVertexBytes:&vpSize
                 length:sizeof(vpSize)
                atIndex:KKVertexInputIndex_ViewportSize];

  float halfW = ioW / 2.0f;
  float halfH = ioH / 2.0f;
  KKVertex2D verts[6] = {
      {{-halfW, -halfH}, {0, 0}}, {{halfW, -halfH}, {1, 0}},
      {{halfW, halfH}, {1, 1}},   {{-halfW, -halfH}, {0, 0}},
      {{halfW, halfH}, {1, 1}},   {{-halfW, halfH}, {0, 1}},
  };
  [pvEnc setVertexBytes:verts
                 length:sizeof(verts)
                atIndex:KKVertexInputIndex_Vertices];
  [pvEnc setFragmentTexture:self.previewTexture atIndex:0];
  [pvEnc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
  [pvEnc endEncoding];
  [pvBuf commit];
  [pvBuf waitUntilScheduled];
  [pvCache returnCommandQueueToCache:pvQueue];
}

- (void)drawBooleanPreviewWithDestinationImage:(FxImageTile *)destinationImage {
  [self computeBooleanPreviewIfNeeded];

  float ioW = [destinationImage.ioSurface width];
  float ioH = [destinationImage.ioSurface height];
  [self renderPreviewTextureForSize:(NSInteger)ioW
                             height:(NSInteger)ioH
                   destinationImage:destinationImage];
  [self drawPreviewTextureWithDestinationImage:destinationImage];
}

@end
