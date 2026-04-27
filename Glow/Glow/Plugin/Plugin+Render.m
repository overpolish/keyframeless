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

static const float kMaxBlurDimension = 2048.0f;

/// Encodes Glow's 4-stage pipeline (prep → MPS Gaussian blur → optional
/// bloom prep+blur → composite) onto a caller-owned command buffer,
/// writing the final composite into `outTex`. Caller is responsible for
/// allocating `prepTex`/`blurTex` (and `bloomPrep`/`bloomBlur` when
/// `state.threshold > 0`), committing the buffer, and managing texture
/// lifetime.
static void _encodeGlowPipeline(
    KKMetalDeviceCache *cache, uint64_t regID, MTLPixelFormat pf,
    id<MTLDevice> device, id<MTLCommandBuffer> cb, GlowPluginState state,
    id<MTLTexture> outTex, id<MTLTexture> inTex, id<MTLTexture> prepTex,
    id<MTLTexture> blurTex, id<MTLTexture> _Nullable bloomPrepTex,
    id<MTLTexture> _Nullable bloomBlurTex, FxImageTile *destinationImage,
    NSArray<FxImageTile *> *sourceImages, NSUInteger bW, NSUInteger bH,
    float bs, float outW, float outH, MTLViewport ovp) {
  BOOL hasBloom =
      (state.threshold > 0.0f) && bloomPrepTex != nil && bloomBlurTex != nil;

  id<MTLRenderPipelineState> prepPS = [cache
      buildAndRegisterPipelineStateForPluginID:@"co.overpolish.keyframeless"
                                               @".Glow.prep"
                                    registryID:regID
                                   pixelFormat:pf
                                      bundleID:nil
                                  vertexShader:@"vertexShader"
                                fragmentShader:@"glowPrep"
                                     blendMode:KKBlendModeNone];
  id<MTLRenderPipelineState> compPS = [cache
      buildAndRegisterPipelineStateForPluginID:@"co.overpolish.keyframeless"
                                               @".Glow.comp"
                                    registryID:regID
                                   pixelFormat:pf
                                      bundleID:nil
                                  vertexShader:@"vertexShader"
                                fragmentShader:@"glowComposite"
                                     blendMode:KKBlendModeNone];
  id<MTLRenderPipelineState> bloomPrepPS = nil;
  if (hasBloom) {
    bloomPrepPS = [cache
        buildAndRegisterPipelineStateForPluginID:@"co.overpolish.keyframeless"
                                                 @".Glow.bloomPrep"
                                      registryID:regID
                                     pixelFormat:pf
                                        bundleID:nil
                                    vertexShader:@"vertexShader"
                                  fragmentShader:@"glowBloomPrep"
                                       blendMode:KKBlendModeNone];
  }
  if (!prepPS || !compPS)
    return;

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
  float sigma = fmaxf(fmaxf(state.radiusX, state.radiusY) * 0.5f * bs, 0.5f);

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

  // 2) MPS Gaussian blur: prepTex → blurTex
  {
    MPSImageGaussianBlur *mps =
        [[MPSImageGaussianBlur alloc] initWithDevice:device sigma:sigma];
    mps.edgeMode = MPSImageEdgeModeClamp;
    [mps encodeToCommandBuffer:cb
                 sourceTexture:prepTex
            destinationTexture:blurTex];
  }

  // 2b) Bloom lane: bright-pass extraction → blur (separate textures)
  if (hasBloom && bloomPrepPS) {
    {
      MTLRenderPassDescriptor *rpd =
          [MTLRenderPassDescriptor renderPassDescriptor];
      rpd.colorAttachments[0].texture = bloomPrepTex;
      rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
      rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
      id<MTLRenderCommandEncoder> e =
          [cb renderCommandEncoderWithDescriptor:rpd];
      [e setViewport:bvp];
      [e setVertexBytes:srcV
                 length:sizeof(srcV)
                atIndex:KKVertexInputIndex_Vertices];
      [e setVertexBytes:&bvs
                 length:sizeof(bvs)
                atIndex:KKVertexInputIndex_ViewportSize];
      [e setRenderPipelineState:bloomPrepPS];
      [e setFragmentTexture:inTex atIndex:KKTextureIndex_InputImage];
      float thr = state.threshold;
      [e setFragmentBytes:&thr length:sizeof(thr) atIndex:0];
      [e drawPrimitives:MTLPrimitiveTypeTriangleStrip
            vertexStart:0
            vertexCount:4];
      [e endEncoding];
    }
    {
      MPSImageGaussianBlur *mps =
          [[MPSImageGaussianBlur alloc] initWithDevice:device sigma:sigma];
      mps.edgeMode = MPSImageEdgeModeClamp;
      [mps encodeToCommandBuffer:cb
                   sourceTexture:bloomPrepTex
              destinationTexture:bloomBlurTex];
    }
  }

  // 3) Composite into outTex
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
    [e setFragmentTexture:(hasBloom ? bloomBlurTex : blurTex) atIndex:2];
    float rx = state.radiusX, ry = state.radiusY;
    float i = state.intensity, f = state.falloff, n = state.noise;
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
    float nseed = state.noiseSeed;
    [e setFragmentBytes:&nseed
                 length:sizeof(nseed)
                atIndex:FragmentIndex_NoiseSeed];
    simd_float2 blurUVScale = {(float)bW / (float)prepTex.width,
                               (float)bH / (float)prepTex.height};
    [e setFragmentBytes:&blurUVScale
                 length:sizeof(blurUVScale)
                atIndex:FragmentIndex_BlurUVScale];
    float thr = state.threshold;
    [e setFragmentBytes:&thr
                 length:sizeof(thr)
                atIndex:FragmentIndex_Threshold];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip
          vertexStart:0
          vertexCount:4];
    [e endEncoding];
  }
}

