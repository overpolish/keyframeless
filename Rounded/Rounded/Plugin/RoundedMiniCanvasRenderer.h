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
extern NSString *const RoundedMiniCanvasDescriptorPath;

/// Rounded's mini-canvas delegate: the generic crop/handle/timeline
/// scaffolding lives in `KKMiniCanvasRenderer`; this subclass only supplies
/// the Rounded shader render and the radius point-handle (its OSC math).
/// MRR (non-ARC).
@interface RoundedMiniCanvasRenderer : KKMiniCanvasRenderer
@end

NS_ASSUME_NONNULL_END
