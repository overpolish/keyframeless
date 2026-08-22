/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKBoxOSC.h>

@class FxImageTile;
@protocol PROAPIAccessing;

NS_ASSUME_NONNULL_BEGIN

// A box-crop control - the shared KKBoxOSC (border + 8 handles + readout) plus
// the crop value semantics (each handle moves an independent edge of a real
// rect; the readout is in source pixels). KKCropPart* / KKCropPointCount are
// kept as aliases of the KKBoxPart* / KKBoxHandleCount values for callers.
enum {
  KKCropPartNone = KKBoxPartNone,
  KKCropPartRect = KKBoxPartRect,
  KKCropPartPointBase = KKBoxPartHandleBase, // + index 0..7
};

#define KKCropPointCount KKBoxHandleCount

@interface KKCropOSC : KKBoxOSC

/// Allow a layout box to move and resize beyond the source canvas. Ordinary
/// destructive crop controls keep the traditional constrained behaviour.
@property(nonatomic) BOOL allowsOutsideCanvas;

/// Returns the current crop as `[w, h, x, y]` (KKCropModel semantics) at
/// the given clip time. May return nil → treated as full image. Plugins
/// typically read from their timeline snapshot or other data source - the
/// crop OSC is unaware of the storage format.
@property(nonatomic, copy, nullable)
    NSArray<NSNumber *> *_Nullable (^valuesProvider)(CMTime time);

/// Persists a new `[w, h, x, y]` from a drag. This runs inside the host's OSC
/// callback; the plugin must not open a custom-parameter action around it.
@property(nonatomic, copy, nullable) void (^valuesWriter)
    (NSArray<NSNumber *> *values, CMTime time);

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
