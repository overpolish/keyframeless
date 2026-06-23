/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasFillRender.h"
#import "CanvasCornerFillet.h" // CanvasPathByExpandingCorners
#import "CanvasLayerRender.h"  // CanvasLayerObjectCenter
#import "CanvasLayerTransform.h"
#import "CanvasPathMorph.h" // CanvasPathMorphedAtFraction
#import <KeyframelessKit/KKShaderTypes.h>
#import <KeyframelessKit/KeyframelessKit.h>

static NSString *const kFillStencilKey =
    @"co.overpolish.keyframeless.Canvas.fillStencil";
static NSString *const kFillColorKey =
    @"co.overpolish.keyframeless.Canvas.fillColor";

// Flatten every contour of `geom` into a triangle fan (one fan per contour,
// each from its own centroid) in CENTERED-PIXEL object space - the same space
// CanvasTessellateStroke + the image quads use, so the fill lands exactly under
// the stroke. Overlapping fans / fans that bulge outside a concave contour are
// resolved by the even-odd stencil, not here. Also reports the centered-pixel
// bounding box so the colour pass can cover the shape with a single quad (no
// self-overlap, unlike re-drawing the fan, so premultiplied blend stays correct
// at opacity < 1). Caller frees *outVerts.
static NSUInteger CanvasBuildFillFan(KKBezierPath *geom, float w, float h,
                                     KKVertex2D **outVerts, simd_float2 *outMin,
                                     simd_float2 *outMax) {
  const NSUInteger segsPerCurve = 32;
  NSUInteger nc = geom.contourCount;
  NSUInteger totalMax = 0;
  for (NSUInteger ci = 0; ci < nc; ci++)
    totalMax += [geom contourRangeAtIndex:ci].length * segsPerCurve + 1;
  if (totalMax == 0)
    return 0;

  simd_float2 *outline = malloc(totalMax * sizeof(simd_float2));
  NSUInteger *fanStarts = malloc((nc + 1) * sizeof(NSUInteger));
  NSUInteger oc = 0;
  simd_float2 lo = {FLT_MAX, FLT_MAX}, hi = {-FLT_MAX, -FLT_MAX};

  for (NSUInteger ci = 0; ci < nc; ci++) {
    fanStarts[ci] = oc;
    NSRange r = [geom contourRangeAtIndex:ci];
    NSUInteger cStart = r.location, cLen = r.length;
    for (NSUInteger c = 0; c < cLen; c++) {
      NSUInteger idx = cStart + c;
      NSUInteger nextIdx = cStart + ((c + 1) % cLen);
      for (NSUInteger s = 0; s < segsPerCurve; s++) {
        float t = (float)s / (float)segsPerCurve;
        simd_float2 norm = [geom evaluatePointAtIndex:idx
                                            nextIndex:nextIdx
                                                  atT:t];
        // Same centered-pixel mapping as CanvasTessellateStroke, so the fill
        // lands exactly under the stroke (both pass through the same matrix +
        // viewport, so they rasterize identically).
        simd_float2 p = {(norm.x - 0.5f) * w, (norm.y - 0.5f) * h};
        outline[oc++] = p;
        lo = simd_min(lo, p);
        hi = simd_max(hi, p);
      }
    }
  }
  fanStarts[nc] = oc;

  KKVertex2D *fill = malloc(oc * 3 * sizeof(KKVertex2D));
  NSUInteger ti = 0;
  for (NSUInteger ci = 0; ci < nc; ci++) {
    NSUInteger start = fanStarts[ci], end = fanStarts[ci + 1],
               len = end - start;
    if (len < 2)
      continue;
    simd_float2 first = outline[start], last = outline[end - 1];
    if (simd_distance_squared(first, last) < 1.0f)
      len--; // drop a closing sample coincident with the start
    if (len < 2)
      continue;
    simd_float2 center = {0, 0};
    for (NSUInteger i = 0; i < len; i++)
      center += outline[start + i];
    center /= (float)len;
    for (NSUInteger i = 0; i < len; i++) {
      simd_float2 cur = outline[start + i];
      simd_float2 nxt = outline[start + ((i + 1) % len)];
      fill[ti * 3 + 0] =
          (KKVertex2D){.position = center, .textureCoordinate = {0, 0}};
      fill[ti * 3 + 1] =
          (KKVertex2D){.position = cur, .textureCoordinate = {0, 0}};
      fill[ti * 3 + 2] =
          (KKVertex2D){.position = nxt, .textureCoordinate = {0, 0}};
      ti++;
    }
  }
  free(outline);
  free(fanStarts);
  if (outMin)
    *outMin = lo;
  if (outMax)
    *outMax = hi;
  *outVerts = fill;
  return ti;
}

