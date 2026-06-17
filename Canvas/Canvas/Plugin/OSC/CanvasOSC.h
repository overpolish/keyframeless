/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Canvas's viewer-side on-screen control: the SELECTED layer's Position handle
/// + motion path, via the reusable `KKPositionOSC`. The inspector publishes the
/// selected layer's timeline as the process snapshot (the control reads it),
/// and the snapshot's lanes carry `layerKey`, so a drag writes back to the
/// right layer's `animationJSON` inside `kParamLayerData` (the control
/// hardwires the single-param write otherwise). Registered to the "Canvas OSC"
/// Info.plist entry. FCP instantiates it, so it's self-contained (no host-set
/// blocks).
@interface CanvasOSC : KKOnScreenControl
@end

NS_ASSUME_NONNULL_END
