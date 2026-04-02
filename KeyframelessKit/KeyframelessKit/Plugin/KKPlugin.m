/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKPlugin.h"
#import "../Math/KKEasing.h"
#import "../Style/KKTokens.h"
#import "../Update/KKUpdateChecker.h"
#import "../Views/KKAlertView.h"
#import "../Views/KKCustomGroupHeaderView.h"
#import "../Views/KKKbd.h"
#import "../Views/KKSeparatorView.h"
#import "../Views/KKTimingGraphView.h"
#import "../Views/KKUpdateBannerView.h"
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
static const void *const kKKTimingExtraIDs = &kKKTimingExtraIDs;

static NSMutableDictionary<NSNumber *, id> *kkClassRegistry(Class cls,
                                                            const void *key) {
  NSMutableDictionary *dict = objc_getAssociatedObject(cls, key);
  if (!dict) {
    dict = [NSMutableDictionary new];
    objc_setAssociatedObject(cls, key, dict, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return dict;
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
  [[KKUpdateChecker shared] checkWithCompletion:^(BOOL __unused available){
  }];
}

@end

@interface KKPlugin () <FxCustomParameterViewHost_v2>
@end

@implementation KKPlugin {
  __weak KKCustomGroupHeaderView *_timingHeader;
  __weak KKTimingGraphView *_timingGraph;
}

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

- (void)setTimingGroupExtraParamIDs:(NSArray<NSNumber *> *)ids {
  objc_setAssociatedObject([self class], kKKTimingExtraIDs, [ids copy],
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSArray<NSNumber *> *)timingGroupExtraParamIDs {
  return objc_getAssociatedObject([self class], kKKTimingExtraIDs);
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
  if (![paramAPI
          addCustomParameterWithName:@""
                         parameterID:kKKParamTimingCurvePreview
                        defaultValue:@(kKKParamTimingCurvePreview)
                      parameterFlags:kFxParameterFlag_NOT_ANIMATABLE |
                                     kFxParameterFlag_CUSTOM_UI |
                                     kFxParameterFlag_USE_FULL_VIEW_WIDTH]) {
    if (error != NULL)
      *error = [NSError
          errorWithDomain:@"co.overpolish.keyframeless.error"
                     code:1
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"Unable to add Curve Preview"
                 }];
    return NO;
  }

  if (![paramAPI
          addCustomParameterWithName:@""
                         parameterID:kKKParamAnimationSeparator
                        defaultValue:@(kKKParamAnimationSeparator)
                      parameterFlags:kFxParameterFlag_NOT_ANIMATABLE |
                                     kFxParameterFlag_CUSTOM_UI |
                                     kFxParameterFlag_USE_FULL_VIEW_WIDTH]) {
    if (error != NULL)
      *error = [NSError
          errorWithDomain:@"co.overpolish.keyframeless.error"
                     code:1
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"Unable to add Timing group"
                 }];
    return NO;
  }

  if (![paramAPI addToggleButtonWithName:@"Animate In"
                             parameterID:kKKParamAnimateIn
                            defaultValue:NO
                          parameterFlags:kFxParameterFlag_HIDDEN]) {
    if (error != NULL)
      *error = [NSError errorWithDomain:@"co.overpolish.keyframeless.error"
                                   code:1
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Unable to add Animate In toggle"
                               }];
    return NO;
  }

  if (![paramAPI addFloatSliderWithName:@"In Duration"
                            parameterID:kKKParamAnimateInDuration
                           defaultValue:0.5
                           parameterMin:0.1
                           parameterMax:2.0
                              sliderMin:0.1
                              sliderMax:2.0
                                  delta:0.1
                         parameterFlags:kFxParameterFlag_HIDDEN]) {
    if (error != NULL)
      *error = [NSError errorWithDomain:@"co.overpolish.keyframeless.error"
                                   code:1
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Unable to add In Duration slider"
                               }];
    return NO;
  }

  if (![paramAPI addPopupMenuWithName:@"In Curve"
                          parameterID:kKKParamAnimateInInterpolation
                         defaultValue:KKEasingCurveEaseOut
                          menuEntries:@[
                            @"Ease In", @"Ease Out", @"Ease In Out", @"Elastic",
                            @"Bounce"
                          ]
                       parameterFlags:kFxParameterFlag_HIDDEN]) {
    if (error != NULL)
      *error = [NSError
          errorWithDomain:@"co.overpolish.keyframeless.error"
                     code:1
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"Unable to add In Curve popup"
                 }];
    return NO;
  }

  if (![paramAPI addFloatSliderWithName:@"In Intensity"
                            parameterID:kKKParamAnimateInIntensity
                           defaultValue:0.5
                           parameterMin:0.0
                           parameterMax:1.0
                              sliderMin:0.0
                              sliderMax:1.0
                                  delta:0.01
                         parameterFlags:kFxParameterFlag_HIDDEN]) {
    if (error != NULL)
      *error = [NSError errorWithDomain:@"co.overpolish.keyframeless.error"
                                   code:1
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Unable to add In Intensity slider"
                               }];
    return NO;
  }

  if (![paramAPI addToggleButtonWithName:@"Animate Out"
                             parameterID:kKKParamAnimateOut
                            defaultValue:NO
                          parameterFlags:kFxParameterFlag_HIDDEN]) {
    if (error != NULL)
      *error = [NSError errorWithDomain:@"co.overpolish.keyframeless.error"
                                   code:1
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Unable to add Animate Out toggle"
                               }];
    return NO;
  }

  if (![paramAPI addFloatSliderWithName:@"Out Duration"
                            parameterID:kKKParamAnimateOutDuration
                           defaultValue:0.5
                           parameterMin:0.1
                           parameterMax:2.0
                              sliderMin:0.1
                              sliderMax:2.0
                                  delta:0.1
                         parameterFlags:kFxParameterFlag_HIDDEN]) {
    if (error != NULL)
      *error = [NSError errorWithDomain:@"co.overpolish.keyframeless.error"
                                   code:1
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Unable to add Out Duration slider"
                               }];
    return NO;
  }

  if (![paramAPI addPopupMenuWithName:@"Out Curve"
                          parameterID:kKKParamAnimateOutInterpolation
                         defaultValue:KKEasingCurveEaseOut
                          menuEntries:@[
                            @"Ease In", @"Ease Out", @"Ease In Out", @"Elastic",
                            @"Bounce"
                          ]
                       parameterFlags:kFxParameterFlag_HIDDEN]) {
    if (error != NULL)
      *error = [NSError
          errorWithDomain:@"co.overpolish.keyframeless.error"
                     code:1
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"Unable to add Out Curve popup"
                 }];
    return NO;
  }

  if (![paramAPI addFloatSliderWithName:@"Out Intensity"
                            parameterID:kKKParamAnimateOutIntensity
                           defaultValue:0.5
                           parameterMin:0.0
                           parameterMax:1.0
                              sliderMin:0.0
                              sliderMax:1.0
                                  delta:0.01
                         parameterFlags:kFxParameterFlag_HIDDEN]) {
    if (error != NULL)
      *error = [NSError errorWithDomain:@"co.overpolish.keyframeless.error"
                                   code:1
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Unable to add Out Intensity slider"
                               }];
    return NO;
  }

  if (![paramAPI addToggleButtonWithName:@""
                             parameterID:kKKParamTimingExpanded
                            defaultValue:NO
                          parameterFlags:kFxParameterFlag_HIDDEN |
                                         kFxParameterFlag_NOT_ANIMATABLE]) {
    if (error != NULL)
      *error = [NSError errorWithDomain:@"co.overpolish.keyframeless.error"
                                   code:1
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Unable to add Timing expanded toggle"
                               }];
    return NO;
  }

  if (![paramAPI addPopupMenuWithName:@""
                          parameterID:kKKParamTimingSelectedSection
                         defaultValue:KKTimingGraphSectionMid
                          menuEntries:@[ @"In", @"Mid", @"Out" ]
                       parameterFlags:kFxParameterFlag_HIDDEN |
                                      kFxParameterFlag_NOT_ANIMATABLE]) {
    if (error != NULL)
      *error = [NSError
          errorWithDomain:@"co.overpolish.keyframeless.error"
                     code:1
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"Unable to add section selector"
                 }];
    return NO;
  }

  if (![paramAPI addPopupMenuWithName:@"Hold Effect"
                          parameterID:kKKParamMidHoldEffect
                         defaultValue:KKHoldEffectNone
                          menuEntries:@[ @"None", @"Bounce", @"Wiggle" ]
                       parameterFlags:kFxParameterFlag_HIDDEN]) {
    if (error != NULL)
      *error = [NSError errorWithDomain:@"co.overpolish.keyframeless.error"
                                   code:1
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Unable to add Hold Effect popup"
                               }];
    return NO;
  }

  return YES;
}

