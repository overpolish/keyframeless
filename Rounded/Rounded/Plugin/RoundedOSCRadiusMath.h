/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <FxPlug/FxPlugSDK.h>

NS_ASSUME_NONNULL_BEGIN

/// Squircle→circle padding (in canvas pixels) between the shape edge and the
/// OSC handle for a given radius. Pure; shared by RoundedOSC and the guide's
/// screen→radius inverse mapping.
float paddingForRadius(double radius, float minDim);

/// Reads the Radius lane value at `frac` (0–1) from the timeline blob param.
/// Returns 20.0 when the param/lane is unavailable. Requires a resolved
/// FxParameterRetrievalAPI (call inside an action scope or render/draw tick).
double radiusFromBlobAtFraction(id<PROAPIAccessing> apiManager, double frac);

NS_ASSUME_NONNULL_END
