/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "CanvasPenController.h" // CanvasPenSurface + CanvasPenModifiers
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CanvasPathEditHit) {
  CanvasPathEditHitNone = 0,
  CanvasPathEditHitAnchor,
  CanvasPathEditHitHandle,
};

/// Surface-agnostic editing of the SELECTED path's anchors + tangent handles
/// (drag to reshape), shared by the viewer OSC and the mini. Reuses the same
/// CanvasPenSurface the pen controller does (coordinate conversion, blob I/O),
/// plus the projection helpers to map under any layer transform. Coords are
/// SURFACE points.
@interface CanvasPathEditController : NSObject
- (instancetype)initWithSurface:(id<CanvasPenSurface>)surface;
@property(nonatomic, readonly) BOOL dragging;
/// What's under a surface point (for the cursor + deciding whether to claim).
- (CanvasPathEditHit)hitTestAtX:(double)x y:(double)y;
/// Grab the anchor / handle under the point. YES if something was grabbed.
- (BOOL)mouseDownAtX:(double)x y:(double)y modifiers:(CanvasPenModifiers)mods;
- (void)mouseDraggedAtX:(double)x y:(double)y modifiers:(CanvasPenModifiers)mods;
- (void)mouseUp;
@end

NS_ASSUME_NONNULL_END
