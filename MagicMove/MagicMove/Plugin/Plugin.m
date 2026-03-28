/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Plugin.h"
#import "Constants.h"
#import "ShaderTypes.h"
#import <AppKit/NSView.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceObjC.h>
#import <KeyframelessKit/KeyframelessKit.h>
#import <QuartzCore/QuartzCore.h>

@implementation MagicMovePlugin {
  KKLog *_log;
}

- (nullable instancetype)initWithAPIManager:(id<PROAPIAccessing>)newApiManager;
{
  _log = [KKLog loggerForPlugin:@"co.overpolish.keyframeless"];
  [_log info:@"MagicMovePlugin: initWithAPIManager called - plugin is loading"];
  self = [super initWithAPIManager:newApiManager];
  if (self != nil) {
    [_log info:@"MagicMovePlugin: Successfully initialized"];
  }
  return self;
}

- (BOOL)properties:(NSDictionary *_Nonnull *)properties
             error:(NSError *_Nullable *)error {
  *properties = @{
    kFxPropertyKey_MayRemapTime : @NO,
    kFxPropertyKey_PixelTransformSupport : @(kFxPixelTransform_ScaleTranslate),
    kFxPropertyKey_VariesWhenParamsAreStatic : @YES
  };

  return YES;
}

- (BOOL)addPointGroupWithName:(NSString *)name
                      groupID:(UInt32)groupID
                      pointID:(UInt32)pointID
                   rotationID:(UInt32)rotationID
                      scaleID:(UInt32)scaleID
                     defaultX:(double)defaultX
                     defaultY:(double)defaultY
                      withAPI:(id<FxParameterCreationAPI_v5>)paramAPI {
  if (![paramAPI startParameterSubGroup:name
                            parameterID:groupID
                         parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![paramAPI addPointParameterWithName:@"Position"
                               parameterID:pointID
                                  defaultX:defaultX
                                  defaultY:defaultY
                            parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![paramAPI addFloatSliderWithName:@"Rotation"
                            parameterID:rotationID
                           defaultValue:0.0
                           parameterMin:-FLT_MAX
                           parameterMax:FLT_MAX
                              sliderMin:-360.0
                              sliderMax:360.0
                                  delta:1.0
                         parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![paramAPI addFloatSliderWithName:@"Scale"
                            parameterID:scaleID
                           defaultValue:1.0
                           parameterMin:0.0
                           parameterMax:10.0
                              sliderMin:0.0
                              sliderMax:5.0
                                  delta:0.01
                         parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![paramAPI endParameterSubGroup])
    return NO;

  return YES;
}

- (BOOL)addParametersWithError:(NSError **)error {
  id<FxParameterCreationAPI_v5> paramAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterCreationAPI_v5)];
  if (paramAPI == nil) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:FxPlugErrorDomain
                                   code:kFxError_APIUnavailable
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Unable to obtain an FxPlug API Object"
                               }];
    }
    return NO;
  }

  if (![self addUpdateBannerParameterWithAPI:paramAPI error:error])
    return NO;

  if (![self addInfoParameterWithText:
                 @"Create a Compound Clip before applying to avoid clipping"
                                 icon:[NSImage imageWithSystemSymbolName:
                                                   @"exclamationmark.triangle"
                                                accessibilityDescription:nil]
                          parameterID:kParamInfoCompound
                              withAPI:paramAPI
                                error:error])
    return NO;

  if (![self addPointGroupWithName:@"Point A"
                           groupID:kParamGroupPointA
                           pointID:kParamPointA
                        rotationID:kParamRotationA
                           scaleID:kParamScaleA
                          defaultX:0.5
                          defaultY:0.5
                           withAPI:paramAPI])
    return NO;

  if (![self addPointGroupWithName:@"Point B"
                           groupID:kParamGroupPointB
                           pointID:kParamPointB
                        rotationID:kParamRotationB
                           scaleID:kParamScaleB
                          defaultX:0.5
                          defaultY:0.5
                           withAPI:paramAPI])
    return NO;

  if (![self addAnimationParametersWithAPI:paramAPI error:error])
    return NO;

  return YES;
}

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
  double t = [self animationFactorAtTime:renderTime];

  double posAx = 0.5, posAy = 0.5, posBx = 0.5, posBy = 0.5;
  [paramGetAPI getXValue:&posAx
                  YValue:&posAy
           fromParameter:kParamPointA
                  atTime:renderTime];
  [paramGetAPI getXValue:&posBx
                  YValue:&posBy
           fromParameter:kParamPointB
                  atTime:renderTime];

  double rotA = 0, rotB = 0, scaleA = 1, scaleB = 1;
  [paramGetAPI getFloatValue:&rotA
               fromParameter:kParamRotationA
                      atTime:renderTime];
  [paramGetAPI getFloatValue:&rotB
               fromParameter:kParamRotationB
                      atTime:renderTime];
  [paramGetAPI getFloatValue:&scaleA
               fromParameter:kParamScaleA
                      atTime:renderTime];
  [paramGetAPI getFloatValue:&scaleB
               fromParameter:kParamScaleB
                      atTime:renderTime];

  MagicMoveParams params;
  params.translate = (simd_float2){(float)((1 - t) * posAx + t * posBx - 0.5),
                                   (float)((1 - t) * posAy + t * posBy - 0.5)};
  params.rotation = (float)(((1 - t) * rotA + t * rotB) * M_PI / 180.0);
  params.scale = (float)((1 - t) * scaleA + t * scaleB);

  *pluginState = [NSData dataWithBytes:&params length:sizeof(params)];
  return (*pluginState != nil);
}

