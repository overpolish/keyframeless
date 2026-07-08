/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Squircle→circle padding (in canvas pixels) between the shape edge and the
/// OSC handle for a given radius. Pure; shared by MeshOSC and the guide's
/// screen→radius inverse mapping.
float paddingForRadius(double radius, float minDim);

/// Process-wide timeline snapshot. Single-instance assumption (per PLAN
/// §"OSC cache"). Written from `parameterChanged:` on main inside an action
/// scope; read from drawOSC ticks where blob param reads are flaky.
void MeshSetTimelineSnapshot(KKTimeline *_Nullable timeline);
KKTimeline *_Nullable MeshTimelineSnapshot(void);

/// Reads the named lane's value at `frac` from the snapshot. Returns
/// `defaultValues` when no lane is found or it's empty.
NSArray<NSNumber *> *
MeshSnapshotValuesForLabel(NSString *label, double frac,
                              NSArray<NSNumber *> *defaultValues);

/// Per-frame duration in seconds, pushed from the plugin's render path
/// (where FxTimingAPI resolves). Used to build a frame-aware keypose snap
/// tolerance so visibility works across framerates / clip lengths.
void MeshSetFrameDurationSeconds(double frameDurSec);

/// Visibility check shared by Radius and Crop OSCs.
/// - Lane absent OR lane.enabled == NO  → always visible (constant).
/// - Lane.enabled == YES                → visible iff a keypose exists within
///                                        `snapEpsilon` of `frac`.
BOOL MeshLaneVisibleAtFraction(NSString *label, double frac);

/// Convenience: shortcut for `MeshSnapshotValuesForLabel(@"Radius", ...)`.
double MeshSnapshotRadiusAtFraction(double frac);

NS_ASSUME_NONNULL_END
