/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import "ShaderTypes.h"
#import <IOSurface/IOSurfaceObjC.h>
#import <KeyframelessKit/KKEasing.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>

static KKLog *_renderLog(void) {
  static KKLog *log;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    log = [KKLog loggerForPlugin:@"co.overpolish.keyframeless.Glow"];
  });
  return log;
}

typedef struct {
  float radiusX;
  float radiusY;
  float intensity;
  float falloff;
  float noise;
  float noiseOffset;
  simd_float2 offset;
  simd_float3 glowColor;
  int colorMode;
  int gradientType;
  float gradientAngle;
  simd_float3 gradientLUT[KK_GRADIENT_LUT_SIZE];
} GlowPluginState;

static const float kExpandMultiplier = 1.2f;
static const float kExpandHeadroom = 200.0f;
static const float kMaxBlurDimension = 2048.0f;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation GlowPlugin (Render)

- (BOOL)pluginState:(NSData **)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error {
  [self updateParameterVisibilityAtTime:renderTime];

  id<FxParameterRetrievalAPI_v6> api =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!api) {
    if (error)
      *error = [NSError errorWithDomain:FxPlugErrorDomain
                                   code:kFxError_APIUnavailable
                               userInfo:nil];
    return NO;
  }

  double radiusX = 100, radiusY = 100, intensity = 1.5, falloff = 1.0,
         noise = 0.0;
  [api getFloatValue:&radiusX fromParameter:kParamRadiusX atTime:renderTime];
  [api getFloatValue:&radiusY fromParameter:kParamRadiusY atTime:renderTime];
  [api getFloatValue:&intensity
       fromParameter:kParamIntensity
              atTime:renderTime];
  [api getFloatValue:&falloff fromParameter:kParamFalloff atTime:renderTime];
  [api getFloatValue:&noise fromParameter:kParamNoise atTime:renderTime];
  double noiseOffset = 0.0;
  [api getFloatValue:&noiseOffset
       fromParameter:kParamNoiseOffset
              atTime:renderTime];

  double offX = 0, offY = 0;
  [api getFloatValue:&offX fromParameter:kParamOffsetX atTime:renderTime];
  [api getFloatValue:&offY fromParameter:kParamOffsetY atTime:renderTime];

  int gradType = 0;
  double gradAngle = 0;
  [api getIntValue:&gradType
      fromParameter:kParamGradientType
             atTime:renderTime];
  [api getFloatValue:&gradAngle
       fromParameter:kParamGradientAngle
              atTime:renderTime];

  KKTimingResult *timing = [self timingAtTime:renderTime];
  double inF = timing.inPhase.factor;
  double outF = timing.outPhase.factor;
  double holdF = timing.holdPhase.factor;

  BOOL inR = YES, inI = YES, inFl = YES, inN = YES, inO = YES;
  [api getBoolValue:&inR fromParameter:kParamInRadius atTime:renderTime];
  [api getBoolValue:&inI fromParameter:kParamInIntensity atTime:renderTime];
  [api getBoolValue:&inFl fromParameter:kParamInFalloff atTime:renderTime];
  [api getBoolValue:&inN fromParameter:kParamInNoise atTime:renderTime];
  [api getBoolValue:&inO fromParameter:kParamInOffset atTime:renderTime];

  BOOL holdR = YES, holdI = YES, holdFl = YES, holdN = YES, holdO = YES;
  [api getBoolValue:&holdR fromParameter:kParamHoldRadius atTime:renderTime];
  [api getBoolValue:&holdI fromParameter:kParamHoldIntensity atTime:renderTime];
  [api getBoolValue:&holdFl fromParameter:kParamHoldFalloff atTime:renderTime];
  [api getBoolValue:&holdN fromParameter:kParamHoldNoise atTime:renderTime];
  [api getBoolValue:&holdO fromParameter:kParamHoldOffset atTime:renderTime];

  BOOL outR = YES, outI = YES, outFl = YES, outN = YES, outO = YES;
  [api getBoolValue:&outR fromParameter:kParamOutRadius atTime:renderTime];
  [api getBoolValue:&outI fromParameter:kParamOutIntensity atTime:renderTime];
  [api getBoolValue:&outFl fromParameter:kParamOutFalloff atTime:renderTime];
  [api getBoolValue:&outN fromParameter:kParamOutNoise atTime:renderTime];
  [api getBoolValue:&outO fromParameter:kParamOutOffset atTime:renderTime];

  BOOL inC = YES, holdC = YES, outC = YES;
  [api getBoolValue:&inC fromParameter:kParamInColor atTime:renderTime];
  [api getBoolValue:&holdC fromParameter:kParamHoldColor atTime:renderTime];
  [api getBoolValue:&outC fromParameter:kParamOutColor atTime:renderTime];

  int holdSeed = 0;
  [api getIntValue:&holdSeed fromParameter:kKKParamHoldSeed atTime:renderTime];

  int holdEffectVal = 0;
  [api getIntValue:&holdEffectVal
      fromParameter:kKKParamHoldEffect
             atTime:renderTime];
  BOOL holdHasEffect = (holdEffectVal != 0);

  double rF = (inR ? inF : 1.0) * (holdR ? holdF : 1.0) * (outR ? outF : 1.0);
  double iF = (inI ? inF : 1.0) * (holdI ? holdF : 1.0) * (outI ? outF : 1.0);
  double fF =
      (inFl ? inF : 1.0) * (holdFl ? holdF : 1.0) * (outFl ? outF : 1.0);
  double nF = (inN ? inF : 1.0) * (holdN ? holdF : 1.0) * (outN ? outF : 1.0);
  double oF = (inO ? inF : 1.0) * (outO ? outF : 1.0);
  double hD = holdF - 1.0;
  double hOX = holdO ? hD * 0.03 * KKSeedSign(holdSeed, 0) : 0.0;
  double hOY = holdO ? hD * 0.03 * KKSeedSign(holdSeed, 1) : 0.0;

  KKColorResult *color = [self colorAtTime:renderTime];

  // --- Timing color blending ---
  simd_float3 finalColor = color.solidColor;
  simd_float3 finalLUT[KK_GRADIENT_LUT_SIZE];

  if (color.mode == KKColorModeGradient) {
    if (color.gradientLUT)
      memcpy(finalLUT, color.gradientLUT,
             sizeof(simd_float3) * KK_GRADIENT_LUT_SIZE);
    else
      for (int i = 0; i < KK_GRADIENT_LUT_SIZE; i++)
        finalLUT[i] = (simd_float3){1, 1, 1};
  }

  if (color.mode == KKColorModeSolid) {
    if (inC && timing.inPhase.enabled) {
      double r = 1, g = 1, b = 1;
      [api getRedValue:&r
             greenValue:&g
              blueValue:&b
          fromParameter:kParamTimingInColor
                 atTime:renderTime];
      float t = (float)inF;
      simd_float3 ic = {(float)r, (float)g, (float)b};
      finalColor = simd_mix(ic, finalColor, (simd_float3){t, t, t});
    }
    if (holdC && holdHasEffect) {
      double r = 1, g = 1, b = 1;
      [api getRedValue:&r
             greenValue:&g
              blueValue:&b
          fromParameter:kParamTimingHoldColor
                 atTime:renderTime];
      float hBlend = (float)timing.holdPhase.progress;
      simd_float3 hc = {(float)r, (float)g, (float)b};
      finalColor =
          simd_mix(finalColor, hc, (simd_float3){hBlend, hBlend, hBlend});
    }
    if (outC && timing.outPhase.enabled) {
      double r = 1, g = 1, b = 1;
      [api getRedValue:&r
             greenValue:&g
              blueValue:&b
          fromParameter:kParamTimingOutColor
                 atTime:renderTime];
      float t = (float)outF;
      simd_float3 oc = {(float)r, (float)g, (float)b};
      finalColor = simd_mix(oc, finalColor, (simd_float3){t, t, t});
    }
  } else if (color.mode == KKColorModeGradient) {
    simd_float3 tempLUT[KK_GRADIENT_LUT_SIZE];

    if (inC && timing.inPhase.enabled) {
      float samples[KK_GRADIENT_LUT_SIZE * 4];
      if ([api getGradientSamples:samples
                       numSamples:KK_GRADIENT_LUT_SIZE
                            depth:kFxDepth_FLOAT32
                    fromParameter:kParamTimingInGradient
                           atTime:renderTime]) {
        float t = (float)inF;
        simd_float3 tv = {t, t, t};
        for (int i = 0; i < KK_GRADIENT_LUT_SIZE; i++) {
          simd_float3 ic = {samples[i * 4], samples[i * 4 + 1],
                            samples[i * 4 + 2]};
          finalLUT[i] = simd_mix(ic, finalLUT[i], tv);
        }
      }
    }
    if (holdC && holdHasEffect) {
      float samples[KK_GRADIENT_LUT_SIZE * 4];
      if ([api getGradientSamples:samples
                       numSamples:KK_GRADIENT_LUT_SIZE
                            depth:kFxDepth_FLOAT32
                    fromParameter:kParamTimingHoldGradient
                           atTime:renderTime]) {
        float hBlend = (float)timing.holdPhase.progress;
        simd_float3 hv = {hBlend, hBlend, hBlend};
        for (int i = 0; i < KK_GRADIENT_LUT_SIZE; i++) {
          simd_float3 hc = {samples[i * 4], samples[i * 4 + 1],
                            samples[i * 4 + 2]};
          finalLUT[i] = simd_mix(finalLUT[i], hc, hv);
        }
      }
    }
    if (outC && timing.outPhase.enabled) {
      float samples[KK_GRADIENT_LUT_SIZE * 4];
      if ([api getGradientSamples:samples
                       numSamples:KK_GRADIENT_LUT_SIZE
                            depth:kFxDepth_FLOAT32
                    fromParameter:kParamTimingOutGradient
                           atTime:renderTime]) {
        float t = (float)outF;
        simd_float3 tv = {t, t, t};
        for (int i = 0; i < KK_GRADIENT_LUT_SIZE; i++) {
          simd_float3 oc = {samples[i * 4], samples[i * 4 + 1],
                            samples[i * 4 + 2]};
          finalLUT[i] = simd_mix(oc, finalLUT[i], tv);
        }
      }
    }
  }

  GlowPluginState state = {
      .radiusX = (float)(radiusX * rF),
      .radiusY = (float)(radiusY * rF),
      .intensity = (float)(intensity * iF),
      .falloff = (float)(1.0 + falloff * fF),
      .noise = (float)(noise * nF),
      .noiseOffset = (float)noiseOffset,
      .offset = {(float)(offX * oF + hOX), (float)(offY * oF + hOY)},
      .glowColor = finalColor,
      .colorMode = (int)color.mode,
      .gradientType = gradType,
      .gradientAngle = (float)gradAngle,
  };

  if (color.mode == KKColorModeGradient) {
    memcpy(state.gradientLUT, finalLUT, sizeof(state.gradientLUT));
  } else {
    for (int i = 0; i < KK_GRADIENT_LUT_SIZE; i++)
      state.gradientLUT[i] = state.glowColor;
  }

  [_renderLog()
      verbose:@"state: rx=%.1f ry=%.1f i=%.2f mode=%d off=(%.3f,%.3f)",
              state.radiusX, state.radiusY, state.intensity, state.colorMode,
              state.offset.x, state.offset.y];

  *pluginState = [NSData dataWithBytes:&state length:sizeof(state)];
  return (*pluginState != nil);
}

