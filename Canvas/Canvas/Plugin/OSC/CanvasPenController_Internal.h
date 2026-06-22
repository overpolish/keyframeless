/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "CanvasPenController.h"

@class KKBezierPath;

NS_ASSUME_NONNULL_BEGIN

/// Shared internal surface for the CanvasPenController split:
///  - base (CanvasPenController.m): the new-path drawing state machine (press /
///    drag / up / keys / resume).
///  - +Draw: the in-progress overlay (rubber-band, handles, anchor dots).
/// The ivars live here so +Draw can read the live drawing state.

/// Surface-px radius within which a click on the first / last anchor ends the
/// path (close / finish zones); shared by the state machine + the overlay.
static const double kPenCloseRadiusPx = 10.0;

@interface CanvasPenController () {
  __weak id<CanvasPenSurface> _surface;
  NSString *_layerID;        // the in-progress vector layer (nil = idle)
  BOOL _pendingActive;       // a point is placed but not yet committed
  CGPoint _pendingPos;       // Y-up object
  CGPoint _dragOut, _dragIn; // pending point's handle offsets (Y-up object)
  BOOL _handleDragging;      // pulling the pending point's handles
  CGPoint _cursorObj;        // Y-up object (snapped) - rubber-band + ghost
  BOOL _cursorValid;
  CGPoint _downSurface; // mouseDown surface point (drag threshold)
  CFTimeInterval _lastClickTime;
  CGPoint _lastClickSurface;
  BOOL _selectionSeen; // latched once our layer is the resolved selection
  // The FIRST point is held transiently until a SECOND is placed, then the
  // layer is created with both in one action - so a 1-point (degenerate,
  // invisible) layer never persists and undo can't land on a single orphan
  // anchor.
  BOOL _hasFirst;
  CGPoint _firstPos, _firstOut, _firstIn; // Y-up object
  // Closing the path: mouseDown landed on the first anchor. The close commits
  // on mouseUp so a click-drag can smooth the first anchor (curved closing
  // segment), matching the pen tool's place-a-point drag. No drag = plain
  // corner close.
  BOOL _closing;
  BOOL _closeDragging;
  CGPoint _closeOut,
      _closeIn; // first anchor's handles being dragged (Y-up object)
  // YES when _layerID is an EXISTING path we resumed (not a fresh pen draw), so
  // Esc just ends the session instead of deleting the path.
  BOOL _resumedExisting;
}

- (void)_endSession;
- (nullable KKBezierPath *)_layer;
- (nullable KKBezierPath *)_workingLayer;
- (nullable KKBezierPath *)_resumableBase;
- (void)_appendPointToLayer:(CGPoint)pos out:(CGPoint)o in:(CGPoint)in;
- (void)_mutateInProgress:(void (^)(KKBezierPath *layer))mutate;
- (CGPoint)_constrainHandle:(CGPoint)h modifiers:(CanvasPenModifiers)mods;

@end

// The overlay-draw helper is declared on a CATEGORY interface (not the class
// extension above) so the compiler doesn't expect it in the primary
// @implementation - it lives in CanvasPenController+Draw.m.
@interface CanvasPenController (Draw)
- (void)_drawHandleAtAnchor:(CGPoint)anchorObj offset:(CGPoint)offset;
@end

NS_ASSUME_NONNULL_END
