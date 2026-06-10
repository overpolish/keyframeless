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

// M1 render fallbacks for every GlowPluginState field that isn't a lane yet.
// Shared by the render path and the mini-viewer preview so they stay in sync
// as later milestones promote these to real lanes / mode params.
static const float kGlowM1Radius = 100.0f; // px per axis; also the lane default
static const float kGlowM1Intensity = 1.0f; // matches pre-v3 default
static const float kGlowM1Falloff = 1.0f;   // = 1 + falloff(0); pre-v3 default
static const float kGlowM1Noise = 0.0f;
static const float kGlowM1NoiseOffset = 0.0f;
static const float kGlowM1NoiseSeed = 0.0f;
static const float kGlowM1Threshold = 0.0f; // 0 => bloom path is never hit
static const int kGlowM1ColorMode = 2; // shader: 2 = Dynamic (source-coloured)
static const int kGlowM1GradientType = 0;
static const float kGlowM1GradientAngle = 0.0f;
