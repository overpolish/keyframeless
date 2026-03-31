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
@property(nonatomic, weak, nullable) KKCustomGroupHeaderView *pointAHeader;
@property(nonatomic, weak, nullable) KKCustomGroupHeaderView *pointBHeader;
@property(nonatomic, weak, nullable) KKCustomGroupHeaderView *driftHeader;
@property(nonatomic, weak, nullable) KKCustomGroupHeaderView *exitHeader;
@property(nonatomic, weak, nullable) KKAlertStackView *alertStackView;
@property(nonatomic, weak, nullable) KKAlertView *previewAlertView;
@property(nonatomic, weak, nullable) KKAlertView *hideOSCAlertView;
@end

@interface MagicMovePlugin (Parameters)
- (BOOL)addPointSectionWithName:(NSString *)name
                          group:(MagicMoveGroupIDs)group
                       defaultX:(double)defaultX
                       defaultY:(double)defaultY
                  defaultHidden:(BOOL)defaultHidden
                    customGroup:(BOOL)customGroup
                        withAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                          error:(NSError **)error;
- (BOOL)addParametersWithError:(NSError **)error;
@end

@interface MagicMovePlugin (Visibility)
- (void)setFlags:(FxParameterFlags)flags
        forGroup:(MagicMoveGroupIDs)group
         withAPI:(id<FxParameterSettingAPI_v5>)api;
- (void)updateParameterVisibilityAtTime:(CMTime)time;
- (void)setGroupEnabled:(BOOL)enabled
            boolParamID:(UInt32)boolParamID
          childParamIDs:(NSArray<NSNumber *> *)childIDs;
@end

@interface MagicMovePlugin (CustomUI)
- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED;
@end

@interface MagicMovePlugin (Animation)
- (MagicMovePointValues)readPointValues:(MagicMovePointParamIDs)ids
                                 atTime:(CMTime)time
                                withAPI:(id<FxParameterRetrievalAPI_v6>)api;
- (KKBezierPath *)readPath:(UInt32)paramID
                   withAPI:(id<FxParameterRetrievalAPI_v6>)api;
- (BOOL)pluginState:(NSData *_Nullable *_Nonnull)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error;
@end

@interface MagicMovePlugin (Render)
- (BOOL)destinationImageRect:(FxRect *)destinationImageRect
                sourceImages:(NSArray<FxImageTile *> *)sourceImages
            destinationImage:(FxImageTile *)destinationImage
                 pluginState:(NSData *)pluginState
                      atTime:(CMTime)renderTime
                       error:(NSError *_Nullable *)outError;
- (BOOL)sourceTileRect:(FxRect *)sourceTileRect
       sourceImageIndex:(NSUInteger)sourceImageIndex
           sourceImages:(NSArray<FxImageTile *> *)sourceImages
    destinationTileRect:(FxRect)destinationTileRect
       destinationImage:(FxImageTile *)destinationImage
            pluginState:(NSData *)pluginState
                 atTime:(CMTime)renderTime
                  error:(NSError *_Nullable *)outError;
- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError *_Nullable *)outError;
@end

NS_ASSUME_NONNULL_END