- (BOOL)destinationImageRect:(FxRect *)destinationImageRect
                sourceImages:(NSArray<FxImageTile *> *)sourceImages
            destinationImage:(FxImageTile *)destinationImage
                 pluginState:(NSData *)pluginState
                      atTime:(CMTime)renderTime
                       error:(NSError **)outError {
  if (!pluginState || pluginState.length < sizeof(GlowPluginState)) {
    *destinationImageRect = sourceImages[0].imagePixelBounds;
    return YES;
  }
  GlowPluginState state;
  [pluginState getBytes:&state length:sizeof(state)];

  FxRect src = sourceImages[0].imagePixelBounds;
  FxMatrix44 *inv = sourceImages[0].inversePixelTransform;
  FxPoint2D ll = {src.left, src.bottom}, ur = {src.right, src.top};
  ll = [inv transform2DPoint:ll];
  ur = [inv transform2DPoint:ur];

  float pxW = src.right - src.left;
  float pxH = src.top - src.bottom;
  float imgW = ur.x - ll.x;
  float s = (pxW > 0) ? imgW / pxW : 1.0f;
  float srcMinDim = fminf(pxW, pxH);
  float maxRadius = fmaxf(state.radiusX, state.radiusY);
  float offsetPx =
      fmaxf(fabsf(state.offset.x), fabsf(state.offset.y)) * srcMinDim;
  float expand =
      (maxRadius * kExpandMultiplier + offsetPx + kExpandHeadroom) * s;

  FxMatrix44 *pt = destinationImage.pixelTransform;
  FxPoint2D dstLL = {ll.x - expand, ll.y - expand};
  FxPoint2D dstUR = {ur.x + expand, ur.y + expand};
  dstLL = [pt transform2DPoint:dstLL];
  dstUR = [pt transform2DPoint:dstUR];

  destinationImageRect->left = floor(dstLL.x);
  destinationImageRect->bottom = floor(dstLL.y);
  destinationImageRect->right = ceil(dstUR.x);
  destinationImageRect->top = ceil(dstUR.y);
  return YES;
}

