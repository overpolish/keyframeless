/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKJoyrideController.h>
#import <KeyframelessKit/KKJoyrideLanesBinder.h>

@class KKTimingGuideConfig;

NS_ASSUME_NONNULL_BEGIN

/// Shared on-screen-control (OSC) visibility walkthrough. Teaches the OSC
/// workflow: edit in the viewer, hide controls individually via the gear's
/// per-element pills or by Option-clicking them, hide them all, and Option-peek
/// when they're off.
///
/// The hide/show controls live in the inspector (master checkbox, settings
/// gear, per-element pills) and are spotlit + advanced on the real user action.
/// The viewer interactions (drag a handle, Option-click, peek) happen in the
/// host viewer window the overlay can't drive, so they are narrated steps that
/// spotlight the viewer rect.
///
/// Needs `config.inspectorView` (the OSC hooks + anchors),
/// `config.viewerScreenRect` (the OSC bridge), and `config.oscKeepLabels` (the
/// featured element). It does not seed or touch the timeline.
@interface KKOSCGuide : NSObject

/// Builds the OSC steps and wires the inspector's OSC observation hooks to
/// advance the guide. The runner nils those hooks on completion.
+ (NSArray<KKJoyrideStep *> *)stepsForGuide:(KKJoyrideController *)guide
                                     binder:(KKJoyrideLanesBinder *)binder
                                     config:(KKTimingGuideConfig *)config;

@end

NS_ASSUME_NONNULL_END