- (KKTimingResult *)timingAtTime:(CMTime)renderTime {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];

  KKTimingInterpolator identity = ^double(double t) {
    return t;
  };

  if (!paramGetAPI || !timingAPI) {
    KKTimingPhase *off = [KKTimingPhase phaseWithEnabled:NO
                                                duration:0
                                                progress:1.0
                                             interpolate:identity];
    return [KKTimingResult resultWithIn:off mid:off out:off];
  }

  BOOL animateIn = NO, animateOut = NO;
  [paramGetAPI getBoolValue:&animateIn
              fromParameter:kKKParamAnimateIn
                     atTime:renderTime];
  [paramGetAPI getBoolValue:&animateOut
              fromParameter:kKKParamAnimateOut
                     atTime:renderTime];

  double inDuration = 0.5, outDuration = 0.5;
  int inCurve = KKEasingCurveEaseOut, outCurve = KKEasingCurveEaseOut;
  if (animateIn) {
    [paramGetAPI getFloatValue:&inDuration
                 fromParameter:kKKParamAnimateInDuration
                        atTime:renderTime];
    [paramGetAPI getIntValue:&inCurve
               fromParameter:kKKParamAnimateInInterpolation
                      atTime:renderTime];
  }
  if (animateOut) {
    [paramGetAPI getFloatValue:&outDuration
                 fromParameter:kKKParamAnimateOutDuration
                        atTime:renderTime];
    [paramGetAPI getIntValue:&outCurve
               fromParameter:kKKParamAnimateOutInterpolation
                      atTime:renderTime];
  }

  CMTime effectStart = kCMTimeZero, effectDuration = kCMTimeZero;
  [timingAPI startTimeForEffect:&effectStart];
  [timingAPI durationTimeForEffect:&effectDuration];

  double startSec = CMTimeGetSeconds(effectStart);
  double durSec = CMTimeGetSeconds(effectDuration);
  double nowSec = CMTimeGetSeconds(renderTime);
  double endSec = startSec + durSec;

  // In phase: progress 0→1
  double inProgress =
      animateIn ? MAX(0.0, MIN(1.0, (nowSec - startSec) / inDuration)) : 1.0;
  double inIntensity = 0.5;
  if (animateIn) {
    [paramGetAPI getFloatValue:&inIntensity
                 fromParameter:kKKParamAnimateInIntensity
                        atTime:renderTime];
  }

  KKEasingCurve inEasing = (KKEasingCurve)inCurve;
  KKTimingInterpolator inInterp = ^double(double t) {
    return KKApplyEasing(t, inEasing, inIntensity);
  };
  KKTimingPhase *inPhase = [KKTimingPhase phaseWithEnabled:animateIn
                                                  duration:inDuration
                                                  progress:inProgress
                                               interpolate:inInterp];

  // Out phase: progress 1→0
  double outProgress =
      animateOut ? MAX(0.0, MIN(1.0, (endSec - nowSec) / outDuration)) : 1.0;
  double outIntensity = 0.5;
  if (animateOut) {
    [paramGetAPI getFloatValue:&outIntensity
                 fromParameter:kKKParamAnimateOutIntensity
                        atTime:renderTime];
  }

  KKEasingCurve outEasing = (KKEasingCurve)outCurve;
  KKTimingInterpolator outInterp = ^double(double t) {
    return KKApplyEasing(t, outEasing, outIntensity);
  };
  KKTimingPhase *outPhase = [KKTimingPhase phaseWithEnabled:animateOut
                                                   duration:outDuration
                                                   progress:outProgress
                                                interpolate:outInterp];

  // Mid phase: hold effect fills the gap between in and out
  int midHoldInt = KKHoldEffectNone;
  [paramGetAPI getIntValue:&midHoldInt
             fromParameter:kKKParamMidHoldEffect
                    atTime:renderTime];
  KKHoldEffect midHold = (KKHoldEffect)midHoldInt;

  static const double kMidOverlap = 0.3;
  double inEnd = startSec + (animateIn ? inDuration : 0);
  double outStart = endSec - (animateOut ? outDuration : 0);
  double midStart = inEnd - (animateIn ? inDuration * kMidOverlap : 0);
  double midEnd = outStart + (animateOut ? outDuration * kMidOverlap : 0);
  double midDur = MAX(0.0, midEnd - midStart);
  double midProgress =
      (midDur > 0) ? MAX(0.0, MIN(1.0, (nowSec - midStart) / midDur)) : 1.0;
  KKTimingInterpolator holdInterp = ^double(double t) {
    return KKApplyHoldEffect(t, midHold);
  };
  KKTimingPhase *midPhase = [KKTimingPhase phaseWithEnabled:YES
                                                   duration:midDur
                                                   progress:midProgress
                                                interpolate:holdInterp];

  return [KKTimingResult resultWithIn:inPhase mid:midPhase out:outPhase];
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

- (BOOL)addUpdateBannerParameterWithAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                                  error:(NSError **)error {
  if (![paramAPI
          addCustomParameterWithName:@""
                         parameterID:kKKParamUpdateBanner
                        defaultValue:@(kKKParamUpdateBanner)
                      parameterFlags:kFxParameterFlag_NOT_ANIMATABLE |
                                     kFxParameterFlag_CUSTOM_UI |
                                     kFxParameterFlag_USE_FULL_VIEW_WIDTH |
                                     kFxParameterFlag_DISABLED]) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:@"co.overpolish.keyframeless.error"
                                   code:1
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Unable to add update banner parameter"
                               }];
    }
    return NO;
  }
  return YES;
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == kKKParamUpdateBanner) {
    return [[KKUpdateBannerView alloc] init];
  }

  if (parameterID == kKKParamAnimationSeparator) {
    NSImage *icon = [NSImage imageWithSystemSymbolName:@"timer"
                              accessibilityDescription:nil];
    KKCustomGroupHeaderView *header =
        [[KKCustomGroupHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 300, 26)
                                            apiManager:_apiManager
                                           parameterId:parameterID
                                                  text:@"Timing"
                                                  icon:icon
                                         showsCheckbox:NO];
    header.isEnabled = YES;

    __weak typeof(self) weakSelf = self;
    header.onExpandedChanged = ^(BOOL isExpanded) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf)
        return;
      id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf->_apiManager
          apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
      [actAPI startAction:strongSelf];
      id<FxParameterSettingAPI_v5> setAPI = [strongSelf->_apiManager
          apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      [setAPI setBoolValue:isExpanded
               toParameter:kKKParamTimingExpanded
                    atTime:[actAPI currentTime]];
      [actAPI endAction:strongSelf];
    };

    id<FxCustomParameterActionAPI_v4> actionAPI =
        [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actionAPI startAction:self];
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];

    BOOL expanded = NO;
    [paramGetAPI getBoolValue:&expanded
                fromParameter:kKKParamTimingExpanded
                       atTime:[actionAPI currentTime]];
    header.isExpanded = expanded;

    [actionAPI endAction:self];

    _timingHeader = header;
    return header;
  }

  if (parameterID == kKKParamTimingCurvePreview) {
    NSView *wrapper = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 168)];
    wrapper.autoresizingMask = NSViewWidthSizable;

    KKTimingGraphView *graphView =
        [[KKTimingGraphView alloc] initWithFrame:NSZeroRect];
    graphView.translatesAutoresizingMaskIntoConstraints = NO;
    [wrapper addSubview:graphView];

    [NSLayoutConstraint activateConstraints:@[
      [graphView.leadingAnchor constraintEqualToAnchor:wrapper.leadingAnchor],
      [graphView.topAnchor constraintEqualToAnchor:wrapper.topAnchor],
      [graphView.bottomAnchor constraintEqualToAnchor:wrapper.bottomAnchor],
      [graphView.trailingAnchor constraintEqualToAnchor:wrapper.trailingAnchor],
    ]];

    id<FxCustomParameterActionAPI_v4> actionAPI =
        [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actionAPI startAction:self];
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    CMTime now = [actionAPI currentTime];

    BOOL animIn = NO, animOut = NO;
    int inCurve = KKEasingCurveEaseOut, outCurve = KKEasingCurveEaseOut;
    [paramGetAPI getBoolValue:&animIn
                fromParameter:kKKParamAnimateIn
                       atTime:now];
    [paramGetAPI getBoolValue:&animOut
                fromParameter:kKKParamAnimateOut
                       atTime:now];
    [paramGetAPI getIntValue:&inCurve
               fromParameter:kKKParamAnimateInInterpolation
                      atTime:now];
    [paramGetAPI getIntValue:&outCurve
               fromParameter:kKKParamAnimateOutInterpolation
                      atTime:now];
    int selectedSection = KKTimingGraphSectionMid;
    int midHold = KKHoldEffectNone;
    [paramGetAPI getIntValue:&selectedSection
               fromParameter:kKKParamTimingSelectedSection
                      atTime:now];
    [paramGetAPI getIntValue:&midHold
               fromParameter:kKKParamMidHoldEffect
                      atTime:now];
    double inIntensity = 0.5, outIntensity = 0.5;
    [paramGetAPI getFloatValue:&inIntensity
                 fromParameter:kKKParamAnimateInIntensity
                        atTime:now];
    [paramGetAPI getFloatValue:&outIntensity
                 fromParameter:kKKParamAnimateOutIntensity
                        atTime:now];
    [actionAPI endAction:self];

    graphView.inEnabled = animIn;
    graphView.outEnabled = animOut;
    graphView.inCurve = (KKEasingCurve)inCurve;
    graphView.outCurve = (KKEasingCurve)outCurve;
    graphView.midHoldEffect = (KKHoldEffect)midHold;
    graphView.inIntensity = inIntensity;
    graphView.outIntensity = outIntensity;
    graphView.selectedSection = (KKTimingGraphSection)selectedSection;

    __weak typeof(self) weakSelf = self;
    graphView.onInToggled = ^(BOOL enabled) {
      [weakSelf timingGraphSetAnimateIn:enabled];
    };
    graphView.onOutToggled = ^(BOOL enabled) {
      [weakSelf timingGraphSetAnimateOut:enabled];
    };
    graphView.onSectionSelected = ^(KKTimingGraphSection section) {
      [weakSelf timingGraphSelectSection:section];
    };
    graphView.onInCurveChanged = ^(KKEasingCurve curve) {
      [weakSelf timingGraphSetIntValue:(int)curve
                          forParameter:kKKParamAnimateInInterpolation];
    };
    graphView.onOutCurveChanged = ^(KKEasingCurve curve) {
      [weakSelf timingGraphSetIntValue:(int)curve
                          forParameter:kKKParamAnimateOutInterpolation];
    };
    graphView.onMidHoldEffectChanged = ^(KKHoldEffect effect) {
      [weakSelf timingGraphSetIntValue:(int)effect
                          forParameter:kKKParamMidHoldEffect];
    };
    graphView.onInIntensityChanged = ^(double intensity) {
      [weakSelf timingGraphSetFloatValue:intensity
                            forParameter:kKKParamAnimateInIntensity];
    };
    graphView.onOutIntensityChanged = ^(double intensity) {
      [weakSelf timingGraphSetFloatValue:intensity
                            forParameter:kKKParamAnimateOutIntensity];
    };

    _timingGraph = graphView;
    return wrapper;
  }

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

