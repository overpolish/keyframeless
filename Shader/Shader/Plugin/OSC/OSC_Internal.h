/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "OSC.h"
#import <FxPlug/FxPlugSDK.h>

NS_ASSUME_NONNULL_BEGIN

@interface ShaderOSC ()
// The [0,1] object rect's canvas corners, feeding the guide bridge's
// zoom-invariant screen<->canvas map. Implemented in OSC.m.
- (BOOL)getCanvasTopRight:(CGPoint *)outTopRight
               bottomLeft:(CGPoint *)outBottomLeft;
@end

/// Pointer/key event handlers. The legacy Origin/Scale/Rotation controls are
/// gone, so these only track opt-reveal and advance the (dormant) timing-guide
/// step machine. Implemented in ShaderOSC+MouseHandlers.m.
@interface ShaderOSC (MouseHandlers)
@end

NS_ASSUME_NONNULL_END
