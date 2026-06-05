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

/// Shared per-process OSC guide bridge. The inspector's timing guide reads
/// `estimatedViewerScreenRect` from it (for the watch-back viewer cutout); the
/// OSC feeds it canvas geometry each drawOSC tick. Same instance across the
/// XPC process (so the inspector and the OSC share it).
KKOSCGuideBridge *MagicMoveSharedOSCGuideBridge(void);

NS_ASSUME_NONNULL_END
