/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

static NSString *const kPluginID = @"co.overpolish.keyframeless.Mesh";

// Origin Position OSC parts (main viewer): the handle / keypose anchor dot, and
// the motion-path tangent handle.
static const NSInteger kOSCPositionPart = 100;
static const NSInteger kOSCPathHandlePart = 101;

/// Posted on the main queue when the OSC handle's screen position updates;
/// the plugin returns this as its help-guide refresh notification.
extern NSNotificationName const kMeshOSCPositionNotification;

@class KKOSCGuideBridge;
/// The shared OSC-guide engine for this XPC process - the generic affine /
/// staleness / notification state behind the Mesh OSC guide. Hand this to
/// a KKJoyrideOSCSegment to build a guide for the Mesh point OSC.
extern KKOSCGuideBridge *MeshSharedOSCGuideBridge(void);

/// Sets the active OSC guide step (forwards to the shared bridge). Call from
/// any thread; the step notification is delivered on the main queue.
extern void MeshSetOSCGuideStep(NSInteger step);
/// YES while the Mesh OSC is actively being drawn (drawOSC fired within the
/// last ~15s) - i.e. the effect is selected in the FCP viewer. FCP gives no
/// deselect callback, so this is a staleness heuristic: idle and deselected
/// both stop drawOSC. NO before the first drawOSC or ~15s after deselect.
extern BOOL MeshHasCanvasReference(void);
/// Re-anchors the bridge's screen↔canvas map by pairing the given screen point
/// with the OSC handle's current canvas position. Call on the press so the
/// drag uses a mapping that survived zoom-to-fit. No-op until drawOSC has run.
extern void MeshOSCCaptureGuideAnchorAtScreen(NSPoint screenPt);
/// Pushes the live radius the guide drag is writing so the OSC handle can
/// track it from the drawOSC tick (the blob is unreadable there).
extern void MeshSetGuideRadius(double radius);
/// Maps a screen point to the radius that would place the OSC handle under it,
/// using the OSC's own geometry. Gives the guide drag the exact 1:1 scale of
/// a native OSC drag. Falls back to the last guide radius until geometry is
/// cached by the bridge.
extern double MeshGuideRadiusForScreenPoint(NSPoint screenPt);

static const UInt32 kParamInspectorUI = 200;
static const UInt32 kParamUIState = 201;
/// Hidden, never-read scratch param. The boundary-value popover writes a fresh
/// random value here on open so FCP treats it as a real parameter change and
/// re-runs -scheduleInputs: for the (otherwise cached) static frame, letting
/// the boundary preview resolve without manual scrubbing.
static const UInt32 kParamRenderNudge = 202;

/// Radius value (in radius units) that the OSC guide targets during the
/// interactive drag step. Shared between OSC.m and MeshInspectorView.m.
static const double kOSCGuideTargetRadius = 60.0;
