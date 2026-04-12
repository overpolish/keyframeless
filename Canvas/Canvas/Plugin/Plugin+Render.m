/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import "ShaderTypes.h"
#import <IOSurface/IOSurfaceObjC.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
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

  NSMutableData *state = [NSMutableData dataWithBytes:&params
                                               length:sizeof(params)];
  if (pathStr.length > 0) {
    [state appendData:[pathStr dataUsingEncoding:NSUTF8StringEncoding]];
  }
  *pluginState = state;
  return (*pluginState != nil);
}

- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError *_Nullable *)outError {
  if (!pluginState || !destinationImage.ioSurface || sourceImages.count < 1) {
    if (outError != NULL) {
      *outError =
          [NSError errorWithDomain:FxPlugErrorDomain
                              code:kFxError_InvalidParameter
                          userInfo:@{
                            NSLocalizedDescriptionKey :
                                @"Invalid plugin state received from host"
                          }];
    }
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

  // Unpack pluginState: CanvasStrokeParams header + base64 multi-path blob
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
        if (decoded) {
          // Try multi-path format
          const uint8_t *bytes = decoded.bytes;
          if (decoded.length >= 4) {
            uint32_t pathCount;
            memcpy(&pathCount, bytes, 4);
            if (pathCount <= 10000 && pathCount > 0) {
              NSMutableArray *result =
                  [NSMutableArray arrayWithCapacity:pathCount];
              NSUInteger offset = 4;
              for (uint32_t i = 0; i < pathCount; i++) {
                if (offset + 4 > decoded.length)
                  break;
                uint32_t len;
                memcpy(&len, bytes + offset, 4);
                offset += 4;
                if (offset + len > decoded.length)
                  break;
                NSData *pd =
                    [decoded subdataWithRange:NSMakeRange(offset, len)];
                KKBezierPath *p = [KKBezierPath pathWithData:pd];
                if (p)
                  [result addObject:p];
                offset += len;
              }
              paths = result;
            } else {
              // Fallback: single path
              KKBezierPath *single = [KKBezierPath pathWithData:decoded];
              if (single && single.count > 0)
                paths = @[ single ];
            }
          }
        }
      }
    }
  }

  // Copy source to output via blit
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

  // No paths: just pass through source
  BOOL hasDrawablePaths = NO;
  for (KKBezierPath *p in paths) {
    if (p.count >= 2) {
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

  // Second pass: draw strokes on top with blending
  for (KKBezierPath *path in paths) {
    if (path.count < 2)
      continue;

    float strokeWidth = strokeParams.strokeWidth;
    float aaPadding = 1.0f;
    float halfWidth = (strokeWidth / 2.0f) + aaPadding;

    NSUInteger segsPerCurve = 128;
    NSUInteger curveCount = path.count - 1;
    if (path.closed && path.count >= 3)
      curveCount = path.count;
    NSUInteger maxVertices = curveCount * ((segsPerCurve + 1) * 2 + 2) + 2;
    CanvasVertex *vertices =
        (CanvasVertex *)malloc(maxVertices * sizeof(CanvasVertex));
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
        simd_float2 tangent = [path evaluateTangentAtIndex:c
                                                 nextIndex:nextIdx
                                                       atT:t];
        // Flip tangent Y to match pixel space (Y-down)
        tangent.y = -tangent.y;

        float len = simd_length(tangent);
        if (len < 1e-6f)
          tangent = (simd_float2){1.0f, 0.0f};
        else
          tangent /= len;

        simd_float2 normal = {-tangent.y, tangent.x};

        // Miter join: at shared corner points, average normals from both
        // segments
        BOOL isEnd = (i == segsPerCurve);
        BOOL isStart = (i == 0);
        // Miter helper: average two normals with length correction
        simd_float2 (^miterNormal)(simd_float2, simd_float2) =
            ^(simd_float2 n1, simd_float2 n2) {
              simd_float2 avg = n1 + n2;
              float avgLen = simd_length(avg);
              if (avgLen < 1e-6f)
                return n1;
              avg /= avgLen;
              // Scale by 1/dot(avg, n1) to extend miter to edge
              float d = simd_dot(avg, n1);
              if (d > 0.1f)
                avg /= d;
              return avg;
            };

        if (isEnd &&
            (c < curveCount - 1 || (path.closed && c == curveCount - 1))) {
          NSUInteger nextC, nextNext;
          if (c < curveCount - 1) {
            nextC = (c + 1) % path.count;
            nextNext = (c + 2) % path.count;
          } else {
            nextC = 0;
            nextNext = 1 % path.count;
          }
          simd_float2 nextTangent = [path evaluateTangentAtIndex:nextC
                                                       nextIndex:nextNext
                                                             atT:0.0f];
          nextTangent.y = -nextTangent.y;
          float nLen = simd_length(nextTangent);
          if (nLen > 1e-6f) {
            nextTangent /= nLen;
            simd_float2 nextNormal = {-nextTangent.y, nextTangent.x};
            normal = miterNormal(normal, nextNormal);
          }
        } else if (isStart && (c > 0 || (path.closed && c == 0))) {
          NSUInteger prevC = (c > 0) ? c - 1 : curveCount - 1;
          NSUInteger prevNext = c;
          simd_float2 prevTangent = [path evaluateTangentAtIndex:prevC
                                                       nextIndex:prevNext
                                                             atT:1.0f];
          prevTangent.y = -prevTangent.y;
          float pLen = simd_length(prevTangent);
          if (pLen > 1e-6f) {
            prevTangent /= pLen;
            simd_float2 prevNormal = {-prevTangent.y, prevTangent.x};
            normal = miterNormal(prevNormal, normal);
          }
        }

        // Object space (0..1) to pixel space, then center
        // Y is inverted: object space Y=0 is bottom, pixel space Y=0 is top
        simd_float2 pixelPos = {pos.x * outputWidth,
                                (1.0f - pos.y) * outputHeight};
        simd_float2 centered = {pixelPos.x - outputWidth / 2.0f,
                                pixelPos.y - outputHeight / 2.0f};

        // capDistance: no caps on closed paths
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

    // Build stroke pipeline with blending
    NSString *strokeKey =
        [NSString stringWithFormat:@"%@_stroke_%lu", kPluginID,
                                   (unsigned long)pixelFormat];
    id<MTLRenderPipelineState> strokePS =
        [cache pipelineStateForPluginID:strokeKey
                             registryID:registryID
                            pixelFormat:pixelFormat];

    if (!strokePS) {
      id<MTLLibrary> library = [device newDefaultLibrary];
      id<MTLFunction> vertFn =
          [library newFunctionWithName:@"strokeVertexShader"];
      id<MTLFunction> fragFn =
          [library newFunctionWithName:@"strokeFragmentShader"];

      MTLRenderPipelineDescriptor *desc =
          [[MTLRenderPipelineDescriptor alloc] init];
      desc.vertexFunction = vertFn;
      desc.fragmentFunction = fragFn;
      desc.colorAttachments[0].pixelFormat = pixelFormat;
      desc.colorAttachments[0].blendingEnabled = YES;
      desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
      desc.colorAttachments[0].destinationRGBBlendFactor =
          MTLBlendFactorOneMinusSourceAlpha;
      desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
      desc.colorAttachments[0].destinationAlphaBlendFactor =
          MTLBlendFactorOneMinusSourceAlpha;

      NSError *error = nil;
      strokePS = [device newRenderPipelineStateWithDescriptor:desc
                                                        error:&error];
      if (!strokePS) {
        free(vertices);
        [cache returnCommandQueueToCache:commandQueue];
        return NO;
      }

      [cache registerPipelineState:strokePS
                       forPluginID:strokeKey
                        registryID:registryID
                       pixelFormat:pixelFormat];
    }

    MTLRenderPassDescriptor *rpd =
        [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = outputTexture;
    rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> enc =
        [commandBuffer renderCommandEncoderWithDescriptor:rpd];

    MTLViewport viewport = {0, 0, outputWidth, outputHeight, -1.0, 1.0};
    [enc setViewport:viewport];
    [enc setRenderPipelineState:strokePS];

    simd_uint2 viewportSize = {(unsigned int)outputWidth,
                               (unsigned int)outputHeight};
    id<MTLBuffer> vertexBuffer =
        [device newBufferWithBytes:vertices
                            length:vertexCount * sizeof(CanvasVertex)
                           options:MTLResourceStorageModeShared];
    [enc setVertexBuffer:vertexBuffer offset:0 atIndex:0];
    [enc setVertexBytes:&viewportSize length:sizeof(viewportSize) atIndex:1];

    simd_float4 color = {strokeParams.r, strokeParams.g, strokeParams.b, 1.0f};
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
