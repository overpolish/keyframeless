/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "RenderImage.h"
#import "CanvasGradientBuilder.h"
#import "ShaderTypes.h"
#import "SketchFill.h"
#import <CoreImage/CoreImage.h>
#import <KeyframelessKit/KKGradientSampling.h>

static NSMutableDictionary<NSString *, id<MTLTexture>> *sImageTextureCache;
static CIContext *sCIContext;
static NSMutableDictionary<NSString *, id<MTLTexture>> *sProcessedImageCache;
static id<MTLComputePipelineState> sJFASeedPS;
static id<MTLComputePipelineState> sJFAFloodPS;
static id<MTLComputePipelineState> sJFACompositePS;

id<MTLTexture> KKGetOrLoadImageTexture(NSString *path, id<MTLDevice> device) {
  if (!path)
    return nil;
  if (!sImageTextureCache)
    sImageTextureCache = [NSMutableDictionary dictionary];
  id<MTLTexture> cached = sImageTextureCache[path];
  if (cached)
    return cached;

  NSImage *nsImage = [[NSImage alloc] initWithContentsOfFile:path];
  if (!nsImage)
    return nil;
  CGImageRef cgImage = [nsImage CGImageForProposedRect:NULL
                                               context:nil
                                                 hints:nil];
  if (!cgImage)
    return nil;

  NSUInteger width = CGImageGetWidth(cgImage);
  NSUInteger height = CGImageGetHeight(cgImage);
  MTLTextureDescriptor *desc = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB
                                   width:width
                                  height:height
                               mipmapped:NO];
  desc.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> tex = [device newTextureWithDescriptor:desc];
  if (!tex)
    return nil;

  NSUInteger bytesPerRow = 4 * width;
  uint8_t *pixelData = calloc(height * bytesPerRow, 1);
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(
      pixelData, width, height, 8, bytesPerRow, colorSpace,
      (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), cgImage);
  CGContextRelease(ctx);
  CGColorSpaceRelease(colorSpace);

  [tex replaceRegion:MTLRegionMake2D(0, 0, width, height)
         mipmapLevel:0
           withBytes:pixelData
         bytesPerRow:bytesPerRow];
  free(pixelData);

  sImageTextureCache[path] = tex;
  return tex;
}

static void ensureJFAPipelines(id<MTLDevice> device) {
  if (sJFASeedPS)
    return;
  id<MTLLibrary> lib = [device newDefaultLibrary];
  NSError *err = nil;
  sJFASeedPS = [device newComputePipelineStateWithFunction:
                           [lib newFunctionWithName:@"jfaSeedInit"]
                                                     error:&err];
  sJFAFloodPS = [device newComputePipelineStateWithFunction:
                            [lib newFunctionWithName:@"jfaFloodPass"]
                                                      error:&err];
  sJFACompositePS = [device newComputePipelineStateWithFunction:
                                [lib newFunctionWithName:@"jfaComposite"]
                                                          error:&err];
}

static CIContext *ensureCIContext(id<MTLDevice> device) {
  if (!sCIContext)
    sCIContext = [CIContext contextWithMTLDevice:device
                                         options:@{
                                           kCIContextCacheIntermediates : @NO
                                         }];
  return sCIContext;
}

