/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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

/// Returns the current crop as `[w, h, x, y]` (KKCropModel semantics) at
/// the given clip time. May return nil → treated as full image. Plugins
/// typically read from their timeline snapshot or other data source - the
/// crop OSC is unaware of the storage format.
@property(nonatomic, copy, nullable)
    NSArray<NSNumber *> *_Nullable (^valuesProvider)(CMTime time);

/// Persists a new `[w, h, x, y]` from a drag. The plugin is responsible for
/// wrapping in an action scope and any undo-coalescing.
@property(nonatomic, copy, nullable) void (^valuesWriter)
    (NSArray<NSNumber *> *values, CMTime time);

@property(nonatomic, strong, readonly) NSArray<KKPointOSC *> *pointOSCs;
@property(nonatomic, strong, readonly) KKRectBorderOSC *borderOSC;
@property(nonatomic, strong, readonly) KKOSCLabel *sizeLabel;

@property(nonatomic) NSInteger hoveredIndex;
@property(nonatomic) NSInteger draggingIndex;

/// Multiplier on the whole crop OSC's alpha (border + corner handles), default
/// 1.0. Draw at < 1.0 to render the crop as a dimmed "ghost" during opt-reveal.
@property(nonatomic) float ghostAlpha;

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
