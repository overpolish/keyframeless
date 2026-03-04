//
//  Plugin.m
//  Rounded
//
//  Created by Dom on 23/02/2026.
//

#import "Plugin.h"
#import "Constants.h"
#import "ShaderTypes.h"
#include <AppKit/NSView.h>
#include <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceObjC.h>
#import <KeyframelessKit/KeyframelessKit.h>
#import <QuartzCore/QuartzCore.h>

@implementation Plugin

- (nullable instancetype)initWithAPIManager:(id<PROAPIAccessing>)newApiManager;
{
  NSLog(@"RoundedPlugin: initWithAPIManager called - plugin is loading");
  self = [super initWithAPIManager:newApiManager];
  if (self != nil) {
    NSLog(@"RoundedPlugin: Successfully initialized");
  }
  return self;
}

- (BOOL)properties:(NSDictionary *_Nonnull *)properties
             error:(NSError *_Nullable *)error {
  *properties = @{
    kFxPropertyKey_MayRemapTime : @NO,
    kFxPropertyKey_PixelTransformSupport : @(kFxPixelTransform_ScaleTranslate),
    kFxPropertyKey_VariesWhenParamsAreStatic : @NO
  };

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

  if (![paramAPI addFloatSliderWithName:@"Radius"
                            parameterID:1
                           defaultValue:20.0
                           parameterMin:0.0
                           parameterMax:100.0
                              sliderMin:0.0
                              sliderMax:100.0
                                  delta:1.0
                         parameterFlags:kFxParameterFlag_DEFAULT]) {
    if (error != NULL) {
      *error = [NSError
          errorWithDomain:FxPlugErrorDomain
                     code:kFxError_InvalidParameter
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"Unable to add radius slider"
                 }];
    }

    return NO;
  }

  // Adding a label with text pushes custom control down
  [paramAPI addCustomParameterWithName:@""
                           parameterID:13
                          defaultValue:nil
                        parameterFlags:kFxParameterFlag_CUSTOM_UI |
                                       kFxParameterFlag_USE_FULL_VIEW_WIDTH];

  // TODO add per corner radius parameters

  return YES;
}

- (NSView *)createViewForParameterID:(UInt32)parameterID {
  // TODO pull out into const
  if (parameterID == 13) {
    // TODO pull out into constant - this is the height of a inspector row
    CGFloat height = 23.0;

    KKCustomGroupHeaderView *view = [[KKCustomGroupHeaderView alloc]
        initWithFrame:NSMakeRect(0, 0, 100.0, height)
           apiManager:self.apiManager
                label:@"Radius"];

    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    return view;
  }
  return nil;
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
  double radius = 20.0;
  [paramGetAPI getFloatValue:&radius fromParameter:1 atTime:renderTime];
  *pluginState = [NSData dataWithBytes:&radius length:sizeof(radius)];
  return (*pluginState != nil);
}

- (BOOL)destinationImageRect:(FxRect *)destinationImageRect
                sourceImages:(NSArray<FxImageTile *> *)sourceImages
            destinationImage:(nonnull FxImageTile *)destinationImage
                 pluginState:(NSData *)pluginState
                      atTime:(CMTime)renderTime
                       error:(NSError *_Nullable *)outError {
  if (sourceImages.count < 1) {
    NSLog(@"No inputImages list");
    return NO;
  }

  // In the case of a filter that only changed RGB values,
  // the output rect is the same as the input rect.
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

  double radius = 0.0;
  [pluginState getBytes:&radius length:sizeof(radius)];

  id<MTLRenderPipelineState> pipelineState =
      [self pipelineStateForPluginID:kPluginID
                    destinationImage:destinationImage
                        vertexShader:@"vertexShader"
                      fragmentShader:@"fragmentShader"
                           blendMode:KKBlendModePremultipliedAlpha];

  if (!pipelineState)
    return NO;

  float fragmentRadius = (float)radius;
  simd_float2 imageSize = {(float)(destinationImage.imagePixelBounds.right -
                                   destinationImage.imagePixelBounds.left),
                           (float)(destinationImage.imagePixelBounds.top -
                                   destinationImage.imagePixelBounds.bottom)};
  simd_float2 tileOffset = {
      roundf((float)(destinationImage.tilePixelBounds.left -
                     destinationImage.imagePixelBounds.left)),
      roundf((float)(destinationImage.tilePixelBounds.bottom -
                     destinationImage.imagePixelBounds.bottom))};

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
                                           setFragmentBytes:&fragmentRadius
                                                     length:sizeof(
                                                                fragmentRadius)
                                                    atIndex:
                                                        FragmentIndex_Radius];
                                       [encoder
                                           setFragmentBytes:&imageSize
                                                     length:sizeof(imageSize)
                                                    atIndex:
                                                        FragmentIndex_ImageSize];
                                       [encoder
                                           setFragmentBytes:&tileOffset
                                                     length:sizeof(tileOffset)
                                                    atIndex:
                                                        FragmentIndex_TileOffset];
                                       [encoder
                                           drawPrimitives:
                                               MTLPrimitiveTypeTriangleStrip
                                              vertexStart:0
                                              vertexCount:4];
                                     }];
}

@end
