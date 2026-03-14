/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKPlugin.h"
#import "KKHostInfo.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKMetalDeviceCache.h>
#import <KeyframelessKit/KKRenderPrimitives.h>

@interface KKPrincipalDelegate : NSObject <FxPrincipalDelegate>
+ (instancetype)shared;
@end

@implementation KKPrincipalDelegate

+ (instancetype)shared {
  static KKPrincipalDelegate *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[KKPrincipalDelegate alloc] init];
  });
  return instance;
}

- (void)didEstablishConnectionWithHost:(NSString *)hostBundleIdentifier
                               version:(NSString *)hostVersionString {
  [KKHostInfo shared].hostID = hostBundleIdentifier;
}

@end

@implementation KKPlugin

+ (id)servicePrincipalDelegate {
  return [KKPrincipalDelegate shared];
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super init];
  if (self) {
    _apiManager = apiManager;
  }
  return self;
}

- (nullable id<MTLRenderPipelineState>)
    pipelineStateForPluginID:(NSString *)pluginID
            destinationImage:(FxImageTile *)destinationImage
                vertexShader:(NSString *)vertexShader
              fragmentShader:(NSString *)fragmentShader
                   blendMode:(KKBlendMode)blendMode {
  MTLPixelFormat pixelFormat =
      [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
  uint64_t registryID = destinationImage.deviceRegistryID;

  return [[KKMetalDeviceCache sharedCache]
      buildAndRegisterPipelineStateForPluginID:pluginID
                                    registryID:registryID
                                   pixelFormat:pixelFormat
                                      bundleID:nil
                                  vertexShader:vertexShader
                                fragmentShader:fragmentShader
                                     blendMode:blendMode];
}

- (BOOL)
    encodeRenderCommandsForDestinationImage:(FxImageTile *)destinationImage
                               sourceImages:
                                   (NSArray<FxImageTile *> *)sourceImages
                                   commands:
                                       (void (^)(
                                           id<MTLRenderCommandEncoder> encoder,
                                           NSArray<id<MTLTexture>>
                                               *inputTextures))commands {
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

  // Build input texture array - empty for generators, one or more for
  // filters/compositors
  NSMutableArray<id<MTLTexture>> *inputTextures =
      [[NSMutableArray alloc] initWithCapacity:sourceImages.count];
  for (FxImageTile *sourceTile in sourceImages) {
    id<MTLTexture> texture = [sourceTile metalTextureForDevice:device];
    if (texture)
      [inputTextures addObject:texture];
  }

  id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
  commandBuffer.label = @"KKPlugin Command Buffer";
  [commandBuffer enqueue];

  MTLRenderPassColorAttachmentDescriptor *colorAttachment =
      [[MTLRenderPassColorAttachmentDescriptor alloc] init];
  colorAttachment.texture = outputTexture;
  colorAttachment.clearColor = MTLClearColorMake(0, 0, 0, 0);
  colorAttachment.loadAction = MTLLoadActionClear;

  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0] = colorAttachment;

  id<MTLRenderCommandEncoder> encoder =
      [commandBuffer renderCommandEncoderWithDescriptor:rpd];

  float outputWidth = (float)(destinationImage.tilePixelBounds.right -
                              destinationImage.tilePixelBounds.left);
  float outputHeight = (float)(destinationImage.tilePixelBounds.top -
                               destinationImage.tilePixelBounds.bottom);

  MTLViewport viewport = {0, 0, outputWidth, outputHeight, -1.0, 1.0};
  [encoder setViewport:viewport];

  KKVertex2D vertices[] = {
      {{outputWidth / 2.0f, -outputHeight / 2.0f}, {1.0, 1.0}},
      {{-outputWidth / 2.0f, -outputHeight / 2.0f}, {0.0, 1.0}},
      {{outputWidth / 2.0f, outputHeight / 2.0f}, {1.0, 0.0}},
      {{-outputWidth / 2.0f, outputHeight / 2.0f}, {0.0, 0.0}},
  };

  simd_uint2 viewportSize = {(unsigned int)outputWidth,
                             (unsigned int)outputHeight};

  [encoder setVertexBytes:vertices
                   length:sizeof(vertices)
                  atIndex:KKVertexInputIndex_Vertices];
  [encoder setVertexBytes:&viewportSize
                   length:sizeof((viewportSize))
                  atIndex:KKVertexInputIndex_ViewportSize];

  commands(encoder, inputTextures);

  [encoder endEncoding];
  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];

  [cache returnCommandQueueToCache:commandQueue];

  return YES;
}

