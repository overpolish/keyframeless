/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "ObjectParams.h"
#import "Plugin_Private.h"
#import "ShaderTypes.h"
#import "Tessellation.h"
#import <IOSurface/IOSurfaceObjC.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

static id<MTLRenderPipelineState> getOrCreatePipeline(
    NSString *key, uint64_t registryID, MTLPixelFormat pixelFormat,
    KKMetalDeviceCache *cache, id<MTLDevice> device, NSString *vertexName,
    NSString *fragmentName, BOOL blending, MTLPixelFormat stencilFormat) {
  id<MTLRenderPipelineState> ps = [cache pipelineStateForPluginID:key
                                                       registryID:registryID
                                                      pixelFormat:pixelFormat];
  if (ps)
    return ps;

  id<MTLLibrary> library = [device newDefaultLibrary];
  MTLRenderPipelineDescriptor *desc =
      [[MTLRenderPipelineDescriptor alloc] init];
  desc.vertexFunction = [library newFunctionWithName:vertexName];
  desc.fragmentFunction = [library newFunctionWithName:fragmentName];
  desc.colorAttachments[0].pixelFormat = pixelFormat;
  if (blending) {
    desc.colorAttachments[0].blendingEnabled = YES;
    desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    desc.colorAttachments[0].destinationRGBBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    desc.colorAttachments[0].destinationAlphaBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
  }
  if (stencilFormat != MTLPixelFormatInvalid)
    desc.stencilAttachmentPixelFormat = stencilFormat;
  if (!blending && stencilFormat != MTLPixelFormatInvalid)
    desc.colorAttachments[0].writeMask = MTLColorWriteMaskNone;

  NSError *error = nil;
  ps = [device newRenderPipelineStateWithDescriptor:desc error:&error];
  if (ps)
    [cache registerPipelineState:ps
                     forPluginID:key
                      registryID:registryID
                     pixelFormat:pixelFormat];
  return ps;
}

