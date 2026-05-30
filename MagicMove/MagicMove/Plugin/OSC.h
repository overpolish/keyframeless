/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The viewer-side on-screen control for Magic Move. A single draggable
/// point handle at the evaluated Position lane value. Reads the timeline
/// via the snapshot bridge (FxParameterRetrievalAPI is nil in the drawOSC
/// tick, so the plugin pushes a copy of the timeline into a static cache
/// from createView + parameterChanged).
@interface MagicMoveOSC : KKArcOSC
@end

NS_ASSUME_NONNULL_END
