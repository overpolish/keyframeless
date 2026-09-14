/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasFillRender.h"
#import "CanvasCornerFillet.h"   // CanvasPathByExpandingCorners
#import "CanvasFillProperties.h" // CanvasFillEnabledAtFraction + colour
#import "CanvasHachure.h"        // hachure / cross-hatch / zigzag / dots lines
#import "CanvasImageTexture.h"   // CanvasImageTextureForPath (image-mask alpha)
#import "CanvasLayerRender.h"    // CanvasLayerObjectCenter
#import "CanvasLayerRenderInternal.h" // CanvasComputeGradientFill (shared w/ stroke)
#import "CanvasLayerTransform.h"
#import "CanvasPathMorph.h"  // CanvasPathMorphedAtFraction
#import "CanvasSketchPath.h" // CanvasSketchPath / CanvasSketchifyHachureLines
#import "CanvasSketchProperties.h" // CanvasSketchEnabledAtFraction + params
#import <KeyframelessKit/KKShaderTypes.h>
#import <KeyframelessKit/KeyframelessKit.h>

static NSString *const kFillStencilKey =
    @"com.keyframeless.Canvas.fillStencil";
static NSString *const kFillColorKey =
    @"com.keyframeless.Canvas.fillColor";
static NSString *const kFillGradientKey =
    @"com.keyframeless.Canvas.fillGradient";
static NSString *const kFillCompositeKey =
    @"com.keyframeless.Canvas.fillComposite";
static NSString *const kFillColorMaskKey =
    @"com.keyframeless.Canvas.fillColorMask";
static NSString *const kFillGradientMaskKey =
    @"com.keyframeless.Canvas.fillGradientMask";

// MSAA sample count for the fill pass: the fan is rasterised multisampled and
// resolved so the silhouette antialiases (coverage-based, crisp - unlike the
// old hairline outline ribbon). 4x is universally supported on Metal Macs.
static const NSUInteger kFillSampleCount = 4;

// Flatten every contour of `geom` into a triangle fan (one fan per contour,
// each from its own centroid) in CENTERED-PIXEL object space - the same space
// CanvasTessellateStroke + the image quads use, so the fill lands exactly under
// the stroke. Overlapping fans / fans that bulge outside a concave contour are
// resolved by the even-odd stencil, not here. Also reports the centered-pixel
// bounding box so the colour pass can cover the shape with a single quad (no
// self-overlap, unlike re-drawing the fan, so premultiplied blend stays correct
// at opacity < 1). Caller frees *outVerts.
NSUInteger CanvasBuildFillFan(KKBezierPath *geom, float w, float h,
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

// Ensure (and cache per process) the fill pass's MSAA render targets sized to
// the tile: a 4x multisample colour + stencil to rasterise the fan into, and a
// 1x resolve texture the multisample colour resolves to (then composited onto
// the dest). Returns NO on failure. `pf` is the dest colour format.
static BOOL CanvasFillEnsureMSAA(id<MTLDevice> device, NSUInteger width,
                                 NSUInteger height, MTLPixelFormat pf,
                                 id<MTLTexture> *outColor,
                                 id<MTLTexture> *outStencil,
                                 id<MTLTexture> *outResolve) {
  if (!device || width == 0 || height == 0 ||
      ![device supportsTextureSampleCount:kFillSampleCount])
    return NO;
  static id<MTLDevice> sDevice = nil;
  static id<MTLTexture> sColor = nil, sStencil = nil, sResolve = nil;
  static NSUInteger sW = 0, sH = 0;
  static MTLPixelFormat sPF = MTLPixelFormatInvalid;
  if (!(sColor && sStencil && sResolve && sDevice == device && sW == width &&
        sH == height && sPF == pf)) {
    MTLTextureDescriptor *cd =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    cd.textureType = MTLTextureType2DMultisample;
    cd.sampleCount = kFillSampleCount;
    cd.usage = MTLTextureUsageRenderTarget;
    cd.storageMode = MTLStorageModePrivate;
    sColor = [device newTextureWithDescriptor:cd];

    MTLTextureDescriptor *sd = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatStencil8
                                     width:width
                                    height:height
                                 mipmapped:NO];
    sd.textureType = MTLTextureType2DMultisample;
    sd.sampleCount = kFillSampleCount;
    sd.usage = MTLTextureUsageRenderTarget;
    sd.storageMode = MTLStorageModePrivate;
    sStencil = [device newTextureWithDescriptor:sd];

    MTLTextureDescriptor *rd =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    rd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    rd.storageMode = MTLStorageModePrivate;
    sResolve = [device newTextureWithDescriptor:rd];

    sDevice = device;
    sW = width;
    sH = height;
    sPF = pf;
  }
  *outColor = sColor;
  *outStencil = sStencil;
  *outResolve = sResolve;
  return sColor && sStencil && sResolve;
}

