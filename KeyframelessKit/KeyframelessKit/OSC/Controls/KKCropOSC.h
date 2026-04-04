/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

@class FxImageTile;
@class KKOSCLabel;
@class KKPointOSC;
@class KKRectBorderOSC;
@protocol PROAPIAccessing;

NS_ASSUME_NONNULL_BEGIN

enum {
  KKCropPartNone = 0,
  KKCropPartRect = 1,
  KKCropPartPointBase = 2, // + index 0..7
};

#define KKCropPointCount 8

@interface KKCropOSC : NSObject

@property(nonatomic, weak) id<PROAPIAccessing> apiManager;

@property(nonatomic) UInt32 cropTopParam;
@property(nonatomic) UInt32 cropBottomParam;
@property(nonatomic) UInt32 cropLeftParam;
@property(nonatomic) UInt32 cropRightParam;

@property(nonatomic, strong, readonly) NSArray<KKPointOSC *> *pointOSCs;
@property(nonatomic, strong, readonly) KKRectBorderOSC *borderOSC;
@property(nonatomic, strong, readonly) KKOSCLabel *sizeLabel;

@property(nonatomic) NSInteger hoveredIndex;
@property(nonatomic) NSInteger draggingIndex;

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager;

/// Returns the crop corner points in canvas space. Pass NULL for values
/// you don't need.
- (BOOL)getTopRight:(CGPoint *)topRight
         bottomLeft:(CGPoint *)bottomLeft
    fullImageCanvas:(nullable CGSize *)fullImageCanvas
             atTime:(CMTime)time;

/// Draws the crop border, 8 handles, and size label.
- (void)drawWithDestinationImage:(FxImageTile *)destinationImage
                          atTime:(CMTime)time;

/// Hit-tests the crop rect and 8 handles. Returns a KKCropPart value.
- (NSInteger)hitTestAtMousePositionX:(double)positionX
                           positionY:(double)positionY
                              atTime:(CMTime)time;

/// Call on mouse down for a crop part.
- (void)mouseDownForPart:(NSInteger)part
               positionX:(double)positionX
               positionY:(double)positionY
                  atTime:(CMTime)time;

/// Call on mouse drag for a crop part.
- (void)mouseDraggedForPart:(NSInteger)part
                  positionX:(double)positionX
                  positionY:(double)positionY
                forceUpdate:(BOOL *)forceUpdate
                     atTime:(CMTime)time;

/// Resets drag state.
- (void)mouseUp;

@end

NS_ASSUME_NONNULL_END