id<MTLTexture> KKApplyImageFill(id<MTLTexture> rawTexture, KKBezierPath *path,
                                id<MTLDevice> device,
                                id<MTLCommandBuffer> commandBuffer) {
  CIContext *ciCtx = ensureCIContext(device);

  CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CIImage *image = [[CIImage alloc]
      initWithMTLTexture:rawTexture
                 options:@{kCIImageColorSpace : (__bridge id)srgb}];

  // Gradient mode: render a flat gradient texture matching the image bounds,
  // then wrap it as a CIImage so the rest of the tint+blend pipeline reuses
  // the same code path as the solid case.
  CIImage *flatColor = nil;
  CanvasGradientParams fillGP = {0};
  fillGP.opacity = 1.0f;
  if (KKBuildCanvasGradientSamples(path, NO, &fillGP)) {
    static id<MTLComputePipelineState> sGradientFillPS;
    if (!sGradientFillPS) {
      id<MTLLibrary> lib = [device newDefaultLibrary];
      id<MTLFunction> fn = [lib newFunctionWithName:@"gradientFillKernel"];
      sGradientFillPS = [device newComputePipelineStateWithFunction:fn
                                                              error:nil];
    }
    if (sGradientFillPS) {
      CanvasGradientParams gp = fillGP;
      gp.bboxMin = (simd_float2){0, 0};
      gp.bboxMax =
          (simd_float2){(float)rawTexture.width, (float)rawTexture.height};

      MTLTextureDescriptor *gradDesc = [MTLTextureDescriptor
          texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB
                                       width:rawTexture.width
                                      height:rawTexture.height
                                   mipmapped:NO];
      gradDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
      id<MTLTexture> gradTex = [device newTextureWithDescriptor:gradDesc];

      id<MTLComputeCommandEncoder> enc = [commandBuffer computeCommandEncoder];
      [enc setComputePipelineState:sGradientFillPS];
      [enc setTexture:gradTex atIndex:0];
      [enc setBytes:&gp length:sizeof(gp) atIndex:0];
      MTLSize tg = MTLSizeMake(16, 16, 1);
      MTLSize grid = MTLSizeMake(rawTexture.width, rawTexture.height, 1);
      [enc dispatchThreads:grid threadsPerThreadgroup:tg];
      [enc endEncoding];

      flatColor = [[CIImage alloc]
          initWithMTLTexture:gradTex
                     options:@{kCIImageColorSpace : (__bridge id)srgb}];
    }
  }
  if (!flatColor) {
    CIColor *fillCI = [CIColor colorWithRed:path.fillR
                                      green:path.fillG
                                       blue:path.fillB
                                      alpha:1.0
                                 colorSpace:srgb];
    CIFilter *colorGen = [CIFilter filterWithName:@"CIConstantColorGenerator"];
    [colorGen setValue:fillCI forKey:kCIInputColorKey];
    flatColor = [colorGen.outputImage imageByCroppingToRect:image.extent];
  }

  CIImage *tinted =
      [flatColor imageByApplyingFilter:@"CIBlendWithAlphaMask"
                   withInputParameters:@{
                     kCIInputBackgroundImageKey : [CIImage emptyImage],
                     kCIInputMaskImageKey : image
                   }];

  // Mix original and tinted by fillTint (0 = original, 1 = fully tinted).
  float t = fminf(fmaxf(path.fillTint, 0.0f), 1.0f);
  CIImage *result;
  if (t >= 0.9999f) {
    result = tinted;
  } else if (t <= 0.0001f) {
    result = image;
  } else {
    result = [tinted imageByApplyingFilter:@"CIDissolveTransition"
                       withInputParameters:@{
                         kCIInputTargetImageKey : image,
                         kCIInputTimeKey : @(1.0 - t)
                       }];
  }

  MTLTextureDescriptor *desc = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB
                                   width:rawTexture.width
                                  height:rawTexture.height
                               mipmapped:NO];
  desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
  id<MTLTexture> outTex = [device newTextureWithDescriptor:desc];

  [ciCtx render:result
       toMTLTexture:outTex
      commandBuffer:commandBuffer
             bounds:image.extent
         colorSpace:srgb];
  CGColorSpaceRelease(srgb);
  return outTex;
}

