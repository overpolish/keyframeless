/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <simd/simd.h>

#import "CanvasPenController.h" // CanvasPenModifiers

NS_ASSUME_NONNULL_BEGIN

/// Constrain a handle / move delta the way both the pen (closing + handle drag)
/// and the path-edit handle drag do: Shift axis-locks to horizontal/vertical,
/// Cmd snaps to the nearest 45 degrees. The math runs in PIXEL space (object X
/// scaled by `aspect`, the canvas outputW/outputH) so the constraint is visual,
/// not skewed, then unscales back to object space. `delta` is an object-space
/// (Y-up) offset; the result is the same space. No modifier -> returned as-is.
/// Shared so the pen and path-edit controllers can't diverge.
simd_float2 CanvasConstrainHandleDelta(simd_float2 delta, float aspect,
                                       CanvasPenModifiers mods);

NS_ASSUME_NONNULL_END
