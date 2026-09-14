/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

static NSString *const kPluginID = @"com.keyframeless.Canvas";

// v3 custom-UI / persistence params. The shared
// timeline blob uses the kit-owned ID (kKKParamTimelineData); motion blur,
// instance id and OSC params get added back as those features land.
static const UInt32 kParamInspectorUI = 200;
static const UInt32 kParamUIState = 201;
/// Hidden, never-read scratch param. The boundary-value popover writes a fresh
/// value here on open so FCP treats it as a real change and re-runs the render
/// for the (otherwise cached) static frame.
static const UInt32 kParamRenderNudge = 202;

/// Hidden, persisted base64 of the KKBezierPath layer blob (the layer list).
/// The Layers panel reads/writes this; render ignores it for now (passthrough).
/// NOTE: ID 210 was briefly registered as a *string* param during development;
/// FCP caches a parameter's type by ID, so a custom write to 210 was accepted
/// but never stored. Use a fresh ID that was only ever a custom (blob) param.
static const UInt32 kParamLayerData = 211;

NS_ASSUME_NONNULL_END