id<MTLTexture> KKApplyImageStroke(id<MTLTexture> srcTexture, KKBezierPath *path,
                                  id<MTLDevice> device,
                                  id<MTLCommandBuffer> commandBuffer) {
  ensureJFAPipelines(device);
  if (!sJFASeedPS || !sJFAFloodPS || !sJFACompositePS)
    return srcTexture;

  float radius = path.strokeWidth;
  NSUInteger pad = (NSUInteger)ceilf(radius);
  NSUInteger outW = srcTexture.width + pad * 2;
  NSUInteger outH = srcTexture.height + pad * 2;

  // Padded source: copy src into center of larger RGBA texture.
  MTLTextureDescriptor *srcPadDesc = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB
                                   width:outW
                                  height:outH
                               mipmapped:NO];
  srcPadDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
  id<MTLTexture> paddedSrc = [device newTextureWithDescriptor:srcPadDesc];

  // Clear padded texture then blit source into center.
  {
    MTLRenderPassDescriptor *clearRPD =
        [MTLRenderPassDescriptor renderPassDescriptor];
    clearRPD.colorAttachments[0].texture = paddedSrc;
    clearRPD.colorAttachments[0].loadAction = MTLLoadActionClear;
    clearRPD.colorAttachments[0].storeAction = MTLStoreActionStore;
    clearRPD.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    id<MTLRenderCommandEncoder> enc =
        [commandBuffer renderCommandEncoderWithDescriptor:clearRPD];
    [enc endEncoding];
  }
  {
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    [blit copyFromTexture:srcTexture
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(srcTexture.width, srcTexture.height, 1)
                toTexture:paddedSrc
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(pad, pad, 0)];
    [blit endEncoding];
  }

  // Two RG16Float textures for JFA ping-pong.
  MTLTextureDescriptor *jfaDesc = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float
                                   width:outW
                                  height:outH
                               mipmapped:NO];
  jfaDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
  id<MTLTexture> jfaA = [device newTextureWithDescriptor:jfaDesc];
  id<MTLTexture> jfaB = [device newTextureWithDescriptor:jfaDesc];

  MTLSize threadGroupSize = MTLSizeMake(16, 16, 1);
  MTLSize gridSize = MTLSizeMake(outW, outH, 1);

  // Seed pass.
  {
    id<MTLComputeCommandEncoder> enc = [commandBuffer computeCommandEncoder];
    [enc setComputePipelineState:sJFASeedPS];
    [enc setTexture:paddedSrc atIndex:0];
    [enc setTexture:jfaA atIndex:1];
    [enc dispatchThreads:gridSize threadsPerThreadgroup:threadGroupSize];
    [enc endEncoding];
  }

  // Flood passes: step sizes from largest power-of-2 >= radius down to 1,
  // plus a +1 cleanup pass.
  int maxStep = 1;
  while (maxStep < (int)pad)
    maxStep *= 2;
  id<MTLTexture> readTex = jfaA;
  id<MTLTexture> writeTex = jfaB;
  for (int step = maxStep; step >= 1; step /= 2) {
    id<MTLComputeCommandEncoder> enc = [commandBuffer computeCommandEncoder];
    [enc setComputePipelineState:sJFAFloodPS];
    [enc setTexture:readTex atIndex:0];
    [enc setTexture:writeTex atIndex:1];
    [enc setBytes:&step length:sizeof(step) atIndex:0];
    [enc dispatchThreads:gridSize threadsPerThreadgroup:threadGroupSize];
    [enc endEncoding];
    id<MTLTexture> tmp = readTex;
    readTex = writeTex;
    writeTex = tmp;
  }
  // +1 cleanup pass.
  {
    int step = 1;
    id<MTLComputeCommandEncoder> enc = [commandBuffer computeCommandEncoder];
    [enc setComputePipelineState:sJFAFloodPS];
    [enc setTexture:readTex atIndex:0];
    [enc setTexture:writeTex atIndex:1];
    [enc setBytes:&step length:sizeof(step) atIndex:0];
    [enc dispatchThreads:gridSize threadsPerThreadgroup:threadGroupSize];
    [enc endEncoding];
    readTex = writeTex;
  }

  // Composite pass: stroke outline behind source image.
  id<MTLTexture> outTex = [device newTextureWithDescriptor:srcPadDesc];
  {
    simd_float4 strokeColor = {path.strokeR, path.strokeG, path.strokeB, 1.0f};

    CanvasGradientParams gradParams = {0};
    gradParams.opacity = path.opacity;
    if (KKBuildCanvasGradientSamples(path, YES, &gradParams)) {
      // Image bbox in padded-texture pixel space (image lives at pad..pad+src).
      gradParams.bboxMin = (simd_float2){(float)pad, (float)pad};
      gradParams.bboxMax = (simd_float2){(float)(pad + srcTexture.width),
                                         (float)(pad + srcTexture.height)};
    }

    id<MTLComputeCommandEncoder> enc = [commandBuffer computeCommandEncoder];
    [enc setComputePipelineState:sJFACompositePS];
    [enc setTexture:paddedSrc atIndex:0];
    [enc setTexture:readTex atIndex:1];
    [enc setTexture:outTex atIndex:2];
    [enc setBytes:&radius length:sizeof(radius) atIndex:0];
    [enc setBytes:&strokeColor length:sizeof(strokeColor) atIndex:1];
    [enc setBytes:&gradParams length:sizeof(gradParams) atIndex:2];
    [enc dispatchThreads:gridSize threadsPerThreadgroup:threadGroupSize];
    [enc endEncoding];
  }

  return outTex;
}

