/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "OSC.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKCropOSC.h>

NS_ASSUME_NONNULL_BEGIN

@interface MeshOSC () {
@protected
  CGPoint _dragStartPosition;
  double _dragStartRadius;
  double _dragCurrentRadius;
  KKCropOSC *_cropOSC;
  // YES while we've forced the radius point's move cursor, so we can reset it
  // to the arrow when the pointer leaves the handle (the crop box self-manages
  // its own resize cursor via KKBoxOSC).
  BOOL _radiusCursorSet;
}
// Geometry/time helpers implemented in the primary @implementation (OSC.m);
// called by the MouseHandlers category.
- (BOOL)getCanvasTopRight:(CGPoint *)outTopRight
               bottomLeft:(CGPoint *)outBottomLeft;
- (double)fractionAtTime:(CMTime)time;
// Crop-aware anchor for the radius handle: top-right corner of the crop
// rect in canvas space + that crop's min dim (canvas pixels), matching the
// mini viewer's `_anchorRectForContentRect:`. Falls back to the full canvas
// for the default crop.
- (BOOL)_cropAnchorCornerForFraction:(double)frac
                           outCorner:(CGPoint *)outCorner
                         outFlippedX:(BOOL *)outFlippedX
                         outFlippedY:(BOOL *)outFlippedY
                           outMinDim:(float *)outMinDim;
// Crop-OSC writeback. Called from the KKCropOSC.valuesWriter block during a
// drag - opens an action scope, mutates the snapshot's Crop lane (preserving
// In/Hold/Out structure like radius), and writes the blob back. Same pattern
// as MeshOSC+MouseHandlers' radius writer.
- (void)_writeCropValues:(NSArray<NSNumber *> *)values atTime:(CMTime)time;
@end

/// Pointer/key event handlers (mouseDown/Dragged/Up + keyDown). Split out of
/// OSC.m for file size; implemented in MeshOSC+MouseHandlers.m. The
/// mouseDragged writes the timeline blob inside an FxCustomParameterAction
/// scope (the only API that resolves outside a host callback).
@interface MeshOSC (MouseHandlers)
@end

NS_ASSUME_NONNULL_END
