/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "ObjectParams.h"
#import "Plugin_Private.h"
#import "ShaderTypes.h"
#import <IOSurface/IOSurfaceObjC.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

static simd_float2 miterNormal(simd_float2 n1, simd_float2 n2) {
  simd_float2 avg = n1 + n2;
  float avgLen = simd_length(avg);
  if (avgLen < 1e-6f)
    return n1;
  avg /= avgLen;
  float d = simd_dot(avg, n1);
  if (d > 0.5f)
    avg /= d;
  return avg;
}

static simd_float2 normalAtPoint(KKBezierPath *path, NSUInteger c,
                                 NSUInteger segsPerCurve, NSUInteger i,
                                 NSUInteger curveCount) {
  NSUInteger nextIdx = (c + 1) % path.count;
  float t = (float)i / (float)segsPerCurve;
  simd_float2 tangent = [path evaluateTangentAtIndex:c nextIndex:nextIdx atT:t];
  tangent.y = -tangent.y;
  float len = simd_length(tangent);
  if (len < 1e-6f)
    tangent = (simd_float2){1.0f, 0.0f};
  else
    tangent /= len;

  simd_float2 normal = {-tangent.y, tangent.x};
  BOOL isEnd = (i == segsPerCurve);
  BOOL isStart = (i == 0);

  if (isEnd && (c < curveCount - 1 || (path.closed && c == curveCount - 1))) {
    NSUInteger nextC = (c < curveCount - 1) ? (c + 1) % path.count : 0;
    NSUInteger nextNext =
        (c < curveCount - 1) ? (c + 2) % path.count : 1 % path.count;
    KKBezierPoint curPt = [path pointAtIndex:nextIdx];
    KKBezierPoint nxtPt = [path pointAtIndex:nextC];
    if (curPt.type == KKBezierPointLinear &&
        nxtPt.type == KKBezierPointLinear) {
      simd_float2 nextTangent = [path evaluateTangentAtIndex:nextC
                                                   nextIndex:nextNext
                                                         atT:0.0f];
      nextTangent.y = -nextTangent.y;
      float nLen = simd_length(nextTangent);
      if (nLen > 1e-6f) {
        nextTangent /= nLen;
        normal =
            miterNormal(normal, (simd_float2){-nextTangent.y, nextTangent.x});
      }
    }
  } else if (isStart && (c > 0 || (path.closed && c == 0))) {
    NSUInteger prevC = (c > 0) ? c - 1 : curveCount - 1;
    NSUInteger prevIdx = c;
    KKBezierPoint curPt = [path pointAtIndex:prevIdx];
    KKBezierPoint prvPt = [path pointAtIndex:prevC];
    if (prvPt.type == KKBezierPointLinear &&
        curPt.type == KKBezierPointLinear) {
      simd_float2 prevTangent = [path evaluateTangentAtIndex:prevC
                                                   nextIndex:prevIdx
                                                         atT:1.0f];
      prevTangent.y = -prevTangent.y;
      float pLen = simd_length(prevTangent);
      if (pLen > 1e-6f) {
        prevTangent /= pLen;
        normal =
            miterNormal((simd_float2){-prevTangent.y, prevTangent.x}, normal);
      }
    }
  }
  return normal;
}

