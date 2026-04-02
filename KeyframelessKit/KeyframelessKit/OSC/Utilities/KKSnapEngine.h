/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <KeyframelessKit/KKOnScreenControl.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKSnapEngine : NSObject

/// Whether the last snap operation snapped on X and/or Y.
/// Set automatically by snap methods, or manually for custom snap logic.
@property(nonatomic) BOOL snappedX;
@property(nonatomic) BOOL snappedY;

/// The snapped value (in whichever coordinate space was used).
/// Set automatically by snap methods, or manually for custom snap logic.
@property(nonatomic) float snapValueX;
@property(nonatomic) float snapValueY;

/// Canvas-pixel threshold for snapping. Default 8.
@property(nonatomic) float threshold;

/// Snap a canvas-space point to the nearest X/Y targets within threshold.
/// Updates snappedX/Y and snapValueX/Y.
- (CGPoint)snapCanvasPoint:(CGPoint)point
                 toTargets:(const CGPoint *)targets
                     count:(NSUInteger)count;

/// Snap an object-space point to the nearest X/Y targets within threshold,
/// converting the threshold from canvas pixels using pixelsPerUnit.
/// Updates snappedX/Y and snapValueX/Y.
- (simd_float2)snapObjectPoint:(simd_float2)point
                     toTargets:(const simd_float2 *)targets
                         count:(NSUInteger)count
                 pixelsPerUnit:(float)pixelsPerUnit;

/// Reset snap state (call on mouseUp).
- (void)reset;

/// Draw yellow snap guide lines across the full canvas bounds.
/// For canvas-space snap values, pass isObjectSpace:NO.
/// For object-space snap values, pass isObjectSpace:YES and provide the OSC
/// for coordinate conversion.
- (void)drawSnapGuidesWithOSC:(KKOnScreenControl *)osc
                isObjectSpace:(BOOL)isObjectSpace
             destinationImage:(FxImageTile *)destinationImage;

@end

NS_ASSUME_NONNULL_END
