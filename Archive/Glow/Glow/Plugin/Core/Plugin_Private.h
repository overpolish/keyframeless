/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "GlowInspectorView.h"
#import "Plugin.h"
#import "ShaderTypes.h"
#import <KeyframelessKit/KeyframelessKit.h>

@class KKPlayheadPoller;

// Render struct: every field a lane could feed. M1 fills radiusX/Y from the
// Radius lane and the rest from the kGlowM1* fallbacks; later milestones
// promote them to real lanes / mode params one at a time.
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
  float noiseSeed;     // time-driven radial-flow phase
  float noiseSeedHash; // static pattern seed (perturbs the spatial hash)
  float noiseGrain;    // grain cell count along the longest axis (coarseness)
  float threshold;
} GlowPluginState;

@interface GlowPlugin ()
@property(nonatomic, weak, nullable) GlowInspectorView *inspectorView;
@property(nonatomic, strong, nonnull) KKRenderCache *renderCache;
@property(nonatomic, strong, nullable) KKPlayheadPoller *playheadPoller;
/// Returns a copy of `timeline` with every lane's lastKnownClipDuration set to
/// the current effect duration (seconds). Must be called inside an action
/// scope (FxTimingAPI resolves there).
- (nullable KKTimeline *)timelineStampedWithClipDuration:
    (nullable KKTimeline *)timeline;
@end

NS_ASSUME_NONNULL_BEGIN

@interface GlowPlugin (Parameters)
- (BOOL)addParametersWithError:(NSError **)error;
@end

@interface GlowPlugin (CustomUI)
- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED;
+ (NSArray<KKLane *> *)availableLanes;
@end

@interface GlowPlugin (Render)
- (BOOL)scheduleInputs:(NSArray<FxImageTileRequest *> *_Nullable *_Nullable)
                           inputImageRequests
       withPluginState:(NSData *)pluginState
                atTime:(CMTime)renderTime
                 error:(NSError **)error;
- (BOOL)pluginState:(NSData *_Nullable *_Nonnull)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error;
/// Computes per-frame Glow params at `time`. Used by both the normal render
/// path (via pluginState:atTime:) and the motion blur sub-frame sample loop.
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
