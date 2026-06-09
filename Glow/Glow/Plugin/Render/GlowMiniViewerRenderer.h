/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Cross-process rendezvous path: the render side's `KKMiniViewerFeed`
/// publishes here and the inspector's `KKMiniViewerView` consumes it.
extern NSString *const GlowMiniViewerDescriptorPath;

/// Reverse channel: the boundary-value popover writes the requested clip
/// fraction here; the render side reads it in `-scheduleInputs:` to also pull
/// that frame for the preview.
extern NSString *const GlowMiniViewerRequestPath;

/// Glow's mini-viewer delegate. The generic timeline / handle scaffolding lives
/// in `KKMiniViewerRenderer`; this subclass supplies only a self-contained
/// glow preview (prep -> MPS blur -> composite). M1 is preview-only: no
/// draggable radius handle yet.
@interface GlowMiniViewerRenderer : KKMiniViewerRenderer
@end

NS_ASSUME_NONNULL_END
