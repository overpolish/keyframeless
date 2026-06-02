/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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

/// YES when the matched X (or Y) target came from the object-targets array
/// passed to the two-tier snap method; NO when it matched a canvas anchor.
/// Lets the guide-drawing path colour each axis independently.
@property(nonatomic) BOOL snapXFromObject;
@property(nonatomic) BOOL snapYFromObject;

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

/// Two-tier snap. `canvasAnchorsX/Y` are per-axis lists of fixed reference
/// values (e.g. 0, 0.25, 0.5, 0.75, 1.0); `objectTargets` are full points
/// snapped on either axis (e.g. other keyposes' positions). Pass
/// per-axis thresholds expressed in the same units as the point (caller
/// converts pixels → units). The matched-kind flags
/// `snapXFromObject`/`snapYFromObject` reflect which list won per axis.
- (simd_float2)snapPoint:(simd_float2)point
          canvasAnchorsX:(nullable const float *)cxs
                  countX:(NSUInteger)nCx
          canvasAnchorsY:(nullable const float *)cys
                  countY:(NSUInteger)nCy
           objectTargets:(nullable const simd_float2 *)objs
                   count:(NSUInteger)nObj
              thresholdX:(float)thrX
              thresholdY:(float)thrY;

/// Same as `drawSnapGuidesWithOSC:isObjectSpace:destinationImage:` but the
/// per-axis colour depends on `snapXFromObject` / `snapYFromObject`:
/// axes that snapped to a canvas anchor get `canvasColor`; axes that
/// snapped to an object target get `objectColor`.
- (void)drawSnapGuidesWithOSC:(KKOnScreenControl *)osc
                isObjectSpace:(BOOL)isObjectSpace
                  canvasColor:(simd_float4)canvasColor
                  objectColor:(simd_float4)objectColor
             destinationImage:(FxImageTile *)destinationImage;

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