- (BOOL)destinationImageRect:(FxRect *)destinationImageRect
                sourceImages:(NSArray<FxImageTile *> *)sourceImages
            destinationImage:(nonnull FxImageTile *)destinationImage
                 pluginState:(NSData *)pluginState
                      atTime:(CMTime)renderTime
                       error:(NSError *_Nullable *)outError {
  if (sourceImages.count < 1) {
    [_log error:@"No inputImages list"];
    return NO;
  }

  *destinationImageRect = sourceImages[0].imagePixelBounds;

  return YES;
}

- (BOOL)sourceTileRect:(FxRect *)sourceTileRect
       sourceImageIndex:(NSUInteger)sourceImageIndex
           sourceImages:(NSArray<FxImageTile *> *)sourceImages
    destinationTileRect:(FxRect)destinationTileRect
       destinationImage:(FxImageTile *)destinationImage
            pluginState:(NSData *)pluginState
                 atTime:(CMTime)renderTime
                  error:(NSError *_Nullable *)outError {
  *sourceTileRect = destinationTileRect;
  return YES;
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

  MagicMoveParams params;
  [pluginState getBytes:&params length:sizeof(params)];

  id<MTLRenderPipelineState> pipelineState =
      [self pipelineStateForPluginID:kPluginID
                    destinationImage:destinationImage
                        vertexShader:@"vertexShader"
                      fragmentShader:@"fragmentShader"
                           blendMode:KKBlendModePremultipliedAlpha];

  if (!pipelineState)
    return NO;

  return [self
      encodeRenderCommandsForDestinationImage:destinationImage
                                 sourceImages:sourceImages
                                     commands:^(
                                         id<MTLRenderCommandEncoder> encoder,
                                         NSArray<id<MTLTexture>>
                                             *inputTextures) {
                                       [encoder setRenderPipelineState:
                                                    pipelineState];
                                       [encoder
                                           setFragmentTexture:inputTextures[0]
                                                      atIndex:
                                                          KKTextureIndex_InputImage];
                                       [encoder
                                           setFragmentBytes:&params
                                                     length:sizeof(params)
                                                    atIndex:
                                                        FragmentIndex_Params];
                                       [encoder
                                           drawPrimitives:
                                               MTLPrimitiveTypeTriangleStrip
                                              vertexStart:0
                                              vertexCount:4];
                                     }];
}

@end