id<MTLTexture> KKApplyImageSketchFill(id<MTLTexture> rawTexture,
                                      KKBezierPath *path, id<MTLDevice> device,
                                      id<MTLCommandBuffer> commandBuffer) {
  static id<MTLRenderPipelineState> sSketchFillPS;
  if (!sSketchFillPS) {
    id<MTLLibrary> lib = [device newDefaultLibrary];
    MTLRenderPipelineDescriptor *desc =
        [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = [lib newFunctionWithName:@"strokeVertexShader"];
    desc.fragmentFunction = [lib newFunctionWithName:@"strokeFragmentShader"];
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm_sRGB;
    desc.colorAttachments[0].blendingEnabled = YES;
    desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    desc.colorAttachments[0].destinationRGBBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    desc.colorAttachments[0].destinationAlphaBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    sSketchFillPS = [device newRenderPipelineStateWithDescriptor:desc
                                                           error:nil];
  }
  if (!sSketchFillPS)
    return rawTexture;

  float imgW = (float)rawTexture.width;
  float imgH = (float)rawTexture.height;

  // Build a simple rect path covering the full image in object space 0-1.
  KKBezierPath *rectPath = [[KKBezierPath alloc] init];
  rectPath.closed = YES;
  [rectPath insertAtIndex:0 position:(simd_float2){0, 0}];
  [rectPath insertAtIndex:1 position:(simd_float2){1, 0}];
  [rectPath insertAtIndex:2 position:(simd_float2){1, 1}];
  [rectPath insertAtIndex:3 position:(simd_float2){0, 1}];

  KKHachureLine *lines = NULL;
  NSUInteger lineCount = KKGenerateHachureLines(
      rectPath, imgW, imgH, path.sketchFillStyle, path.sketchFillGap,
      path.sketchFillAngle, 0.0f, 0, &lines);
  if (lineCount == 0 || !lines)
    return rawTexture;

  float fw = path.sketchFillWeight;
  CanvasGradientParams gradParams = {0};
  gradParams.solidColor =
      (simd_float4){path.fillR, path.fillG, path.fillB, 1.0f};
  gradParams.opacity = 1.0f;
  if (KKBuildCanvasGradientSamples(path, NO, &gradParams)) {
    // bbox in centered framebuffer-Y pixels (matches the vertex math below).
    gradParams.bboxMin = (simd_float2){-imgW * 0.5f, -imgH * 0.5f};
    gradParams.bboxMax = (simd_float2){imgW * 0.5f, imgH * 0.5f};
  }
  float halfW = fw / 2.0f;
  BOOL isDots = (path.sketchFillStyle == 4);
  float dotRadius = fw * 1.5f;
  float dotSpacing = path.sketchFillGap;
  if (dotSpacing < dotRadius * 2.0f)
    dotSpacing = dotRadius * 2.0f;

  NSUInteger maxVerts;
  if (isDots) {
    NSUInteger dotsPerLine = 50;
    maxVerts = lineCount * dotsPerLine * 60 + 256;
  } else {
    maxVerts = lineCount * 6 + 256;
  }
  CanvasVertex *vertices = malloc(maxVerts * sizeof(CanvasVertex));
  NSUInteger vc = 0;

  if (isDots) {
    NSUInteger dotSegs = 32;
    for (NSUInteger i = 0; i < lineCount; i++) {
      simd_float2 pa = {lines[i].a.x - imgW / 2.0f,
                        (imgH - lines[i].a.y) - imgH / 2.0f};
      simd_float2 pb = {lines[i].b.x - imgW / 2.0f,
                        (imgH - lines[i].b.y) - imgH / 2.0f};
      float dx = pb.x - pa.x, dy = pb.y - pa.y;
      float len = sqrtf(dx * dx + dy * dy);
      if (len < 0.001f)
        continue;
      NSUInteger nDots = (NSUInteger)(len / dotSpacing) + 1;
      for (NSUInteger d = 0; d < nDots; d++) {
        float t = (nDots == 1) ? 0.5f : (float)d / (float)(nDots - 1);
        simd_float2 center = {pa.x + dx * t, pa.y + dy * t};
        for (NSUInteger s = 0; s < dotSegs; s++) {
          if (vc + 3 >= maxVerts) {
            maxVerts *= 2;
            vertices = realloc(vertices, maxVerts * sizeof(CanvasVertex));
          }
          float a1 = (float)s / (float)dotSegs * 2.0f * M_PI;
          float a2 = (float)(s + 1) / (float)dotSegs * 2.0f * M_PI;
          vertices[vc++] = (CanvasVertex){center, 0.0f, 0.0f};
          vertices[vc++] = (CanvasVertex){{center.x + cosf(a1) * dotRadius,
                                           center.y + sinf(a1) * dotRadius},
                                          1.0f,
                                          0.0f};
          vertices[vc++] = (CanvasVertex){{center.x + cosf(a2) * dotRadius,
                                           center.y + sinf(a2) * dotRadius},
                                          1.0f,
                                          0.0f};
        }
      }
    }
  } else {
    for (NSUInteger i = 0; i < lineCount; i++) {
      simd_float2 pa = {lines[i].a.x - imgW / 2.0f,
                        (imgH - lines[i].a.y) - imgH / 2.0f};
      simd_float2 pb = {lines[i].b.x - imgW / 2.0f,
                        (imgH - lines[i].b.y) - imgH / 2.0f};
      float dx = pb.x - pa.x, dy = pb.y - pa.y;
      float len = sqrtf(dx * dx + dy * dy);
      if (len < 0.001f)
        continue;
      simd_float2 perp = {-dy / len * halfW, dx / len * halfW};
      if (vc > 0) {
        vertices[vc] = vertices[vc - 1];
        vc++;
        vertices[vc++] =
            (CanvasVertex){{pa.x + perp.x, pa.y + perp.y}, 1.0f, 0.0f};
      }
      vertices[vc++] =
          (CanvasVertex){{pa.x + perp.x, pa.y + perp.y}, 1.0f, 0.0f};
      vertices[vc++] =
          (CanvasVertex){{pa.x - perp.x, pa.y - perp.y}, -1.0f, 0.0f};
      vertices[vc++] =
          (CanvasVertex){{pb.x + perp.x, pb.y + perp.y}, 1.0f, 0.0f};
      vertices[vc++] =
          (CanvasVertex){{pb.x - perp.x, pb.y - perp.y}, -1.0f, 0.0f};
    }
  }
  free(lines);

  if (vc == 0) {
    free(vertices);
    return rawTexture;
  }

  // Render hachure lines to a temp texture at image resolution.
  MTLTextureDescriptor *desc = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB
                                   width:(NSUInteger)imgW
                                  height:(NSUInteger)imgH
                               mipmapped:NO];
  desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
  id<MTLTexture> hachureTex = [device newTextureWithDescriptor:desc];

  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture = hachureTex;
  rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
  rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);

  simd_uint2 imgViewport = {(uint32_t)imgW, (uint32_t)imgH};
  id<MTLRenderCommandEncoder> enc =
      [commandBuffer renderCommandEncoderWithDescriptor:rpd];
  [enc setViewport:(MTLViewport){0, 0, imgW, imgH, -1, 1}];
  [enc setRenderPipelineState:sSketchFillPS];
  id<MTLBuffer> vBuf = [device newBufferWithBytes:vertices
                                           length:vc * sizeof(CanvasVertex)
                                          options:MTLResourceStorageModeShared];
  [enc setVertexBuffer:vBuf offset:0 atIndex:0];
  [enc setVertexBytes:&imgViewport length:sizeof(imgViewport) atIndex:1];
  [enc setFragmentBytes:&gradParams length:sizeof(gradParams) atIndex:0];
  [enc setFragmentBytes:&imgViewport length:sizeof(imgViewport) atIndex:1];
  MTLPrimitiveType prim =
      isDots ? MTLPrimitiveTypeTriangle : MTLPrimitiveTypeTriangleStrip;
  [enc drawPrimitives:prim vertexStart:0 vertexCount:vc];
  [enc endEncoding];
  free(vertices);

  // Mask the hachure texture with the original image alpha via CI.
  CIContext *ciCtx = ensureCIContext(device);
  CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CIImage *hachureCI = [[CIImage alloc]
      initWithMTLTexture:hachureTex
                 options:@{kCIImageColorSpace : (__bridge id)srgb}];
  CIImage *maskCI = [[CIImage alloc]
      initWithMTLTexture:rawTexture
                 options:@{kCIImageColorSpace : (__bridge id)srgb}];

  CIImage *masked =
      [hachureCI imageByApplyingFilter:@"CIBlendWithAlphaMask"
                   withInputParameters:@{
                     kCIInputBackgroundImageKey : [CIImage emptyImage],
                     kCIInputMaskImageKey : maskCI
                   }];

  desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
  id<MTLTexture> outTex = [device newTextureWithDescriptor:desc];
  [ciCtx render:masked
       toMTLTexture:outTex
      commandBuffer:commandBuffer
             bounds:masked.extent
         colorSpace:srgb];
  CGColorSpaceRelease(srgb);
  return outTex;
}

