/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

static NSString *const kPluginID = @"co.overpolish.keyframeless.Glow";

// v3 custom-UI / persistence params (mirrors Rounded). The shared timeline,
// motion-blur and instance-id blobs use the kit-owned IDs (kKKParam*).
static const UInt32 kParamInspectorUI = 200;
static const UInt32 kParamUIState = 201;
/// Hidden, never-read scratch param. The boundary-value popover writes a fresh
/// value here on open so FCP treats it as a real change and re-runs
/// -scheduleInputs: for the (otherwise cached) static frame.
static const UInt32 kParamRenderNudge = 202;

// Viewer on-screen-control part identifiers. M1 has the radius ring only; the
// Position offset arc (inherited KKArcOSC handle) lights up with the Position
// lane in a later milestone.
static const NSInteger kOSCRadiusPart = 100;

@class KKOSCGuideBridge;
/// The shared OSC-guide engine for this XPC process - the generic affine /
/// staleness / notification state behind Glow's radius-ring OSC guide. Hand
/// this to a KKJoyrideOSCSegment to build a guide for the ring OSC.
extern KKOSCGuideBridge *GlowSharedOSCGuideBridge(void);
/// Re-anchors the bridge's screen↔canvas map by pairing the given screen point
/// with the ring handle's current canvas position. Call on the press so the
/// drag uses a mapping that survived zoom-to-fit. No-op until drawOSC has run.
extern void GlowOSCCaptureGuideAnchorAtScreen(NSPoint screenPt);
/// Pushes the live [X, Y] radius the guide drag is writing so the ring can
/// track it from the drawOSC tick (the blob is unreadable there).
extern void GlowSetGuideRadiusValues(NSArray<NSNumber *> *values);
/// Maps a screen point to the [X, Y] radius that places the ring edge under it
/// (distance from centre through the ring mapping R = minDim*0.012*sqrt(val),
/// linked so both axes match). Falls back to the last guide radius until the
/// bridge has cached usable geometry.
extern NSArray<NSNumber *> *
GlowGuideRadiusValuesForScreenPoint(NSPoint screenPt);

/// Radius value (px per axis) the OSC guide targets during the interactive
/// drag step. Matches the Basic guide's primaryTargetValues; shared between
/// OSC.m and GlowInspectorView+BasicTimingGuide.m.
static const double kGlowOSCGuideTargetRadius = 250.0;

// M1 render fallbacks for every GlowPluginState field that isn't a lane yet.
// Shared by the render path and the mini-viewer preview so they stay in sync
// as later milestones promote these to real lanes / mode params.
static const float kGlowM1Radius = 100.0f; // px per axis; also the lane default
static const float kGlowM1Intensity = 1.0f; // matches pre-v3 default
static const float kGlowM1Falloff = 1.0f;   // = 1 + falloff(0); pre-v3 default
static const float kGlowM1Noise = 0.0f;
static const float kGlowM1NoiseOffset = 0.0f;
static const float kGlowM1NoiseSeed = 0.0f;
// Outward-flow rate (0-1). The shader's noiseSeed phase = time * speed * 5.
// Default 0 = static grain; raise Speed to make it drift outward.
static const float kGlowM1NoiseSpeed = 0.0f;
static const float kGlowM1Threshold = 0.0f; // 0 => bloom path is never hit
static const int kGlowM1ColorMode = 2; // shader: 2 = Dynamic (source-coloured)
static const int kGlowM1GradientType = 0;
static const float kGlowM1GradientAngle = 0.0f;
