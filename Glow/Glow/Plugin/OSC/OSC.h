/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Viewer on-screen control for Glow. M1 draws a single draggable radius ring
/// centred on the clip; it reads + writes the Radius lane via the timeline
/// snapshot bridge (FxParameterRetrievalAPI is nil in the drawOSC tick, so the
/// plugin pushes a copy of the timeline into KKProcessTimelineSnapshot from
/// createView + parameterChanged). The inherited KKArcOSC handle is the
/// (dormant) Position offset, lit up when the Position lane lands later.
@interface GlowOSC : KKArcOSC

@property(nonatomic, readonly) KKRingOSC *radiusRing;

@end

NS_ASSUME_NONNULL_END
