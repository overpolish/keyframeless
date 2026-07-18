/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin+Render_Internal.h"
#import "ShaderCustomShader.h"
#import "ShaderDirectives.h"         // ShaderCommonDefault
#import "ShaderMiniViewerRenderer.h" // per-instance descriptor path
#import "ShaderStateBlob.h"

#import <KeyframelessKit/KKMetalDeviceCache.h>
#import <KeyframelessKit/KKMiniViewerFeed.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

// Cleared code = passthrough (show the source unchanged), not the plasma
// default.
static NSString *const kShaderPassthroughSource =
    @"void mainImage(out vec4 O, in vec2 fc){ O = "
    @"texture(iChannel0, fc / iResolution.xy); }";

@implementation ShaderPlugin (Render)

// Effect: request the clip we're applied to as the source (bound to iChannel0
// in the Custom render path). Motion blur averages the shader over a single
// source frame, so no sub-frame source requests. The boundary-value popover
// additionally pulls its requested clip fraction for the mini-viewer preview.
- (BOOL)scheduleInputs:(NSArray<FxImageTileRequest *> *_Nullable *_Nullable)
                           inputImageRequests
       withPluginState:(NSData *)pluginState
                atTime:(CMTime)renderTime
                 error:(NSError **)error {
  NSArray<FxImageTileRequest *> *sourceReqs = KKBuildSourceRequests(
      renderTime,
      ShaderMiniViewerRequestPathForUUID(KKInstanceUUIDForAPI(self.apiManager)),
      self.renderCache, ^id(CMTime t) {
        return [[FxImageTileRequest alloc]
            initWithSource:kFxImageTileRequestSourceEffectClip
                      time:t
            includeFilters:YES
               parameterID:0];
      });
  // Also ask for the "To" image well. In a Motion transition template it is
  // wired to "Drop Zone Transition B", which lands the incoming clip alongside
  // the effect clip in -renderDestinationImage: - the only way an FxPlug filter
  // gets a second texture, and so the whole basis of transition support.
  NSMutableArray<FxImageTileRequest *> *reqs = [sourceReqs mutableCopy];
  [reqs addObject:[[FxImageTileRequest alloc]
                      initWithSource:kFxImageTileRequestSourceParameter
                                time:renderTime
                      includeFilters:NO
                         parameterID:kParamToImage]];
  *inputImageRequests = reqs;
  return YES;
}

// The fixed uniform block for this frame. `mediaW/H` are the output dimensions,
// which drive iResolution.
static KKGLSLUniforms ShaderBuildUniforms(const ShaderPluginState *base,
                                          CGFloat mediaW, CGFloat mediaH,
                                          float encodeSRGB) {
  float iTime = base->common.time * base->common.speed +
                fmodf(base->common.seed, 10000.0f);
  KKGLSLUniforms u;
  u.resTime = (simd_float4){(float)mediaW, (float)mediaH, 1.0f, iTime};
  u.mouse = (simd_float4){0.0f, 0.0f, 0.0f, 0.0f};
  u.date = (simd_float4){0.0f, 0.0f, 0.0f, 0.0f};
  // x=iTimeDelta (approx), y=float(iFrame) (approx), z=flipY (FCP dest is
  // reverse-Y, no flip), w=encodeSRGB.
  u.extra = (simd_float4){1.0f / 60.0f, iTime * 60.0f, 0.0f, encodeSRGB};
  // Core film grain (Grain / Grain Size lanes), same as the built-in Types.
  u.grain =
      (simd_float4){base->common.grain, base->common.grainSize, 0.0f, 0.0f};
  // iChannelResolution: 0 = source clip (filled from the bound texture at draw
  // time), 1-3 = the 256x256 noise texture.
  u.chanRes[0] = (simd_float4){(float)mediaW, (float)mediaH, 1.0f, 0.0f};
  for (int c = 1; c < 4; c++)
    u.chanRes[c] = (simd_float4){256.0f, 256.0f, 1.0f, 0.0f};
  // iProgress: raw clip fraction, deliberately NOT scaled by Speed/Seed the way
  // iTime is - a transition's progress has to reach exactly 1.0 at the cut
  // regardless of the motion-rate params.
  u.transition = (simd_float4){base->common.progress, 0.0f, 0.0f, 0.0f};
  return u;
}