- (BOOL)sourceTileRect:(FxRect *)sourceTileRect
       sourceImageIndex:(NSUInteger)sourceImageIndex
           sourceImages:(NSArray<FxImageTile *> *)sourceImages
    destinationTileRect:(FxRect)destinationTileRect
       destinationImage:(FxImageTile *)destinationImage
            pluginState:(NSData *)pluginState
                 atTime:(CMTime)renderTime
                  error:(NSError **)outError {
  *sourceTileRect = destinationTileRect;
  return YES;
}

- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError *_Nullable *)outError {
  if (!pluginState || pluginState.length < sizeof(GlowPluginState) ||
      !sourceImages.count || !sourceImages[0].ioSurface ||
      !destinationImage.ioSurface) {
    [_renderLog() error:@"render bail: state=%p len=%lu src=%lu", pluginState,
                        (unsigned long)pluginState.length,
                        (unsigned long)sourceImages.count];
    if (outError)
      *outError = [NSError errorWithDomain:FxPlugErrorDomain
                                      code:kFxError_InvalidParameter
                                  userInfo:nil];
    return NO;
  }

  GlowPluginState state;
  [pluginState getBytes:&state length:sizeof(state)];

  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  uint64_t regID = destinationImage.deviceRegistryID;
  MTLPixelFormat pf =
      [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
  id<MTLDevice> device = [cache deviceWithRegistryID:regID];
  id<MTLCommandQueue> queue = [cache commandQueueWithRegistryID:regID
                                                    pixelFormat:pf];
  if (!device || !queue)
    return NO;

  id<MTLTexture> outTex = [destinationImage metalTextureForDevice:device];
  id<MTLTexture> inTex = [sourceImages[0] metalTextureForDevice:device];

  float outW = (float)(destinationImage.tilePixelBounds.right -
                       destinationImage.tilePixelBounds.left);
  float outH = (float)(destinationImage.tilePixelBounds.top -
                       destinationImage.tilePixelBounds.bottom);

  // Blur textures capped for memory/perf
  float bs = 1.0f;
  if (outW > kMaxBlurDimension || outH > kMaxBlurDimension)
    bs = fminf(kMaxBlurDimension / outW, kMaxBlurDimension / outH);
  NSUInteger bW = MAX(1, (NSUInteger)(outW * bs));
  NSUInteger bH = MAX(1, (NSUInteger)(outH * bs));

  MTLTextureDescriptor *desc =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf
                                                         width:bW
                                                        height:bH
                                                     mipmapped:NO];
  desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead |
               MTLTextureUsageShaderWrite;
  desc.storageMode = MTLStorageModePrivate;
  id<MTLTexture> prepTex = [device newTextureWithDescriptor:desc];
  id<MTLTexture> blurTex = [device newTextureWithDescriptor:desc];
  if (!prepTex || !blurTex) {
    [cache returnCommandQueueToCache:queue];
    return NO;
  }

  // Pipeline states
  id<MTLRenderPipelineState> prepPS =
      [cache buildAndRegisterPipelineStateForPluginID:
                 @"co.overpolish.keyframeless.Glow.prep"
                                           registryID:regID
                                          pixelFormat:pf
                                             bundleID:nil
                                         vertexShader:@"vertexShader"
                                       fragmentShader:@"glowPrep"
                                            blendMode:KKBlendModeNone];
  id<MTLRenderPipelineState> compPS =
      [cache buildAndRegisterPipelineStateForPluginID:
                 @"co.overpolish.keyframeless.Glow.comp"
                                           registryID:regID
                                          pixelFormat:pf
                                             bundleID:nil
                                         vertexShader:@"vertexShader"
                                       fragmentShader:@"glowComposite"
                                            blendMode:KKBlendModeNone];
  if (!prepPS || !compPS) {
    [cache returnCommandQueueToCache:queue];
    return NO;
  }

  // Vertex geometry
  FxRect st = sourceImages[0].tilePixelBounds;
  FxRect dt = destinationImage.tilePixelBounds;
  float cx = (dt.left + dt.right) / 2.0f;
  float cy = (dt.bottom + dt.top) / 2.0f;

  KKVertex2D srcV[] = {
      {{((float)st.right - cx) * bs, -((float)st.top - cy) * bs}, {1, 1}},
      {{((float)st.left - cx) * bs, -((float)st.top - cy) * bs}, {0, 1}},
      {{((float)st.right - cx) * bs, -((float)st.bottom - cy) * bs}, {1, 0}},
      {{((float)st.left - cx) * bs, -((float)st.bottom - cy) * bs}, {0, 0}},
  };
  KKVertex2D dstV[] = {
      {{outW / 2, -outH / 2}, {1, 1}},
      {{-outW / 2, -outH / 2}, {0, 1}},
      {{outW / 2, outH / 2}, {1, 0}},
      {{-outW / 2, outH / 2}, {0, 0}},
  };

  simd_uint2 bvs = {(uint)bW, (uint)bH};
  simd_uint2 fvs = {(uint)outW, (uint)outH};
  MTLViewport bvp = {0, 0, (double)bW, (double)bH, -1, 1};
  float ioH = (float)[destinationImage.ioSurface height];
  MTLViewport ovp = {0, ioH - outH, outW, outH, -1, 1};

  id<MTLCommandBuffer> cb = [queue commandBuffer];
  cb.label = @"Glow";
  [cb enqueue];

  // 1) Prep: draw source into blur-sized texture
  {
    MTLRenderPassDescriptor *rpd =
        [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = prepTex;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rpd];
    [e setViewport:bvp];
    [e setVertexBytes:srcV
               length:sizeof(srcV)
              atIndex:KKVertexInputIndex_Vertices];
    [e setVertexBytes:&bvs
               length:sizeof(bvs)
              atIndex:KKVertexInputIndex_ViewportSize];
    [e setRenderPipelineState:prepPS];
    [e setFragmentTexture:inTex atIndex:KKTextureIndex_InputImage];
    int cm = state.colorMode;
    [e setFragmentBytes:&cm length:sizeof(cm) atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip
          vertexStart:0
          vertexCount:4];
    [e endEncoding];
  }

  // 2) MPS Gaussian blur
  {
    float sigma = fmaxf(fmaxf(state.radiusX, state.radiusY) * 0.5f * bs, 0.5f);
    MPSImageGaussianBlur *mps =
        [[MPSImageGaussianBlur alloc] initWithDevice:device sigma:sigma];
    mps.edgeMode = MPSImageEdgeModeClamp;
    [mps encodeToCommandBuffer:cb
                 sourceTexture:prepTex
            destinationTexture:blurTex];
  }

  // 3) Composite: glow behind original → output
  {
    MTLRenderPassDescriptor *rpd =
        [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = outTex;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rpd];
    [e setViewport:ovp];
    [e setVertexBytes:dstV
               length:sizeof(dstV)
              atIndex:KKVertexInputIndex_Vertices];
    [e setVertexBytes:&fvs
               length:sizeof(fvs)
              atIndex:KKVertexInputIndex_ViewportSize];
    [e setRenderPipelineState:compPS];
    [e setFragmentTexture:inTex atIndex:KKTextureIndex_InputImage];
    [e setFragmentTexture:blurTex atIndex:1];
    float rx = state.radiusX, ry = state.radiusY;
    float i = state.intensity, f = state.falloff, n = state.noise;
    // Offset is in object-space fractions → convert to UV.
    FxRect sp = sourceImages[0].imagePixelBounds;
    float srcW = sp.right - sp.left;
    float srcH = sp.top - sp.bottom;
    simd_float2 off = {-state.offset.x * srcW / outW,
                       -state.offset.y * srcH / outH};
    int cm = state.colorMode, gt = state.gradientType;
    float ga = state.gradientAngle;
    [e setFragmentBytes:&rx length:sizeof(rx) atIndex:FragmentIndex_RadiusX];
    [e setFragmentBytes:&ry length:sizeof(ry) atIndex:FragmentIndex_RadiusY];
    [e setFragmentBytes:&i length:sizeof(i) atIndex:FragmentIndex_Intensity];
    [e setFragmentBytes:&f length:sizeof(f) atIndex:FragmentIndex_Falloff];
    [e setFragmentBytes:&off length:sizeof(off) atIndex:FragmentIndex_Offset];
    [e setFragmentBytes:&state.glowColor
                 length:sizeof(state.glowColor)
                atIndex:FragmentIndex_GlowColor];
    [e setFragmentBytes:&cm length:sizeof(cm) atIndex:FragmentIndex_ColorMode];
    [e setFragmentBytes:state.gradientLUT
                 length:sizeof(state.gradientLUT)
                atIndex:FragmentIndex_GradientLUT];
    [e setFragmentBytes:&gt
                 length:sizeof(gt)
                atIndex:FragmentIndex_GradientType];
    [e setFragmentBytes:&ga
                 length:sizeof(ga)
                atIndex:FragmentIndex_GradientAngle];
    [e setFragmentBytes:&n length:sizeof(n) atIndex:FragmentIndex_Noise];
    float noff = state.noiseOffset;
    [e setFragmentBytes:&noff
                 length:sizeof(noff)
                atIndex:FragmentIndex_NoiseOffset];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip
          vertexStart:0
          vertexCount:4];
    [e endEncoding];
  }

  [cb commit];
  [cb waitUntilCompleted];
  [cache returnCommandQueueToCache:queue];
  return YES;
}

@end
#pragma clang diagnostic pop
