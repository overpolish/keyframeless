/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "OSC.h"
#import <FxPlug/FxPlugSDK.h>

NS_ASSUME_NONNULL_BEGIN

@interface RoundedOSC () {
@protected
  CGPoint _dragStartPosition;
  double _dragStartRadius;
  double _dragCurrentRadius;
}
// Geometry/time helpers implemented in the primary @implementation (OSC.m);
// called by the MouseHandlers category.
- (BOOL)getCanvasTopRight:(CGPoint *)outTopRight
               bottomLeft:(CGPoint *)outBottomLeft;
- (double)fractionAtTime:(CMTime)time;
@end

/// Pointer/key event handlers (mouseDown/Dragged/Up + keyDown). Split out of
/// OSC.m for file size; implemented in RoundedOSC+MouseHandlers.m. The
/// mouseDragged writes the timeline blob inside an FxCustomParameterAction
/// scope (the only API that resolves outside a host callback).
@interface RoundedOSC (MouseHandlers)
@end

NS_ASSUME_NONNULL_END
