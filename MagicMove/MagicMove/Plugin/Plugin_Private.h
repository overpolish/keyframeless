/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import "Plugin.h"
#import <KeyframelessKit/KeyframelessKit.h>

#import "Constants.h"

NS_ASSUME_NONNULL_BEGIN

@interface MagicMovePlugin ()
@property(nonatomic, strong) KKLog *log;
@end

@interface MagicMovePlugin (Parameters)
- (BOOL)addParametersWithError:(NSError **)error;
@end

@interface MagicMovePlugin (Visibility)
- (void)updateParameterVisibilityAtTime:(CMTime)time;
@end

@interface MagicMovePlugin (CustomUI)
- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED;
@end

@interface MagicMovePlugin (Animation)
- (MagicMovePointValues)readPointValuesAtTime:(CMTime)time
                                      withAPI:
                                          (id<FxParameterRetrievalAPI_v6>)api;
- (BOOL)pluginState:(NSData *_Nullable *_Nonnull)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error;
@end

@interface MagicMovePlugin (Render)
- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError *_Nullable *)outError;
@end

NS_ASSUME_NONNULL_END
