/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "MagicMoveMiniViewerRenderer.h"
#import <KeyframelessKit/KeyframelessKit.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

// Shared lane lookup against a timeline (defined in the core .m).
KKLane *_Nullable MMMiniLaneNamed(KKTimeline *timeline, NSString *label);

@interface MagicMoveMiniViewerRenderer () {
  KKSnapEngine *_snapEngine;
  // Normalised press point captured at begin-drag; used as the Shift
  // axis-lock anchor so the locked axis stays pinned where it was, not
  // wherever the cursor most recently passed through.
  double _posPressNX;
  double _posPressNY;
  // Position value at grab, for delta dragging (move by the cursor's offset
  // from the press point) instead of snapping the handle to the cursor -
  // matches the viewer OSC.
  double _posGrabValX;
  double _posGrabValY;
  // Pipeline cache keyed by (device, pixelFormat) - the plugin's own metallib
  // is in this XPC process's bundle, so we build a real PSO and apply the
  // shader source → dest locally. No FxPlug round-trip = no Flexo lock
  // contention = no deadlock during live drag.
  id<MTLRenderPipelineState> _pipeline;
  id<MTLDevice> _pipelineDevice;
  MTLPixelFormat _pipelineFormat;
  // Motion-path drag: which keypose + which part (0=anchor, 1=out, 2=in).
  BOOL _pathGrabbed;
  NSInteger _pathIndex;
  NSInteger _pathPart;
  double _pathPressNX;
  double _pathPressNY;
  double _pathGrabValX; // keypose value at grab (delta-drag anchor)
  double _pathGrabValY;
  // Scale box drag (mirrors the viewer OSC's absolute + Cmd-fine model).
  BOOL _scaleGrabbed;
  NSInteger _scaleGrabHandle; // 0-7
  CGPoint _scalePressCenter;
  double _scalePressSclX;
  double _scalePressSclY;
  CGPoint _scaleEffCursor; // effective cursor (starts at the grabbed handle)
  CGPoint _scaleLastCursor;
  // Anchor-square drag: delta-based like Position (snap off unless Cmd).
  BOOL _anchorGrabbed;
  double _anchorGrabValX;
  double _anchorGrabValY;
  double _anchorPressNX;
  double _anchorPressNY;
}
// Geometry helper defined in the primary @implementation (the core .m); called
// across the Interaction category.
- (CGPoint)_handlePointForContentRect:(CGRect)cr
                             position:(NSArray<NSNumber *> *)pos;
@end

@interface MagicMoveMiniViewerRenderer (Interaction)
@end

NS_ASSUME_NONNULL_END
