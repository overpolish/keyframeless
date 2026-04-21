/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "LayerList_Private.h"
#import "ObjectParams.h"
#import "Plugin_Private.h"
#import "RenderFill.h"
#import "RenderImage.h"
#import "RenderStroke.h"
#import "ShaderTypes.h"
#import "SketchPath.h"
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

  if (pathStr.length > 0) {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:pathStr
                                                       options:0];
    NSMutableArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
    NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
    NSIndexSet *sel = uuid ? KKCanvasCurrentSelection(uuid) : nil;
    if (sel.count > 0) {
      KKParamsToSelectedPaths(paramGetAPI, sel, paths);
      NSData *newBlob = [KKBezierPath blobFromPaths:paths];
      pathStr = [newBlob base64EncodedStringWithOptions:0];
    } else {
      NSInteger selIdx = KKReadSelectedIndex(paramGetAPI);
      if (selIdx >= 0 && (NSUInteger)selIdx < paths.count &&
          !paths[selIdx].isGroup) {
        KKParamsToPath(paramGetAPI, paths[selIdx]);
        NSData *newBlob = [KKBezierPath blobFromPaths:paths];
        pathStr = [newBlob base64EncodedStringWithOptions:0];
      }
    }
  }

  NSMutableData *state = [NSMutableData dataWithBytes:&params
                                               length:sizeof(params)];
  if (pathStr.length > 0)
    [state appendData:[pathStr dataUsingEncoding:NSUTF8StringEncoding]];
  *pluginState = state;
  return (*pluginState != nil);
}