// Single pass: source clip -> iChannel0, the "To" well -> iChannel1, noise ->
// the rest.
- (BOOL)_renderSinglePassWithUniforms:(KKGLSLUniforms)u
                                 base:(const ShaderPluginState *)base
                               source:(NSString *)effectiveSource
                     destinationImage:(FxImageTile *)destinationImage
                         sourceImages:(NSArray<FxImageTile *> *)sourceImages {
  id<MTLRenderPipelineState> customPS =
      [self customPipelineForSource:effectiveSource
                   destinationImage:destinationImage];
  if (!customPS) {
    effectiveSource = ShaderCustomErrorShaderSource();
    customPS = [self customPipelineForSource:effectiveSource
                            destinationImage:destinationImage];
  }
  if (!customPS)
    return NO;
  KKGLSLTranspileResult *tr = KKTranspileGLSL(effectiveSource);
  KKMetalDeviceCache *dc = [KKMetalDeviceCache sharedCache];
  uint64_t registryID = destinationImage.deviceRegistryID;
  id<MTLDevice> device = [dc deviceWithRegistryID:registryID];
  id<MTLTexture> noiseTex =
      tr.declaredChannelMask ? KKCustomChannelNoiseTexture(device) : nil;
  id<MTLSamplerState> chSampler =
      tr.declaredChannelMask ? KKCustomChannelSampler(device) : nil;
  id<MTLSamplerState> srcSampler =
      tr.declaredChannelMask ? KKCustomSourceSampler(device) : nil;
  // The clip we're applied to -> iChannel0, the "To" image well -> iChannel1.
  // In a Motion transition template the well is wired to "Drop Zone Transition
  // B", so a GL transition samples the outgoing and incoming clips together.
  id<MTLTexture> rawTo = [KKImageTileForParameterID(sourceImages, kParamToImage)
      metalTextureForDevice:device];
  // Gamma-encode the linear sources so a Shadertoy shader (gamma-space input,
  // output re-decoded for the float dest) round-trips them instead of
  // double-decoding + darkening. extra.w==0 == float/linear dest; an 8-bit dest
  // already carries gamma source, so leave it untouched. BOTH channels get the
  // same treatment: a transition blending a gamma A against a linear B would
  // tear across the mix.
  //
  // gammaSrc stays nil when nothing was encoded - the encode block below then
  // falls back to its own inputTextures[0].
  id<MTLTexture> gammaSrc = nil, gammaTo = rawTo;
  if (u.extra.w == 0.0f && (sourceImages.count || rawTo)) {
    id<MTLTexture> rawSrc = sourceImages.count
                                ? [sourceImages[0] metalTextureForDevice:device]
                                : nil;
    id<MTLCommandQueue> gq = [dc
        commandQueueWithRegistryID:registryID
                       pixelFormat:[KKMetalDeviceCache pixelFormatForImageTile:
                                                           destinationImage]];
    if (rawSrc)
      gammaSrc = KKGammaEncodeSourceTexture(gq, rawSrc);
    if (rawTo)
      gammaTo = KKGammaEncodeSourceTexture(gq, rawTo) ?: rawTo;
    if (gq)
      [dc returnCommandQueueToCache:gq];
  }
  id<MTLTexture> toTex = gammaTo;
  ShaderPluginState baseCopy = *base;
  return [self
      encodeRenderCommandsForDestinationImage:destinationImage
                                 sourceImages:sourceImages
                                     commands:^(
                                         id<MTLRenderCommandEncoder> encoder,
                                         NSArray<id<MTLTexture>>
                                             *inputTextures) {
                                       [encoder
                                           setRenderPipelineState:customPS];
                                       id<MTLTexture> src =
                                           gammaSrc
                                               ?: (inputTextures.count
                                                       ? inputTextures[0]
                                                       : nil);
                                       KKGLSLUniforms uu = u;
                                       if (src)
                                         uu.chanRes[0] = (simd_float4){
                                             (float)src.width,
                                             (float)src.height, 1.0f, 0.0f};
                                       if (toTex)
                                         uu.chanRes[1] = (simd_float4){
                                             (float)toTex.width,
                                             (float)toTex.height, 1.0f, 0.0f};
                                       KKBindGLSLUniforms(
                                           encoder, &uu, baseCopy.colorPool,
                                           baseCopy.colorPoolCount);
                                       KKBindCustomChannelTextures(
                                           encoder, tr,
                                           @[
                                             src ?: (id)[NSNull null],
                                             toTex ?: (id)[NSNull null],
                                             [NSNull null], [NSNull null]
                                           ],
                                           srcSampler, noiseTex, chSampler);
                                       [encoder
                                           drawPrimitives:
                                               MTLPrimitiveTypeTriangleStrip
                                              vertexStart:0
                                              vertexCount:4];
                                     }];
}

// Publish the source (and the "To" well) to the inspector's mini-viewer feed.
// The renderer applies the shader locally, so these are the RAW textures.
- (void)_publishMiniViewerFeeds:(FxImageTile *)destinationImage
                   sourceImages:(NSArray<FxImageTile *> *)sourceImages
                     renderTime:(CMTime)renderTime {
  // Per slot: single-slot = playhead, multi-slot = boundary preview / filmstrip
  // / onion. Shared glue in KKPlugin (MiniViewerFeed). The single-slot tag is
  // this frame's clip fraction (not a hard 0), so during playback/scrub the
  // open popover's mini-viewer sets editFraction to it and advances iTime with
  // the playhead - otherwise the preview stays frozen at t=0 while the timeline
  // moves (the popover live-playback plumbing the rest of the kit already
  // does).
  [self
      kkPublishMiniViewerFeedForDestination:destinationImage
                               sourceImages:sourceImages
                             descriptorPath:
                                 ShaderMiniViewerDescriptorPathForUUID(
                                     KKInstanceUUIDForAPI(self.apiManager))
                            boundaryReqSecs:self.renderCache.boundaryReqSecs
                           boundaryReqFracs:self.renderCache.boundaryReqFracs
                            multiSlotActive:self.renderCache.boundaryFeedActive
                          changesOutputSize:NO
                                 defaultTag:[self.renderCache
                                                clipFractionAtSeconds:
                                                    CMTimeGetSeconds(
                                                        renderTime)]];
  // The "To" well as a second feed texture, so the mini-viewer can preview a
  // two-texture (GL-transition) shader instead of falling through to
  // iChannel1's noise.
  [self kkPublishMiniViewerChannel1ForDestination:destinationImage
                                     sourceImages:sourceImages
                                  wellParameterID:kParamToImage];
}

- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError *_Nullable *)outError {
  if (sourceImages.count == 0 || !sourceImages[0].ioSurface ||
      !destinationImage.ioSurface) {
    if (outError != NULL) {
      *outError = [NSError errorWithDomain:FxPlugErrorDomain
                                      code:kFxError_InvalidParameter
                                  userInfo:@{
                                    NSLocalizedDescriptionKey :
                                        @"No source/destination IOSurface"
                                  }];
    }
    return NO;
  }

  [self _publishMiniViewerFeeds:destinationImage
                   sourceImages:sourceImages
                     renderTime:renderTime];

  // Output dimensions drive the shader's resolution uniform (iResolution etc.).
  CGFloat mediaW = destinationImage.imagePixelBounds.right -
                   destinationImage.imagePixelBounds.left;
  CGFloat mediaH = destinationImage.imagePixelBounds.top -
                   destinationImage.imagePixelBounds.bottom;

  // State built in -pluginState: (the params API is invalid here). Layout is
  // [KKMotionBlurState][state@sample0][sections...]; read the header + the base
  // sample. Fall back to defaults if the blob is missing/short.
  KKMotionBlurState mbState;
  ShaderPluginState base;
  if (pluginState.length >= sizeof(mbState) + sizeof(base)) {
    [pluginState getBytes:&mbState length:sizeof(mbState)];
    [pluginState getBytes:&base
                    range:NSMakeRange(sizeof(mbState), sizeof(base))];
  } else {
    memset(&mbState, 0, sizeof(mbState)); // disabled
    memset(&base, 0, sizeof(base));
    base.common = ShaderCommonDefault();
  }

  float encodeSRGB =
      (destinationImage.ioSurface.pixelFormat == kCVPixelFormatType_32BGRA)
          ? 1.0f
          : 0.0f;
  KKGLSLUniforms u = ShaderBuildUniforms(&base, mediaW, mediaH, encodeSRGB);

  // Multi-pass sections from the blob tail (Image / Common / Buffer A-D).
  // Common is prepended to every pass.
  NSUInteger head = sizeof(mbState) + sizeof(ShaderPluginState);
  NSDictionary<NSString *, NSString *> *sections =
      (pluginState.length > head) ? ShaderParseSections(pluginState, head)
                                  : @{};
  NSString *common = sections[@"Common"] ?: @"";
  NSString *imageSrc = sections[@"Image"];
  if (imageSrc.length == 0)
    imageSrc = kShaderPassthroughSource;
  NSString * (^withCommon)(NSString *) = ^NSString *(NSString *s) {
    return common.length ? [NSString stringWithFormat:@"%@\n%@", common, s] : s;
  };

  // Any Buffer A-D present -> multi-pass (buffer textures feed the passes'
  // iChannels).
  NSArray<NSString *> *bufNames =
      @[ @"Buffer A", @"Buffer B", @"Buffer C", @"Buffer D" ];
  NSMutableArray<NSString *> *bufSources = [NSMutableArray arrayWithCapacity:4];
  BOOL anyBuffer = NO;
  for (NSString *bn in bufNames) {
    NSString *bs = sections[bn];
    if (bs.length > 0) {
      [bufSources addObject:withCommon(bs)];
      anyBuffer = YES;
    } else {
      [bufSources addObject:@""];
    }
  }
  if (!anyBuffer)
    return [self _renderSinglePassWithUniforms:u
                                          base:&base
                                        source:withCommon(imageSrc)
                              destinationImage:destinationImage
                                  sourceImages:sourceImages];

  // Frame index + per-frame iTime step, so feedback buffers advance
  // deterministically (carry-forward on a sequential frame, re-sim on a seek).
  // frameDurSec comes from the render cache; -1 = unknown (fall back to a plain
  // one-step advance).
  double frameDur = self.renderCache.frameDurSec;
  NSInteger frameIndex =
      (frameDur > 0.0) ? (NSInteger)llround(base.common.time / frameDur) : -1;
  float dtPerFrame = (float)(frameDur * base.common.speed);
  return [self renderCustomMultipassWithUniforms:u
                                       colorPool:base.colorPool
                                       poolCount:base.colorPoolCount
                                     imageSource:withCommon(imageSrc)
                                   bufferSources:bufSources
                                      frameIndex:frameIndex
                                      dtPerFrame:dtPerFrame
                                destinationImage:destinationImage
                                    sourceImages:sourceImages];
}

@end

#pragma clang diagnostic pop
