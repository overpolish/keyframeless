/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "CanvasPathEditController.h"
#import <KeyframelessKit/KKBezierPath.h>

NS_ASSUME_NONNULL_BEGIN

/// Shared internal surface for the CanvasPathEditController category split:
///  - base (CanvasPathEditController.m): interaction state machine - press /
///    drag / up, marquee, constrain.
///  - +Query: read-only "what's under the cursor" (hit-test, segment-hit, the
///    editable-path resolution).
///  - +Topology: mutations that change the point count / type (insert, remove,
///    convert smooth<->corner).
/// The ivars live here (not in the @implementation) so the categories can reach
/// the shared drag / selection state.
@interface CanvasPathEditController () {
  __weak id<CanvasPenSurface> _surface;
  BOOL _dragging;
  NSInteger _grabAnchor; // index, -1 = none
  BOOL _grabIsHandle;
  BOOL _grabHandleIsOut; // which tangent handle of the anchor
  NSMutableIndexSet *_selectedAnchors;
  BOOL _didDrag;                // distinguishes a click from a drag on mouseUp
  BOOL _didEdit;                // geometry changed this gesture -> commit on up
  CanvasPenModifiers _dragMods; // mods captured for the marquee finalize on up
  KKBezierPath
      *_dragStartGeom; // working geometry at mouseDown (stable delta base)
  BOOL _marqueeActive;
  CGPoint _marqueeStart, _marqueeEnd; // surface points
  CFTimeInterval _lastClickTime;      // for the viewer's timing double-click
  NSInteger _lastClickAnchor;         // anchor of the last click, -1 = none
}

/// The selected layer if it's an editable vector path, else nil.
- (nullable KKBezierPath *)_path;
/// The geometry shown / edited at the current fraction: the base for a constant
/// path, or the interpolated shape for an animated one.
- (nullable KKBezierPath *)_workingPath;
/// YES when the path is animated but the playhead is NOT parked on a Points
/// keypose - geometry isn't editable there.
- (BOOL)_animatedOffKeypose;
/// Local (Y-up) -> surface point, through the layer transform + groups.
- (CGPoint)_surfaceForLocalX:(float)lx y:(float)ly path:(KKBezierPath *)path;
- (CanvasPathEditHit)_hitAtX:(double)x
                           y:(double)y
                   outAnchor:(NSInteger *)outAnchor
                outHandleOut:(BOOL *)outHandleOut;
/// Nearest segment to (x,y) by sampling each segment's projected polyline.
- (BOOL)_segmentHitAtX:(double)x
                     y:(double)y
                outSeg:(NSUInteger *)outSeg
                  outT:(double *)outT;
/// Toggle anchor `idx` corner<->smooth (called by the base double-click path).
- (BOOL)_toggleSmoothAtIndex:(NSUInteger)idx;

@end

NS_ASSUME_NONNULL_END