- (void)renderPath:(KKBezierPath *)path
          originalPath:(KKBezierPath *)orig
                target:(id<MTLTexture>)target
           outputWidth:(float)outputWidth
          outputHeight:(float)outputHeight
                device:(id<MTLDevice>)device
         commandBuffer:(id<MTLCommandBuffer>)commandBuffer
          viewportSize:(simd_uint2)viewportSize
               imagePS:(id<MTLRenderPipelineState>)imagePS
              strokePS:(id<MTLRenderPipelineState>)strokePS
         fillStencilPS:(id<MTLRenderPipelineState>)fillStencilPS
           fillColorPS:(id<MTLRenderPipelineState>)fillColorPS
       strokeStencilPS:(id<MTLRenderPipelineState>)strokeStencilPS
    fillStencilDSState:(id<MTLDepthStencilState>)fillStencilDSState
      fillColorDSState:(id<MTLDepthStencilState>)fillColorDSState
        stencilTexture:(id<MTLTexture>)stencilTexture {
  if (path.isImage && path.imagePath && imagePS) {
    id<MTLTexture> imgTex = KKGetOrLoadImageTexture(path.imagePath, device);
    if (imgTex) {
      KKBezierPoint bl = [path pointAtIndex:0];
      KKBezierPoint br = [path pointAtIndex:1];
      KKBezierPoint tr = [path pointAtIndex:2];
      KKBezierPoint tl = [path pointAtIndex:3];
      float hw = outputWidth / 2.0f;
      float hh = outputHeight / 2.0f;

      id<MTLTexture> drawTex =
          KKProcessImageWithEffects(imgTex, path, device, commandBuffer);

      float scaleX = (float)drawTex.width / (float)imgTex.width;
      float scaleY = (float)drawTex.height / (float)imgTex.height;
      float cx = (bl.x + tr.x) * 0.5f;
      float cy = (bl.y + tr.y) * 0.5f;

      CanvasFillVertex quadVerts[4] = {
          {{(cx + (bl.x - cx) * scaleX) * outputWidth - hw,
            (1.0f - (cy + (bl.y - cy) * scaleY)) * outputHeight - hh}},
          {{(cx + (br.x - cx) * scaleX) * outputWidth - hw,
            (1.0f - (cy + (br.y - cy) * scaleY)) * outputHeight - hh}},
          {{(cx + (tl.x - cx) * scaleX) * outputWidth - hw,
            (1.0f - (cy + (tl.y - cy) * scaleY)) * outputHeight - hh}},
          {{(cx + (tr.x - cx) * scaleX) * outputWidth - hw,
            (1.0f - (cy + (tr.y - cy) * scaleY)) * outputHeight - hh}},
      };

      float opacity = path.opacity;
      MTLRenderPassDescriptor *rpd =
          [MTLRenderPassDescriptor renderPassDescriptor];
      rpd.colorAttachments[0].texture = target;
      rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
      rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

      id<MTLRenderCommandEncoder> enc =
          [commandBuffer renderCommandEncoderWithDescriptor:rpd];
      [enc setViewport:(MTLViewport){0, 0, outputWidth, outputHeight, -1, 1}];
      [enc setRenderPipelineState:imagePS];
      [enc setVertexBytes:quadVerts length:sizeof(quadVerts) atIndex:0];
      [enc setVertexBytes:&viewportSize length:sizeof(viewportSize) atIndex:1];
      [enc setFragmentTexture:drawTex atIndex:0];
      [enc setFragmentBytes:&opacity length:sizeof(opacity) atIndex:0];
      [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip
              vertexStart:0
              vertexCount:4];
      [enc endEncoding];
    }
  } else if (path.fillEnabled && orig.count >= 2 && fillStencilPS &&
             fillColorPS && stencilTexture) {
    if (path.sketchFillStyle > 0) {
      KKBezierPath *clipPath = orig;
      if (orig.sketchEnabled && orig.sketchRoughness > 0.0001f) {
        clipPath = KKSketchPath(orig, orig.sketchRoughness, orig.sketchBowing,
                                orig.sketchSeed, 1, outputWidth, outputHeight);
      }
      KKRenderFillStencilOnly(clipPath, outputWidth, outputHeight, device,
                              commandBuffer, target, stencilTexture,
                              fillStencilPS, fillStencilDSState, viewportSize);
      KKRenderSketchFillForPath(
          orig, outputWidth, outputHeight, device, commandBuffer, target,
          stencilTexture, strokeStencilPS, fillColorDSState, viewportSize, YES);
    } else {
      KKBezierPath *fillPath = orig;
      if (orig.sketchEnabled && orig.sketchRoughness > 0.0001f) {
        fillPath = KKSketchPath(orig, orig.sketchRoughness, orig.sketchBowing,
                                orig.sketchSeed, 1, outputWidth, outputHeight);
      }
      KKRenderFillForPath(fillPath, outputWidth, outputHeight, device,
                          commandBuffer, target, stencilTexture, fillStencilPS,
                          fillColorPS, fillStencilDSState, fillColorDSState,
                          viewportSize);
    }
  }

  if (!path.isImage && path.strokeEnabled) {
    KKRenderStrokeForPath(path, outputWidth, outputHeight, device,
                          commandBuffer, target, strokePS, viewportSize);
  }
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

  @autoreleasepool {

    id<MTLDevice> device = [cache deviceWithRegistryID:registryID];
    id<MTLTexture> outputTexture =
        [destinationImage metalTextureForDevice:device];
    id<MTLTexture> inputTexture =
        [sourceImages[0] metalTextureForDevice:device];

    float outputWidth = (float)(destinationImage.tilePixelBounds.right -
                                destinationImage.tilePixelBounds.left);
    float outputHeight = (float)(destinationImage.tilePixelBounds.top -
                                 destinationImage.tilePixelBounds.bottom);

    NSString *renderUUID = KKLayerUUIDForAPI(self.apiManager);
    if (renderUUID) {
      KKLayerInstanceState *renderState = KKLayerStateForUUID(renderUUID);
      renderState.canvasWidth = outputWidth;
      renderState.canvasHeight = outputHeight;
    }

    FxRect srcBounds = sourceImages[0].imagePixelBounds;
    FxMatrix44 *inv = sourceImages[0].inversePixelTransform;
    FxPoint2D ll = {srcBounds.left, srcBounds.bottom};
    FxPoint2D ur = {srcBounds.right, srcBounds.top};
    ll = [inv transform2DPoint:ll];
    ur = [inv transform2DPoint:ur];
    float pxW = srcBounds.right - srcBounds.left;
    float logicalW = ur.x - ll.x;
    float renderScale = (logicalW > 0) ? (pxW / logicalW) : 1.0f;

    CanvasStrokeParams strokeParams = {8.0f, 1.0f, 0.0f, 0.0f};
    NSArray<KKBezierPath *> *paths = @[];

    if (pluginState.length >= sizeof(CanvasStrokeParams)) {
      memcpy(&strokeParams, pluginState.bytes, sizeof(CanvasStrokeParams));
      if (pluginState.length > sizeof(CanvasStrokeParams)) {
        NSData *blobData = [pluginState
            subdataWithRange:NSMakeRange(sizeof(CanvasStrokeParams),
                                         pluginState.length -
                                             sizeof(CanvasStrokeParams))];
        NSString *blobStr =
            [[NSString alloc] initWithData:blobData
                                  encoding:NSUTF8StringEncoding];
        if (blobStr.length > 0) {
          NSData *decoded = [[NSData alloc] initWithBase64EncodedString:blobStr
                                                                options:0];
          if (decoded)
            paths = [KKBezierPath pathsFromBlob:decoded];
        }
      }
    }

    // Fix up rounded rect geometry.
    for (KKBezierPath *p in paths) {
      if (p.isRect && !p.isImage && p.count >= 4) {
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

    // Scale pixel-space stroke properties by render quality.
    if (renderScale < 0.9999f) {
      for (KKBezierPath *p in paths) {
        p.strokeWidth *= renderScale;
        p.endWidth *= renderScale;
        p.dashLength *= renderScale;
        p.dashGap *= renderScale;
        p.dotGap *= renderScale;
        p.sketchFillGap *= renderScale;
        p.sketchFillWeight *= renderScale;
      }
    }

    // Keep original paths for sketch fill generation.
    NSMutableArray<KKBezierPath *> *origPathsMut =
        [NSMutableArray arrayWithCapacity:paths.count];
    NSMutableArray<KKBezierPath *> *renderPaths =
        [NSMutableArray arrayWithCapacity:paths.count];

    // Apply sketch jitter. When an open path has 2 strokes, split into
    // two separate single-pass paths.
    for (KKBezierPath *p in paths) {
      if (p.sketchEnabled && p.count >= 2 && !p.hidden) {
        BOOL needsSplit = !p.closed && p.sketchStrokes >= 2;
        if (needsSplit) {
          KKBezierPath *pass1 =
              KKSketchPath(p, p.sketchRoughness, p.sketchBowing, p.sketchSeed,
                           1, outputWidth, outputHeight);
          [renderPaths addObject:pass1];
          [origPathsMut addObject:p];
          KKBezierPath *pass2 = KKSketchPath(
              p, p.sketchRoughness, p.sketchBowing, p.sketchSeed ^ 0xFACE0042,
              1, outputWidth, outputHeight);
          pass2.fillEnabled = NO;
          pass2.startMarker = 0;
          pass2.endMarker = 0;
          [renderPaths addObject:pass2];
          [origPathsMut addObject:p];
        } else {
          [renderPaths
              addObject:KKSketchPath(p, p.sketchRoughness, p.sketchBowing,
                                     p.sketchSeed, p.sketchStrokes, outputWidth,
                                     outputHeight)];
          [origPathsMut addObject:p];
        }
      } else {
        [renderPaths addObject:p];
        [origPathsMut addObject:p];
      }
    }
    paths = renderPaths;
    NSArray<KKBezierPath *> *origPaths = origPathsMut;

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

    NSString *strokeKey =
        [NSString stringWithFormat:@"%@_stroke_%lu", kPluginID,
                                   (unsigned long)pixelFormat];
    id<MTLRenderPipelineState> strokePS =
        getOrCreatePipeline(strokeKey, registryID, pixelFormat, cache, device,
                            @"strokeVertexShader", @"strokeFragmentShader", YES,
                            MTLPixelFormatInvalid);
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
        fillColorKey, registryID, pixelFormat, cache, device,
        @"fillVertexShader", @"fillFragmentShader", YES, stencilFormat);

    NSString *strokeStencilKey =
        [NSString stringWithFormat:@"%@_strokeStencil_%lu", kPluginID,
                                   (unsigned long)pixelFormat];
    id<MTLRenderPipelineState> strokeStencilPS = getOrCreatePipeline(
        strokeStencilKey, registryID, pixelFormat, cache, device,
        @"strokeVertexShader", @"strokeFragmentShader", YES, stencilFormat);

    // Cache depth/stencil states.
    static id<MTLDepthStencilState> sFillStencilDSState = nil;
    static id<MTLDepthStencilState> sFillColorDSState = nil;
    if (!sFillStencilDSState) {
      MTLStencilDescriptor *stencilInvertDesc =
          [[MTLStencilDescriptor alloc] init];
      stencilInvertDesc.stencilCompareFunction = MTLCompareFunctionAlways;
      stencilInvertDesc.depthStencilPassOperation = MTLStencilOperationInvert;
      MTLDepthStencilDescriptor *fillStencilDSDesc =
          [[MTLDepthStencilDescriptor alloc] init];
      fillStencilDSDesc.frontFaceStencil = stencilInvertDesc;
      fillStencilDSDesc.backFaceStencil = stencilInvertDesc;
      sFillStencilDSState =
          [device newDepthStencilStateWithDescriptor:fillStencilDSDesc];

      MTLStencilDescriptor *stencilTestDesc =
          [[MTLStencilDescriptor alloc] init];
      stencilTestDesc.stencilCompareFunction = MTLCompareFunctionNotEqual;
      stencilTestDesc.readMask = 0xFF;
      stencilTestDesc.stencilFailureOperation = MTLStencilOperationKeep;
      stencilTestDesc.depthStencilPassOperation = MTLStencilOperationZero;
      MTLDepthStencilDescriptor *fillColorDSDesc =
          [[MTLDepthStencilDescriptor alloc] init];
      fillColorDSDesc.frontFaceStencil = stencilTestDesc;
      fillColorDSDesc.backFaceStencil = stencilTestDesc;
      sFillColorDSState =
          [device newDepthStencilStateWithDescriptor:fillColorDSDesc];
    }
    id<MTLDepthStencilState> fillStencilDSState = sFillStencilDSState;
    id<MTLDepthStencilState> fillColorDSState = sFillColorDSState;

    // Cache stencil and intermediate textures.
    static id<MTLTexture> sCachedStencilTex = nil;
    static id<MTLTexture> sCachedIntermediateTex = nil;
    static NSUInteger sCachedTexW = 0, sCachedTexH = 0;
    static MTLPixelFormat sCachedIntPixFmt = MTLPixelFormatInvalid;
    NSUInteger texW = (NSUInteger)outputWidth;
    NSUInteger texH = (NSUInteger)outputHeight;

    if (sCachedTexW != texW || sCachedTexH != texH) {
      sCachedStencilTex = nil;
      sCachedIntermediateTex = nil;
      sCachedTexW = texW;
      sCachedTexH = texH;
      sCachedIntPixFmt = MTLPixelFormatInvalid;
    }

    id<MTLTexture> stencilTexture = nil;
    BOOL anyFill = NO;
    for (NSUInteger pi = 0; pi < paths.count; pi++) {
      if (paths[pi].fillEnabled && paths[pi].count >= 2 && !paths[pi].hidden) {
        anyFill = YES;
        break;
      }
    }
    if (anyFill && fillStencilPS && fillColorPS) {
      if (!sCachedStencilTex) {
        MTLTextureDescriptor *stencilTexDesc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:stencilFormat
                                         width:texW
                                        height:texH
                                     mipmapped:NO];
        stencilTexDesc.usage = MTLTextureUsageRenderTarget;
        stencilTexDesc.storageMode = MTLStorageModePrivate;
        sCachedStencilTex = [device newTextureWithDescriptor:stencilTexDesc];
      }
      stencilTexture = sCachedStencilTex;
    }

    NSString *compositeKey =
        [NSString stringWithFormat:@"%@_composite_%lu", kPluginID,
                                   (unsigned long)pixelFormat];
    id<MTLRenderPipelineState> compositePS = getOrCreatePipeline(
        compositeKey, registryID, pixelFormat, cache, device,
        @"compositeVertexShader", @"compositeFragmentShader", YES,
        MTLPixelFormatInvalid);

    NSString *imageKey = [NSString stringWithFormat:@"%@_image_%lu", kPluginID,
                                                    (unsigned long)pixelFormat];
    id<MTLRenderPipelineState> imagePS = getOrCreatePipeline(
        imageKey, registryID, pixelFormat, cache, device, @"imageVertexShader",
        @"imageFragmentShader", YES, MTLPixelFormatInvalid);

    id<MTLTexture> intermediateTexture = nil;
    if (compositePS) {
      if (!sCachedIntermediateTex || sCachedIntPixFmt != pixelFormat) {
        MTLTextureDescriptor *intDesc =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixelFormat
                                                               width:texW
                                                              height:texH
                                                           mipmapped:NO];
        intDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        intDesc.storageMode = MTLStorageModePrivate;
        sCachedIntermediateTex = [device newTextureWithDescriptor:intDesc];
        sCachedIntPixFmt = pixelFormat;
      }
      intermediateTexture = sCachedIntermediateTex;
    }

    for (NSUInteger pi = paths.count; pi > 0; pi--) {
      @autoreleasepool {
        KKBezierPath *path = paths[pi - 1];
        KKBezierPath *orig = origPaths[pi - 1];
        if (path.count < 2 || path.hidden)
          continue;

        float pathOpacity = path.opacity;
        BOOL needsIntermediate =
            intermediateTexture && compositePS && pathOpacity < 0.9999f;

        id<MTLTexture> target =
            needsIntermediate ? intermediateTexture : outputTexture;

        if (needsIntermediate) {
          path.opacity = 1.0f;
          orig.opacity = 1.0f;

          MTLRenderPassDescriptor *clearRPD =
              [MTLRenderPassDescriptor renderPassDescriptor];
          clearRPD.colorAttachments[0].texture = intermediateTexture;
          clearRPD.colorAttachments[0].loadAction = MTLLoadActionClear;
          clearRPD.colorAttachments[0].storeAction = MTLStoreActionStore;
          clearRPD.colorAttachments[0].clearColor =
              MTLClearColorMake(0, 0, 0, 0);
          id<MTLRenderCommandEncoder> clearEnc =
              [commandBuffer renderCommandEncoderWithDescriptor:clearRPD];
          [clearEnc endEncoding];
        }

        [self renderPath:path
                  originalPath:orig
                        target:target
                   outputWidth:outputWidth
                  outputHeight:outputHeight
                        device:device
                 commandBuffer:commandBuffer
                  viewportSize:viewportSize
                       imagePS:imagePS
                      strokePS:strokePS
                 fillStencilPS:fillStencilPS
                   fillColorPS:fillColorPS
               strokeStencilPS:strokeStencilPS
            fillStencilDSState:fillStencilDSState
              fillColorDSState:fillColorDSState
                stencilTexture:stencilTexture];

        if (needsIntermediate) {
          path.opacity = pathOpacity;
          orig.opacity = pathOpacity;

          MTLRenderPassDescriptor *compRPD =
              [MTLRenderPassDescriptor renderPassDescriptor];
          compRPD.colorAttachments[0].texture = outputTexture;
          compRPD.colorAttachments[0].loadAction = MTLLoadActionLoad;
          compRPD.colorAttachments[0].storeAction = MTLStoreActionStore;

          id<MTLRenderCommandEncoder> compEnc =
              [commandBuffer renderCommandEncoderWithDescriptor:compRPD];
          [compEnc setViewport:(MTLViewport){0, 0, outputWidth, outputHeight,
                                             -1, 1}];
          [compEnc setRenderPipelineState:compositePS];
          [compEnc setFragmentTexture:intermediateTexture atIndex:0];
          [compEnc setFragmentBytes:&pathOpacity
                             length:sizeof(pathOpacity)
                            atIndex:0];
          [compEnc drawPrimitives:MTLPrimitiveTypeTriangleStrip
                      vertexStart:0
                      vertexCount:4];
          [compEnc endEncoding];
        }
      }
    }

    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];

  } // @autoreleasepool

  [cache returnCommandQueueToCache:commandQueue];
  return YES;
}

@end