- (void)timingGraphApplyState {
  if (!_timingGraph)
    return;
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  CMTime t = [actionAPI currentTime];

  BOOL animIn = NO, animOut = NO;
  int inCurve = KKEasingCurveEaseOut, outCurve = KKEasingCurveEaseOut;
  int sel = KKTimingGraphSectionMid;
  [paramGetAPI getBoolValue:&animIn fromParameter:kKKParamAnimateIn atTime:t];
  [paramGetAPI getBoolValue:&animOut fromParameter:kKKParamAnimateOut atTime:t];
  [paramGetAPI getIntValue:&inCurve
             fromParameter:kKKParamAnimateInInterpolation
                    atTime:t];
  [paramGetAPI getIntValue:&outCurve
             fromParameter:kKKParamAnimateOutInterpolation
                    atTime:t];
  [paramGetAPI getIntValue:&sel
             fromParameter:kKKParamTimingSelectedSection
                    atTime:t];
  int midHold = KKHoldEffectNone;
  [paramGetAPI getIntValue:&midHold
             fromParameter:kKKParamMidHoldEffect
                    atTime:t];
  double inIntensity = 0.5, outIntensity = 0.5;
  [paramGetAPI getFloatValue:&inIntensity
               fromParameter:kKKParamAnimateInIntensity
                      atTime:t];
  [paramGetAPI getFloatValue:&outIntensity
               fromParameter:kKKParamAnimateOutIntensity
                      atTime:t];
  [actionAPI endAction:self];

  _timingGraph.inEnabled = animIn;
  _timingGraph.outEnabled = animOut;
  _timingGraph.inCurve = (KKEasingCurve)inCurve;
  _timingGraph.outCurve = (KKEasingCurve)outCurve;
  _timingGraph.midHoldEffect = (KKHoldEffect)midHold;
  _timingGraph.inIntensity = inIntensity;
  _timingGraph.outIntensity = outIntensity;
  _timingGraph.selectedSection = (KKTimingGraphSection)sel;
}

