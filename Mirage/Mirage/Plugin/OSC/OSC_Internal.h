/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "OSC.h"
#import <FxPlug/FxPlugSDK.h>

NS_ASSUME_NONNULL_BEGIN

// KKPositionGuideProvider: during the timing guide the point handle draws at
// the guide-pushed position (the drawOSC tick can't read the timeline blob), so
// the taught handle - and the spotlight tracking it - follow the walkthrough
// instead of sitting at the lane's stored value. Mirrors MagicMove.
@interface MirageOSC () <KKPositionGuideProvider>
// YES when a control forced a non-arrow cursor last hover; reset at the top of
// the next hit-test so moving off a handle restores the arrow.
@property(nonatomic) BOOL pointCursorSet;

// The [0,1] object rect's canvas corners, feeding the guide bridge's
// zoom-invariant screen<->canvas map. Implemented in OSC.m.
- (BOOL)getCanvasTopRight:(CGPoint *)outTopRight
               bottomLeft:(CGPoint *)outBottomLeft;

// Position-handle mouse routing (dynamic `#point osc` controllers). Return YES
// when a controller claimed the event. Implemented in OSC.m.
- (BOOL)oscMouseDownAtX:(double)x
                      y:(double)y
             activePart:(NSInteger)part
              modifiers:(NSUInteger)modifiers
            forceUpdate:(BOOL *)forceUpdate
                 atTime:(CMTime)time;
- (BOOL)oscMouseDraggedAtX:(double)x
                         y:(double)y
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time;
- (void)oscMouseUp;
@end

/// Pointer/key event handlers. The legacy Origin/Scale/Rotation controls are
/// gone, so these only track opt-reveal and advance the (dormant) timing-guide
/// step machine. Implemented in MirageOSC+MouseHandlers.m.
@interface MirageOSC (MouseHandlers)
@end

NS_ASSUME_NONNULL_END
