/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "Plugin.h"
#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface RoundedPlugin (Parameters)
- (BOOL)addParametersWithError:(NSError **)error;
@end

@interface RoundedPlugin (Visibility)
- (void)updateCropParameterVisibility;
@end

@interface RoundedPlugin (CustomUI)
- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED;
@end

typedef struct {
  double radius;
  double cropTop;
  double cropBottom;
  double cropLeft;
  double cropRight;
} RoundedPluginState;

@interface RoundedPlugin (Render)
- (BOOL)pluginState:(NSData *_Nullable *_Nonnull)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error;
/// Computes the per-frame rounded params at `time`. Used by both the
/// normal render path (via pluginState:atTime:) and the motion blur
/// sub-frame sample loop.
- (BOOL)roundedParams:(RoundedPluginState *)outParams
               atTime:(CMTime)time
                error:(NSError **)error;
- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError *_Nullable *)outError;
@end

NS_ASSUME_NONNULL_END
