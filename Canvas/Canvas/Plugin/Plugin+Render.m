/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import "ShaderTypes.h"
#import <IOSurface/IOSurfaceObjC.h>

static simd_float2 evaluateCubicBezier(simd_float2 p0, simd_float2 p1,
                                       simd_float2 p2, simd_float2 p3,
                                       float t) {
  float u = 1.0f - t;
  float uu = u * u;
  float uuu = uu * u;
  float tt = t * t;
  float ttt = tt * t;
  return uuu * p0 + 3.0f * uu * t * p1 + 3.0f * u * tt * p2 + ttt * p3;
}

static simd_float2 evaluateCubicBezierTangent(simd_float2 p0, simd_float2 p1,
                                              simd_float2 p2, simd_float2 p3,
                                              float t) {
  float u = 1.0f - t;
  return 3.0f * u * u * (p1 - p0) + 6.0f * u * t * (p2 - p1) +
         3.0f * t * t * (p3 - p2);
}

@implementation CanvasPlugin (Render)

- (BOOL)pluginState:(NSData **)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error {
  uint8_t placeholder = 0;
  *pluginState = [NSData dataWithBytes:&placeholder length:sizeof(placeholder)];
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

  // Read path data from parameter
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSString *pathStr = nil;
  [paramGetAPI getStringParameterValue:&pathStr fromParameter:kParamPathData];

  KKBezierPath *path = nil;
  if (pathStr.length > 0) {
    NSData *data = [[NSData alloc] initWithBase64EncodedString:pathStr
                                                       options:0];
    if (data)
      path = [KKBezierPath pathWithData:data];
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

  // No path or too few points: just pass through source
  if (!path || path.count < 2) {
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    [cache returnCommandQueueToCache:commandQueue];
    return YES;
  }

  // Second pass: draw strokes on top with blending
  {
    float strokeWidth = 8.0f;
    float aaPadding = 1.0f;
    float halfWidth = (strokeWidth / 2.0f) + aaPadding;

    NSUInteger segsPerCurve = 128;
    NSUInteger curveCount = path.count - 1;
    NSUInteger maxVertices = curveCount * ((segsPerCurve + 1) * 2 + 2) + 2;
    CanvasVertex *vertices =
        (CanvasVertex *)malloc(maxVertices * sizeof(CanvasVertex));
    NSUInteger vertexCount = 0;

    for (NSUInteger c = 0; c < curveCount; c++) {
      KKBezierPoint bp0 = [path pointAtIndex:c];
      KKBezierPoint bp1 = [path pointAtIndex:c + 1];

      simd_float2 a = {bp0.x, bp0.y};
      simd_float2 cp1 = {bp0.x + bp0.outX, bp0.y + bp0.outY};
      simd_float2 cp2 = {bp1.x + bp1.inX, bp1.y + bp1.inY};
      simd_float2 b = {bp1.x, bp1.y};

      if (c > 0 && vertexCount > 0) {
        vertices[vertexCount] = vertices[vertexCount - 1];
        vertexCount++;
      }

      for (NSUInteger i = 0; i <= segsPerCurve; i++) {
        float t = (float)i / (float)segsPerCurve;
        simd_float2 pos = evaluateCubicBezier(a, cp1, cp2, b, t);
        simd_float2 tangent = evaluateCubicBezierTangent(a, cp1, cp2, b, t);

        float len = simd_length(tangent);
        if (len < 1e-6f)
          tangent = (simd_float2){1.0f, 0.0f};
        else
          tangent /= len;

        simd_float2 normal = {-tangent.y, tangent.x};

        // Object space (0..1) to pixel space, then center
        simd_float2 pixelPos = {pos.x * outputWidth, pos.y * outputHeight};
        simd_float2 centered = {pixelPos.x - outputWidth / 2.0f,
                                pixelPos.y - outputHeight / 2.0f};

        vertices[vertexCount].position = centered + normal * halfWidth;
        vertices[vertexCount].edgeDistance = 1.0f;
        vertexCount++;
        vertices[vertexCount].position = centered - normal * halfWidth;
        vertices[vertexCount].edgeDistance = -1.0f;
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