static void renderFillForPath(KKBezierPath *path, float outputWidth,
                              float outputHeight, id<MTLDevice> device,
                              id<MTLCommandBuffer> commandBuffer,
                              id<MTLTexture> outputTexture,
                              id<MTLTexture> stencilTexture,
                              id<MTLRenderPipelineState> fillStencilPS,
                              id<MTLRenderPipelineState> fillColorPS,
                              id<MTLDepthStencilState> fillStencilDSState,
                              id<MTLDepthStencilState> fillColorDSState,
                              simd_uint2 viewportSize) {
  NSUInteger segsPerCurve = 64;
  BOOL isClosed = path.closed;
  NSUInteger curveCount = isClosed ? path.count : (path.count - 1);
  NSUInteger outlineCount = curveCount * segsPerCurve + (isClosed ? 0 : 1);
  simd_float2 *outline = malloc(outlineCount * sizeof(simd_float2));
  NSUInteger oc = 0;
  for (NSUInteger c = 0; c < curveCount; c++) {
    NSUInteger nextIdx = isClosed ? ((c + 1) % path.count) : (c + 1);
    for (NSUInteger s = 0; s < segsPerCurve; s++) {
      float t = (float)s / (float)segsPerCurve;
      simd_float2 pos = [path evaluatePointAtIndex:c nextIndex:nextIdx atT:t];
      simd_float2 px = {pos.x * outputWidth - outputWidth / 2.0f,
                        (1.0f - pos.y) * outputHeight - outputHeight / 2.0f};
      outline[oc++] = px;
    }
  }
  if (!isClosed) {
    simd_float2 pos = [path evaluatePointAtIndex:curveCount - 1
                                       nextIndex:curveCount
                                             atT:1.0f];
    simd_float2 px = {pos.x * outputWidth - outputWidth / 2.0f,
                      (1.0f - pos.y) * outputHeight - outputHeight / 2.0f};
    outline[oc++] = px;
  }

  simd_float2 center = {0, 0};
  for (NSUInteger i = 0; i < oc; i++)
    center += outline[i];
  center /= (float)oc;

  NSUInteger triCount = oc;
  CanvasFillVertex *fillVerts = malloc(triCount * 3 * sizeof(CanvasFillVertex));
  for (NSUInteger i = 0; i < triCount; i++) {
    NSUInteger next = (i + 1) % oc;
    fillVerts[i * 3 + 0].position = center;
    fillVerts[i * 3 + 1].position = outline[i];
    fillVerts[i * 3 + 2].position = outline[next];
  }
  free(outline);

  id<MTLBuffer> fillBuf =
      [device newBufferWithBytes:fillVerts
                          length:triCount * 3 * sizeof(CanvasFillVertex)
                         options:MTLResourceStorageModeShared];
  free(fillVerts);

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
    [enc setViewport:(MTLViewport){0, 0, outputWidth, outputHeight, -1, 1}];
    [enc setRenderPipelineState:fillStencilPS];
    [enc setDepthStencilState:fillStencilDSState];
    [enc setStencilReferenceValue:0];
    [enc setVertexBuffer:fillBuf offset:0 atIndex:0];
    [enc setVertexBytes:&viewportSize length:sizeof(viewportSize) atIndex:1];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle
            vertexStart:0
            vertexCount:triCount * 3];
    [enc endEncoding];
  }

  {
    float a = path.opacity;
    simd_float4 fc = {path.fillR * a, path.fillG * a, path.fillB * a, a};

    CanvasFillVertex quadVerts[6] = {
        {{-(float)outputWidth, -(float)outputHeight}},
        {{(float)outputWidth, -(float)outputHeight}},
        {{-(float)outputWidth, (float)outputHeight}},
        {{(float)outputWidth, -(float)outputHeight}},
        {{(float)outputWidth, (float)outputHeight}},
        {{-(float)outputWidth, (float)outputHeight}},
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
    [enc setViewport:(MTLViewport){0, 0, outputWidth, outputHeight, -1, 1}];
    [enc setRenderPipelineState:fillColorPS];
    [enc setDepthStencilState:fillColorDSState];
    [enc setStencilReferenceValue:0];
    [enc setVertexBytes:quadVerts length:sizeof(quadVerts) atIndex:0];
    [enc setVertexBytes:&viewportSize length:sizeof(viewportSize) atIndex:1];
    [enc setFragmentBytes:&fc length:sizeof(fc) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [enc endEncoding];
  }
}

static void renderStrokeForPath(KKBezierPath *path, float outputWidth,
                                float outputHeight, id<MTLDevice> device,
                                id<MTLCommandBuffer> commandBuffer,
                                id<MTLTexture> outputTexture,
                                id<MTLRenderPipelineState> strokePS,
                                simd_uint2 viewportSize) {
  float sw = path.strokeWidth;
  float oa = path.opacity;
  simd_float4 color = {path.strokeR * oa, path.strokeG * oa, path.strokeB * oa,
                       oa};

  CanvasVertex *vertices = NULL;
  NSUInteger vertexCount = 0;
  NSUInteger segsPerCurve = 128;
  NSUInteger curveCount = path.count - 1;
  if (path.closed && path.count >= 2)
    curveCount = path.count;

  if (path.strokeStyle == 1) {
    NSUInteger maxVertices = curveCount * segsPerCurve * 12 + 8192;
    vertices = malloc(maxVertices * sizeof(CanvasVertex));
    vertexCount = KKTessellateDashedPath(path, sw, outputWidth, outputHeight,
                                         path.dashLength, path.dashGap,
                                         path.lineJoin, vertices);
  } else if (path.strokeStyle == 2) {
    NSUInteger maxVertices = curveCount * segsPerCurve * 4 + 4096;
    vertices = malloc(maxVertices * sizeof(CanvasVertex));
    vertexCount = KKTessellateDottedPath(path, sw, outputWidth, outputHeight,
                                         path.dotGap, vertices);
  } else {
    NSUInteger capExtra = (!path.closed && path.lineCap != 0) ? 256 : 0;
    NSUInteger joinExtra = (path.lineJoin != 0) ? curveCount * 48 : 0;
    NSUInteger maxVertices =
        curveCount * ((segsPerCurve + 1) * 2 + 2) + 2 + capExtra + joinExtra;
    vertices = malloc(maxVertices * sizeof(CanvasVertex));
    vertexCount = KKTessellatePath(path, sw, outputWidth, outputHeight,
                                   path.lineCap, path.lineJoin, vertices);
  }

  if (vertexCount > 0 && vertices) {
    MTLRenderPassDescriptor *rpd =
        [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = outputTexture;
    rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> enc =
        [commandBuffer renderCommandEncoderWithDescriptor:rpd];
    [enc setViewport:(MTLViewport){0, 0, outputWidth, outputHeight, -1, 1}];
    [enc setRenderPipelineState:strokePS];

    id<MTLBuffer> vertexBuffer =
        [device newBufferWithBytes:vertices
                            length:vertexCount * sizeof(CanvasVertex)
                           options:MTLResourceStorageModeShared];
    [enc setVertexBuffer:vertexBuffer offset:0 atIndex:0];
    [enc setVertexBytes:&viewportSize length:sizeof(viewportSize) atIndex:1];
    [enc setFragmentBytes:&color length:sizeof(color) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip
            vertexStart:0
            vertexCount:vertexCount];
    [enc endEncoding];
  }
  free(vertices);
}

@implementation CanvasPlugin (Render)

- (BOOL)pluginState:(NSData **)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];

  CanvasStrokeParams params;
  double width = 8.0;
  [paramGetAPI getFloatValue:&width
               fromParameter:kParamStrokeWidth
                      atTime:renderTime];
  params.strokeWidth = (float)width;

  double r = 1.0, g = 0.0, b = 0.0;
  [paramGetAPI getRedValue:&r
                greenValue:&g
                 blueValue:&b
             fromParameter:kParamStrokeColor
                    atTime:renderTime];
  params.r = (float)r;
  params.g = (float)g;
  params.b = (float)b;

  NSString *pathStr = nil;
  [paramGetAPI getStringParameterValue:&pathStr fromParameter:kParamPathData];

  NSInteger selIdx = KKReadSelectedIndex(paramGetAPI);
  if (pathStr.length > 0 && selIdx >= 0) {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:pathStr
                                                       options:0];
    NSMutableArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
    if ((NSUInteger)selIdx < paths.count && !paths[selIdx].isGroup) {
      KKParamsToPath(paramGetAPI, paths[selIdx]);
      NSData *newBlob = [KKBezierPath blobFromPaths:paths];
      pathStr = [newBlob base64EncodedStringWithOptions:0];
    }
  }

  NSMutableData *state = [NSMutableData dataWithBytes:&params
                                               length:sizeof(params)];
  if (pathStr.length > 0)
    [state appendData:[pathStr dataUsingEncoding:NSUTF8StringEncoding]];
  *pluginState = state;
  return (*pluginState != nil);
}

- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError *_Nullable *)outError {
  if (!pluginState || !destinationImage.ioSurface || sourceImages.count < 1) {
    if (outError != NULL)
      *outError =
          [NSError errorWithDomain:FxPlugErrorDomain
                              code:kFxError_InvalidParameter
                          userInfo:@{
                            NSLocalizedDescriptionKey :
                                @"Invalid plugin state received from host"
                          }];
    return NO;
  }

  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  MTLPixelFormat pixelFormat =
      [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
  uint64_t registryID = destinationImage.deviceRegistryID;
  id<MTLCommandQueue> commandQueue =
      [cache commandQueueWithRegistryID:registryID pixelFormat:pixelFormat];
  if (!commandQueue)
    return NO;

  id<MTLDevice> device = [cache deviceWithRegistryID:registryID];
  id<MTLTexture> outputTexture =
      [destinationImage metalTextureForDevice:device];
  id<MTLTexture> inputTexture = [sourceImages[0] metalTextureForDevice:device];

  float outputWidth = (float)(destinationImage.tilePixelBounds.right -
                              destinationImage.tilePixelBounds.left);
  float outputHeight = (float)(destinationImage.tilePixelBounds.top -
                               destinationImage.tilePixelBounds.bottom);

  CanvasStrokeParams strokeParams = {8.0f, 1.0f, 0.0f, 0.0f};
  NSArray<KKBezierPath *> *paths = @[];

  if (pluginState.length >= sizeof(CanvasStrokeParams)) {
    memcpy(&strokeParams, pluginState.bytes, sizeof(CanvasStrokeParams));
    if (pluginState.length > sizeof(CanvasStrokeParams)) {
      NSData *blobData = [pluginState
          subdataWithRange:NSMakeRange(sizeof(CanvasStrokeParams),
                                       pluginState.length -
                                           sizeof(CanvasStrokeParams))];
      NSString *blobStr = [[NSString alloc] initWithData:blobData
                                                encoding:NSUTF8StringEncoding];
      if (blobStr.length > 0) {
        NSData *decoded = [[NSData alloc] initWithBase64EncodedString:blobStr
                                                              options:0];
        if (decoded)
          paths = [KKBezierPath pathsFromBlob:decoded];
      }
    }
  }

  for (KKBezierPath *p in paths) {
    if (p.isRect && p.count >= 4) {
      simd_float2 pMin = {HUGE_VALF, HUGE_VALF};
      simd_float2 pMax = {-HUGE_VALF, -HUGE_VALF};
      for (NSUInteger i = 0; i < p.count; i++) {
        KKBezierPoint pt = [p pointAtIndex:i];
        pMin.x = fminf(pMin.x, pt.x);
        pMin.y = fminf(pMin.y, pt.y);
        pMax.x = fmaxf(pMax.x, pt.x);
        pMax.y = fmaxf(pMax.y, pt.y);
      }
      float rW = (pMax.x - pMin.x) * outputWidth;
      float rH = (pMax.y - pMin.y) * outputHeight;
      [p setRoundedRectWithMin:pMin
                           max:pMax
                    fractionTL:p.cornerRadiusTL
                    fractionTR:p.cornerRadiusTR
                    fractionBR:p.cornerRadiusBR
                    fractionBL:p.cornerRadiusBL
                   canvasWidth:rW
                  canvasHeight:rH];
    }
  }

  id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
  commandBuffer.label = @"Canvas Command Buffer";
  [commandBuffer enqueue];

  {
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    NSUInteger copyW = MIN(inputTexture.width, outputTexture.width);
    NSUInteger copyH = MIN(inputTexture.height, outputTexture.height);
    [blit copyFromTexture:inputTexture
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(copyW, copyH, 1)
                toTexture:outputTexture
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
  }

  BOOL hasDrawablePaths = NO;
  for (KKBezierPath *p in paths) {
    if (p.count >= 2 && !p.hidden) {
      hasDrawablePaths = YES;
      break;
    }
  }
  if (!hasDrawablePaths) {
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    [cache returnCommandQueueToCache:commandQueue];
    return YES;
  }

  NSString *strokeKey = [NSString
      stringWithFormat:@"%@_stroke_%lu", kPluginID, (unsigned long)pixelFormat];
  id<MTLRenderPipelineState> strokePS = getOrCreatePipeline(
      strokeKey, registryID, pixelFormat, cache, device, @"strokeVertexShader",
      @"strokeFragmentShader", YES, MTLPixelFormatInvalid);
  if (!strokePS) {
    [cache returnCommandQueueToCache:commandQueue];
    return NO;
  }

  simd_uint2 viewportSize = {(unsigned int)outputWidth,
                             (unsigned int)outputHeight};

  MTLPixelFormat stencilFormat = MTLPixelFormatStencil8;

  NSString *fillStencilKey =
      [NSString stringWithFormat:@"%@_fillStencil_%lu", kPluginID,
                                 (unsigned long)pixelFormat];
  id<MTLRenderPipelineState> fillStencilPS = getOrCreatePipeline(
      fillStencilKey, registryID, pixelFormat, cache, device,
      @"fillVertexShader", @"fillFragmentShader", NO, stencilFormat);

  NSString *fillColorKey =
      [NSString stringWithFormat:@"%@_fillColor_%lu", kPluginID,
                                 (unsigned long)pixelFormat];
  id<MTLRenderPipelineState> fillColorPS = getOrCreatePipeline(
      fillColorKey, registryID, pixelFormat, cache, device, @"fillVertexShader",
      @"fillFragmentShader", YES, stencilFormat);

  MTLStencilDescriptor *stencilInvertDesc = [[MTLStencilDescriptor alloc] init];
  stencilInvertDesc.stencilCompareFunction = MTLCompareFunctionAlways;
  stencilInvertDesc.depthStencilPassOperation = MTLStencilOperationInvert;

  MTLDepthStencilDescriptor *fillStencilDSDesc =
      [[MTLDepthStencilDescriptor alloc] init];
  fillStencilDSDesc.frontFaceStencil = stencilInvertDesc;
  fillStencilDSDesc.backFaceStencil = stencilInvertDesc;
  id<MTLDepthStencilState> fillStencilDSState =
      [device newDepthStencilStateWithDescriptor:fillStencilDSDesc];

  MTLStencilDescriptor *stencilTestDesc = [[MTLStencilDescriptor alloc] init];
  stencilTestDesc.stencilCompareFunction = MTLCompareFunctionNotEqual;
  stencilTestDesc.readMask = 0xFF;
  stencilTestDesc.stencilFailureOperation = MTLStencilOperationKeep;
  stencilTestDesc.depthStencilPassOperation = MTLStencilOperationZero;

  MTLDepthStencilDescriptor *fillColorDSDesc =
      [[MTLDepthStencilDescriptor alloc] init];
  fillColorDSDesc.frontFaceStencil = stencilTestDesc;
  fillColorDSDesc.backFaceStencil = stencilTestDesc;
  id<MTLDepthStencilState> fillColorDSState =
      [device newDepthStencilStateWithDescriptor:fillColorDSDesc];

  id<MTLTexture> stencilTexture = nil;
  BOOL anyFill = NO;
  for (NSUInteger pi = 0; pi < paths.count; pi++) {
    if (paths[pi].fillEnabled && paths[pi].count >= 3 && !paths[pi].hidden) {
      anyFill = YES;
      break;
    }
  }
  if (anyFill && fillStencilPS && fillColorPS) {
    MTLTextureDescriptor *stencilTexDesc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:stencilFormat
                                                           width:outputWidth
                                                          height:outputHeight
                                                       mipmapped:NO];
    stencilTexDesc.usage = MTLTextureUsageRenderTarget;
    stencilTexDesc.storageMode = MTLStorageModePrivate;
    stencilTexture = [device newTextureWithDescriptor:stencilTexDesc];
  }

  for (NSUInteger pi = paths.count; pi > 0; pi--) {
    KKBezierPath *path = paths[pi - 1];
    if (path.count < 2 || path.hidden)
      continue;

    if (path.fillEnabled && path.count >= 3 && fillStencilPS && fillColorPS &&
        stencilTexture) {
      renderFillForPath(path, outputWidth, outputHeight, device, commandBuffer,
                        outputTexture, stencilTexture, fillStencilPS,
                        fillColorPS, fillStencilDSState, fillColorDSState,
                        viewportSize);
    }

    if (path.strokeEnabled) {
      renderStrokeForPath(path, outputWidth, outputHeight, device,
                          commandBuffer, outputTexture, strokePS, viewportSize);
    }
  }

  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];
  [cache returnCommandQueueToCache:commandQueue];
  return YES;
}

@end
