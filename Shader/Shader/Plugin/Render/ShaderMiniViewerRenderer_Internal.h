/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "ShaderMiniViewerRenderer.h"
#import <KeyframelessKit/KeyframelessKit.h>

@class KKPointOSCSet;
@class KKRingOSCSet;

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
// Re-derive the set's lane labels from the current shader source. Cheap no-op
// when the source is unchanged.
- (void)_syncMiniPointController;
// Re-derive the ring set's specs from the current shader source.
- (void)_syncMiniRingController;
@end

@interface ShaderMiniViewerRenderer (Interaction)
@end

NS_ASSUME_NONNULL_END
