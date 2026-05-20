/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

static NSString *const kPluginID = @"co.overpolish.keyframeless.Rounded";

static const NSInteger kOSCRadiusPart = 100;
// Crop part IDs: rect-drag = 200, 8 handles = 201..208.
static const NSInteger kOSCCropRectPart = 200;
static const NSInteger kOSCCropPointBase = 201;

/// Posted on the main queue when the OSC handle's screen position updates;
/// the plugin returns this as its help-guide refresh notification.
extern NSNotificationName const kRoundedOSCPositionNotification;

@class KKOSCGuideBridge;
/// The shared OSC-guide engine for this XPC process — the generic affine /
/// staleness / notification state behind the Rounded OSC guide. Hand this to
/// a KKJoyrideOSCSegment to build a guide for the Rounded point OSC.
extern KKOSCGuideBridge *RoundedSharedOSCGuideBridge(void);

/// Sets the active OSC guide step (forwards to the shared bridge). Call from
/// any thread; the step notification is delivered on the main queue.
extern void RoundedSetOSCGuideStep(NSInteger step);
/// YES while the Rounded OSC is actively being drawn (drawOSC fired within the
/// last ~15s) — i.e. the effect is selected in the FCP viewer. FCP gives no
/// deselect callback, so this is a staleness heuristic: idle and deselected
/// both stop drawOSC. NO before the first drawOSC or ~15s after deselect.
extern BOOL RoundedHasCanvasReference(void);
/// Re-anchors the bridge's screen↔canvas map by pairing the given screen point
/// with the OSC handle's current canvas position. Call on the press so the
/// drag uses a mapping that survived zoom-to-fit. No-op until drawOSC has run.
extern void RoundedOSCCaptureGuideAnchorAtScreen(NSPoint screenPt);
/// Pushes the live radius the guide drag is writing so the OSC handle can
/// track it from the drawOSC tick (the blob is unreadable there).
extern void RoundedSetGuideRadius(double radius);
/// Maps a screen point to the radius that would place the OSC handle under it,
/// using the OSC's own geometry. Gives the guide drag the exact 1:1 scale of
/// a native OSC drag. Falls back to the last guide radius until geometry is
/// cached by the bridge.
extern double RoundedGuideRadiusForScreenPoint(NSPoint screenPt);

static const UInt32 kParamInspectorUI = 200;
static const UInt32 kParamUIState = 201;
/// Hidden, never-read scratch param. The boundary-value popover writes a fresh
/// random value here on open so FCP treats it as a real parameter change and
/// re-runs -scheduleInputs: for the (otherwise cached) static frame, letting
/// the boundary preview resolve without manual scrubbing.
static const UInt32 kParamRenderNudge = 202;

/// Radius value (in radius units) that the OSC guide targets during the
/// interactive drag step. Shared between OSC.m and RoundedInspectorView.m.
static const double kOSCGuideTargetRadius = 60.0;
