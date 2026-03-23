/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKMetalDeviceCache.h>
#import <Metal/Metal.h>

@class FxImageTile;
@class NSBezierPath;
@protocol PROAPIAccessing;
@protocol FxParameterCreationAPI_v5;

/// Interpolation curve presets for animationFactorAtTime:baseParamID:.
/// Values are 0-indexed to match the FxPlug popup menu convention.
typedef NS_ENUM(NSInteger, KKAnimationCurve) {
  KKAnimationCurveLinear = 0, ///< No easing — constant rate
  KKAnimationCurveSmooth = 1, ///< Smoothstep — symmetric ease in/out
  KKAnimationCurveCubic = 2,  ///< Ease-out in, ease-in out — snappy (default)
  KKAnimationCurveSpring = 3, ///< Sinusoidal spring — overshoots and settles
};

NS_ASSUME_NONNULL_BEGIN

@interface KKPlugin : NSObject

@property(nonatomic, weak) id<PROAPIAccessing> apiManager;

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager;

/// Convenience wrapper around KKMetalDeviceCache buildAndRegisterPipelineState.
/// Call from renderDestinationImage: to get or build the pipeline state for
/// this plugin.
- (nullable id<MTLRenderPipelineState>)
    pipelineStateForPluginID:(NSString *)pluginID
            destinationImage:(FxImageTile *)destinationImage
                vertexShader:(NSString *)vertexShader
              fragmentShader:(NSString *)fragmentShader
                   blendMode:(KKBlendMode)blendMode;

/// Shared rendering infrastructure for any plugin render pass.
/// Handles command buffer, render pass, viewport, fullscreen quad, and cleanup.
/// Your block receives the encoder and input texture - set pipeline state,
/// fragment bytes, and draw.
- (BOOL)
    encodeRenderCommandsForDestinationImage:(FxImageTile *)destinationImage
                               sourceImages:
                                   (NSArray<FxImageTile *> *)sourceImages
                                   commands:
                                       (void (^)(
                                           id<MTLRenderCommandEncoder> encoder,
                                           NSArray<id<MTLTexture>>
                                               *inputTextures))commands;

/// Returns the shared FxPrincipalDelegate that captures the host ID into
/// KKHostInfo. Pass to +[FxPrincipal startServicePrincipalWithDelegate:] in
/// main().
+ (id)servicePrincipalDelegate;

/// Adds a "Timing" separator, "Animate In" (toggle), "Animate Out" (toggle),
/// "Duration" (float slider, seconds), and "Interpolation" (popup) at the
/// fixed IDs defined in KKConstants.h (kKKParamAnimationSeparator … 9904).
/// Call from addParametersWithError: to opt a plugin into auto animation.
/// Plugins that don't need it (e.g. motion blur) simply don't call this.
- (BOOL)addAnimationParametersWithAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                                error:(NSError **)error;

/// Returns the animation factor t ∈ [0,1] at renderTime using the fixed
/// animation parameter IDs defined in KKConstants.h.
/// Apply t to any parameters you want animated — radius, position, scale, etc.
/// Returns 1.0 when animation is off or the timing API is unavailable.
- (double)animationFactorAtTime:(CMTime)renderTime;

/// Adds a full-width informational text display occupying one parameter ID.
/// The parameter is not animatable and stores no meaningful value — it is
/// purely a static label in the inspector.
- (BOOL)addInfoParameterWithText:(NSString *)text
                            icon:(nullable NSImage *)icon
                     parameterID:(UInt32)parameterID
                         withAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                           error:(NSError **)error;

/// Accepts an attributed string — use to embed KKKbd badges
/// or other inline styled content.
- (BOOL)addInfoParameterWithAttributedText:(NSAttributedString *)text
                                      icon:(nullable NSImage *)icon
                               parameterID:(UInt32)parameterID
                                   withAPI:
                                       (id<FxParameterCreationAPI_v5>)paramAPI
                                     error:(NSError **)error;

/// Adds a full-width horizontal divider occupying one parameter ID.
/// Pass text and/or icon to render  ──── [icon] [text] ────  centred on the
/// line; pass nil for both for a plain rule.
- (BOOL)addSeparatorParameterWithText:(nullable NSString *)text
                                 icon:(nullable NSImage *)icon
                          parameterID:(UInt32)parameterID
                              withAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                                error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
