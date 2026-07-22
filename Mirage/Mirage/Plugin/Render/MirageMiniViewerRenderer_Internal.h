/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "MirageMiniViewerRenderer.h"
#import <KeyframelessKit/KeyframelessKit.h>

@class KKPointOSCSet;
@class KKRotationOSCSet;
@class MirageExprMiniSet;

NS_ASSUME_NONNULL_BEGIN

@interface MirageMiniViewerRenderer ()
// The reusable mini-viewer Position OSC set - one KKPositionMiniController per
// `#point osc` lane, all drawn/dragged uniformly (no "primary"). The
// Interaction category forwards every KKMiniViewerDelegate point method to it;
// Mirage only parses the source for the osc-point uniform names and feeds them
// in.
@property(nonatomic, strong, readonly) KKPointOSCSet *pointSet;
// The reusable mini-viewer rotation set - the mini sibling of the viewer's
// KKRotationOSC loop, one 3-ring gizmo per `osc={..}` lane. Interaction
// forwards the rotation draw + generic handle methods here; Mirage feeds it the
// rotate specs (label + active-axis bitmask + clip-centre) from the source.
@property(nonatomic, strong, readonly) KKRotationOSCSet *rotSet;
// The mini sibling of the viewer's `// @osc` control loop (directive sugar
// included): point glyphs, value rings, boxes - one control per block.
// Interaction forwards the draw + generic handle methods here; Mirage feeds it
// the source (which it parses + compiles through the shared
// MirageOSCBlockRuntime).
@property(nonatomic, strong, readonly) MirageExprMiniSet *exprSet;
// Re-derive the set's lane labels from the current shader source. Cheap no-op
// when the source is unchanged.
- (void)_syncMiniPointController;
// Re-derive the rotation set's specs from the current shader source. Cheap
// no-op when the source is unchanged.
- (void)_syncMiniRotController;
// Re-derive the custom `// @osc` handles from the current shader source. Cheap
// no-op when the source is unchanged.
- (void)_syncMiniExprController;
@end

@interface MirageMiniViewerRenderer (Interaction)
@end

NS_ASSUME_NONNULL_END
