/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <simd/simd.h>

#import <KeyframelessKit/KKBezierPath.h>

NS_ASSUME_NONNULL_BEGIN

/// Capture a path's geometry as a morph snapshot blob.
/// Format: uint32 count + uint8 closed + `count` × KKBezierPoint.
/// Properties (stroke/fill/transform) are NOT included — morph only operates
/// on geometry.
FOUNDATION_EXPORT NSData *KKMorphSnapshotCapture(KKBezierPath *path);

/// Read the count + closed-flag header of a snapshot blob without copying
/// the points. Returns NO if the blob is malformed.
FOUNDATION_EXPORT BOOL KKMorphSnapshotPeek(NSData *_Nullable blob,
                                           uint32_t *_Nullable outCount,
                                           BOOL *_Nullable outClosed);

/// Apply a snapshot blob's geometry to a path: replaces points (with full
/// bezier handles preserved) and the closed flag. Used at render time when
/// a Morph lane's active segment is a Hold and we want the exact authored
/// shape, not a resampled polyline.
FOUNDATION_EXPORT void KKMorphSnapshotApply(NSData *blob, KKBezierPath *path);

/// High-level: morph `path` to the interpolated state between two snapshots
/// at progress `t`. When both snapshots have matching topology (same point
/// count + closed flag) — the dominant case for the split-then-edit-a-point
/// workflow — interpolates control points 1:1 with bezier handles
/// preserved. When topologies differ, falls back to uniform arc-length
/// resampling with linear-only output.
FOUNDATION_EXPORT void KKMorphInterpolateApply(NSData *fromBlob, NSData *toBlob,
                                               float t, KKBezierPath *path);

/// Interpolate two snapshots at progress t (0..1). Both snapshots are
/// uniformly resampled along arc length to a common point count, then
/// positions are linearly lerped. The resulting points are linear
/// (handles cleared) — Stage 1 limitation; corner pinning + bezier
/// preservation are future work.
///
/// `outPositions` must have capacity for at least `outSampleCount` entries
/// (typically max(snapshotACount, snapshotBCount), with a floor of 8).
/// Returns the number of positions written. The closed flag is taken
/// from the `to` snapshot. Returns 0 on failure.
FOUNDATION_EXPORT NSUInteger KKMorphInterpolate(NSData *fromBlob,
                                                NSData *toBlob, float t,
                                                simd_float2 *outPositions,
                                                BOOL *_Nullable outClosed);

/// Pick the resample count that `KKMorphInterpolate` will use for the given
/// pair. Useful for sizing the output buffer.
FOUNDATION_EXPORT NSUInteger KKMorphInterpolateSampleCount(NSData *fromBlob,
                                                           NSData *toBlob);

NS_ASSUME_NONNULL_END
