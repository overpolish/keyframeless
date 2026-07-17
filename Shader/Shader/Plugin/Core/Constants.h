/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

static NSString *const kPluginID = @"co.overpolish.keyframeless.Shader";

/// Posted on the main queue when the OSC handle's screen position updates;
/// the plugin returns this as its help-guide refresh notification.
extern NSNotificationName const kShaderOSCPositionNotification;

@class KKOSCGuideBridge;
/// The shared OSC-guide engine for this XPC process - the generic affine /
/// staleness / notification state behind the Shader OSC guide. Hand this to
/// a KKJoyrideOSCSegment to build a guide for the Shader point OSC.
extern KKOSCGuideBridge *ShaderSharedOSCGuideBridge(void);

/// Sets the active OSC guide step (forwards to the shared bridge). Call from
/// any thread; the step notification is delivered on the main queue.
extern void ShaderSetOSCGuideStep(NSInteger step);
/// YES while the Shader OSC is actively being drawn (drawOSC fired within the
/// last ~15s) - i.e. the effect is selected in the FCP viewer. FCP gives no
/// deselect callback, so this is a staleness heuristic: idle and deselected
/// both stop drawOSC. NO before the first drawOSC or ~15s after deselect.
extern BOOL ShaderHasCanvasReference(void);
/// Pushes the live Origin position (object [0,1] space) the guide drag is
/// writing so the OSC handle can track it from the drawOSC tick (the blob is
/// unreadable there). Mirrors MagicMove's Position guide plumbing.
extern void ShaderSetGuidePosition(double objX, double objY);
/// The object-space Origin position the OSC guide's interactive drag targets.
extern CGPoint ShaderGuideTargetObjectPosition(void);
/// Maps a screen point to the Origin position (object [0,1] space) under it,
/// via the bridge's cached viewer rect. Returns NO until that geometry is
/// available. Gives the guide drag the same 1:1 mapping a native Origin drag
/// uses.
extern BOOL ShaderGuidePositionForScreenPoint(NSPoint screenPt, double *outX,
                                              double *outY);

static const UInt32 kParamInspectorUI = 200;
static const UInt32 kParamUIState = 201;
/// Hidden, never-read scratch param. The boundary-value popover writes a fresh
/// random value here on open so FCP treats it as a real parameter change and
/// re-runs -scheduleInputs: for the (otherwise cached) static frame, letting
/// the boundary preview resolve without manual scrubbing.
static const UInt32 kParamRenderNudge = 202;
/// Hidden store of Sonar tickets: what each `#audio` binding points at, so a
/// project carried to a Mac that never published can still say what it wants.
/// A plain string param on purpose - see Plugin+AudioTickets.m.
static const UInt32 kParamAudioTickets = 203;

/// The baked default Custom shader (animated cosine plasma). Rendered when the
/// Shader lane's codeString is empty, and seeds the "Shader" lane in the
/// catalog. Defined in Plugin+Render.
extern NSString *ShaderCustomDefaultShaderSource(void);
