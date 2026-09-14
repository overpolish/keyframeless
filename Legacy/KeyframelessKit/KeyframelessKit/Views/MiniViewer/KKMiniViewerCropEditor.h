/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Plugin-agnostic crop-rectangle editor for a mini viewer.
///
/// Owns the geometry + drag math for the standard 8-handle crop box driven
/// by the `[w, h, x, y]` crop model (see `KKCropModel.h`): handle positions,
/// hit-testing, and turning a corner/edge/body drag into new clamped model
/// values (kept inside the image, with a minimum extent). It is stateless
/// except for the in-flight drag, so a renderer can own one and forward the
/// `KKMiniViewerDelegate` handle callbacks to it.
///
/// All rects/points are in the canvas overlay's points (y-up). `contentRect`
/// is the image rect in that space; the y term is flipped to match the
/// mini-viewer's V-flipped display so a handle sits on the rendered crop.
@interface KKMiniViewerCropEditor : NSObject

/// Let an authored layout box move and resize beyond `contentRect`.
@property(nonatomic) BOOL allowsOutsideCanvas;

/// The crop box for `values` (`[w,h,x,y]`) within `contentRect`.
- (CGRect)cropRectForValues:(NSArray<NSNumber *> *)values
                contentRect:(CGRect)contentRect;

/// The 8 handle centres (NSValue-boxed CGPoint) for that crop box.
- (NSArray<NSValue *> *)handleCentersForValues:(NSArray<NSNumber *> *)values
                                   contentRect:(CGRect)contentRect;

/// Hit-test: -1 none, 0 rect body, 1+idx for a corner/edge handle. Handles
/// take priority over the body.
- (NSInteger)partAtPoint:(CGPoint)p
                  values:(NSArray<NSNumber *> *)values
             contentRect:(CGRect)contentRect;

/// Begin a drag at `p`; latches the grabbed part + grab state. Returns the
/// part (see `partAtPoint:`); ≥0 means a drag is now active.
- (NSInteger)beginDragAtPoint:(CGPoint)p
                       values:(NSArray<NSNumber *> *)values
                  contentRect:(CGRect)contentRect;

/// New `[w,h,x,y]` for the active drag dragged to `p`. Constrained to the
/// content rect unless `allowsOutsideCanvas` is enabled. Nil if no active drag.
- (nullable NSArray<NSNumber *> *)valuesForDragToPoint:(CGPoint)p
                                           contentRect:(CGRect)contentRect;

- (void)endDrag;

/// -1 when no drag is active.
@property(nonatomic, readonly) NSInteger activePart;

@end

NS_ASSUME_NONNULL_END
