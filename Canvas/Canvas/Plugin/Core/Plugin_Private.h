/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "Plugin.h"
#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CanvasPlugin (Parameters)
- (BOOL)addParametersWithError:(NSError **)error;
@end

@interface CanvasPlugin (Visibility)
- (void)updateParameterVisibilityAtTime:(CMTime)time;
@end

@interface CanvasPlugin (CustomUI)
- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED;
- (void)refreshLayerList;
@end

@interface CanvasPlugin (StyleViews)
- (NSView *)createStyleViewForParameterID:(UInt32)parameterID
    NS_RETURNS_RETAINED;
@end

@interface CanvasPlugin (Timing)
- (void)kkPushParamToLane:(UInt32)paramID;
+ (void)kkApplyLanes:(NSArray<KKTimingLane *> *)lanes
          atFraction:(double)frac
        effectDurSec:(double)effectDurSec
             toPaths:(NSArray<KKBezierPath *> *)paths;
@end

@interface CanvasPlugin (Render)
- (BOOL)pluginState:(NSData *_Nullable *_Nonnull)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error;
- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError *_Nullable *)outError;
@end

NS_ASSUME_NONNULL_END
