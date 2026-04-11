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
  if (!pluginState || !destinationImage.ioSurface) {
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

  float outputWidth = (float)(destinationImage.tilePixelBounds.right -
                              destinationImage.tilePixelBounds.left);
  float outputHeight = (float)(destinationImage.tilePixelBounds.top -
                               destinationImage.tilePixelBounds.bottom);
  NSUInteger w = (NSUInteger)outputWidth;
  NSUInteger h = (NSUInteger)outputHeight;

  // Build MSAA pipeline (4x) - can't use the cache helper since it doesn't
  // support sampleCount
  NSString *msaaKey = [NSString
      stringWithFormat:@"%@_msaa_%lu", kPluginID, (unsigned long)pixelFormat];
  id<MTLRenderPipelineState> pipelineState =
      [cache pipelineStateForPluginID:msaaKey
                           registryID:registryID
                          pixelFormat:pixelFormat];

  if (!pipelineState) {
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
    desc.sampleCount = 4;

    NSError *error = nil;
    pipelineState = [device newRenderPipelineStateWithDescriptor:desc
                                                           error:&error];
    if (!pipelineState) {
      [cache returnCommandQueueToCache:commandQueue];
      return NO;
    }

    [cache registerPipelineState:pipelineState
                     forPluginID:msaaKey
                      registryID:registryID
                     pixelFormat:pixelFormat];
  }

  // Create MSAA texture
  MTLTextureDescriptor *msaaDesc =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixelFormat
                                                         width:w
                                                        height:h
                                                     mipmapped:NO];
  msaaDesc.textureType = MTLTextureType2DMultisample;
  msaaDesc.sampleCount = 4;
  msaaDesc.usage = MTLTextureUsageRenderTarget;
  msaaDesc.storageMode = MTLStorageModePrivate;

  id<MTLTexture> msaaTexture = [device newTextureWithDescriptor:msaaDesc];

  // Hardcoded bezier curve (in pixel space, centered on canvas)
  float cx = outputWidth / 2.0f;
  float cy = outputHeight / 2.0f;
  simd_float2 p0 = {cx - 400.0f, cy + 100.0f};
  simd_float2 p1 = {cx - 150.0f, cy - 300.0f};
  simd_float2 p2 = {cx + 150.0f, cy + 300.0f};
  simd_float2 p3 = {cx + 400.0f, cy - 100.0f};

  float strokeWidth = 8.0f;
  float aaPadding = 1.0f;
  float halfWidth = (strokeWidth / 2.0f) + aaPadding;

  // Tessellate bezier into triangle strip
  NSUInteger segments = 1024;
  NSUInteger vertexCount = (segments + 1) * 2;
  CanvasVertex *vertices =
      (CanvasVertex *)malloc(vertexCount * sizeof(CanvasVertex));

  for (NSUInteger i = 0; i <= segments; i++) {
    float t = (float)i / (float)segments;
    simd_float2 pos = evaluateCubicBezier(p0, p1, p2, p3, t);
    simd_float2 tangent = evaluateCubicBezierTangent(p0, p1, p2, p3, t);

    float len = simd_length(tangent);
    if (len < 1e-6f)
      tangent = (simd_float2){1.0f, 0.0f};
    else
      tangent /= len;

    simd_float2 normal = {-tangent.y, tangent.x};

    simd_float2 centered = {pos.x - outputWidth / 2.0f,
                            pos.y - outputHeight / 2.0f};

    vertices[i * 2 + 0].position = centered + normal * halfWidth;
    vertices[i * 2 + 0].edgeDistance = 1.0f;
    vertices[i * 2 + 1].position = centered - normal * halfWidth;
    vertices[i * 2 + 1].edgeDistance = -1.0f;
  }

  // Render to MSAA texture, resolve to output
  id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
  commandBuffer.label = @"Canvas Stroke Command Buffer";
  [commandBuffer enqueue];

  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture = msaaTexture;
  rpd.colorAttachments[0].resolveTexture = outputTexture;
  rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
  rpd.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;

  id<MTLRenderCommandEncoder> encoder =
      [commandBuffer renderCommandEncoderWithDescriptor:rpd];

  MTLViewport viewport = {0, 0, outputWidth, outputHeight, -1.0, 1.0};
  [encoder setViewport:viewport];
  [encoder setRenderPipelineState:pipelineState];

  simd_uint2 viewportSize = {(unsigned int)outputWidth,
                             (unsigned int)outputHeight};
  id<MTLBuffer> vertexBuffer =
      [device newBufferWithBytes:vertices
                          length:vertexCount * sizeof(CanvasVertex)
                         options:MTLResourceStorageModeShared];
  [encoder setVertexBuffer:vertexBuffer offset:0 atIndex:0];
  [encoder setVertexBytes:&viewportSize length:sizeof(viewportSize) atIndex:1];

  [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
              vertexStart:0
              vertexCount:vertexCount];

  [encoder endEncoding];
  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];

  free(vertices);
  [cache returnCommandQueueToCache:commandQueue];

  return YES;
}

@end
