/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

static NSString *const kPluginID = @"co.overpolish.keyframeless.Mirage";

/// Label of the code lane carrying the shader source (KKLaneValueTypeCode).
/// The label is the lane's PERSISTED identity - shipped timelines contain it,
/// so it never tracks product renames. Match against this constant, never the
/// literal.
static NSString *const kMirageCodeLaneLabel = @"Mirage";

/// Posted on the main queue when the OSC handle's screen position updates;
/// the plugin returns this as its help-guide refresh notification.
extern NSNotificationName const kMirageOSCPositionNotification;

@class KKOSCGuideBridge;
/// The shared OSC-guide engine for this XPC process - the generic affine /
/// staleness / notification state behind the Mirage OSC guide. Hand this to
/// a KKJoyrideOSCSegment to build a guide for the Mirage point OSC.
extern KKOSCGuideBridge *MirageSharedOSCGuideBridge(void);

/// Sets the active OSC guide step (forwards to the shared bridge). Call from
/// any thread; the step notification is delivered on the main queue.
extern void MirageSetOSCGuideStep(NSInteger step);
/// YES while the Mirage OSC is actively being drawn (drawOSC fired within the
/// last ~15s) - i.e. the effect is selected in the FCP viewer. FCP gives no
/// deselect callback, so this is a staleness heuristic: idle and deselected
/// both stop drawOSC. NO before the first drawOSC or ~15s after deselect.
extern BOOL MirageHasCanvasReference(void);
/// Pushes the live Origin position (object [0,1] space) the guide drag is
/// writing so the OSC handle can track it from the drawOSC tick (the blob is
/// unreadable there).
extern void MirageSetGuidePosition(double objX, double objY);
/// The object-space Origin position the OSC guide's interactive drag targets.
extern CGPoint MirageGuideTargetObjectPosition(void);
/// Maps a screen point to the Origin position (object [0,1] space) under it,
/// via the bridge's cached viewer rect. Returns NO until that geometry is
/// available. Gives the guide drag the same 1:1 mapping a native Origin drag
/// uses.
extern BOOL MirageGuidePositionForScreenPoint(NSPoint screenPt, double *outX,
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
/// Image-well probe: a second texture source, bound to iChannel1 when filled.
/// In a Motion transition template this is meant to take "Drop Zone Transition
/// B", giving the shader both clips (effect clip = A, this = B).
static const UInt32 kParamToImage = 204;

/// The baked default Custom shader (animated cosine plasma). Rendered when the
/// Mirage lane's codeString is empty, and seeds the "Mirage" lane in the
/// catalog. Defined in Plugin+Render.
extern NSString *MirageCustomDefaultShaderSource(void);

/// The shipped Frame filter: crops the clip to a rounded window, then borders,
/// shadows and (with an audio source) pulses it. Masks with `#alpha` so the
/// corners are genuinely transparent.
extern NSString *MirageFrameShaderSource(void);
/// Frame's other sections: shared blur helper, then the two halves of the
/// separable glow blur. Buffer A is skipped so ch0 keeps the source clip.
extern NSString *MirageFrameCommonSource(void);
extern NSString *MirageFrameBufferBSource(void);
extern NSString *MirageFrameBufferCSource(void);
extern NSString *MirageFrameBufferDSource(void);
