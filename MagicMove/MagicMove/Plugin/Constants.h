/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

static NSString *const kPluginID = @"co.overpolish.keyframeless.MagicMove";

// v3 params - all animatable values live as lanes inside the timeline blob.
static const UInt32 kParamInspectorUI = 200;
static const UInt32 kParamUIState = 201;
/// Hidden scratch param the boundary-value popover writes on open so FCP
/// treats it as a real change and re-runs scheduleInputs for the static
/// frame, letting the boundary preview resolve without manual scrubbing.
static const UInt32 kParamRenderNudge = 202;

typedef struct {
  double x, y, rotation, rotationX, rotationY, scaleX, scaleY, opacity;
} MagicMovePointValues;
