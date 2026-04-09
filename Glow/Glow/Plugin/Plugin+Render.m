/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import "ShaderTypes.h"
#import <IOSurface/IOSurfaceObjC.h>
#import <KeyframelessKit/KKEasing.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

typedef struct {
  float radius;
  float intensity;
  float falloff;
  simd_float2 offset;
  simd_float3 glowColor;
  int colorMode;
  int gradientType;
  float gradientAngle;
  simd_float3 gradientLUT[KK_GRADIENT_LUT_SIZE];
} GlowPluginState;

@implementation GlowPlugin (Render)

- (BOOL)pluginState:(NSData **)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (paramGetAPI == nil) {
    if (error != NULL) {
      *error =
          [NSError errorWithDomain:FxPlugErrorDomain
                              code:kFxError_ThirdPartyDeveloperStart + 20
                          userInfo:@{
                            NSLocalizedDescriptionKey :
                                @"Unable to retrieve FxParameterRetrievalAPI_v6"
                          }];
    }
    return NO;
  }

  double radius = 100.0;
  double intensity = 1.5;
  double falloff = 1.0;
  [paramGetAPI getFloatValue:&radius
               fromParameter:kParamRadius
                      atTime:renderTime];
  [paramGetAPI getFloatValue:&intensity
               fromParameter:kParamIntensity
                      atTime:renderTime];
  [paramGetAPI getFloatValue:&falloff
               fromParameter:kParamFalloff
                      atTime:renderTime];

  double offsetX = 0.5, offsetY = 0.5;
  [paramGetAPI getXValue:&offsetX
                  YValue:&offsetY
           fromParameter:kParamOffset
                  atTime:renderTime];

  KKTimingResult *timing = [self timingAtTime:renderTime];
  double inF = timing.inPhase.factor;
  double outF = timing.outPhase.factor;
  double holdF = timing.holdPhase.factor;

  BOOL holdRadius = YES, holdIntensity = YES, holdFalloff = YES,
       holdOffset = YES;
  [paramGetAPI getBoolValue:&holdRadius
              fromParameter:kParamHoldRadius
                     atTime:renderTime];
  [paramGetAPI getBoolValue:&holdIntensity
              fromParameter:kParamHoldIntensity
                     atTime:renderTime];
  [paramGetAPI getBoolValue:&holdFalloff
              fromParameter:kParamHoldFalloff
                     atTime:renderTime];
  [paramGetAPI getBoolValue:&holdOffset
              fromParameter:kParamHoldOffset
                     atTime:renderTime];

  int holdSeed = 0;
  [paramGetAPI getIntValue:&holdSeed
             fromParameter:kKKParamHoldSeed
                    atTime:renderTime];

  int gradientType = 0;
  double gradientAngle = 0.0;
  [paramGetAPI getIntValue:&gradientType
             fromParameter:kParamGradientType
                    atTime:renderTime];
  [paramGetAPI getFloatValue:&gradientAngle
               fromParameter:kParamGradientAngle
                      atTime:renderTime];

  KKColorResult *colorResult = [self colorAtTime:renderTime];
  int colorMode = (int)colorResult.mode;

  double radiusFactor = inF * (holdRadius ? holdF : 1.0) * outF;
  double intensityFactor = inF * (holdIntensity ? holdF : 1.0) * outF;
  double falloffFactor = inF * (holdFalloff ? holdF : 1.0) * outF;
  double offsetInOut = inF * outF;

  static const double kHoldOffsetAmount = 0.03;
  double holdD = holdF - 1.0;
  double holdOffsetX =
      holdOffset ? holdD * kHoldOffsetAmount * KKSeedSign(holdSeed, 0) : 0.0;
  double holdOffsetY =
      holdOffset ? holdD * kHoldOffsetAmount * KKSeedSign(holdSeed, 1) : 0.0;

  GlowPluginState state;
  state.radius = (float)(radius * radiusFactor);
  state.intensity = (float)(intensity * intensityFactor);
  state.falloff = (float)(1.0 + falloff * falloffFactor);
  state.offset =
      (simd_float2){(float)((offsetX - 0.5) * offsetInOut + holdOffsetX),
                    (float)((offsetY - 0.5) * offsetInOut + holdOffsetY)};
  state.glowColor = colorResult.solidColor;
  state.colorMode = colorMode;
  state.gradientType = gradientType;
  state.gradientAngle = (float)gradientAngle;

  if (colorMode == KKColorModeGradient) {
    memcpy(state.gradientLUT, colorResult.gradientLUT,
           sizeof(state.gradientLUT));
  } else {
    for (int i = 0; i < KK_GRADIENT_LUT_SIZE; i++)
      state.gradientLUT[i] = state.glowColor;
  }

  *pluginState = [NSData dataWithBytes:&state length:sizeof(state)];
  return (*pluginState != nil);
}

- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError *_Nullable *)outError {
  if (!pluginState || !sourceImages[0].ioSurface ||
      !destinationImage.ioSurface) {
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

  GlowPluginState state;
  [pluginState getBytes:&state length:sizeof(state)];

  float fragmentRadius = state.radius;
  float fragmentIntensity = state.intensity;
  float fragmentFalloff = state.falloff;
  simd_float2 fragmentOffset = state.offset;
  simd_float3 fragmentColor = state.glowColor;
  int fragmentColorMode = state.colorMode;

  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  MTLPixelFormat pixelFormat =
      [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
  uint64_t registryID = destinationImage.deviceRegistryID;

  id<MTLDevice> device = [cache deviceWithRegistryID:registryID];
  id<MTLCommandQueue> commandQueue =
      [cache commandQueueWithRegistryID:registryID pixelFormat:pixelFormat];
  if (!device || !commandQueue)
    return NO;

  id<MTLTexture> outputTexture =
      [destinationImage metalTextureForDevice:device];
  id<MTLTexture> inputTexture = [sourceImages[0] metalTextureForDevice:device];

  float outputWidth = (float)(destinationImage.tilePixelBounds.right -
                              destinationImage.tilePixelBounds.left);
  float outputHeight = (float)(destinationImage.tilePixelBounds.top -
                               destinationImage.tilePixelBounds.bottom);

  MTLTextureDescriptor *intermediateDesc = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:pixelFormat
                                   width:(NSUInteger)outputWidth
                                  height:(NSUInteger)outputHeight
                               mipmapped:NO];
  intermediateDesc.usage =
      MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  intermediateDesc.storageMode = MTLStorageModePrivate;
  id<MTLTexture> hBlurTexture =
      [device newTextureWithDescriptor:intermediateDesc];
  id<MTLTexture> fullBlurTexture =
      [device newTextureWithDescriptor:intermediateDesc];
  if (!hBlurTexture || !fullBlurTexture) {
    [cache returnCommandQueueToCache:commandQueue];
    return NO;
  }

  static NSString *const kHBlurID = @"co.overpolish.keyframeless.Glow.hblur";
  static NSString *const kVBlurID = @"co.overpolish.keyframeless.Glow.vblur";
  static NSString *const kCompID = @"co.overpolish.keyframeless.Glow.comp";

  id<MTLRenderPipelineState> hBlurPipeline =
      [cache buildAndRegisterPipelineStateForPluginID:kHBlurID
                                           registryID:registryID
                                          pixelFormat:pixelFormat
                                             bundleID:nil
                                         vertexShader:@"vertexShader"
                                       fragmentShader:@"blurHorizontal"
                                            blendMode:KKBlendModeNone];

  id<MTLRenderPipelineState> vBlurPipeline =
      [cache buildAndRegisterPipelineStateForPluginID:kVBlurID
                                           registryID:registryID
                                          pixelFormat:pixelFormat
                                             bundleID:nil
                                         vertexShader:@"vertexShader"
                                       fragmentShader:@"blurVertical"
                                            blendMode:KKBlendModeNone];

  id<MTLRenderPipelineState> compPipeline =
      [cache buildAndRegisterPipelineStateForPluginID:kCompID
                                           registryID:registryID
                                          pixelFormat:pixelFormat
                                             bundleID:nil
                                         vertexShader:@"vertexShader"
                                       fragmentShader:@"composite"
                                            blendMode:KKBlendModeNone];

  if (!hBlurPipeline || !vBlurPipeline || !compPipeline) {
    [cache returnCommandQueueToCache:commandQueue];
    return NO;
  }

  KKVertex2D vertices[] = {
      {{outputWidth / 2.0f, -outputHeight / 2.0f}, {1.0, 1.0}},
      {{-outputWidth / 2.0f, -outputHeight / 2.0f}, {0.0, 1.0}},
      {{outputWidth / 2.0f, outputHeight / 2.0f}, {1.0, 0.0}},
      {{-outputWidth / 2.0f, outputHeight / 2.0f}, {0.0, 0.0}},
  };
  simd_uint2 viewportSize = {(unsigned int)outputWidth,
                             (unsigned int)outputHeight};
  MTLViewport viewport = {0, 0, outputWidth, outputHeight, -1.0, 1.0};

  id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
  commandBuffer.label = @"Glow Command Buffer";
  [commandBuffer enqueue];

  // Pass 1: horizontal blur → hBlurTexture
  {
    MTLRenderPassDescriptor *rpd =
        [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = hBlurTexture;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;

    id<MTLRenderCommandEncoder> encoder =
        [commandBuffer renderCommandEncoderWithDescriptor:rpd];
    [encoder setViewport:viewport];
    [encoder setVertexBytes:vertices
                     length:sizeof(vertices)
                    atIndex:KKVertexInputIndex_Vertices];
    [encoder setVertexBytes:&viewportSize
                     length:sizeof(viewportSize)
                    atIndex:KKVertexInputIndex_ViewportSize];
    [encoder setRenderPipelineState:hBlurPipeline];
    [encoder setFragmentTexture:inputTexture atIndex:KKTextureIndex_InputImage];
    [encoder setFragmentBytes:&fragmentRadius
                       length:sizeof(fragmentRadius)
                      atIndex:FragmentIndex_Radius];
    [encoder setFragmentBytes:&fragmentColorMode
                       length:sizeof(fragmentColorMode)
                      atIndex:FragmentIndex_ColorMode];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0
                vertexCount:4];
    [encoder endEncoding];
  }

  // Pass 2: vertical blur → fullBlurTexture
  {
    MTLRenderPassDescriptor *rpd =
        [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = fullBlurTexture;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;

    id<MTLRenderCommandEncoder> encoder =
        [commandBuffer renderCommandEncoderWithDescriptor:rpd];
    [encoder setViewport:viewport];
    [encoder setVertexBytes:vertices
                     length:sizeof(vertices)
                    atIndex:KKVertexInputIndex_Vertices];
    [encoder setVertexBytes:&viewportSize
                     length:sizeof(viewportSize)
                    atIndex:KKVertexInputIndex_ViewportSize];
    [encoder setRenderPipelineState:vBlurPipeline];
    [encoder setFragmentTexture:hBlurTexture atIndex:KKTextureIndex_InputImage];
    [encoder setFragmentBytes:&fragmentRadius
                       length:sizeof(fragmentRadius)
                      atIndex:FragmentIndex_Radius];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0
                vertexCount:4];
    [encoder endEncoding];
  }

  // Pass 3: composite → destination
  {
    MTLRenderPassDescriptor *rpd =
        [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = outputTexture;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;

    id<MTLRenderCommandEncoder> encoder =
        [commandBuffer renderCommandEncoderWithDescriptor:rpd];
    [encoder setViewport:viewport];
    [encoder setVertexBytes:vertices
                     length:sizeof(vertices)
                    atIndex:KKVertexInputIndex_Vertices];
    [encoder setVertexBytes:&viewportSize
                     length:sizeof(viewportSize)
                    atIndex:KKVertexInputIndex_ViewportSize];
    [encoder setRenderPipelineState:compPipeline];
    [encoder setFragmentTexture:inputTexture atIndex:KKTextureIndex_InputImage];
    [encoder setFragmentTexture:fullBlurTexture atIndex:1];
    [encoder setFragmentBytes:&fragmentRadius
                       length:sizeof(fragmentRadius)
                      atIndex:FragmentIndex_Radius];
    [encoder setFragmentBytes:&fragmentIntensity
                       length:sizeof(fragmentIntensity)
                      atIndex:FragmentIndex_Intensity];
    [encoder setFragmentBytes:&fragmentFalloff
                       length:sizeof(fragmentFalloff)
                      atIndex:FragmentIndex_Falloff];
    [encoder setFragmentBytes:&fragmentOffset
                       length:sizeof(fragmentOffset)
                      atIndex:FragmentIndex_Offset];
    [encoder setFragmentBytes:&fragmentColor
                       length:sizeof(fragmentColor)
                      atIndex:FragmentIndex_GlowColor];
    [encoder setFragmentBytes:&fragmentColorMode
                       length:sizeof(fragmentColorMode)
                      atIndex:FragmentIndex_ColorMode];
    [encoder setFragmentBytes:state.gradientLUT
                       length:sizeof(state.gradientLUT)
                      atIndex:FragmentIndex_GradientLUT];
    int fragGradType = state.gradientType;
    float fragGradAngle = state.gradientAngle;
    [encoder setFragmentBytes:&fragGradType
                       length:sizeof(fragGradType)
                      atIndex:FragmentIndex_GradientType];
    [encoder setFragmentBytes:&fragGradAngle
                       length:sizeof(fragGradAngle)
                      atIndex:FragmentIndex_GradientAngle];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0
                vertexCount:4];
    [encoder endEncoding];
  }

  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];
  [cache returnCommandQueueToCache:commandQueue];

  return YES;
}

@end
#pragma clang diagnostic pop
