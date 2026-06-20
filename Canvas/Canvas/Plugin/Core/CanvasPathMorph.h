/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

@class KKBezierPath;

NS_ASSUME_NONNULL_BEGIN

/// Parked-at-a-keypose tolerance (clip fraction) shared by the editable gate and
/// the path-edit controller's keypose routing.
extern const double kCanvasPathKeyposeEps;

/// The path's geometry AT clip fraction `frac`. For a non-animated path (no
/// enabled "Points" lane with >=2 keyposes) returns `path` unchanged. Otherwise
/// returns a COPY of `path` whose points are interpolated between the
/// surrounding Points keyposes' geometry snapshots (a keypose without a snapshot
/// falls back to `path`'s base points). Stroke / transform props are unchanged,
/// so the caller renders / draws it exactly like the base path.
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
/// edited shape persists + a keypose without its own snapshot falls back to it).
/// Returns `path` unchanged if it has no animated Points lane / bad index.
KKBezierPath *CanvasPathBySettingKeyposeGeometry(KKBezierPath *path,
                                                 NSInteger keyposeIndex,
                                                 KKBezierPath *geometry);

NS_ASSUME_NONNULL_END
