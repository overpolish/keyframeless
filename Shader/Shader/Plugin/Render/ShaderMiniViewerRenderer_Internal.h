/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "ShaderMiniViewerRenderer.h"
#import <KeyframelessKit/KeyframelessKit.h>

@class KKPointOSCSet;
@class KKRingOSCSet;
@class KKBoxOSCSet;

NS_ASSUME_NONNULL_BEGIN

@interface ShaderMiniViewerRenderer ()
// The reusable mini-viewer Position OSC set - one KKPositionMiniController per
// `#point osc` lane, all drawn/dragged uniformly (no "primary"). The
// Interaction category forwards every KKMiniViewerDelegate point method to it;
// Shader only parses the source for the osc-point uniform names and feeds them
// in.
@property(nonatomic, strong, readonly) KKPointOSCSet *pointSet;
// The reusable mini-viewer radius-ring set - the mini sibling of the viewer's
// ring loop, one entry per `osc=ring` scalar lane. Interaction forwards the
// ring draw + generic handle methods here; Shader feeds it the ring specs
// (label + value range + object-space centre) from the source.
@property(nonatomic, strong, readonly) KKRingOSCSet *ringSet;
// The reusable mini-viewer box set - the mini sibling of the viewer's box loop,
// one entry per `osc=box` scalar lane. Interaction forwards the box draw +
// generic handle methods here; Shader feeds it the box specs (same radial specs
// as the rings, plus the field type for the readout) from the source.
@property(nonatomic, strong, readonly) KKBoxOSCSet *boxSet;
// Re-derive the set's lane labels from the current shader source. Cheap no-op
// when the source is unchanged.
- (void)_syncMiniPointController;
// Re-derive BOTH the ring and box sets' specs from the current shader source in
// one parse (a ring and a box share the same radial spec; only the osc kind and
// the target set differ). Cheap no-op when the source is unchanged.
- (void)_syncMiniRadialControllers;
@end

@interface ShaderMiniViewerRenderer (Interaction)
@end

NS_ASSUME_NONNULL_END
