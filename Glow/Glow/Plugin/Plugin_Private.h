/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import "Plugin.h"
#import "ShaderTypes.h"
#import <KeyframelessKit/KeyframelessKit.h>

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
  float noiseSeed;
  float threshold;
} GlowPluginState;

NS_ASSUME_NONNULL_BEGIN

@interface GlowPlugin (Parameters)
- (BOOL)addParametersWithError:(NSError **)error;
@end

@interface GlowPlugin (Visibility)
- (void)updateParameterVisibilityAtTime:(CMTime)time;
@end

@interface GlowPlugin (Presets)
- (void)applyPresetAtTime:(CMTime)time;
@end

@interface GlowPlugin (Render)
- (BOOL)pluginState:(NSData *_Nullable *_Nonnull)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error;
/// Computes per-frame Glow params at `time`. Used by both the normal
/// render path (via pluginState:atTime:) and the motion blur sub-frame
/// sample loop.
- (BOOL)glowParams:(GlowPluginState *)outParams
            atTime:(CMTime)time
             error:(NSError **)error;
- (BOOL)destinationImageRect:(FxRect *)destinationImageRect
                sourceImages:(NSArray<FxImageTile *> *)sourceImages
            destinationImage:(FxImageTile *)destinationImage
                 pluginState:(NSData *_Nullable)pluginState
                      atTime:(CMTime)renderTime
                       error:(NSError **)outError;
- (BOOL)sourceTileRect:(FxRect *)sourceTileRect
       sourceImageIndex:(NSUInteger)sourceImageIndex
           sourceImages:(NSArray<FxImageTile *> *)sourceImages
    destinationTileRect:(FxRect)destinationTileRect
       destinationImage:(FxImageTile *)destinationImage
            pluginState:(NSData *_Nullable)pluginState
                 atTime:(CMTime)renderTime
                  error:(NSError **)outError;
- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError *_Nullable *)outError;
@end

NS_ASSUME_NONNULL_END