// Pool of texture pairs for blur intermediates. All allocated at max cap size.
// Concurrency limited by semaphore — at most kTexPairPoolSize renders
// in-flight.
typedef struct {
  id<MTLTexture> a;
  id<MTLTexture> b;
} GlowTexPair;

static const NSUInteger kTexPairPoolSize = 4;
static GlowTexPair _texPairPool[4];
static BOOL _texPairInUse[4];
static dispatch_semaphore_t _texPairSema;
static dispatch_once_t _texPairOnce;

static void _texPairPoolInit(void) {
  dispatch_once(&_texPairOnce, ^{
    _texPairSema = dispatch_semaphore_create(kTexPairPoolSize);
    memset(_texPairInUse, 0, sizeof(_texPairInUse));
  });
}

static NSInteger _texPairCheckout(id<MTLDevice> device, MTLPixelFormat pf) {
  _texPairPoolInit();
  dispatch_semaphore_wait(_texPairSema, DISPATCH_TIME_FOREVER);
  @synchronized([GlowPlugin class]) {
    for (NSUInteger i = 0; i < kTexPairPoolSize; i++) {
      if (!_texPairInUse[i]) {
        _texPairInUse[i] = YES;
        if (!_texPairPool[i].a || _texPairPool[i].a.pixelFormat != pf) {
          NSUInteger cap = (NSUInteger)kMaxBlurDimension;
          MTLTextureDescriptor *desc =
              [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf
                                                                 width:cap
                                                                height:cap
                                                             mipmapped:NO];
          desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead |
                       MTLTextureUsageShaderWrite;
          desc.storageMode = MTLStorageModePrivate;
          _texPairPool[i].a = [device newTextureWithDescriptor:desc];
          _texPairPool[i].b = [device newTextureWithDescriptor:desc];
        }
        return (NSInteger)i;
      }
    }
  }
  return -1;
}

