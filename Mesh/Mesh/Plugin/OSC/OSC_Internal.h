/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "OSC.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKPositionOSC.h>

NS_ASSUME_NONNULL_BEGIN

@interface MeshOSC ()
/// The reusable Origin Position control (arc handle + motion path). MeshOSC is
/// the single FxPlug control and forwards draw / hit-test / mouse to it.
@property(nonatomic, retain) KKPositionOSC *originController;
// Geometry/time helpers implemented in the primary @implementation (OSC.m);
// called by the MouseHandlers category.
- (BOOL)getCanvasTopRight:(CGPoint *)outTopRight
               bottomLeft:(CGPoint *)outBottomLeft;
- (double)fractionAtTime:(CMTime)time;
@end

/// Pointer/key event handlers (mouseDown/Dragged/Up + keyDown). Split out of
/// OSC.m for file size; implemented in MeshOSC+MouseHandlers.m. The
/// mouseDragged writes the timeline blob inside an FxCustomParameterAction
/// scope (the only API that resolves outside a host callback).
@interface MeshOSC (MouseHandlers)
@end

NS_ASSUME_NONNULL_END