- (void)timingGraphSetAnimateIn:(BOOL)enabled {
  id<FxCustomParameterActionAPI_v4> actAPI =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterSettingAPI_v5> setAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  CMTime t = [actAPI currentTime];
  [setAPI setBoolValue:enabled toParameter:kKKParamAnimateIn atTime:t];
  if (!enabled) {
    int sel = KKTimingGraphSectionMid;
    id<FxParameterRetrievalAPI_v6> getAPI =
        [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    [getAPI getIntValue:&sel
          fromParameter:kKKParamTimingSelectedSection
                 atTime:t];
    if (sel == KKTimingGraphSectionIn)
      [setAPI setIntValue:KKTimingGraphSectionMid
              toParameter:kKKParamTimingSelectedSection
                   atTime:t];
  }
  [actAPI endAction:self];
  [self timingGraphApplyState];
}

- (void)timingGraphSetAnimateOut:(BOOL)enabled {
  id<FxCustomParameterActionAPI_v4> actAPI =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterSettingAPI_v5> setAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  CMTime t = [actAPI currentTime];
  [setAPI setBoolValue:enabled toParameter:kKKParamAnimateOut atTime:t];
  if (!enabled) {
    int sel = KKTimingGraphSectionMid;
    id<FxParameterRetrievalAPI_v6> getAPI =
        [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    [getAPI getIntValue:&sel
          fromParameter:kKKParamTimingSelectedSection
                 atTime:t];
    if (sel == KKTimingGraphSectionOut)
      [setAPI setIntValue:KKTimingGraphSectionMid
              toParameter:kKKParamTimingSelectedSection
                   atTime:t];
  }
  [actAPI endAction:self];
  [self timingGraphApplyState];
}

- (void)timingGraphSelectSection:(KKTimingGraphSection)section {
  // Don't allow selecting disabled sections
  if (section == KKTimingGraphSectionIn && !_timingGraph.inEnabled)
    return;
  if (section == KKTimingGraphSectionOut && !_timingGraph.outEnabled)
    return;

  id<FxCustomParameterActionAPI_v4> actAPI =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterSettingAPI_v5> setAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  [setAPI setIntValue:(int)section
          toParameter:kKKParamTimingSelectedSection
               atTime:[actAPI currentTime]];
  [actAPI endAction:self];
  [self timingGraphApplyState];
}

- (void)timingGraphSetIntValue:(int)value forParameter:(UInt32)paramID {
  id<FxCustomParameterActionAPI_v4> actAPI =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterSettingAPI_v5> setAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  [setAPI setIntValue:value toParameter:paramID atTime:[actAPI currentTime]];
  [actAPI endAction:self];
  [self timingGraphApplyState];
}

- (void)timingGraphSetFloatValue:(double)value forParameter:(UInt32)paramID {
  id<FxCustomParameterActionAPI_v4> actAPI =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterSettingAPI_v5> setAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  [setAPI setFloatValue:value toParameter:paramID atTime:[actAPI currentTime]];
  [actAPI endAction:self];
  [self timingGraphApplyState];
}

- (void)updateTimingParameterVisibility {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!paramGetAPI || !paramSetAPI)
    return;
  BOOL expandedTiming = NO;
  [paramGetAPI getBoolValue:&expandedTiming
              fromParameter:kKKParamTimingExpanded
                     atTime:kCMTimeZero];

  // Animate In/Out toggles are handled by the graph checkboxes — always hide
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kKKParamAnimateIn];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kKKParamAnimateOut];

  BOOL animateIn = NO, animateOut = NO;
  int inCurve = KKEasingCurveEaseOut, outCurve = KKEasingCurveEaseOut;
  if (expandedTiming) {
    [paramGetAPI getBoolValue:&animateIn
                fromParameter:kKKParamAnimateIn
                       atTime:kCMTimeZero];
    [paramGetAPI getBoolValue:&animateOut
                fromParameter:kKKParamAnimateOut
                       atTime:kCMTimeZero];
    [paramGetAPI getIntValue:&inCurve
               fromParameter:kKKParamAnimateInInterpolation
                      atTime:kCMTimeZero];
    [paramGetAPI getIntValue:&outCurve
               fromParameter:kKKParamAnimateOutInterpolation
                      atTime:kCMTimeZero];
  }

  int sel = KKTimingGraphSectionMid;
  [paramGetAPI getIntValue:&sel
             fromParameter:kKKParamTimingSelectedSection
                    atTime:kCMTimeZero];

  BOOL showIn = expandedTiming && sel == KKTimingGraphSectionIn && animateIn;
  FxParameterFlags flagIn =
      showIn ? kFxParameterFlag_DEFAULT : kFxParameterFlag_HIDDEN;
  [paramSetAPI setParameterFlags:flagIn toParameter:kKKParamAnimateInDuration];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kKKParamAnimateInInterpolation];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kKKParamAnimateInIntensity];

  BOOL showOut = expandedTiming && sel == KKTimingGraphSectionOut && animateOut;
  FxParameterFlags flagOut =
      showOut ? kFxParameterFlag_DEFAULT : kFxParameterFlag_HIDDEN;
  [paramSetAPI setParameterFlags:flagOut
                     toParameter:kKKParamAnimateOutDuration];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kKKParamAnimateOutInterpolation];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kKKParamAnimateOutIntensity];

  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kKKParamMidHoldEffect];

  for (NSNumber *paramID in self.timingGroupExtraParamIDs) {
    FxParameterFlags flagTiming =
        expandedTiming ? kFxParameterFlag_DEFAULT : kFxParameterFlag_HIDDEN;
    [paramSetAPI setParameterFlags:flagTiming
                       toParameter:paramID.unsignedIntValue];
  }
}

- (BOOL)forceShowAllParametersIfEnabled:(UInt32)forceShowParamID
                               paramIDs:(NSArray<NSNumber *> *)paramIDs
                                 atTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  BOOL forceShow = NO;
  [paramGetAPI getBoolValue:&forceShow
              fromParameter:forceShowParamID
                     atTime:time];
  if (!forceShow)
    return NO;

  id<FxParameterSettingAPI_v5> paramSetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  for (NSNumber *paramID in paramIDs) {
    [paramSetAPI setParameterFlags:kFxParameterFlag_DEFAULT
                       toParameter:paramID.unsignedIntValue];
  }
  return YES;
}

@end
