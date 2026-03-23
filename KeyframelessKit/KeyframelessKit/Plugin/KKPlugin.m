/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKPlugin.h"
#import "../Views/KKAlertView.h"
#import "../Views/KKKbd.h"
#import "../Views/KKSeparatorView.h"
#import "KKConstants.h"
#import "KKHostInfo.h"
#import <AppKit/AppKit.h>
#import <AppKit/NSView.h>
#import <Foundation/Foundation.h>
#import <FxPlug/FxPlugSDK.h>
#import <FxPlug/FxTypes.h>
#import <KeyframelessKit/KKMetalDeviceCache.h>
#import <KeyframelessKit/KKRenderPrimitives.h>
#import <objc/runtime.h>

// FxPlug calls createViewForParameterID: on a fresh plugin instance, not the
// one that ran addParametersWithError:. Store parameter metadata at class level
// (keyed by the concrete plugin class) so any instance can look it up.
static const void *const kKKSepTexts = &kKKSepTexts;
static const void *const kKKSepIcons = &kKKSepIcons;
static const void *const kKKInfoTexts = &kKKInfoTexts;
static const void *const kKKInfoAttrTexts = &kKKInfoAttrTexts;
static const void *const kKKInfoIcons = &kKKInfoIcons;

static NSMutableDictionary<NSNumber *, id> *kkClassRegistry(Class cls,
                                                            const void *key) {
  NSMutableDictionary *dict = objc_getAssociatedObject(cls, key);
  if (!dict) {
    dict = [NSMutableDictionary new];
    objc_setAssociatedObject(cls, key, dict, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return dict;
}

// ---------------------------------------------------------------------------
// Animation curve functions
// In-factor:  raw 0→1 as clip progresses from start (used for animate-in)
// Out-factor: raw 1→0 as clip approaches end       (used for animate-out)
// Bounce and Elastic may exceed [0,1] intentionally (overshoot effect).
// ---------------------------------------------------------------------------

static double kkSmoothstep(double t) { return t * t * (3.0 - 2.0 * t); }

// In: ease-out cubic — fast start, decelerates to rest
static double kkEaseOutCubic(double t) { return 1.0 - pow(1.0 - t, 3.0); }

// Out: ease-in cubic — slow start, accelerates away
static double kkEaseInCubic(double t) { return t * t * t; }

// In: spring — overshoots target once, settles back (ease-out-back)
static double kkEaseOutSpring(double t) {
  const double c1 = 1.70158, c3 = c1 + 1.0;
  return 1.0 + c3 * pow(t - 1.0, 3.0) + c1 * pow(t - 1.0, 2.0);
}

// Out: spring — holds near full, brief anticipation dip, snaps away
// (ease-in-back)
static double kkEaseInSpring(double t) {
  const double c1 = 1.70158, c3 = c1 + 1.0;
  return c3 * t * t * t - c1 * t * t;
}

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

@interface KKPlugin () <FxCustomParameterViewHost_v2>
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

- (BOOL)addAnimationParametersWithAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                                error:(NSError **)error {
  if (![self
          addSeparatorParameterWithText:@"Timing"
                                   icon:[NSImage
                                            imageWithSystemSymbolName:@"timer"
                                             accessibilityDescription:nil]
                            parameterID:kKKParamAnimationSeparator
                                withAPI:paramAPI
                                  error:error]) {
    return NO;
  }

  if (![paramAPI addToggleButtonWithName:@"Animate In"
                             parameterID:kKKParamAnimateIn
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
                             parameterID:kKKParamAnimateOut
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
                            parameterID:kKKParamAnimationDuration
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

  if (![paramAPI
          addPopupMenuWithName:@"Interpolation"
                   parameterID:kKKParamAnimationInterpolation
                  defaultValue:KKAnimationCurveCubic
                   menuEntries:@[ @"Linear", @"Smooth", @"Cubic", @"Spring" ]
                parameterFlags:kFxParameterFlag_DEFAULT]) {
    if (error != NULL)
      *error = [NSError errorWithDomain:@"co.overpolish.keyframeless.error"
                                   code:1
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Unable to add Interpolation popup"
                               }];
    return NO;
  }

  return YES;
}

- (double)animationFactorAtTime:(CMTime)renderTime {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!paramGetAPI)
    return 1.0;

  BOOL animateIn = NO;
  BOOL animateOut = NO;
  [paramGetAPI getBoolValue:&animateIn
              fromParameter:kKKParamAnimateIn
                     atTime:renderTime];
  [paramGetAPI getBoolValue:&animateOut
              fromParameter:kKKParamAnimateOut
                     atTime:renderTime];

  if (!animateIn && !animateOut)
    return 1.0;

  double animDuration = 0.5;
  [paramGetAPI getFloatValue:&animDuration
               fromParameter:kKKParamAnimationDuration
                      atTime:renderTime];

  int curve = KKAnimationCurveCubic;
  [paramGetAPI getIntValue:&curve
             fromParameter:kKKParamAnimationInterpolation
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
    double raw =
        MAX(0.0, MIN(1.0, (renderTimeSecs - effectStartSecs) / animDuration));
    switch (curve) {
    case KKAnimationCurveLinear:
      t *= raw;
      break;
    case KKAnimationCurveSmooth:
      t *= kkSmoothstep(raw);
      break;
    case KKAnimationCurveSpring:
      t *= kkEaseOutSpring(raw);
      break;
    default:
      t *= kkEaseOutCubic(raw);
      break;
    }
  }

  if (animateOut) {
    double effectEndSecs = effectStartSecs + effectDurationSecs;
    double raw =
        MAX(0.0, MIN(1.0, (effectEndSecs - renderTimeSecs) / animDuration));
    switch (curve) {
    case KKAnimationCurveLinear:
      t *= raw;
      break;
    case KKAnimationCurveSmooth:
      t *= kkSmoothstep(raw);
      break;
    case KKAnimationCurveSpring:
      t *= kkEaseInSpring(raw);
      break;
    default:
      t *= kkEaseInCubic(raw);
      break;
    }
  }

  return t;
}

- (BOOL)addInfoParameterWithText:(NSString *)text
                            icon:(nullable NSImage *)icon
                     parameterID:(UInt32)parameterID
                         withAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                           error:(NSError **)error {
  kkClassRegistry([self class], kKKInfoTexts)[@(parameterID)] = [text copy];
  if (icon) {
    kkClassRegistry([self class], kKKInfoIcons)[@(parameterID)] = icon;
  }

  if (![paramAPI
          addCustomParameterWithName:@"" // If not empty pushes entire control
                                         // down when FULL_WIDTH
                         parameterID:parameterID
                        defaultValue:@(parameterID)
                      parameterFlags:kFxParameterFlag_NOT_ANIMATABLE |
                                     kFxParameterFlag_CUSTOM_UI |
                                     kFxParameterFlag_USE_FULL_VIEW_WIDTH |
                                     kFxParameterFlag_DISABLED]) {
    kkClassRegistry([self class], kKKInfoTexts)[@(parameterID)] = nil;
    if (error != NULL) {
      *error = [NSError
          errorWithDomain:@"co.overpolish.keyframeless.error"
                     code:1
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"Unable to add info parameter"
                 }];
    }

    return NO;
  }

  return YES;
}

- (BOOL)addInfoParameterWithAttributedText:(NSAttributedString *)text
                                      icon:(nullable NSImage *)icon
                               parameterID:(UInt32)parameterID
                                   withAPI:
                                       (id<FxParameterCreationAPI_v5>)paramAPI
                                     error:(NSError **)error {
  kkClassRegistry([self class], kKKInfoAttrTexts)[@(parameterID)] = [text copy];
  if (icon) {
    kkClassRegistry([self class], kKKInfoIcons)[@(parameterID)] = icon;
  }

  if (![paramAPI
          addCustomParameterWithName:@""
                         parameterID:parameterID
                        defaultValue:@(parameterID)
                      parameterFlags:kFxParameterFlag_NOT_ANIMATABLE |
                                     kFxParameterFlag_CUSTOM_UI |
                                     kFxParameterFlag_USE_FULL_VIEW_WIDTH |
                                     kFxParameterFlag_DISABLED]) {
    kkClassRegistry([self class], kKKInfoAttrTexts)[@(parameterID)] = nil;
    if (error != NULL) {
      *error = [NSError
          errorWithDomain:@"co.overpolish.keyframeless.error"
                     code:1
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"Unable to add info parameter"
                 }];
    }

    return NO;
  }

  return YES;
}