id<MTLTexture> CanvasFillStencilTexture(id<MTLDevice> device, NSUInteger width,
                                        NSUInteger height) {
  if (!device || width == 0 || height == 0)
    return nil;
  static id<MTLDevice> sDevice = nil;
  static id<MTLTexture> sTex = nil;
  static NSUInteger sW = 0, sH = 0;
  if (sTex && sDevice == device && sW == width && sH == height)
    return sTex;
  MTLTextureDescriptor *desc = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatStencil8
                                   width:width
                                  height:height
                               mipmapped:NO];
  desc.usage = MTLTextureUsageRenderTarget;
  desc.storageMode = MTLStorageModePrivate;
  sTex = [device newTextureWithDescriptor:desc];
  sDevice = device;
  sW = width;
  sH = height;
  return sTex;
}

void CanvasFillBuildPipelines(id<MTLDevice> device, uint64_t registryID,
                              MTLPixelFormat pixelFormat,
                              id<MTLRenderPipelineState> *outStencilPS,
                              id<MTLRenderPipelineState> *outColorPS,
                              id<MTLDepthStencilState> *outStencilDS,
                              id<MTLDepthStencilState> *outColorDS) {
  *outStencilPS = nil;
  *outColorPS = nil;
  *outStencilDS = nil;
  *outColorDS = nil;
  if (!device)
    return;
  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];

  id<MTLRenderPipelineState> stencilPS =
      [cache pipelineStateForPluginID:kFillStencilKey
                           registryID:registryID
                          pixelFormat:pixelFormat];
  id<MTLRenderPipelineState> colorPS =
      [cache pipelineStateForPluginID:kFillColorKey
                           registryID:registryID
                          pixelFormat:pixelFormat];

  if (!stencilPS || !colorPS) {
    NSBundle *kitBundle = [NSBundle bundleForClass:[KKPlugin class]];
    NSError *err = nil;
    id<MTLLibrary> lib = [device newDefaultLibraryWithBundle:kitBundle
                                                       error:&err];
    id<MTLFunction> vfn = [lib newFunctionWithName:@"KKTransformVertexShader"];
    id<MTLFunction> ffn = [lib newFunctionWithName:@"KKSolidColorFragment"];
    if (!vfn || !ffn) {
      KKLogError(@"Canvas fill: missing kit shader functions (%@)", err);
      return;
    }

    // Stencil pass: write stencil only, no colour (even-odd toggle via the DS
    // state's Invert op).
    MTLRenderPipelineDescriptor *sd =
        [[MTLRenderPipelineDescriptor alloc] init];
    sd.vertexFunction = vfn;
    sd.fragmentFunction = ffn;
    sd.colorAttachments[0].pixelFormat = pixelFormat;
    sd.colorAttachments[0].writeMask = MTLColorWriteMaskNone;
    sd.stencilAttachmentPixelFormat = MTLPixelFormatStencil8;
    stencilPS = [device newRenderPipelineStateWithDescriptor:sd error:&err];

    // Colour pass: premultiplied "over" where the stencil is odd.
    MTLRenderPipelineDescriptor *cd =
        [[MTLRenderPipelineDescriptor alloc] init];
    cd.vertexFunction = vfn;
    cd.fragmentFunction = ffn;
    cd.colorAttachments[0].pixelFormat = pixelFormat;
    cd.colorAttachments[0].blendingEnabled = YES;
    cd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    cd.colorAttachments[0].destinationRGBBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    cd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    cd.colorAttachments[0].destinationAlphaBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    cd.stencilAttachmentPixelFormat = MTLPixelFormatStencil8;
    colorPS = [device newRenderPipelineStateWithDescriptor:cd error:&err];

    if (!stencilPS || !colorPS) {
      KKLogError(@"Canvas fill: pipeline build failed (%@)", err);
      return;
    }
    [cache registerPipelineState:stencilPS
                     forPluginID:kFillStencilKey
                      registryID:registryID
                     pixelFormat:pixelFormat];
    [cache registerPipelineState:colorPS
                     forPluginID:kFillColorKey
                      registryID:registryID
                     pixelFormat:pixelFormat];
  }

  // Depth-stencil states: cache per device (cheap to keep, costly to rebuild
  // every tile).
  static id<MTLDevice> sDSDevice = nil;
  static id<MTLDepthStencilState> sStencilDS = nil;
  static id<MTLDepthStencilState> sColorDS = nil;
  if (sDSDevice != device) {
    MTLStencilDescriptor *invert = [[MTLStencilDescriptor alloc] init];
    invert.stencilCompareFunction = MTLCompareFunctionAlways;
    invert.depthStencilPassOperation = MTLStencilOperationInvert;
    MTLDepthStencilDescriptor *sDesc = [[MTLDepthStencilDescriptor alloc] init];
    sDesc.frontFaceStencil = invert;
    sDesc.backFaceStencil = invert;
    sStencilDS = [device newDepthStencilStateWithDescriptor:sDesc];

    MTLStencilDescriptor *test = [[MTLStencilDescriptor alloc] init];
    test.stencilCompareFunction = MTLCompareFunctionNotEqual; // odd -> inside
    test.readMask = 0xFF;
    test.stencilFailureOperation = MTLStencilOperationKeep;
    test.depthStencilPassOperation = MTLStencilOperationZero; // reset for next
    MTLDepthStencilDescriptor *cDesc = [[MTLDepthStencilDescriptor alloc] init];
    cDesc.frontFaceStencil = test;
    cDesc.backFaceStencil = test;
    sColorDS = [device newDepthStencilStateWithDescriptor:cDesc];
    sDSDevice = device;
  }

  *outStencilPS = stencilPS;
  *outColorPS = colorPS;
  *outStencilDS = sStencilDS;
  *outColorDS = sColorDS;
}