id<MTLTexture> KKProcessImageWithEffects(id<MTLTexture> rawTexture,
                                         KKBezierPath *path,
                                         id<MTLDevice> device,
                                         id<MTLCommandBuffer> commandBuffer) {
  if (!path.strokeEnabled && !path.fillEnabled)
    return rawTexture;

  NSString *cacheKey = [NSString
      stringWithFormat:@"%@_s%d_%.1f_%.2f_%.2f_%.2f_f%d_%d_%.1f_%.1f_%.1f_%.2f_"
                       @"%.2f_%.2f_t%.2f_sg%d_%d_%.3f_%@_fg%d_%d_%.3f_%@",
                       path.imagePath, path.strokeEnabled, path.strokeWidth,
                       path.strokeR, path.strokeG, path.strokeB,
                       path.fillEnabled, path.sketchFillStyle,
                       path.sketchFillGap, path.sketchFillAngle,
                       path.sketchFillWeight, path.fillR, path.fillG,
                       path.fillB, path.fillTint, (int)path.strokeColorMode,
                       (int)path.strokeGradientType, path.strokeGradientAngle,
                       path.strokeGradientJSON ?: @"", (int)path.fillColorMode,
                       (int)path.fillGradientType, path.fillGradientAngle,
                       path.fillGradientJSON ?: @""];
  if (!sProcessedImageCache)
    sProcessedImageCache = [NSMutableDictionary dictionary];
  id<MTLTexture> cached = sProcessedImageCache[cacheKey];
  if (cached)
    return cached;

  id<MTLTexture> result = rawTexture;

  if (path.fillEnabled) {
    if (path.sketchFillStyle > 0)
      result = KKApplyImageSketchFill(result, path, device, commandBuffer);
    else
      result = KKApplyImageFill(result, path, device, commandBuffer);
  }

  if (path.strokeEnabled)
    result = KKApplyImageStroke(result, path, device, commandBuffer);

  sProcessedImageCache[cacheKey] = result;
  return result;
}