- (BOOL)addAnimationParametersStartingAtID:(UInt32)baseID
                                   withAPI:
                                       (id<FxParameterCreationAPI_v5>)paramAPI
                                     error:(NSError **)error {
  if (![paramAPI addToggleButtonWithName:@"Animate In"
                             parameterID:baseID
                            defaultValue:NO
                          parameterFlags:kFxParameterFlag_DEFAULT]) {
    if (error != NULL)
      *error = [NSError errorWithDomain:@"co.overpolish.keyframeless.error"
                                   code:1
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Unable to add Animate In toggle"
                               }];
    return NO;
  }

  if (![paramAPI addToggleButtonWithName:@"Animate Out"
                             parameterID:baseID + 1
                            defaultValue:NO
                          parameterFlags:kFxParameterFlag_DEFAULT]) {
    if (error != NULL)
      *error = [NSError errorWithDomain:@"co.overpolish.keyframeless.error"
                                   code:1
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Unable to add Animate Out toggle"
                               }];
    return NO;
  }

  if (![paramAPI addFloatSliderWithName:@"Duration"
                            parameterID:baseID + 2
                           defaultValue:0.5
                           parameterMin:0.1
                           parameterMax:2.0
                              sliderMin:0.1
                              sliderMax:2.0
                                  delta:0.1
                         parameterFlags:kFxParameterFlag_DEFAULT]) {
    if (error != NULL)
      *error = [NSError
          errorWithDomain:@"co.overpolish.keyframeless.error"
                     code:1
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"Unable to add Duration slider"
                 }];
    return NO;
  }

  return YES;
}

- (double)animationFactorAtTime:(CMTime)renderTime baseParamID:(UInt32)baseID {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!paramGetAPI)
    return 1.0;

  BOOL animateIn = NO;
  BOOL animateOut = NO;
  [paramGetAPI getBoolValue:&animateIn fromParameter:baseID atTime:renderTime];
  [paramGetAPI getBoolValue:&animateOut
              fromParameter:baseID + 1
                     atTime:renderTime];

  if (!animateIn && !animateOut)
    return 1.0;

  double animDuration = 0.5;
  [paramGetAPI getFloatValue:&animDuration
               fromParameter:baseID + 2
                      atTime:renderTime];

  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  if (!timingAPI)
    return 1.0;

  CMTime effectStart = kCMTimeZero;
  [timingAPI startTimeForEffect:&effectStart];

  CMTime effectDuration = kCMTimeZero;
  [timingAPI durationTimeForEffect:&effectDuration];

  double effectStartSecs = CMTimeGetSeconds(effectStart);
  double effectDurationSecs = CMTimeGetSeconds(effectDuration);
  double renderTimeSecs = CMTimeGetSeconds(renderTime);
  double t = 1.0;

  if (animateIn) {
    double inFactor = (renderTimeSecs - effectStartSecs) / animDuration;
    inFactor = MAX(0.0, MIN(1.0, inFactor));
    // ease-out cubic: fast expand, gentle settle
    inFactor = 1.0 - pow(1.0 - inFactor, 3.0);
    t *= inFactor;
  }

  if (animateOut) {
    double effectEndSecs = effectStartSecs + effectDurationSecs;
    double outFactor = (effectEndSecs - renderTimeSecs) / animDuration;
    outFactor = MAX(0.0, MIN(1.0, outFactor));
    // ease-in cubic: holds full value, then snaps away
    outFactor = pow(outFactor, 3.0);
    t *= outFactor;
  }

  return t;
}

@end
