/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KeyframelessKit.h>

@class KKBezierPath;

NS_ASSUME_NONNULL_BEGIN

/// Cross-process rendezvous path: the render side's `KKMiniViewerFeed`
/// publishes here and the inspector's `KKMiniViewerView` consumes it.
extern NSString *const CanvasMiniViewerDescriptorPath;

/// Reverse channel: the boundary / filmstrip / onion previews write the
/// requested clip fraction here; the render side reads it in `-scheduleInputs:`
/// to also pull those frames for the preview.
extern NSString *const CanvasMiniViewerRequestPath;

/// Canvas's mini-viewer delegate. The generic timeline / handle scaffolding
/// lives in `KKMiniViewerRenderer`; this subclass runs the same image-layer
/// compositing as the main render (Plugin+Render.m) over the source frame, so
/// the preview matches the viewer. The host keeps `layers` synced from the
/// `kParamLayerData` blob (see CanvasInspectorView).
@interface CanvasMiniViewerRenderer : KKMiniViewerRenderer
/// The layer stack to composite, kept in sync by the host. Index 0 is topmost.
@property(nonatomic, copy, nullable) NSArray<KKBezierPath *> *layers;
@end

NS_ASSUME_NONNULL_END
