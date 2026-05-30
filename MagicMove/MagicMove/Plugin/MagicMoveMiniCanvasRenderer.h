/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Cross-process rendezvous path: the render side's `KKMiniCanvasFeed`
/// publishes here and the inspector's `KKMiniCanvasView` consumes it.
extern NSString *const MagicMoveMiniCanvasDescriptorPath;

/// Reverse channel: the boundary-value popover writes the requested clip
/// fraction here; the render side reads it in -scheduleInputs:.
extern NSString *const MagicMoveMiniCanvasRequestPath;

/// MagicMove's mini-canvas delegate. Position (XY) is the only point handle;
/// the effect render falls back to the base passthrough until we add a
/// dedicated mini-canvas transform shader.
@interface MagicMoveMiniCanvasRenderer : KKMiniCanvasRenderer
@end

NS_ASSUME_NONNULL_END
