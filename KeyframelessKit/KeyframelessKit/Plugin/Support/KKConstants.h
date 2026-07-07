/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

/// Parameter ID reserved ranges shared across all plugins.
///
/// 1 – 8999   real (animatable) plugin parameters
/// 9000–9899  decorative UI parameters (info labels, separators)
/// 9900–9998  animation system parameters (added by KKPlugin)

static const UInt32 kKKParamAnimationSeparator __attribute__((unused)) = 9900;
static const UInt32 kKKParamTimingCurvePreview __attribute__((unused)) = 9905;
static const UInt32 kKKParamTimingExpanded __attribute__((unused)) = 9908;

/// Retired animation IDs - old saved projects may still carry values for
/// these but no current code reads or registers them. Do not reuse:
///   9901–9904, 9906, 9907, 9909–9917 (legacy 3-phase factor engine)
///   9918 (legacy always-on multi-stage gate)
///   9920, 9921 (legacy MultiStage Selected* int sliders - selection is
///               carried in the lanes JSON's `sel` field instead)
/// Multi-stage timing parameters:
static const UInt32 kKKParamMultiStageData __attribute__((unused)) = 9919;

/// Hidden per-instance UUID - keys the static per-instance state map so
/// multiple copies of a plugin on the same timeline don't share state.
static const UInt32 kKKParamInstanceID __attribute__((unused)) = 9922;

/// Persisted toggle for sequencer loop-playback. The actual render-path loop
/// check reads the mirror in KKPluginInstanceState.loopEnabled (populated
/// from this param on apply-state ticks) to avoid touching FxParameter APIs
/// from inside the render callback.
static const UInt32 kKKParamTimingLoopEnabled __attribute__((unused)) = 9923;

/// Timeline blob (KKTimeline JSON, KKDataBlob). Written by the sequencer;
/// read by the render path via `KKTimelineLaneValueAtFraction`.
static const UInt32 kKKParamTimelineData __attribute__((unused)) = 9931;

/// Native-string mirror of `kKKParamMultiStageData`. The blob is
/// unreadable from the OSC's apiManager (FxPlug XPC scope rule); native
/// strings DO read cold, so we mirror the same JSON here. Canonical
/// store stays the blob (preserves undo); the mirror is a write-through
/// cache kept in sync at every `KKWriteMultiStageJSONDeduped` tick and
/// refreshed on cmd-Z echo. Cold-boot OSC ticks seed `lanesSnapshot`
/// from this mirror so all existing snapshot consumers (oscVisible,
/// bezier path, etc.) just work without per-consumer plumbing.
static const UInt32 kKKParamMultiStageDataMirror __attribute__((unused)) = 9930;

/// Motion blur parameters (9924–9929). Registered by
/// `addMotionBlurParametersWithAPI:` as a custom group with an Enabled
/// checkbox; shutter/quality reveal when enabled.
static const UInt32 kKKParamMotionBlurSeparator __attribute__((unused)) = 9924;
static const UInt32 kKKParamMotionBlurEnabled __attribute__((unused)) = 9925;
static const UInt32 kKKParamMotionBlurShutter __attribute__((unused)) = 9926;
static const UInt32 kKKParamMotionBlurQuality __attribute__((unused)) = 9927;
static const UInt32 kKKParamMotionBlurExpanded __attribute__((unused)) = 9928;
static const UInt32 kKKParamMotionBlurTransitionsOnly __attribute__((unused)) =
    9929;

/// Custom-UI motion blur state (KKDataBlob, JSON
/// `{enabled,shutterAngle,samples}`). Replaces the native 9924–9929 group when
/// motion blur is edited from a custom-UI parameter row instead of native
/// controls. `shutterAngle` 0–360° sets the shutter window; `samples` 2–128 is
/// the explicit sample count. Read at render time via
/// `+[KKMotionBlur snapshotStateFromJSON:...]`.
static const UInt32 kKKParamMotionBlurData __attribute__((unused)) = 9932;

/// Color system parameters (9800–9810)
static const UInt32 kKKParamColorGroup __attribute__((unused)) = 9800;
static const UInt32 kKKParamColorMode __attribute__((unused)) = 9801;
static const UInt32 kKKParamColorSolid __attribute__((unused)) = 9802;
static const UInt32 kKKParamColorCustomUI __attribute__((unused)) = 9803;
static const UInt32 kKKParamColorExpanded __attribute__((unused)) = 9804;
static const UInt32 kKKParamGradientData __attribute__((unused)) = 9805;

typedef NS_ENUM(NSInteger, KKColorMode) {
  KKColorModeSolid = 0,
  KKColorModeGradient = 1,
  KKColorModeDynamic = 2,
};

static const UInt32 kKKParamLogoBanner __attribute__((unused)) = 9990;