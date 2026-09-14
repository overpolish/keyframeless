/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <simd/simd.h>

@class KKKeyPose;
@class KKLane;
@class KKSnapEngine;

NS_ASSUME_NONNULL_BEGIN

/// Headless core of the Position element, shared by the viewer's
/// KKPositionOSC and the mini-viewer's KKPositionMiniController. Each
/// frontend supplies its own screen projection (viewer: canvas px through the
/// parent transform + warp; mini: contentRect points) and hit tolerance
/// derivation - the LOGIC (which keypose/handle is hit, what a snap resolves
/// to) lives here once so the two surfaces cannot drift. Grow this model, not
/// the frontends: new Position behavior goes here with a projection/state
/// callback, never as parallel per-surface implementations.

/// Screen-space projection of a lane keypose value pair for hit testing.
/// `fraction` is the keypose time (frontends that warp by fraction use it).
typedef CGPoint (^KKPositionProjection)(double objX, double objY,
                                        double fraction);

/// The ONE hit-slop rule: a dot with visual radius `dotRadiusPt` grabs within
/// radius + 6pt (the viewer's historical oscRadius+6; the mini's flat 12pt is
/// this rule with its 6pt dot).
FOUNDATION_EXPORT double KKPositionHitTolPt(double dotRadiusPt);

/// Index of the keypose anchor dot nearest `pt` within `hitTolPt`, projecting
/// each keypose through `project`; -1 if none. `skipIndex` excludes the
/// anchor covered by the live position handle (-1 = none). Lanes with fewer
/// than 2 keyposes have no path and never hit.
FOUNDATION_EXPORT NSInteger KKPositionAnchorHitIndex(
    KKLane *_Nullable lane, CGPoint pt, double hitTolPt, NSInteger skipIndex,
    NS_NOESCAPE KKPositionProjection project);

/// Index of the smooth keypose whose tangent-handle dot is nearest `pt`
/// within `hitTolPt`; -1 if none. `*outIsOut` reports which side (outgoing vs
/// incoming) when hit. Zero-length tangents never hit.
FOUNDATION_EXPORT NSInteger KKPositionTangentHitIndex(
    KKLane *_Nullable lane, CGPoint pt, double hitTolPt, BOOL *_Nullable outIsOut,
    NS_NOESCAPE KKPositionProjection project);

/// Anchor drag shaping: proposed target = grab + (cursor - press) per axis;
/// Shift pins whichever axis has LESS travel from the press point.
FOUNDATION_EXPORT void KKPositionShapeAnchorDrag(double grabX, double grabY,
                                                 double dx, double dy,
                                                 BOOL shiftAxisLock,
                                                 double *outX, double *outY);

/// Tangent-handle drag applied to `kp` (must already be a mutable copy):
/// shapes the offset (cursor - anchor, object space) - Shift axis-locks to
/// H/V, Cmd snaps the angle to 45-degree steps with length preserved - then
/// writes the dragged side and mirrors the opposite side for a smooth curve
/// unless `ctrlCusp` breaks the tangent (in/out independent). Marks the
/// keypose spatialSmooth. Per-keypose curve shape is NOT shared by a
/// hold-link, so callers write the keypose alone.
FOUNDATION_EXPORT void KKPositionApplyTangentDrag(KKKeyPose *kp, BOOL isOut,
                                                  double offX, double offY,
                                                  BOOL shiftAxisLock,
                                                  BOOL cmdAngleSnap,
                                                  BOOL ctrlCusp);

/// Snap `p` (object/normalized space) against the shared target set: the
/// 0/.25/.5/.75/1 edge anchors plus every OTHER keypose of `lane` plus
/// host-supplied `externalTargets` (CGPoint NSValues in the same space).
/// `excludeIndex` (and its hold-linked twins, which move WITH the drag) are
/// skipped so the dragged anchor can't snap to itself. Thresholds are in the
/// same object space - each frontend derives them from its own screen scale.
FOUNDATION_EXPORT simd_float2 KKPositionSnapPoint(
    KKSnapEngine *engine, simd_float2 p, KKLane *_Nullable lane,
    NSInteger excludeIndex, NSArray<NSValue *> *_Nullable externalTargets,
    float thresholdX, float thresholdY);

NS_ASSUME_NONNULL_END