- (BOOL)addSeparatorParameterWithText:(nullable NSString *)text
                                 icon:(nullable NSImage *)icon
                          parameterID:(UInt32)parameterID
                              withAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                                error:(NSError **)error {
  kkClassRegistry([self class], kKKSepTexts)[@(parameterID)] =
      [text copy] ?: @"";
  if (icon) {
    kkClassRegistry([self class], kKKSepIcons)[@(parameterID)] = icon;
  }

  if (![paramAPI
          addCustomParameterWithName:@""
                         parameterID:parameterID
                        defaultValue:@(parameterID)
                      parameterFlags:kFxParameterFlag_NOT_ANIMATABLE |
                                     kFxParameterFlag_CUSTOM_UI |
                                     kFxParameterFlag_USE_FULL_VIEW_WIDTH |
                                     kFxParameterFlag_DISABLED]) {
    kkClassRegistry([self class], kKKSepTexts)[@(parameterID)] = nil;
    if (error != NULL) {
      *error = [NSError errorWithDomain:@"co.overpolish.keyframeless.error"
                                   code:1
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Unable to add separator parameter"
                               }];
    }
    return NO;
  }

  return YES;
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  NSString *separatorText =
      kkClassRegistry([self class], kKKSepTexts)[@(parameterID)];
  if (separatorText) {
    return [[KKSeparatorView alloc]
        initWithText:(separatorText.length > 0 ? separatorText : nil)
                icon:kkClassRegistry([self class],
                                     kKKSepIcons)[@(parameterID)]];
  }

  NSAttributedString *attributedText =
      kkClassRegistry([self class], kKKInfoAttrTexts)[@(parameterID)];
  if (attributedText) {
    KKAlertView *infoView =
        [[KKAlertView alloc] initWithAttributedText:attributedText];
    infoView.icon = kkClassRegistry([self class], kKKInfoIcons)[@(parameterID)];
    return infoView;
  }

  NSString *text = kkClassRegistry([self class], kKKInfoTexts)[@(parameterID)];
  if (!text) {
    return nil;
  }

  KKAlertView *infoView = [[KKAlertView alloc] initWithText:text];
  infoView.icon = kkClassRegistry([self class], kKKInfoIcons)[@(parameterID)];
  return infoView;
}

@end