void CanvasEncodeFilledLayers(
    NSArray<KKBezierPath *> *layers, id<MTLDevice> device,
    id<MTLCommandBuffer> commandBuffer, id<MTLTexture> outputTexture,
    id<MTLTexture> stencilTexture, id<MTLRenderPipelineState> fillStencilPS,
    id<MTLRenderPipelineState> fillColorPS,
    id<MTLDepthStencilState> fillStencilDS,
    id<MTLDepthStencilState> fillColorDS, float imageWidth, float imageHeight,
    float tileWidth, float tileHeight, float tileShiftX, float tileShiftY,
    double frac, NSString *overrideLayerID, KKTimeline *overrideTimeline) {
  if (!commandBuffer || !outputTexture || !stencilTexture || !fillStencilPS ||
      !fillColorPS || layers.count == 0)
    return;
  simd_float2 scale = simd_make_float2(imageWidth, imageHeight);
  simd_float2 tileShift = simd_make_float2(tileShiftX, tileShiftY);
  simd_uint2 viewport = {(unsigned int)tileWidth, (unsigned int)tileHeight};
  float aspect = imageHeight > 0 ? imageWidth / imageHeight : 1.0f;

  // Bottom-first (index 0 = topmost, drawn last), same stack order as the image
  // + stroke passes.
  for (NSInteger i = (NSInteger)layers.count - 1; i >= 0; i--) {
    KKBezierPath *path = layers[i];
    if (path.isImage || path.isGroup || path.hidden || !path.fillEnabled)
      continue;
    if (path.count < 3)
      continue;

    KKBezierPath *geom =
        (frac < 0.0) ? path : CanvasPathMorphedAtFraction(path, frac);
    if (geom.count < 3)
      continue;
    if (geom.hasCornerRadii)
      geom = CanvasPathByExpandingCorners(geom, aspect);

    KKVertex2D *fan = NULL;
    simd_float2 bbMin = {0, 0}, bbMax = {0, 0};
    NSUInteger triCount =
        CanvasBuildFillFan(geom, imageWidth, imageHeight, &fan, &bbMin, &bbMax);
    if (triCount == 0) {
      free(fan);
      continue;
    }

    CanvasLayerTransform t;
    if (frac < 0.0)
      t = CanvasLayerTransformIdentity();
    else if (overrideTimeline && overrideLayerID.length &&
             [path.layerID isEqualToString:overrideLayerID])
      t = CanvasLayerTransformFromTimeline(overrideTimeline, frac);
    else
      t = CanvasLayerTransformAtFraction(path, frac);

    CanvasGroupXform groups[kCanvasGroupXformCap];
    NSInteger ng =
        CanvasBuildGroupXforms(layers, (NSUInteger)i, frac, overrideLayerID,
                               overrideTimeline, groups, kCanvasGroupXformCap);
    matrix_float4x4 m = CanvasComposedModelMatrix(
        t, CanvasLayerObjectCenter(geom), groups, ng, scale, tileShift);

    float opacity = t.opacity * path.opacity;
    for (NSInteger k = 0; k < ng; k++)
      opacity *= groups[k].t.opacity;
    // TEMP white fill (premultiplied). Swap to (fillR,fillG,fillB) here for the
    // path's actual colour once real fill styling lands.
    simd_float4 color = simd_make_float4(opacity, opacity, opacity, opacity);

    id<MTLBuffer> fanBuf =
        [device newBufferWithBytes:fan
                            length:sizeof(KKVertex2D) * triCount * 3
                           options:MTLResourceStorageModeShared];
    free(fan);

    // Stencil pass: clear to 0, toggle (Invert) for each covered fan triangle.
    {
      MTLRenderPassDescriptor *rpd =
          [MTLRenderPassDescriptor renderPassDescriptor];
      rpd.colorAttachments[0].texture = outputTexture;
      rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
      rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
      rpd.stencilAttachment.texture = stencilTexture;
      rpd.stencilAttachment.loadAction = MTLLoadActionClear;
      rpd.stencilAttachment.storeAction = MTLStoreActionStore;
      rpd.stencilAttachment.clearStencil = 0;
      id<MTLRenderCommandEncoder> enc =
          [commandBuffer renderCommandEncoderWithDescriptor:rpd];
      [enc setViewport:(MTLViewport){0, 0, tileWidth, tileHeight, -1, 1}];
      [enc setRenderPipelineState:fillStencilPS];
      [enc setDepthStencilState:fillStencilDS];
      [enc setStencilReferenceValue:0];
      [enc setVertexBuffer:fanBuf offset:0 atIndex:KKVertexInputIndex_Vertices];
      [enc setVertexBytes:&viewport
                   length:sizeof(viewport)
                  atIndex:KKVertexInputIndex_ViewportSize];
      [enc setVertexBytes:&m
                   length:sizeof(m)
                  atIndex:KKVertexInputIndex_Transform];
      [enc drawPrimitives:MTLPrimitiveTypeTriangle
              vertexStart:0
              vertexCount:triCount * 3];
      [enc endEncoding];
    }

    // Colour pass: a single bbox quad (no self-overlap) masked to the odd
    // stencil region, zeroing the stencil as it goes so the next path starts
    // clean.
    {
      simd_float2 pad = {1.0f, 1.0f};
      simd_float2 q0 = bbMin - pad, q1 = bbMax + pad;
      KKVertex2D quad[6] = {
          {.position = {q0.x, q0.y}, .textureCoordinate = {0, 0}},
          {.position = {q1.x, q0.y}, .textureCoordinate = {0, 0}},
          {.position = {q0.x, q1.y}, .textureCoordinate = {0, 0}},
          {.position = {q1.x, q0.y}, .textureCoordinate = {0, 0}},
          {.position = {q1.x, q1.y}, .textureCoordinate = {0, 0}},
          {.position = {q0.x, q1.y}, .textureCoordinate = {0, 0}},
      };
      MTLRenderPassDescriptor *rpd =
          [MTLRenderPassDescriptor renderPassDescriptor];
      rpd.colorAttachments[0].texture = outputTexture;
      rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
      rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
      rpd.stencilAttachment.texture = stencilTexture;
      rpd.stencilAttachment.loadAction = MTLLoadActionLoad;
      rpd.stencilAttachment.storeAction = MTLStoreActionDontCare;
      id<MTLRenderCommandEncoder> enc =
          [commandBuffer renderCommandEncoderWithDescriptor:rpd];
      [enc setViewport:(MTLViewport){0, 0, tileWidth, tileHeight, -1, 1}];
      [enc setRenderPipelineState:fillColorPS];
      [enc setDepthStencilState:fillColorDS];
      [enc setStencilReferenceValue:0];
      [enc setVertexBytes:quad
                   length:sizeof(quad)
                  atIndex:KKVertexInputIndex_Vertices];
      [enc setVertexBytes:&viewport
                   length:sizeof(viewport)
                  atIndex:KKVertexInputIndex_ViewportSize];
      [enc setVertexBytes:&m
                   length:sizeof(m)
                  atIndex:KKVertexInputIndex_Transform];
      [enc setFragmentBytes:&color length:sizeof(color) atIndex:0];
      [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
      [enc endEncoding];
    }
  }
}
