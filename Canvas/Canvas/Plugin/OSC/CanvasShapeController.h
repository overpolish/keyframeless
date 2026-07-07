/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

#import "CanvasPenController.h" // CanvasPenSurface + CanvasPenModifiers

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CanvasShapeKind) {
  CanvasShapeKindRect = 0,    // 4 linear corners (round them with the widget)
  CanvasShapeKindEllipse = 1, // 4 cubic anchors, kappa tangent handles
};

/// The surface-agnostic shape-creation tool: drag a bounding box to drop a new
/// closed rect / ellipse layer (selected, one undo). Shares the
/// CanvasPenSurface the pen + path-edit controllers use, so it drives both the
/// FCP viewer OSC and the inspector mini-viewer with identical behaviour. The
/// created rect is plain 4-corner geometry, so the live-corner widget rounds it
/// for free.
@interface CanvasShapeController : NSObject
- (instancetype)initWithSurface:(id<CanvasPenSurface>)surface;
/// Which shape the active tool draws; set before each gesture by the surface.
@property(nonatomic) CanvasShapeKind kind;
@property(nonatomic, readonly) BOOL dragging; // a box is being dragged out

// All coords are SURFACE points. mouseDown returns YES (the tool consumed it).
- (BOOL)mouseDownAtX:(double)x y:(double)y modifiers:(CanvasPenModifiers)mods;
- (void)mouseDraggedAtX:(double)x
                      y:(double)y
              modifiers:(CanvasPenModifiers)mods;
- (void)mouseUp;
- (void)draw; // emits the surface preview primitives during the drag
@end

NS_ASSUME_NONNULL_END