static NSUInteger tessellatePath(KKBezierPath *path, float strokeWidth,
                                 float outputWidth, float outputHeight,
                                 CanvasVertex *vertices) {
  float aaPadding = 1.0f;
  float halfWidth = (strokeWidth / 2.0f) + aaPadding;
  NSUInteger segsPerCurve = 128;
  NSUInteger curveCount = path.count - 1;
  if (path.closed && path.count >= 2)
    curveCount = path.count;
  NSUInteger vertexCount = 0;

  for (NSUInteger c = 0; c < curveCount; c++) {
    if (c > 0 && vertexCount > 0) {
      vertices[vertexCount] = vertices[vertexCount - 1];
      vertexCount++;
    }

    for (NSUInteger i = 0; i <= segsPerCurve; i++) {
      float t = (float)i / (float)segsPerCurve;
      NSUInteger nextIdx = (c + 1) % path.count;
      simd_float2 pos = [path evaluatePointAtIndex:c nextIndex:nextIdx atT:t];
      simd_float2 normal = normalAtPoint(path, c, segsPerCurve, i, curveCount);

      simd_float2 pixelPos = {pos.x * outputWidth,
                              (1.0f - pos.y) * outputHeight};
      simd_float2 centered = {pixelPos.x - outputWidth / 2.0f,
                              pixelPos.y - outputHeight / 2.0f};

      float capDist = 0.0f;
      if (!path.closed) {
        float globalT =
            ((float)c + (float)i / (float)segsPerCurve) / (float)curveCount;
        float capFade = 1.0f;
        float startDist = globalT * (float)curveCount * (float)segsPerCurve;
        float endDist =
            (1.0f - globalT) * (float)curveCount * (float)segsPerCurve;
        if (startDist < capFade)
          capDist = 1.0f - startDist / capFade;
        if (endDist < capFade)
          capDist = 1.0f - endDist / capFade;
      }

      vertices[vertexCount].position = centered + normal * halfWidth;
      vertices[vertexCount].edgeDistance = 1.0f;
      vertices[vertexCount].capDistance = capDist;
      vertexCount++;
      vertices[vertexCount].position = centered - normal * halfWidth;
      vertices[vertexCount].edgeDistance = -1.0f;
      vertices[vertexCount].capDistance = capDist;
      vertexCount++;
    }

    if (c < curveCount - 1) {
      vertices[vertexCount] = vertices[vertexCount - 1];
      vertexCount++;
    }
  }
  return vertexCount;
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

  // Patch selected path from current param values so the render reflects
  // inspector edits immediately (before pathData is persisted).
  NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
  NSIndexSet *sel = uuid ? KKCanvasCurrentSelection(uuid) : nil;
  if (pathStr.length > 0 && sel.count > 0) {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:pathStr
                                                       options:0];
    NSMutableArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
    KKBezierPath *selPath = KKSelectedPath(sel, paths);
    if (selPath) {
      KKParamsToPath(paramGetAPI, selPath);
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
  id<MTLRenderPipelineState> strokePS =
      [cache pipelineStateForPluginID:strokeKey
                           registryID:registryID
                          pixelFormat:pixelFormat];
  if (!strokePS) {
    id<MTLLibrary> library = [device newDefaultLibrary];
    MTLRenderPipelineDescriptor *desc =
        [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = [library newFunctionWithName:@"strokeVertexShader"];
    desc.fragmentFunction =
        [library newFunctionWithName:@"strokeFragmentShader"];
    desc.colorAttachments[0].pixelFormat = pixelFormat;
    desc.colorAttachments[0].blendingEnabled = YES;
    desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    desc.colorAttachments[0].destinationRGBBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    desc.colorAttachments[0].destinationAlphaBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;

    NSError *error = nil;
    strokePS = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!strokePS) {
      [cache returnCommandQueueToCache:commandQueue];
      return NO;
    }
    [cache registerPipelineState:strokePS
                     forPluginID:strokeKey
                      registryID:registryID
                     pixelFormat:pixelFormat];
  }

  simd_uint2 viewportSize = {(unsigned int)outputWidth,
                             (unsigned int)outputHeight};

  // Build fill pipeline on demand.
  NSString *fillKey = [NSString
      stringWithFormat:@"%@_fill_%lu", kPluginID, (unsigned long)pixelFormat];
  id<MTLRenderPipelineState> fillPS =
      [cache pipelineStateForPluginID:fillKey
                           registryID:registryID
                          pixelFormat:pixelFormat];
  if (!fillPS) {
    id<MTLLibrary> library = [device newDefaultLibrary];
    MTLRenderPipelineDescriptor *desc =
        [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = [library newFunctionWithName:@"fillVertexShader"];
    desc.fragmentFunction = [library newFunctionWithName:@"fillFragmentShader"];
    desc.colorAttachments[0].pixelFormat = pixelFormat;
    desc.colorAttachments[0].blendingEnabled = YES;
    desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    desc.colorAttachments[0].destinationRGBBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    desc.colorAttachments[0].destinationAlphaBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;

    NSError *error = nil;
    fillPS = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (fillPS)
      [cache registerPipelineState:fillPS
                       forPluginID:fillKey
                        registryID:registryID
                       pixelFormat:pixelFormat];
  }

  // Render in reverse: index 0 is drawn last (on top), matching layer list.
  for (NSUInteger pi = paths.count; pi > 0; pi--) {
    KKBezierPath *path = paths[pi - 1];
    if (path.count < 2 || path.hidden)
      continue;

    // Fill (behind stroke): fan triangulation from centroid for closed paths.
    if (path.fillEnabled && path.closed && path.count >= 3 && fillPS) {
      NSUInteger segsPerCurve = 64;
      NSUInteger curveCount = path.count;
      NSUInteger outlineCount = curveCount * segsPerCurve;
      simd_float2 *outline = malloc(outlineCount * sizeof(simd_float2));
      NSUInteger oc = 0;
      for (NSUInteger c = 0; c < curveCount; c++) {
        NSUInteger nextIdx = (c + 1) % path.count;
        for (NSUInteger s = 0; s < segsPerCurve; s++) {
          float t = (float)s / (float)segsPerCurve;
          simd_float2 pos = [path evaluatePointAtIndex:c
                                             nextIndex:nextIdx
                                                   atT:t];
          simd_float2 px = {pos.x * outputWidth - outputWidth / 2.0f,
                            (1.0f - pos.y) * outputHeight -
                                outputHeight / 2.0f};
          outline[oc++] = px;
        }
      }

      // Centroid
      simd_float2 center = {0, 0};
      for (NSUInteger i = 0; i < oc; i++)
        center += outline[i];
      center /= (float)oc;

      // Fan triangles from centroid
      NSUInteger triCount = oc;
      CanvasFillVertex *fillVerts =
          malloc(triCount * 3 * sizeof(CanvasFillVertex));
      for (NSUInteger i = 0; i < oc; i++) {
        NSUInteger next = (i + 1) % oc;
        fillVerts[i * 3 + 0].position = center;
        fillVerts[i * 3 + 1].position = outline[i];
        fillVerts[i * 3 + 2].position = outline[next];
      }
      free(outline);

      simd_float4 fc = {path.fillR, path.fillG, path.fillB, 1.0f};

      MTLRenderPassDescriptor *rpd =
          [MTLRenderPassDescriptor renderPassDescriptor];
      rpd.colorAttachments[0].texture = outputTexture;
      rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
      rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

      id<MTLRenderCommandEncoder> enc =
          [commandBuffer renderCommandEncoderWithDescriptor:rpd];
      [enc setViewport:(MTLViewport){0, 0, outputWidth, outputHeight, -1, 1}];
      [enc setRenderPipelineState:fillPS];

      id<MTLBuffer> fillBuf =
          [device newBufferWithBytes:fillVerts
                              length:triCount * 3 * sizeof(CanvasFillVertex)
                             options:MTLResourceStorageModeShared];
      [enc setVertexBuffer:fillBuf offset:0 atIndex:0];
      [enc setVertexBytes:&viewportSize length:sizeof(viewportSize) atIndex:1];
      [enc setFragmentBytes:&fc length:sizeof(fc) atIndex:0];
      [enc drawPrimitives:MTLPrimitiveTypeTriangle
              vertexStart:0
              vertexCount:triCount * 3];
      [enc endEncoding];
      free(fillVerts);
    }

    // Stroke
    float sw = path.strokeWidth;
    simd_float4 color = {path.strokeR, path.strokeG, path.strokeB, 1.0f};

    NSUInteger segsPerCurve = 128;
    NSUInteger curveCount = path.count - 1;
    if (path.closed && path.count >= 2)
      curveCount = path.count;
    NSUInteger maxVertices = curveCount * ((segsPerCurve + 1) * 2 + 2) + 2;
    CanvasVertex *vertices =
        (CanvasVertex *)malloc(maxVertices * sizeof(CanvasVertex));
    NSUInteger vertexCount =
        tessellatePath(path, sw, outputWidth, outputHeight, vertices);

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
    free(vertices);
  }

  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];
  [cache returnCommandQueueToCache:commandQueue];
  return YES;
}

@end
#pragma clang diagnostic pop
