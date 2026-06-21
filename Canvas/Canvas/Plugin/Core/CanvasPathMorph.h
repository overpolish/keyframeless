/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

@class KKBezierPath;

NS_ASSUME_NONNULL_BEGIN

/// Parked-at-a-keypose tolerance (clip fraction) shared by the editable gate
/// and the path-edit controller's keypose routing.
extern const double kCanvasPathKeyposeEps;

/// The path's geometry AT clip fraction `frac`. For a non-animated path (no
/// enabled "Points" lane with >=2 keyposes) returns `path` unchanged. Otherwise
/// returns a COPY of `path` whose points are interpolated between the
/// surrounding Points keyposes' geometry snapshots (a keypose without a
/// snapshot falls back to `path`'s base points). Stroke / transform props are
/// unchanged, so the caller renders / draws it exactly like the base path.
KKBezierPath *CanvasPathMorphedAtFraction(KKBezierPath *path, double frac);

/// Index of the Points keypose the playhead is parked at (within `eps`), or -1
/// (not animated, or between keyposes). Geometry editing is only allowed AT a
/// keypose; the edit writes that keypose's snapshot.
NSInteger CanvasPathActiveKeyposeAtFraction(KKBezierPath *path, double frac,
                                            double eps);

/// YES when the path's anchors should show / be editable at `frac`: the path is
/// constant (no animated Points lane) OR the playhead is parked on a Points
/// keypose. Between keyposes returns NO - the OSC rule every plugin follows
/// (anchors show only when constant or on a keypose).
BOOL CanvasPathGeometryEditableAtFraction(KKBezierPath *path, double frac);

/// Write `geometry`'s points (captured as a morph snapshot) into the Points
/// keypose at `keyposeIndex`, returning a COPY of `path` with the updated
/// `animationJSON`. The base `points` are also set to `geometry` (so the last-
/// edited shape persists + a keypose without its own snapshot falls back to
/// it). Returns `path` unchanged if it has no animated Points lane / bad index.
KKBezierPath *CanvasPathBySettingKeyposeGeometry(KKBezierPath *path,
                                                 NSInteger keyposeIndex,
                                                 KKBezierPath *geometry);

/// Persist an edited WORKING geometry (the shape shown at `frac`) back into
/// `base`: writes the parked keypose's snapshot when animated + on a keypose,
/// else returns `editedWorking` itself (constant path = the base IS the shape).
/// The single place insert / move / continue all funnel through so per-keypose
/// vs constant is decided once.
KKBezierPath *CanvasPathByWritingWorkingGeometry(KKBezierPath *base,
                                                 double frac,
                                                 KKBezierPath *editedWorking);

/// A COPY of `path` with its point order reversed (in/out tangents swapped) -
/// and EVERY Points keypose snapshot reversed the same way, so the per-keypose
/// morph correspondence is preserved. Renders identically (a path and its
/// reverse draw the same stroke); used so the pen can continue from the FIRST
/// anchor by reversing then appending. No-op for < 2 points.
KKBezierPath *CanvasPathByReversingGeometry(KKBezierPath *path);

/// Drop the Points keypose at `keyposeIndex` (the user emptied its geometry
/// below a viable 2 points). Returns the reduced path:
///  - >= 2 keyposes remain -> still animated, that keypose removed.
///  - 1 remains -> collapse to a CONSTANT path using the survivor's shape
///  (Points
///    lane disabled), or nil if the survivor isn't viable.
///  - 0 remain -> nil (the caller deletes the layer).
KKBezierPath *_Nullable CanvasPathByRemovingKeypose(KKBezierPath *path,
                                                    NSUInteger keyposeIndex);

NS_ASSUME_NONNULL_END