void CanvasFillBuildPipelines(id<MTLDevice> device, uint64_t registryID,
                              MTLPixelFormat pixelFormat,
                              CanvasFillPipelines *outPipelines) {
  *outPipelines = (CanvasFillPipelines){0};
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
  id<MTLRenderPipelineState> gradientPS =
      [cache pipelineStateForPluginID:kFillGradientKey
                           registryID:registryID
                          pixelFormat:pixelFormat];
  id<MTLRenderPipelineState> compositePS =
      [cache pipelineStateForPluginID:kFillCompositeKey
                           registryID:registryID
                          pixelFormat:pixelFormat];
  id<MTLRenderPipelineState> colorMaskPS =
      [cache pipelineStateForPluginID:kFillColorMaskKey
                           registryID:registryID
                          pixelFormat:pixelFormat];
  id<MTLRenderPipelineState> gradientMaskPS =
      [cache pipelineStateForPluginID:kFillGradientMaskKey
                           registryID:registryID
                          pixelFormat:pixelFormat];

  if (!stencilPS || !colorPS || !gradientPS || !compositePS || !colorMaskPS ||
      !gradientMaskPS) {
    NSBundle *kitBundle = [NSBundle bundleForClass:[KKPlugin class]];
    NSError *err = nil;
    id<MTLLibrary> lib = [device newDefaultLibraryWithBundle:kitBundle
                                                       error:&err];
    id<MTLFunction> vfn = [lib newFunctionWithName:@"KKTransformVertexShader"];
    id<MTLFunction> ffn = [lib newFunctionWithName:@"KKSolidColorFragment"];
    id<MTLFunction> gffn = [lib newFunctionWithName:@"KKGradientFillFragment"];
    // Masked variants (image-layer hachure): the same solid / gradient colour,
    // multiplied by the image's own alpha so the pattern keeps the picture's
    // silhouette instead of filling its bounding rect.
    id<MTLFunction> mffn =
        [lib newFunctionWithName:@"KKHachureMaskSolidFragment"];
    id<MTLFunction> mgffn =
        [lib newFunctionWithName:@"KKHachureMaskGradientFragment"];
    // Composite (resolve -> dest): a plain fullscreen blit of the resolved
    // fill.
    id<MTLFunction> cvfn = [lib newFunctionWithName:@"KKVertexShader"];
    id<MTLFunction> cffn =
        [lib newFunctionWithName:@"KKTexturePassthroughFragment"];
    if (!vfn || !ffn || !gffn || !mffn || !mgffn || !cvfn || !cffn) {
      KKLogError(@"Canvas fill: missing kit shader functions (%@)", err);
      return;
    }

    // Stencil pass: write stencil only, no colour (even-odd toggle via the DS
    // state's Invert op). Multisampled (the fan is rasterised at 4x).
    MTLRenderPipelineDescriptor *sd =
        [[MTLRenderPipelineDescriptor alloc] init];
    sd.vertexFunction = vfn;
    sd.fragmentFunction = ffn;
    sd.rasterSampleCount = kFillSampleCount;
    sd.colorAttachments[0].pixelFormat = pixelFormat;
    sd.colorAttachments[0].writeMask = MTLColorWriteMaskNone;
    sd.stencilAttachmentPixelFormat = MTLPixelFormatStencil8;
    stencilPS = [device newRenderPipelineStateWithDescriptor:sd error:&err];

    // Colour pass: premultiplied "over" where the stencil is odd. Multisampled.
    MTLRenderPipelineDescriptor *cd =
        [[MTLRenderPipelineDescriptor alloc] init];
    cd.vertexFunction = vfn;
    cd.fragmentFunction = ffn;
    cd.rasterSampleCount = kFillSampleCount;
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

    // Gradient colour pass: same premultiplied "over" blend + stencil as the
    // solid pass, but the per-pixel bbox-gradient fragment.
    cd.fragmentFunction = gffn;
    gradientPS = [device newRenderPipelineStateWithDescriptor:cd error:&err];

    // Image-hachure masked passes: solid + gradient clipped to the image alpha.
    cd.fragmentFunction = mffn;
    colorMaskPS = [device newRenderPipelineStateWithDescriptor:cd error:&err];
    cd.fragmentFunction = mgffn;
    gradientMaskPS = [device newRenderPipelineStateWithDescriptor:cd
                                                            error:&err];

    // Composite pass (1x): blit the resolved fill over the dest, premult over.
    MTLRenderPipelineDescriptor *pd =
        [[MTLRenderPipelineDescriptor alloc] init];
    pd.vertexFunction = cvfn;
    pd.fragmentFunction = cffn;
    pd.colorAttachments[0].pixelFormat = pixelFormat;
    pd.colorAttachments[0].blendingEnabled = YES;
    pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    pd.colorAttachments[0].destinationRGBBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    pd.colorAttachments[0].destinationAlphaBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    compositePS = [device newRenderPipelineStateWithDescriptor:pd error:&err];

    if (!stencilPS || !colorPS || !gradientPS || !compositePS || !colorMaskPS ||
        !gradientMaskPS) {
      KKLogError(@"Canvas fill: pipeline build failed (%@)", err);
      return;
    }
    [cache registerPipelineState:colorMaskPS
                     forPluginID:kFillColorMaskKey
                      registryID:registryID
                     pixelFormat:pixelFormat];
    [cache registerPipelineState:gradientMaskPS
                     forPluginID:kFillGradientMaskKey
                      registryID:registryID
                     pixelFormat:pixelFormat];
    [cache registerPipelineState:stencilPS
                     forPluginID:kFillStencilKey
                      registryID:registryID
                     pixelFormat:pixelFormat];
    [cache registerPipelineState:colorPS
                     forPluginID:kFillColorKey
                      registryID:registryID
                     pixelFormat:pixelFormat];
    [cache registerPipelineState:gradientPS
                     forPluginID:kFillGradientKey
                      registryID:registryID
                     pixelFormat:pixelFormat];
    [cache registerPipelineState:compositePS
                     forPluginID:kFillCompositeKey
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
    // Keep (not Zero): the MSAA stencil is cleared per layer, so no reset is
    // needed - and Zero would self-mask overlapping hachure lines (cross-hatch
    // crossings, zigzag, dots) after the first draw at a pixel.
    test.depthStencilPassOperation = MTLStencilOperationKeep;
    MTLDepthStencilDescriptor *cDesc = [[MTLDepthStencilDescriptor alloc] init];
    cDesc.frontFaceStencil = test;
    cDesc.backFaceStencil = test;
    sColorDS = [device newDepthStencilStateWithDescriptor:cDesc];
    sDSDevice = device;
  }

  outPipelines->stencil = stencilPS;
  outPipelines->color = colorPS;
  outPipelines->gradient = gradientPS;
  outPipelines->composite = compositePS;
  outPipelines->colorMask = colorMaskPS;
  outPipelines->gradientMask = gradientMaskPS;
  outPipelines->stencilDS = sStencilDS;
  outPipelines->colorDS = sColorDS;
}

// Per-layer shared render state for the three fill passes - the MSAA targets +
// tile viewport, constant across a CanvasEncodeFilledLayers call. Object
// pointers are unretained (the caller holds them for the synchronous encode).
typedef struct {
  __unsafe_unretained id<MTLDevice> device;
  __unsafe_unretained id<MTLCommandBuffer> commandBuffer;
  __unsafe_unretained id<MTLTexture> msaaColor;
  __unsafe_unretained id<MTLTexture> msaaStencil;
  __unsafe_unretained id<MTLTexture> resolveTex;
  __unsafe_unretained id<MTLTexture> outputTexture;
  simd_uint2 viewport;
  float tileWidth;
  float tileHeight;
} CanvasFillPassCtx;

// The colour pass's per-layer inputs: the fill style + geometry (so it builds
// its own hachure line buffer), the bbox + resolved solid/gradient colour, and
// the optional image-alpha mask (image-layer hachure).
typedef struct {
  __unsafe_unretained KKBezierPath *geom;
  CanvasFillStyle fs;
  BOOL hachure;
  simd_float2 bbMin;
  simd_float2 bbMax;
  BOOL useGradient;
  simd_float4 color;
  KKGradientFillParams gparams;
  const KKColorLanesValue *cv; // gradient LUT source
  BOOL maskHachure;
  __unsafe_unretained id<MTLTexture> maskTex;
  KKHachureMaskParams mparams;
  float imageWidth;
  float imageHeight;
  // Sketch (hand-drawn) jitter for the hachure lines.
  BOOL sketchHachure;
  float sketchRoughness;
  float sketchBowing;
  uint32_t sketchSeed;
} CanvasFillColorInputs;

// Stencil pass: clear the MSAA colour + stencil, then toggle (Invert) the
// even-odd stencil for each fan triangle. No colour is written.
static void CanvasFillEncodeStencilPass(const CanvasFillPassCtx *c,
                                        const CanvasFillPipelines *pl,
                                        id<MTLBuffer> fanBuf,
                                        NSUInteger triCount,
                                        const matrix_float4x4 *m) {
  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture = c->msaaColor;
  rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
  rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
  rpd.stencilAttachment.texture = c->msaaStencil;
  rpd.stencilAttachment.loadAction = MTLLoadActionClear;
  rpd.stencilAttachment.storeAction = MTLStoreActionStore;
  rpd.stencilAttachment.clearStencil = 0;
  id<MTLRenderCommandEncoder> enc =
      [c->commandBuffer renderCommandEncoderWithDescriptor:rpd];
  [enc setViewport:(MTLViewport){0, 0, c->tileWidth, c->tileHeight, -1, 1}];
  [enc setRenderPipelineState:pl->stencil];
  [enc setDepthStencilState:pl->stencilDS];
  [enc setStencilReferenceValue:0];
  [enc setVertexBuffer:fanBuf offset:0 atIndex:KKVertexInputIndex_Vertices];
  [enc setVertexBytes:&c->viewport
               length:sizeof(c->viewport)
              atIndex:KKVertexInputIndex_ViewportSize];
  [enc setVertexBytes:m length:sizeof(*m) atIndex:KKVertexInputIndex_Transform];
  // The stencil pipeline reuses KKSolidColorFragment (it writes no colour - the
  // pass only toggles the even-odd stencil), but that fragment still DECLARES a
  // `constant float4 *color [[buffer(0)]]`, so Metal's validation layer requires
  // it bound before the draw. Bind a throwaway colour to satisfy it; the value
  // is discarded by the None write mask.
  simd_float4 unusedColor = {0, 0, 0, 0};
  [enc setFragmentBytes:&unusedColor length:sizeof(unusedColor) atIndex:0];
  [enc drawPrimitives:MTLPrimitiveTypeTriangle
          vertexStart:0
          vertexCount:triCount * 3];
  [enc endEncoding];
}

// Colour pass: draw the fill into the MSAA target where the stencil is odd,
// resolving to the 1x resolve texture. Solid/gradient covers a single bbox
// quad; a hachure style draws its line pattern (optionally clipped to an image
// alpha).
static void CanvasFillEncodeColorPass(const CanvasFillPassCtx *c,
                                      const CanvasFillPipelines *pl,
                                      const matrix_float4x4 *m,
                                      const CanvasFillColorInputs *in) {
  // Hachure geometry built up front (clipped by the shape stencil); empty ->
  // the pass just resolves transparent.
  id<MTLBuffer> hBuf = nil;
  NSUInteger hvc = 0;
  if (in->hachure) {
    CanvasHachureLine *hl = NULL;
    NSUInteger lc =
        CanvasGenerateHachureLines(in->geom, in->imageWidth, in->imageHeight,
                                   in->fs.style, in->fs.gap, in->fs.angle, &hl);
    // Sketch: wobble the straight hachure lines into hand-drawn strokes.
    if (lc > 0 && in->sketchHachure)
      CanvasSketchifyHachureLines(&hl, &lc, in->sketchRoughness,
                                  in->sketchBowing, in->sketchSeed,
                                  in->imageWidth, in->imageHeight);
    KKVertex2D *hv = NULL;
    if (lc > 0)
      hvc = CanvasHachureTriangles(hl, lc, in->fs.style, in->fs.gap,
                                   in->fs.weight, &hv);
    free(hl);
    if (hvc >= 3)
      hBuf = [c->device newBufferWithBytes:hv
                                    length:sizeof(KKVertex2D) * hvc
                                   options:MTLResourceStorageModeShared];
    free(hv);
  }
  simd_float2 pad = {1.0f, 1.0f};
  simd_float2 q0 = in->bbMin - pad, q1 = in->bbMax + pad;
  // textureCoordinate carries each corner's OBJECT-SPACE position so the
  // gradient fragment gets the per-pixel position (perspective-correct); the
  // solid fragment ignores it.
  KKVertex2D quad[6] = {
      {.position = {q0.x, q0.y}, .textureCoordinate = {q0.x, q0.y}},
      {.position = {q1.x, q0.y}, .textureCoordinate = {q1.x, q0.y}},
      {.position = {q0.x, q1.y}, .textureCoordinate = {q0.x, q1.y}},
      {.position = {q1.x, q0.y}, .textureCoordinate = {q1.x, q0.y}},
      {.position = {q1.x, q1.y}, .textureCoordinate = {q1.x, q1.y}},
      {.position = {q0.x, q1.y}, .textureCoordinate = {q0.x, q1.y}},
  };
  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture = c->msaaColor;
  rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
  rpd.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
  rpd.colorAttachments[0].resolveTexture = c->resolveTex;
  rpd.stencilAttachment.texture = c->msaaStencil;
  rpd.stencilAttachment.loadAction = MTLLoadActionLoad;
  rpd.stencilAttachment.storeAction = MTLStoreActionDontCare;
  id<MTLRenderCommandEncoder> enc =
      [c->commandBuffer renderCommandEncoderWithDescriptor:rpd];
  [enc setViewport:(MTLViewport){0, 0, c->tileWidth, c->tileHeight, -1, 1}];
  [enc setDepthStencilState:pl->colorDS];
  [enc setStencilReferenceValue:0];
  [enc setVertexBytes:&c->viewport
               length:sizeof(c->viewport)
              atIndex:KKVertexInputIndex_ViewportSize];
  [enc setVertexBytes:m length:sizeof(*m) atIndex:KKVertexInputIndex_Transform];
  if (in->hachure) {
    if (hBuf) {
      if (in->maskHachure) {
        [enc setRenderPipelineState:(in->useGradient ? pl->gradientMask
                                                     : pl->colorMask)];
        [enc setFragmentTexture:in->maskTex atIndex:KKTextureIndex_InputImage];
      } else {
        [enc setRenderPipelineState:(in->useGradient ? pl->gradient
                                                     : pl->color)];
      }
      [enc setVertexBuffer:hBuf offset:0 atIndex:KKVertexInputIndex_Vertices];
      if (in->useGradient) {
        [enc setFragmentBytes:in->cv->gradientLUT
                       length:sizeof(in->cv->gradientLUT)
                      atIndex:0];
        [enc setFragmentBytes:&in->gparams
                       length:sizeof(in->gparams)
                      atIndex:1];
        if (in->maskHachure)
          [enc setFragmentBytes:&in->mparams
                         length:sizeof(in->mparams)
                        atIndex:2];
      } else {
        [enc setFragmentBytes:&in->color length:sizeof(in->color) atIndex:0];
        if (in->maskHachure)
          [enc setFragmentBytes:&in->mparams
                         length:sizeof(in->mparams)
                        atIndex:1];
      }
      [enc drawPrimitives:MTLPrimitiveTypeTriangle
              vertexStart:0
              vertexCount:hvc];
    }
  } else {
    [enc setRenderPipelineState:(in->useGradient ? pl->gradient : pl->color)];
    [enc setVertexBytes:quad
                 length:sizeof(quad)
                atIndex:KKVertexInputIndex_Vertices];
    if (in->useGradient) {
      [enc setFragmentBytes:in->cv->gradientLUT
                     length:sizeof(in->cv->gradientLUT)
                    atIndex:0];
      [enc setFragmentBytes:&in->gparams length:sizeof(in->gparams) atIndex:1];
    } else {
      [enc setFragmentBytes:&in->color length:sizeof(in->color) atIndex:0];
    }
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
  }
  [enc endEncoding];
}

// Composite pass: blit the resolved (antialiased) fill over the dest with
// premultiplied "over" - a full-tile quad sampling the resolve 1:1 (same
// top-left UV convention as the source / image blit).
static void CanvasFillEncodeCompositePass(const CanvasFillPassCtx *c,
                                          const CanvasFillPipelines *pl) {
  float tw = c->tileWidth, th = c->tileHeight;
  KKVertex2D blit[4] = {
      {{tw / 2.0f, -th / 2.0f}, {1, 1}},
      {{-tw / 2.0f, -th / 2.0f}, {0, 1}},
      {{tw / 2.0f, th / 2.0f}, {1, 0}},
      {{-tw / 2.0f, th / 2.0f}, {0, 0}},
  };
  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture = c->outputTexture;
  rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> enc =
      [c->commandBuffer renderCommandEncoderWithDescriptor:rpd];
  [enc setViewport:(MTLViewport){0, 0, tw, th, -1, 1}];
  [enc setRenderPipelineState:pl->composite];
  [enc setVertexBytes:blit
               length:sizeof(blit)
              atIndex:KKVertexInputIndex_Vertices];
  [enc setVertexBytes:&c->viewport
               length:sizeof(c->viewport)
              atIndex:KKVertexInputIndex_ViewportSize];
  [enc setFragmentTexture:c->resolveTex atIndex:KKTextureIndex_InputImage];
  [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip
          vertexStart:0
          vertexCount:4];
  [enc endEncoding];
}

void CanvasEncodeFilledLayers(
    NSArray<KKBezierPath *> *layers, id<MTLDevice> device,
    NSMutableDictionary<NSString *, id<MTLTexture>> *textureCache,
    id<MTLCommandBuffer> commandBuffer, id<MTLTexture> outputTexture,
    const CanvasFillPipelines *pipelines, float imageWidth, float imageHeight,
    float tileWidth, float tileHeight, float tileShiftX, float tileShiftY,
    double frac, NSString *overrideLayerID, KKTimeline *overrideTimeline) {
  if (!commandBuffer || !outputTexture || !pipelines || !pipelines->stencil ||
      !pipelines->color || !pipelines->composite || device == nil ||
      layers.count == 0)
    return;
  // The fill rasterises into a 4x multisample colour + stencil, resolves to a
  // 1x texture (coverage AA), then composites that over the dest.
  id<MTLTexture> msaaColor = nil, msaaStencil = nil, resolveTex = nil;
  if (!CanvasFillEnsureMSAA(device, (NSUInteger)tileWidth,
                            (NSUInteger)tileHeight, outputTexture.pixelFormat,
                            &msaaColor, &msaaStencil, &resolveTex))
    return;
  simd_float2 scale = simd_make_float2(imageWidth, imageHeight);
  simd_float2 tileShift = simd_make_float2(tileShiftX, tileShiftY);
  simd_uint2 viewport = {(unsigned int)tileWidth, (unsigned int)tileHeight};
  float aspect = imageHeight > 0 ? imageWidth / imageHeight : 1.0f;
  // Shared render state for the three per-layer passes (MSAA targets + tile).
  CanvasFillPassCtx passCtx = {
      .device = device,
      .commandBuffer = commandBuffer,
      .msaaColor = msaaColor,
      .msaaStencil = msaaStencil,
      .resolveTex = resolveTex,
      .outputTexture = outputTexture,
      .viewport = viewport,
      .tileWidth = tileWidth,
      .tileHeight = tileHeight,
  };

  // Bottom-first (index 0 = topmost, drawn last), same stack order as the image
  // + stroke passes.
  for (NSInteger i = (NSInteger)layers.count - 1; i >= 0; i--) {
    KKBezierPath *path = layers[i];
    if (path.isGroup || path.hidden)
      continue;
    // Fraction to EVALUATE lanes at (a static preview, frac < 0, reads frame
    // 0).
    double evalFrac = frac < 0.0 ? 0.0 : frac;
    if (!CanvasFillEnabledAtFraction(path, evalFrac, overrideLayerID,
                                     overrideTimeline))
      continue;

    KKBezierPath *geom;
    // Image-layer hachure clips to the picture's alpha (the masked color pass
    // samples this rect's UV); a vector fill leaves it at the unit rect
    // (unused).
    BOOL isImageHachure = NO;
    simd_float2 imgRectMin = {0, 0}, imgRectMax = {1, 1};
    if (path.isImage) {
      // Image fill: only a HACHURE pattern is drawn here (a Solid image fill is
      // a tint, handled in the image pass). The shape is the image's rect; the
      // pattern is then masked to the image's own alpha in the colour pass so
      // it keeps the picture's silhouette rather than its bounding box.
      CanvasFillStyle ifs = CanvasFillStyleAtFraction(
          path, evalFrac, overrideLayerID, overrideTimeline);
      if (ifs.style == 0 || ![path.shape isKindOfClass:[KKRectShape class]])
        continue;
      KKRectShape *r = (KKRectShape *)path.shape;
      simd_float2 corners[4] = {r.min, simd_make_float2(r.max.x, r.min.y),
                                r.max, simd_make_float2(r.min.x, r.max.y)};
      KKBezierPath *rect = [[KKBezierPath alloc] init];
      [rect setLinearPositions:corners count:4 closed:YES];
      geom = rect;
      isImageHachure = YES;
      imgRectMin = r.min;
      imgRectMax = r.max;
    } else {
      if (path.count < 3)
        continue;
      geom = (frac < 0.0) ? path : CanvasPathMorphedAtFraction(path, frac);
      if (geom.count < 3)
        continue;
      if (geom.hasCornerRadii)
        geom = CanvasPathByExpandingCorners(geom, aspect);
    }

    // Sketch (hand-drawn): roughen the fill. For a VECTOR shape the silhouette
    // fan is built from a jittered copy of the outline (strokes=1 - a fill
    // wants one wobbly border, not a disjoint double-draw); for an IMAGE the
    // rect stays put (its silhouette comes from the alpha mask) and only the
    // hachure lines wobble. The hachure lines are jittered in the colour pass.
    CanvasSketchParams sp = {0};
    BOOL sketchOn = CanvasSketchEnabledAtFraction(
        path, evalFrac, overrideLayerID, overrideTimeline);
    if (sketchOn) {
      sp = CanvasSketchParamsAtFraction(path, evalFrac, overrideLayerID,
                                        overrideTimeline);
      if (sp.roughness > 0.0001f && !path.isImage) {
        float ss = path.strokeWidth, se = path.strokeWidth;
        CanvasStrokeWidthAtFraction(path, evalFrac, overrideLayerID,
                                    overrideTimeline, &ss, &se);
        geom = CanvasSketchPath(geom, sp.roughness, sp.bowing, sp.seed,
                                /*strokes=*/1, fmaxf(ss, se), imageWidth,
                                imageHeight);
      }
    }

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
    // Resolved fill colour from the shared Fill colour lanes. Solid: sRGB ->
    // linear (the render working space, like the stroke), premultiplied by the
    // composed layer/group opacity. Gradient: a per-pixel bbox fill (same
    // CanvasComputeGradientFill the stroke uses) in the gradient colour pass.
    KKColorLanesValue cv = CanvasFillColorAtFraction(
        path, evalFrac, overrideLayerID, overrideTimeline);
    BOOL useGradient =
        (cv.mode == KKColorModeGradient) && pipelines->gradient != nil;
    simd_float3 fc = cv.solidColor;
    simd_float4 color =
        simd_make_float4(powf(fc.x, 2.2f) * opacity, powf(fc.y, 2.2f) * opacity,
                         powf(fc.z, 2.2f) * opacity, opacity);
    KKGradientFillParams gparams = {0};
    CanvasGradientFill gfill = {0};
    if (useGradient) {
      gfill = CanvasComputeGradientFill(geom, imageWidth, imageHeight, 0.0f,
                                        0.0f, 1.0f, cv, NULL, 0);
      gparams.center = gfill.center;
      gparams.dir = gfill.dir;
      gparams.halfExtent = gfill.halfExtent;
      gparams.maxDim = gfill.maxDim;
      gparams.type = gfill.type;
      gparams.opacity = opacity;
    }
    // Fill style: Solid (the bbox quad), or a hachure line pattern (clipped by
    // the shape stencil). The pattern carries the solid OR gradient fill colour
    // (its verts bake the object-space position for the gradient fragment).
    CanvasFillStyle fs = CanvasFillStyleAtFraction(
        path, evalFrac, overrideLayerID, overrideTimeline);
    BOOL hachure = fs.style != 0;
    // Image-layer hachure: clip the pattern to the image's alpha (its
    // silhouette) via the masked colour pass, which samples the image at the
    // rect's UV.
    KKHachureMaskParams mparams = {0};
    id<MTLTexture> maskTex = nil;
    BOOL maskHachure = isImageHachure && hachure && textureCache != nil &&
                       path.imagePath.length > 0;
    if (maskHachure) {
      maskTex = CanvasImageTextureForPath(path.imagePath, device, textureCache);
      maskHachure =
          (maskTex != nil) && (useGradient ? pipelines->gradientMask != nil
                                           : pipelines->colorMask != nil);
      mparams.scale = scale;
      mparams.rectMin = imgRectMin;
      mparams.rectMax = imgRectMax;
    }

    id<MTLBuffer> fanBuf =
        [device newBufferWithBytes:fan
                            length:sizeof(KKVertex2D) * triCount * 3
                           options:MTLResourceStorageModeShared];
    free(fan);

    CanvasFillEncodeStencilPass(&passCtx, pipelines, fanBuf, triCount, &m);

    CanvasFillColorInputs colorIn = {
        .geom = geom,
        .fs = fs,
        .hachure = hachure,
        .bbMin = bbMin,
        .bbMax = bbMax,
        .useGradient = useGradient,
        .color = color,
        .gparams = gparams,
        .cv = &cv,
        .maskHachure = maskHachure,
        .maskTex = maskTex,
        .mparams = mparams,
        .imageWidth = imageWidth,
        .imageHeight = imageHeight,
        .sketchHachure = sketchOn && sp.roughness > 0.0001f,
        .sketchRoughness = sp.roughness,
        .sketchBowing = sp.bowing,
        .sketchSeed = sp.seed,
    };
    CanvasFillEncodeColorPass(&passCtx, pipelines, &m, &colorIn);

    CanvasFillEncodeCompositePass(&passCtx, pipelines);
  }
}
