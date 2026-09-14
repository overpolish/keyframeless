/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

@class KKOSCGuideBridge;

NS_ASSUME_NONNULL_BEGIN

/// Shared per-process OSC guide bridge for Canvas's viewer Position handle. The
/// CanvasOSC tick feeds it canvas geometry (corners + scale + handle pos); the
/// inspector's timing guides read its viewer screen rect (watch-back / OSC
/// spotlight) and its `hasCanvasReference` (the "guides are disabled until you
/// focus the effect and move over the viewer" gate every other plugin shows).
KKOSCGuideBridge *CanvasSharedOSCGuideBridge(void);

/// Push the guide-scoped Position (object [0,1] clip space) the OSC handle
/// follows while a guide drag is active - the drawOSC tick can't read the layer
/// blob, so the inspector drag pushes the live value here.
void CanvasSetGuidePosition(double objX, double objY);

/// The object-space destination the interactive Position drag targets (offset
/// from the 0.5,0.5 centre so the move is clearly visible).
CGPoint CanvasGuideTargetObjectPosition(void);

/// Inverse map: a screen point -> object-space Position via the bridge's cached
/// viewer rect (object [0,1]^2 maps to the viewer rect corners, both Y-up). NO
/// if no live geometry has landed yet.
BOOL CanvasGuidePositionForScreenPoint(NSPoint screenPt, double *_Nullable outX,
                                       double *_Nullable outY);

NS_ASSUME_NONNULL_END