static void _texPairReturn(NSInteger idx) {
  if (idx < 0)
    return;
  @synchronized([GlowPlugin class]) {
    _texPairInUse[idx] = NO;
  }
  dispatch_semaphore_signal(_texPairSema);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation GlowPlugin (Render)

- (BOOL)pluginState:(NSData **)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error {
  [self updateParameterVisibilityAtTime:renderTime];

  GlowPluginState params;
  if (![self glowParams:&params atTime:renderTime error:error])
    return NO;

  id<FxParameterRetrievalAPI_v6> paramAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  KKMotionBlurState mbState =
      [KKMotionBlur snapshotStateWithParameterAPI:paramAPI
                                        timingAPI:timingAPI
                                           atTime:renderTime];

  if (mbState.enabled && mbState.transitionsOnly &&
      ![self multiStageAnyLaneInTransitionAtTime:renderTime]) {
    mbState.enabled = false;
  }

  // Layout: [KKMotionBlurState | N × GlowPluginState]. Sample 0 is at
  // renderTime; samples 1..N-1 are evaluated backwards across the shutter
  // window when blur is enabled.
  NSMutableData *data = [NSMutableData data];
  [data appendBytes:&mbState length:sizeof(mbState)];
  [data appendBytes:&params length:sizeof(params)];

  if (mbState.enabled) {
    NSArray<NSValue *> *times = [KKMotionBlur sampleTimesForState:mbState
                                                       renderTime:renderTime];
    for (NSUInteger i = 1; i < times.count; i++) {
      CMTime t = kCMTimeZero;
      [times[i] getValue:&t];
      GlowPluginState p;
      if (![self glowParams:&p atTime:t error:error])
        return NO;
      [data appendBytes:&p length:sizeof(p)];
    }
  }

  *pluginState = data;
  return (*pluginState != nil);
}

- (BOOL)glowParams:(GlowPluginState *)outParams
            atTime:(CMTime)renderTime
             error:(NSError **)error {
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
  double threshold = 0.0;
  [api getFloatValue:&threshold
       fromParameter:kParamThreshold
              atTime:renderTime];
  [api getFloatValue:&noise fromParameter:kParamNoise atTime:renderTime];
  double noiseOffset = 0.0;
  [api getFloatValue:&noiseOffset
       fromParameter:kParamNoiseOffset
              atTime:renderTime];
  double noiseSpeed = 0.0;
  [api getFloatValue:&noiseSpeed
       fromParameter:kParamNoiseSpeed
              atTime:renderTime];
  double noiseSeedVal = CMTimeGetSeconds(renderTime) * noiseSpeed * 5.0;

  double posX = 0.5, posY = 0.5;
  [api getXValue:&posX
             YValue:&posY
      fromParameter:kParamPosition
             atTime:renderTime];

  int gradType = 0;
  double gradAngle = 0;
  [api getIntValue:&gradType
      fromParameter:kParamGradientType
             atTime:renderTime];
  [api getFloatValue:&gradAngle
       fromParameter:kParamGradientAngle
              atTime:renderTime];

  NSDictionary<NSString *, NSArray<NSNumber *> *> *multiStage =
      [self multiStageValuesAtTime:renderTime];

  KKColorResult *color = [self colorAtTime:renderTime];

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

  NSArray<NSNumber *> *msColor = multiStage[@"Color"];
  if (color.mode == KKColorModeSolid && msColor.count >= 3) {
    finalColor = (simd_float3){(float)msColor[0].doubleValue,
                               (float)msColor[1].doubleValue,
                               (float)msColor[2].doubleValue};
  }

  // Multi-stage gradient LUT: `[r0, g0, b0, r1, g1, b1, ...]` of length
  // `3 * KK_GRADIENT_LUT_SIZE` — wins over the static gradient when present.
  NSArray<NSNumber *> *msGradient = multiStage[@"Gradient"];
  if (color.mode == KKColorModeGradient &&
      msGradient.count == (NSUInteger)(KK_GRADIENT_LUT_SIZE * 3)) {
    for (int i = 0; i < KK_GRADIENT_LUT_SIZE; i++) {
      finalLUT[i] = (simd_float3){
          (float)msGradient[i * 3 + 0].doubleValue,
          (float)msGradient[i * 3 + 1].doubleValue,
          (float)msGradient[i * 3 + 2].doubleValue,
      };
    }
  }

  NSArray<NSNumber *> *msRadius = multiStage[@"Radius"];
  NSArray<NSNumber *> *msIntensity = multiStage[@"Intensity"];
  NSArray<NSNumber *> *msFalloff = multiStage[@"Falloff"];
  NSArray<NSNumber *> *msNoise = multiStage[@"Noise"];
  NSArray<NSNumber *> *msPosition = multiStage[@"Position"];
  NSArray<NSNumber *> *msNoiseOffset = multiStage[@"N. Offset"];

  double outRadiusX = msRadius.count >= 1 ? msRadius[0].doubleValue : radiusX;
  double outRadiusY = msRadius.count >= 2 ? msRadius[1].doubleValue : radiusY;
  double outIntensity =
      msIntensity.count >= 1 ? msIntensity[0].doubleValue : intensity;
  double outFalloff =
      msFalloff.count >= 1 ? (1.0 + msFalloff[0].doubleValue) : (1.0 + falloff);
  double outNoise = msNoise.count >= 1 ? msNoise[0].doubleValue : noise;
  double outOffsetX =
      (msPosition.count >= 1 ? msPosition[0].doubleValue : posX) - 0.5;
  double outOffsetY =
      (msPosition.count >= 2 ? msPosition[1].doubleValue : posY) - 0.5;
  double outNoiseOffsetVal =
      msNoiseOffset.count >= 1 ? msNoiseOffset[0].doubleValue : noiseOffset;

  GlowPluginState state = {
      .radiusX = (float)outRadiusX,
      .radiusY = (float)outRadiusY,
      .intensity = (float)outIntensity,
      .falloff = (float)outFalloff,
      .noise = (float)outNoise,
      .noiseOffset = (float)outNoiseOffsetVal,
      .offset = {(float)outOffsetX, (float)outOffsetY},
      .glowColor = finalColor,
      .colorMode = (int)color.mode,
      .gradientType = gradType,
      .gradientAngle = (float)gradAngle,
      .noiseSeed = (float)noiseSeedVal,
      .threshold = (float)threshold,
  };

  if (color.mode == KKColorModeGradient) {
    memcpy(state.gradientLUT, finalLUT, sizeof(state.gradientLUT));
  } else {
    for (int i = 0; i < KK_GRADIENT_LUT_SIZE; i++)
      state.gradientLUT[i] = state.glowColor;
  }

  *outParams = state;
  return YES;
}

- (BOOL)destinationImageRect:(FxRect *)destinationImageRect
                sourceImages:(NSArray<FxImageTile *> *)sourceImages
            destinationImage:(FxImageTile *)destinationImage
                 pluginState:(NSData *)pluginState
                      atTime:(CMTime)renderTime
                       error:(NSError **)outError {
  if (!pluginState || pluginState.length <
                          sizeof(KKMotionBlurState) + sizeof(GlowPluginState)) {
    *destinationImageRect = sourceImages[0].imagePixelBounds;
    return YES;
  }
  GlowPluginState state;
  [pluginState getBytes:&state
                  range:NSMakeRange(sizeof(KKMotionBlurState), sizeof(state))];

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
  // Visible glow ≈ radius pixels from source edge.
  float blurX = state.radiusX * 1.1f * s;
  float blurY = state.radiusY * 1.1f * s;
  float offPxX = state.offset.x * srcMinDim * s;
  float offPxY = state.offset.y * srcMinDim * s;

  // Asymmetric: only expand toward the glow direction.
  float expandL = blurX + fmaxf(-offPxX, 0);
  float expandR = blurX + fmaxf(offPxX, 0);
  float expandB = blurY + fmaxf(-offPxY, 0);
  float expandT = blurY + fmaxf(offPxY, 0);

  FxMatrix44 *pt = destinationImage.pixelTransform;
  FxPoint2D dstLL = {ll.x - expandL, ll.y - expandB};
  FxPoint2D dstUR = {ur.x + expandR, ur.y + expandT};
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
  [KKPlugin multiStageRenderTickForAPI:self.apiManager
                                atTime:renderTime
                                sender:self];
  [KKPlugin colorSyncFromParams:self.apiManager];

  if (!pluginState ||
      pluginState.length <
          sizeof(KKMotionBlurState) + sizeof(GlowPluginState) ||
      !sourceImages.count || !sourceImages[0].ioSurface ||
      !destinationImage.ioSurface) {
    KKLogError(@"render bail: state=%p len=%lu src=%lu", pluginState,
               (unsigned long)pluginState.length,
               (unsigned long)sourceImages.count);
    if (outError)
      *outError = [NSError errorWithDomain:FxPlugErrorDomain
                                      code:kFxError_InvalidParameter
                                  userInfo:nil];
    return NO;
  }

  @autoreleasepool {

    KKMotionBlurState mbState;
    [pluginState getBytes:&mbState length:sizeof(mbState)];

    KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
    uint64_t regID = destinationImage.deviceRegistryID;
    MTLPixelFormat pf =
        [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
    id<MTLDevice> device = [cache deviceWithRegistryID:regID];
    if (!device)
      return NO;

    float outW = (float)(destinationImage.tilePixelBounds.right -
                         destinationImage.tilePixelBounds.left);
    float outH = (float)(destinationImage.tilePixelBounds.top -
                         destinationImage.tilePixelBounds.bottom);
    float bs = 1.0f;
    if (outW > kMaxBlurDimension || outH > kMaxBlurDimension)
      bs = fminf(kMaxBlurDimension / outW, kMaxBlurDimension / outH);
    NSUInteger bW = MAX(1, (NSUInteger)(outW * bs));
    NSUInteger bH = MAX(1, (NSUInteger)(outH * bs));

    if (mbState.enabled) {
      NSData *capturedState = pluginState;
      MTLTextureUsage scratchUsage = MTLTextureUsageRenderTarget |
                                     MTLTextureUsageShaderRead |
                                     MTLTextureUsageShaderWrite;

      BOOL applied = [KKMotionBlur
          applyToDestinationImage:destinationImage
                     sourceImages:sourceImages
                            state:mbState
                       renderTime:renderTime
                      renderBlock:^BOOL(int sampleIndex,
                                        id<MTLTexture> sampleDest,
                                        id<MTLCommandBuffer> commandBuffer,
                                        NSArray<id<MTLTexture>> *inputs) {
                        if (inputs.count == 0)
                          return NO;
                        NSUInteger off =
                            sizeof(KKMotionBlurState) +
                            (NSUInteger)sampleIndex * sizeof(GlowPluginState);
                        if (off + sizeof(GlowPluginState) >
                            capturedState.length)
                          return NO;
                        GlowPluginState s;
                        [capturedState
                            getBytes:&s
                               range:NSMakeRange(off, sizeof(GlowPluginState))];
                        // Per-sample render target may be downscaled
                        // (KKMotionBlur subframeScale). Fold that ratio into
                        // `bs` so blur intermediate, sigma, and viewport all
                        // halve together while the offset formula keeps its
                        // full-res `outW/outH` reference.
                        float effRatio = (float)sampleDest.width / outW;
                        float bsEff = bs * effRatio;
                        NSUInteger bWEff =
                            MAX((NSUInteger)1, (NSUInteger)(outW * bsEff));
                        NSUInteger bHEff =
                            MAX((NSUInteger)1, (NSUInteger)(outH * bsEff));
                        MTLViewport sampleVP = {0,
                                                0,
                                                (double)sampleDest.width,
                                                (double)sampleDest.height,
                                                -1,
                                                1};
                        // Pooled scratch textures — reused across frames so
                        // memory stays bounded under FCP look-ahead playback.
                        id<MTLTexture> prepTex =
                            [KKMotionBlur scratchTextureForKey:@"glow.prep"
                                                   sampleIndex:sampleIndex
                                                         width:bWEff
                                                        height:bHEff
                                                        format:pf
                                                         usage:scratchUsage
                                                        device:device];
                        id<MTLTexture> blurTex =
                            [KKMotionBlur scratchTextureForKey:@"glow.blur"
                                                   sampleIndex:sampleIndex
                                                         width:bWEff
                                                        height:bHEff
                                                        format:pf
                                                         usage:scratchUsage
                                                        device:device];
                        id<MTLTexture> bloomPrepTex = nil, bloomBlurTex = nil;
                        if (s.threshold > 0.0f) {
                          bloomPrepTex = [KKMotionBlur
                              scratchTextureForKey:@"glow.bloomPrep"
                                       sampleIndex:sampleIndex
                                             width:bWEff
                                            height:bHEff
                                            format:pf
                                             usage:scratchUsage
                                            device:device];
                          bloomBlurTex = [KKMotionBlur
                              scratchTextureForKey:@"glow.bloomBlur"
                                       sampleIndex:sampleIndex
                                             width:bWEff
                                            height:bHEff
                                            format:pf
                                             usage:scratchUsage
                                            device:device];
                        }
                        if (!prepTex || !blurTex)
                          return NO;
                        _encodeGlowPipeline(
                            cache, regID, pf, device, commandBuffer, s,
                            sampleDest, inputs[0], prepTex, blurTex,
                            bloomPrepTex, bloomBlurTex, destinationImage,
                            sourceImages, bWEff, bHEff, bsEff, outW, outH,
                            sampleVP);
                        return YES;
                      }];
      if (applied)
        return YES;
      // Fall through on failure so the user sees the un-blurred frame.
    }

    GlowPluginState state;
    [pluginState
        getBytes:&state
           range:NSMakeRange(sizeof(KKMotionBlurState), sizeof(state))];

    id<MTLCommandQueue> queue = [cache commandQueueWithRegistryID:regID
                                                      pixelFormat:pf];
    if (!queue)
      return NO;

    id<MTLTexture> outTex = [destinationImage metalTextureForDevice:device];
    id<MTLTexture> inTex = [sourceImages[0] metalTextureForDevice:device];

    NSInteger texIdx = _texPairCheckout(device, pf);
    if (texIdx < 0) {
      [cache returnCommandQueueToCache:queue];
      return NO;
    }
    id<MTLTexture> prepTex = _texPairPool[texIdx].a;
    id<MTLTexture> blurTex = _texPairPool[texIdx].b;

    BOOL hasBloom = state.threshold > 0.0f;
    NSInteger bloomTexIdx = -1;
    id<MTLTexture> bloomPrepTex = nil;
    id<MTLTexture> bloomBlurTex = nil;
    if (hasBloom) {
      bloomTexIdx = _texPairCheckout(device, pf);
      if (bloomTexIdx < 0)
        hasBloom = NO;
      else {
        bloomPrepTex = _texPairPool[bloomTexIdx].a;
        bloomBlurTex = _texPairPool[bloomTexIdx].b;
      }
    }

    float ioH = (float)[destinationImage.ioSurface height];
    MTLViewport ovp = {0, ioH - outH, outW, outH, -1, 1};

    id<MTLCommandBuffer> cb = [queue commandBufferWithUnretainedReferences];
    cb.label = @"Glow";
    [cb enqueue];

    _encodeGlowPipeline(cache, regID, pf, device, cb, state, outTex, inTex,
                        prepTex, blurTex, bloomPrepTex, bloomBlurTex,
                        destinationImage, sourceImages, bW, bH, bs, outW, outH,
                        ovp);

    [cb commit];
    [cb waitUntilCompleted];
    _texPairReturn(texIdx);
    _texPairReturn(bloomTexIdx);
    [cache returnCommandQueueToCache:queue];
    return YES;

  } // @autoreleasepool
}

@end
#pragma clang diagnostic pop
