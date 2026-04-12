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

  // Unpack pluginState: CanvasStrokeParams header + base64 path string
  CanvasStrokeParams strokeParams = {8.0f, 1.0f, 0.0f, 0.0f};
  KKBezierPath *path = nil;

  if (pluginState.length >= sizeof(CanvasStrokeParams)) {
    memcpy(&strokeParams, pluginState.bytes, sizeof(CanvasStrokeParams));

    if (pluginState.length > sizeof(CanvasStrokeParams)) {
      NSData *pathData = [pluginState
          subdataWithRange:NSMakeRange(sizeof(CanvasStrokeParams),
                                       pluginState.length -
                                           sizeof(CanvasStrokeParams))];
      NSString *pathStr = [[NSString alloc] initWithData:pathData
                                                encoding:NSUTF8StringEncoding];
      if (pathStr.length > 0) {
        NSData *decoded = [[NSData alloc] initWithBase64EncodedString:pathStr
                                                              options:0];
        if (decoded)
          path = [KKBezierPath pathWithData:decoded];
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

  // No path or too few points: just pass through source
  if (!path || path.count < 2) {
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    [cache returnCommandQueueToCache:commandQueue];
    return YES;
  }

  // Second pass: draw strokes on top with blending
  {
    float strokeWidth = strokeParams.strokeWidth;
    float aaPadding = 1.0f;
    float halfWidth = (strokeWidth / 2.0f) + aaPadding;

    NSUInteger segsPerCurve = 128;
    NSUInteger curveCount = path.count - 1;
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
        simd_float2 pos = [path evaluatePointAtIndex:c nextIndex:c + 1 atT:t];
        simd_float2 tangent = [path evaluateTangentAtIndex:c
                                                 nextIndex:c + 1
                                                       atT:t];
        // Flip tangent Y to match pixel space (Y-down)
        tangent.y = -tangent.y;

        float len = simd_length(tangent);
        if (len < 1e-6f)
          tangent = (simd_float2){1.0f, 0.0f};
        else
          tangent /= len;

        simd_float2 normal = {-tangent.y, tangent.x};

        // Object space (0..1) to pixel space, then center
        // Y is inverted: object space Y=0 is bottom, pixel space Y=0 is top
        simd_float2 pixelPos = {pos.x * outputWidth,
                                (1.0f - pos.y) * outputHeight};
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
