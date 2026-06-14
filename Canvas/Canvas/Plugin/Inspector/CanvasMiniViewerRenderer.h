/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Cross-process rendezvous path: the render side's `KKMiniViewerFeed`
/// publishes here and the inspector's `KKMiniViewerView` consumes it.
extern NSString *const CanvasMiniViewerDescriptorPath;

/// Reverse channel: the boundary / filmstrip / onion previews write the
/// requested clip fraction here; the render side reads it in `-scheduleInputs:`
/// to also pull those frames for the preview.
extern NSString *const CanvasMiniViewerRequestPath;

/// Canvas's mini-viewer delegate. The generic timeline / handle scaffolding
/// lives in `KKMiniViewerRenderer`; this subclass currently adds nothing - the
/// base does a raw source passthrough, which matches Canvas's passthrough
/// render (increment 1). The real shape preview + OSC handles land here as the
/// rendering features are rebuilt onto the v3 timing core.
@interface CanvasMiniViewerRenderer : KKMiniViewerRenderer
@end

NS_ASSUME_NONNULL_END
